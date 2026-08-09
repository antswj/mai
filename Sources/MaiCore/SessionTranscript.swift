import Foundation

// Saving a plain transcript when a session ends.
//
// A session's lines accumulate whether or not note-taking was on, but until now they
// were only ever written to disk by the note-taking pipeline. A session that ended
// without note-taking dropped its transcript silently at the next session start. This
// writes that transcript out, with no model call: no write-up, no verification pass, no
// title generation, just what was said.
//
// All decisions here are pure so the acceptance harness can cover them without a running
// app: whether to save, what to call the file, what the status line should say.

public enum SessionEndReason: Sendable, Equatable {
    case stopped
    case newSession
    case quit
    case rolledOver(String)
}

/// The transcript of one just-ended session, lifted out of the app model so a rollover
/// can clear the live state without losing the artifact.
public struct SessionTranscriptDraft: Sendable, Equatable {
    public let lines: [MeetingLine]
    public let startedAt: Date
    public let endedAt: Date
    public let reason: SessionEndReason
    public let truncated: Bool
    public var savedFileName: String?

    public init(lines: [MeetingLine], startedAt: Date, endedAt: Date,
                reason: SessionEndReason, truncated: Bool, savedFileName: String? = nil) {
        self.lines = lines; self.startedAt = startedAt; self.endedAt = endedAt
        self.reason = reason; self.truncated = truncated; self.savedFileName = savedFileName
    }
}

public enum SessionTranscript {
    /// The in-memory line cap for a session. Sessions run up to four hours by default, and
    /// at a realistic pace the old cap of 1000 silently truncated exactly the long meetings
    /// this feature exists to preserve. The cost of raising it is memory only, roughly one
    /// to one and a half megabytes for a full session, released when the session resets.
    public static let lineCap = 5_000

    public static func truncationNote(cap: Int = lineCap) -> String {
        "This session ran past \(cap) recorded lines, so the earliest lines are not included."
    }
}

public enum SessionTranscriptPolicy {
    public enum Decision: Sendable, Equatable {
        case save
        case skipDisabled
        case skipNoteTakingSaved
        case skipEmpty
        case skipNoFolder
    }

    /// Order is load-bearing. Disabled comes first so a feature the user turned off never
    /// nags about a missing folder, and note-taking comes before empty so the reason
    /// reported is the true one.
    public static func decide(enabled: Bool, noteTakingSaved: Bool,
                              lineCount: Int, hasFolder: Bool) -> Decision {
        if !enabled { return .skipDisabled }
        if noteTakingSaved { return .skipNoteTakingSaved }
        if lineCount == 0 { return .skipEmpty }
        if !hasFolder { return .skipNoFolder }
        return .save
    }
}

public enum SessionTranscriptNaming {
    /// The human title, which keeps its colon: "Session 14:05".
    public static func title(startedAt: Date) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        return "Session \(fmt.string(from: startedAt))"
    }

    /// The file base name. `NotesStore.fileBase` sanitizes the colon out, so the file reads
    /// "2026-08-09 Session 14-05" while the title shown in the app keeps "14:05".
    public static func fileBase(startedAt: Date) -> String {
        NotesStore.fileBase(title: title(startedAt: startedAt), date: startedAt)
    }

    /// Two sessions ending in the same minute would otherwise collide. `exists` is injected
    /// so the collision behavior is testable without touching the disk.
    public static func uniqueFileName(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = base + ext
        if !exists(first) { return first }
        for n in 2...99 {
            let candidate = "\(base) (\(n))\(ext)"
            if !exists(candidate) { return candidate }
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "\(base) \(fmt.string(from: Date()))\(ext)"
    }
}

public enum SessionTranscriptOutcome: Sendable, Equatable {
    case saved(fileName: String)
    case skipped(SessionTranscriptPolicy.Decision)
    case failed(String)
}

public enum SessionTranscriptStatus {
    /// The status fragment for an outcome, or nil when there is nothing worth saying. Kept
    /// separate from the writer so the wording is testable and cannot drift between the
    /// automatic and manual paths.
    public static func fragment(for outcome: SessionTranscriptOutcome,
                                includeSetupHint: Bool) -> String? {
        switch outcome {
        case .saved(let fileName):
            return "Saved session transcript: \(fileName)"
        case .failed(let error):
            return "Could not save the session transcript: \(error)"
        case .skipped(.skipNoFolder):
            return "Transcript not saved (choose a notes folder in Settings)."
        case .skipped(.skipDisabled):
            // Said once, the first time it would have mattered, then never again.
            return includeSetupHint
                ? "Transcript not saved. Turn on \"Save transcript when a session ends\" in Settings to keep it."
                : nil
        case .skipped(.skipEmpty), .skipped(.skipNoteTakingSaved):
            return nil
        case .skipped(.save):
            return nil   // not reachable: a decision to save is reported as .saved or .failed
        }
    }
}

public enum SessionTranscriptWriter {
    public struct Saved: Sendable, Equatable {
        public let id: String
        public let title: String
        public let fileName: String
        public let lineCount: Int
    }

    /// Write the transcript and add it to the saved-meetings index. Returns nil for empty
    /// input, with no file and no directory side effects.
    ///
    /// The folder is deliberately NOT created if it is missing (unlike the notes pipeline):
    /// this runs unattended at session end, and silently recreating a folder the user
    /// deleted, or writing into a stale bookmark target, is the wrong default. A missing
    /// folder surfaces as a save failure the user can see and act on.
    @discardableResult
    public static func save(draft: SessionTranscriptDraft, to folder: URL,
                            id: String = UUID().uuidString) throws -> Saved? {
        guard !draft.lines.isEmpty else { return nil }

        let title = SessionTranscriptNaming.title(startedAt: draft.startedAt)
        let base = SessionTranscriptNaming.fileBase(startedAt: draft.startedAt)
        let fm = FileManager.default
        let fileName = SessionTranscriptNaming.uniqueFileName(base: base, ext: ".md") { candidate in
            fm.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }

        try MarkdownTranscript.write(
            title: title, lines: draft.lines,
            startedAt: draft.startedAt, endedAt: draft.endedAt,
            note: draft.truncated ? SessionTranscript.truncationNote() : nil,
            to: folder.appendingPathComponent(fileName))

        // The transcript is on disk before the index is touched, so a failed index write
        // still leaves a readable file rather than losing the session.
        try MeetingIndexEntry.upsert(
            MeetingIndexEntry(id: id, title: title, date: draft.startedAt,
                              docxFileName: "", markdownFileName: fileName,
                              kind: MeetingIndexEntry.kindTranscript),
            in: folder)

        return Saved(id: id, title: title, fileName: fileName, lineCount: draft.lines.count)
    }
}
