import Foundation

// The notes and summary pipeline, end to end. While note-taking is on, it
// accumulates finalized transcript lines plus any explicit "note this down" items.
// On stop it: writes up structured notes from the transcript, runs a SEPARATE
// verification pass that drops any bullet the transcript does not support (so the
// write-up never contains anything that was not said), generates a title, and saves
// a clean .docx (notes) and a timestamped .md (raw transcript) to the user-chosen
// folder, plus a complete export bundle for a later phase to pick up. An actor, so
// accumulation and the write-up never race.
public actor NotesStore {
    private var llm: LLMProvider
    private var model: String
    private var interface: Language
    // The notes pipeline sends the whole meeting transcript to the model, a separate
    // outbound surface from the engine's rolling context, so it redacts on its own. Its
    // placeholder numbering is independent of the engine's and does not need to match:
    // each subsystem redacts what it sends and rehydrates what it produces.
    private var redactor: PIIRedactor?

    private var active = false
    private var startedAt: Date?
    private var lines: [MeetingLine] = []
    private var noted: [String] = []

    public init(llm: LLMProvider, model: String, interface: Language, policy: PIIPolicy = .off) {
        self.llm = llm; self.model = model; self.interface = interface
        self.redactor = policy.isActive ? PIIRedactor(policy: policy) : nil
    }

    public func isActive() -> Bool { active }
    public func lineCount() -> Int { lines.count }
    public func notedCount() -> Int { noted.count }

    public func update(llm: LLMProvider, model: String, interface: Language, policy: PIIPolicy = .off) {
        self.llm = llm
        self.model = model
        self.interface = interface
        self.redactor = policy.isActive ? PIIRedactor(policy: policy) : nil
    }

    /// The transcript as it may be SENT. The saved meeting keeps the real text.
    private func outbound(_ lines: [MeetingLine]) -> [MeetingLine] {
        guard let redactor else { return lines }
        return lines.map {
            MeetingLine(speaker: redactor.redact($0.speaker), isUser: $0.isUser,
                        text: redactor.redact($0.text), timestamp: $0.timestamp, language: $0.language)
        }
    }

    private func outbound(_ items: [String]) -> [String] {
        guard let redactor else { return items }
        return items.map { redactor.redact($0) }
    }

    private func restored(_ notes: MeetingNotes) -> MeetingNotes {
        guard let redactor else { return notes }
        return MeetingNotes(summary: redactor.rehydrate(notes.summary),
                            sections: notes.sections.map {
                                MeetingNotes.Section(heading: redactor.rehydrate($0.heading),
                                                     bullets: $0.bullets.map { b in redactor.rehydrate(b) })
                            })
    }

    public func start(now: Date) {
        active = true; startedAt = now; lines.removeAll(); noted.removeAll()
    }

    public func add(_ line: MeetingLine) {
        guard active else { return }
        lines.append(line)
    }

    /// Fold a "note this down" item into the running notes. An empty item notes the
    /// most recent transcript line (the user pointing at "this").
    public func note(_ item: String) {
        guard active else { return }
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { noted.append(trimmed) }
        else if let last = lines.last { noted.append(last.text) }
    }

    public enum Stage: String, Sendable {
        case reviewing = "Reviewing the transcript"
        case verifying = "Checking the notes against what was said"
        case titling = "Generating a title"
        case saving = "Saving the meeting"
        case done = "Done"
    }

    public struct StopResult: Sendable, Equatable {
        public let export: MeetingExport?
        public let saveError: String?

        public init(export: MeetingExport?, saveError: String?) {
            self.export = export
            self.saveError = saveError
        }

        public var savedToDisk: Bool { export != nil && saveError == nil }
    }

    // Run the write-up pipeline. `onStage` reports the visible processing state.
    // Returns the export (also written to `folder` when provided), or nil if nothing
    // was captured.
    public func stop(now: Date, folder: URL?, extraNoted: [String] = [],
                     onStage: @Sendable (Stage) -> Void = { _ in }) async -> MeetingExport? {
        await stopWithResult(now: now, folder: folder, extraNoted: extraNoted, onStage: onStage).export
    }

    // Same pipeline as `stop`, but preserves a disk-write failure so the app can show
    // an honest status instead of claiming a meeting was saved when only the in-memory
    // export exists.
    public func stopWithResult(now: Date, folder: URL?, extraNoted: [String] = [],
                               onStage: @Sendable (Stage) -> Void = { _ in }) async -> StopResult {
        active = false
        let started = startedAt ?? now
        let captured = lines
        // Merge extra noted items (for example pinned cards the user marked) at the TOP,
        // before BOTH the write-up and the verification pass read the noted list, so the
        // card content is written in AND treated as supported (not dropped by verify).
        let notedItems = noted + extraNoted.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !captured.isEmpty || !notedItems.isEmpty else { return StopResult(export: nil, saveError: nil) }

        // Everything the model sees is redacted; everything saved to disk keeps the real
        // text, because the saved meeting is the user's own local record.
        let sendableLines = outbound(captured)
        let sendableNoted = outbound(notedItems)

        onStage(.reviewing)
        var notes = await writeUp(lines: sendableLines, noted: sendableNoted)

        onStage(.verifying)
        notes = await verify(notes: notes, lines: sendableLines, noted: sendableNoted)

        onStage(.titling)
        let rawTitle = await makeTitle(notes: notes, lines: sendableLines, now: now)

        notes = restored(notes)
        let title = redactor.map { $0.rehydrate(rawTitle) } ?? rawTitle

        onStage(.saving)
        let id = UUID().uuidString
        let base = Self.fileBase(title: title, date: started)
        let export = MeetingExport(id: id, title: title, startedAt: started, endedAt: now,
                                   notes: notes, notedItems: notedItems, transcript: captured,
                                   docxFileName: base + ".docx", markdownFileName: base + ".md")
        var saveError: String?
        if let folder {
            do {
                try save(export, to: folder)
            } catch {
                saveError = error.localizedDescription
            }
        }
        onStage(.done)
        return StopResult(export: export, saveError: saveError)
    }

    // MARK: - Pipeline stages

    private func writeUp(lines: [MeetingLine], noted: [String]) async -> MeetingNotes {
        let user = """
        Interface language: \(LookupRouter.name(interface))
        Transcript (lines marked "You" are the user's own speech):
        \(AssistantContext.transcriptContext(lines, maxChars: 16000))
        Explicitly noted items:
        \(noted.isEmpty ? "(none)" : noted.map { "- \($0)" }.joined(separator: "\n"))
        Produce the JSON now.
        """
        guard let raw = try? await llm.complete(system: Prompts.notesWriter, user: user, model: model),
              let obj = JSONExtract.decodeObject(raw) else {
            return MeetingNotes(summary: "", sections: [])
        }
        let summary = (obj["summary"] as? String) ?? ""
        var sections: [MeetingNotes.Section] = []
        if let arr = obj["sections"] as? [[String: Any]] {
            for s in arr {
                let heading = (s["heading"] as? String) ?? ""
                let bullets = (s["bullets"] as? [Any])?.compactMap { $0 as? String } ?? []
                if !heading.isEmpty && !bullets.isEmpty { sections.append(.init(heading: heading, bullets: bullets)) }
            }
        }
        return MeetingNotes(summary: summary, sections: sections)
    }

    // The verification pass: every bullet is checked against the transcript and the
    // unsupported ones are dropped. The summary is kept (it is an overview), but each
    // section keeps only supported bullets, and empty sections are removed.
    private func verify(notes: MeetingNotes, lines: [MeetingLine], noted: [String]) async -> MeetingNotes {
        var flat: [String] = []
        for s in notes.sections { flat.append(contentsOf: s.bullets) }
        guard !flat.isEmpty else { return notes }

        let numbered = flat.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let user = """
        Transcript:
        \(AssistantContext.transcriptContext(lines, maxChars: 16000))
        Explicitly noted items (treat these as supported):
        \(noted.isEmpty ? "(none)" : noted.map { "- \($0)" }.joined(separator: "\n"))
        Candidate bullets:
        \(numbered)
        Produce the JSON now.
        """
        var supported = Set(flat.indices)   // default: keep all if the verifier fails
        if let raw = try? await llm.complete(system: Prompts.notesVerify, user: user, model: model),
           let obj = JSONExtract.decodeObject(raw),
           let results = obj["results"] as? [[String: Any]] {
            supported = []
            for r in results {
                let idx = (r["index"] as? Int) ?? Int((r["index"] as? Double) ?? -1)
                let ok = (r["supported"] as? Bool) ?? false
                if ok, idx >= 0, idx < flat.count { supported.insert(idx) }
            }
        }
        // Rebuild sections keeping only supported bullets.
        var cursor = 0
        var kept: [MeetingNotes.Section] = []
        for s in notes.sections {
            var keptBullets: [String] = []
            for b in s.bullets {
                if supported.contains(cursor) { keptBullets.append(b) }
                cursor += 1
            }
            if !keptBullets.isEmpty { kept.append(.init(heading: s.heading, bullets: keptBullets)) }
        }
        return MeetingNotes(summary: notes.summary, sections: kept)
    }

    private func makeTitle(notes: MeetingNotes, lines: [MeetingLine], now: Date) async -> String {
        let user = """
        Interface language: \(LookupRouter.name(interface))
        Summary: \(notes.summary)
        First lines: \(lines.prefix(8).map { $0.text }.joined(separator: " | "))
        Produce the JSON now.
        """
        if let raw = try? await llm.complete(system: Prompts.notesTitle, user: user, model: model),
           let obj = JSONExtract.decodeObject(raw),
           let t = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return "Meeting \(fmt.string(from: now))"
    }

    // MARK: - Saving

    private func save(_ export: MeetingExport, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // 1. The notes as a clean .docx.
        var blocks: [DocxBlock] = []
        if !export.notes.summary.isEmpty {
            blocks.append(.heading1("Summary"))
            blocks.append(.paragraph(export.notes.summary))
        }
        for section in export.notes.sections {
            blocks.append(.heading1(section.heading))
            for b in section.bullets { blocks.append(.bullet(b)) }
        }
        if blocks.isEmpty { blocks.append(.paragraph("No transcript-supported notes were captured.")) }
        try DocxWriter.write(title: export.title, blocks: blocks,
                             to: folder.appendingPathComponent(export.docxFileName))

        // 2. The raw transcript as a timestamped .md.
        try MarkdownTranscript.write(title: export.title, lines: export.transcript,
                                     startedAt: export.startedAt, endedAt: export.endedAt,
                                     to: folder.appendingPathComponent(export.markdownFileName))

        // 3. The complete export bundle (phase-B handoff: a later phase picks this up).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let exportURL = folder.appendingPathComponent(Self.fileBase(title: export.title, date: export.startedAt) + ".mai.json")
        try encoder.encode(export).write(to: exportURL, options: .atomic)

        // 4. Update the saved-meetings index the app's notes view reads.
        try updateIndex(folder: folder, export: export)
    }

    private func updateIndex(folder: URL, export: MeetingExport) throws {
        try MeetingIndexEntry.upsert(
            MeetingIndexEntry(id: export.id, title: export.title, date: export.startedAt,
                              docxFileName: export.docxFileName, markdownFileName: export.markdownFileName),
            in: folder)
    }

    // A filesystem-safe "YYYY-MM-DD Title" base name.
    static func fileBase(title: String, date: Date) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let safe = title.unicodeScalars.map { s -> Character in
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
            return bad.contains(s) ? "-" : Character(s)
        }
        var name = String(safe).trimmingCharacters(in: .whitespaces)
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = "Meeting" }
        return "\(fmt.string(from: date)) \(name)"
    }
}

