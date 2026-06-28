import Testing
import Foundation
@testable import MaiCore

@Suite struct MemoryTests {

    @Test func allRecordKindsWrittenAndExported() async throws {
        let rig = try makeRig()
        // sushi line -> transcript + card + note
        await rig.engine.process(tline("ngl ちょっとお寿司を食べたい気分", speaker: "Lee"))
        // screen change -> screen record
        await rig.engine.process(sscreen("Slide 2: Q4 roadmap"))
        // on-demand summary -> summary record
        let summary = await rig.engine.summarize()
        #expect(summary != nil)
        await rig.engine.endSession()

        let data = try await rig.engine.exportSession()
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["session"] != nil)
        let records = (obj["records"] as? [[String: Any]]) ?? []
        let kinds = records.compactMap { $0["kind"] as? String }
        for required in ["transcript", "screen", "card", "note", "summary"] {
            #expect(kinds.contains(required), "export missing record kind: \(required)")
        }
        // Order within the first event: transcript before its card before its note.
        let iT = try #require(kinds.firstIndex(of: "transcript"))
        let iC = try #require(kinds.firstIndex(of: "card"))
        let iN = try #require(kinds.firstIndex(of: "note"))
        #expect(iT < iC)
        #expect(iC < iN)
        #expect(kinds.last == "summary", "summary is generated last")

        let session = obj["session"] as? [String: Any]
        #expect(session?["meetingMode"] as? Bool == true)
        #expect((session?["startedAt"] as? String) != nil)
        #expect((session?["endedAt"] as? String) != nil)
    }

    @Test func syncExportWrapperMatchesStore() async throws {
        let rig = try makeRig()
        await rig.engine.process(tline("i wanna make pudding but i wonder how", speaker: "Mia"))
        let sid = await rig.engine.sessionId
        let viaWrapper = try SyncExport(store: rig.store).exportSession(sid)
        let obj = try JSONSerialization.jsonObject(with: viaWrapper) as? [String: Any]
        let records = (obj?["records"] as? [[String: Any]]) ?? []
        #expect(records.contains { ($0["kind"] as? String) == "card" })
        #expect(records.contains { ($0["kind"] as? String) == "transcript" })
    }

    @Test func verbatimLogCaptured() async throws {
        let dir = maiTempDir()
        let store = try SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
        let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
        let engine = Engine(config: Config(), llm: StubLLM(), places: StubPlaces(),
                            location: FixedLocation(lat: 35.7016, lng: 139.9853),
                            store: store, verbatim: verbatim, face: ConsoleFace())
        await engine.process(tline("hello there", speaker: "A"))
        await engine.process(sscreen("Slide 1"))
        let text = (try? String(contentsOfFile: verbatim.path, encoding: .utf8)) ?? ""
        #expect(text.contains("\"type\":\"transcript\""))
        #expect(text.contains("\"type\":\"screen\""))
    }
}
