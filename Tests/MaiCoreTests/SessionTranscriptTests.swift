import Testing
import Foundation
@testable import MaiCore

@Suite struct SessionTranscriptTests {
    @Test func policyGates() {
        typealias P = SessionTranscriptPolicy
        #expect(P.decide(enabled: false, noteTakingSaved: false, lineCount: 5, hasFolder: true) == .skipDisabled)
        #expect(P.decide(enabled: true, noteTakingSaved: true, lineCount: 5, hasFolder: true) == .skipNoteTakingSaved)
        #expect(P.decide(enabled: true, noteTakingSaved: false, lineCount: 0, hasFolder: true) == .skipEmpty)
        #expect(P.decide(enabled: true, noteTakingSaved: false, lineCount: 5, hasFolder: false) == .skipNoFolder)
        #expect(P.decide(enabled: true, noteTakingSaved: false, lineCount: 5, hasFolder: true) == .save)
        // A disabled feature reports being disabled, never a missing folder.
        #expect(P.decide(enabled: false, noteTakingSaved: false, lineCount: 5, hasFolder: false) == .skipDisabled)
    }

    @Test func namingSanitizesColons() {
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        let hhmm = DateFormatter(); hhmm.dateFormat = "HH:mm"
        #expect(SessionTranscriptNaming.title(startedAt: started) == "Session " + hhmm.string(from: started))
        let base = SessionTranscriptNaming.fileBase(startedAt: started)
        #expect(!base.contains(":"))
        #expect(base.contains("Session"))
    }

    @Test func collisionsWalkToTheNextFreeName() {
        #expect(SessionTranscriptNaming.uniqueFileName(base: "X", ext: ".md", exists: { _ in false }) == "X.md")
        #expect(SessionTranscriptNaming.uniqueFileName(base: "X", ext: ".md",
                                                       exists: { ["X.md", "X (2).md"].contains($0) }) == "X (3).md")
    }

    @Test func emptyDraftWritesNothing() throws {
        let dir = maiTempDir()
        let draft = SessionTranscriptDraft(lines: [], startedAt: Date(), endedAt: Date(),
                                           reason: .stopped, truncated: false)
        #expect(try SessionTranscriptWriter.save(draft: draft, to: dir) == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.isEmpty)
    }

    @Test func savesTranscriptAndIndexesIt() throws {
        let dir = maiTempDir()
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        let lines = [
            MeetingLine(speaker: "Sato", isUser: false, text: "来週の予定を確認しましょう。", timestamp: started, language: "ja"),
            MeetingLine(speaker: "You", isUser: true, text: "Sounds good.", timestamp: started.addingTimeInterval(3), language: "en")
        ]
        let draft = SessionTranscriptDraft(lines: lines, startedAt: started,
                                           endedAt: started.addingTimeInterval(60),
                                           reason: .rolledOver("idle"), truncated: false)
        let saved = try #require(try SessionTranscriptWriter.save(draft: draft, to: dir))
        #expect(saved.lineCount == 2)
        #expect(saved.fileName.hasSuffix(".md"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(saved.fileName).path))

        let index = MeetingIndexEntry.load(from: dir.appendingPathComponent("mai-meetings.json"))
        #expect(index.count == 1)
        #expect(index.first?.isTranscriptOnly == true)
        // A transcript has no .docx, so Open must target the .md.
        #expect(index.first?.openFileName == saved.fileName)

        // A second session in the same minute gets its own file rather than overwriting.
        let again = try #require(try SessionTranscriptWriter.save(draft: draft, to: dir))
        #expect(again.fileName != saved.fileName)
        #expect(MeetingIndexEntry.load(from: dir.appendingPathComponent("mai-meetings.json")).count == 2)
    }

    /// load() returns [] on ANY decode error, so a row it cannot read would wipe the
    /// user's whole saved list. Both directions have to decode.
    @Test func indexStaysCompatibleBothWays() throws {
        let dir = maiTempDir()
        let url = dir.appendingPathComponent("mai-meetings.json")

        let legacy = """
        [{"id":"old","title":"Legacy","date":"2026-08-01T10:00:00Z","docxFileName":"a.docx","markdownFileName":"a.md"}]
        """
        try Data(legacy.utf8).write(to: url)
        let old = MeetingIndexEntry.load(from: url)
        #expect(old.count == 1)
        #expect(old.first?.kind == nil)
        #expect(old.first?.isTranscriptOnly == false)

        let future = """
        [{"id":"new","title":"Newer","date":"2026-08-01T10:00:00Z","docxFileName":"a.docx","markdownFileName":"a.md","kind":"somethingNewer"}]
        """
        try Data(future.utf8).write(to: url)
        let newer = MeetingIndexEntry.load(from: url)
        #expect(newer.count == 1)
        #expect(newer.first?.isTranscriptOnly == false)
    }

    @Test func truncationIsStatedInTheFile() {
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        let line = MeetingLine(speaker: "A", isUser: false, text: "hello there", timestamp: started, language: "en")
        let note = SessionTranscript.truncationNote()
        let withNote = MarkdownTranscript.render(title: "T", lines: [line], startedAt: started,
                                                 endedAt: started, note: note)
        #expect(withNote.contains(note))
        // Existing callers pass no note and their output is unchanged.
        let without = MarkdownTranscript.render(title: "T", lines: [line], startedAt: started, endedAt: started)
        #expect(!without.contains(note))
    }

    @Test func statusWordingIsStable() {
        typealias S = SessionTranscriptStatus
        #expect(S.fragment(for: .saved(fileName: "a.md"), includeSetupHint: false) == "Saved session transcript: a.md")
        #expect(S.fragment(for: .skipped(.skipEmpty), includeSetupHint: false) == nil)
        #expect(S.fragment(for: .skipped(.skipNoteTakingSaved), includeSetupHint: false) == nil)
        #expect(S.fragment(for: .skipped(.skipDisabled), includeSetupHint: false) == nil)
        #expect(S.fragment(for: .skipped(.skipDisabled), includeSetupHint: true)?.contains("Settings") == true)
        #expect(S.fragment(for: .skipped(.skipNoFolder), includeSetupHint: false)?.contains("notes folder") == true)
        #expect(S.fragment(for: .failed("disk full"), includeSetupHint: false)?.contains("disk full") == true)
    }
}