// One row in the saved-meetings index that the notes view lists.
public struct MeetingIndexEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let date: Date
    public let docxFileName: String
    public let markdownFileName: String
    /// What produced this row. Nil means full meeting notes (every row written before
    /// transcripts existed). Deliberately a plain String rather than an enum: `load`
    /// returns an empty array on ANY decode error, so an unknown future value in an enum
    /// would silently wipe the user's whole saved list. A String decodes anything and
    /// degrades to "treat as full notes".
    public let kind: String?

    public static let kindTranscript = "transcript"
    public var isTranscriptOnly: Bool { kind == Self.kindTranscript }
    /// The file "Open" should open. A transcript-only row has just the one file.
    public var openFileName: String { docxFileName.isEmpty ? markdownFileName : docxFileName }

    public init(id: String, title: String, date: Date, docxFileName: String,
                markdownFileName: String, kind: String? = nil) {
        self.id = id; self.title = title; self.date = date
        self.docxFileName = docxFileName; self.markdownFileName = markdownFileName
        self.kind = kind
    }

    public static func load(from url: URL) -> [MeetingIndexEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([MeetingIndexEntry].self, from: data)) ?? []
    }

    /// Insert or replace a row (newest first), keyed by id. Shared by the notes pipeline
    /// and the session-transcript writer so there is one index format with one writer.
    public static func upsert(_ entry: MeetingIndexEntry, in folder: URL) throws {
        let indexURL = folder.appendingPathComponent("mai-meetings.json")
        var entries = load(from: indexURL)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }
}
