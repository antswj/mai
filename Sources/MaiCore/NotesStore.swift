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
    private let llm: LLMProvider
    private let model: String
    private let interface: Language

    private var active = false
    private var startedAt: Date?
    private var lines: [MeetingLine] = []
    private var noted: [String] = []

    public init(llm: LLMProvider, model: String, interface: Language) {
        self.llm = llm; self.model = model; self.interface = interface
    }

    public func isActive() -> Bool { active }
    public func lineCount() -> Int { lines.count }
    public func notedCount() -> Int { noted.count }

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

    // Run the write-up pipeline. `onStage` reports the visible processing state.
    // Returns the export (also written to `folder` when provided), or nil if nothing
    // was captured.
    public func stop(now: Date, folder: URL?, onStage: @Sendable (Stage) -> Void = { _ in }) async -> MeetingExport? {
        active = false
        let started = startedAt ?? now
        let captured = lines
        let notedItems = noted
        guard !captured.isEmpty || !notedItems.isEmpty else { return nil }

        onStage(.reviewing)
        var notes = await writeUp(lines: captured, noted: notedItems)

        onStage(.verifying)
        notes = await verify(notes: notes, lines: captured, noted: notedItems)

        onStage(.titling)
        let title = await makeTitle(notes: notes, lines: captured, now: now)

        onStage(.saving)
        let id = UUID().uuidString
        let base = Self.fileBase(title: title, date: started)
        let export = MeetingExport(id: id, title: title, startedAt: started, endedAt: now,
                                   notes: notes, notedItems: notedItems, transcript: captured,
                                   docxFileName: base + ".docx", markdownFileName: base + ".md")
        if let folder { try? save(export, to: folder) }
        onStage(.done)
        return export
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
        let indexURL = folder.appendingPathComponent("mai-meetings.json")
        var entries = MeetingIndexEntry.load(from: indexURL)
        entries.removeAll { $0.id == export.id }
        entries.insert(MeetingIndexEntry(id: export.id, title: export.title, date: export.startedAt,
                                         docxFileName: export.docxFileName, markdownFileName: export.markdownFileName),
                       at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
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

    public static func load(from url: URL) -> [MeetingIndexEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([MeetingIndexEntry].self, from: data)) ?? []
    }
}
