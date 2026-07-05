import Testing
import Foundation
@testable import MaiCore

@Suite struct NotesStoreTests {
    @Test func stopWithResultReportsSaveFailure() async throws {
        let store = NotesStore(llm: StubLLM(), model: "claude-sonnet-4-6", interface: .en)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await store.start(now: t0)
        await store.add(MeetingLine(speaker: "Sato", isUser: false,
                                    text: "Let us finalize the launch checklist today.",
                                    timestamp: t0))

        let dir = maiTempDir()
        let notAFolder = dir.appendingPathComponent("not-a-folder")
        try Data("already a file".utf8).write(to: notAFolder)

        let result = await store.stopWithResult(now: t0.addingTimeInterval(60), folder: notAFolder)
        let export = try #require(result.export)
        #expect(export.title == "Team Sync Notes")
        #expect(result.saveError?.isEmpty == false)
        #expect(result.savedToDisk == false)
        #expect(!FileManager.default.fileExists(atPath: notAFolder.appendingPathComponent(export.docxFileName).path))
    }
}
