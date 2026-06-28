import Testing
import Foundation
@testable import MaiCore

// The seven canonical acceptance examples, driven end to end through the engine
// with StubLLM + StubPlaces (no live calls). Latency, the always-seeing screen
// behavior, and the dual-language prepared lines are all covered here.
@Suite struct EngineTests {

    // 1) Mixed-language nearest sushi -> a place info card with an open_in_maps action.
    @Test func example1_MixedLanguageSushi() async throws {
        let rig = try makeRig()
        await rig.engine.process(tline("ngl ちょっとお寿司を食べたい気分", speaker: "Lee"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.trigger == .place)
        #expect(card.title.lowercased().contains("sushi"))
        #expect(card.action?.kind == "open_in_maps")
        #expect(card.action?.params["url"]?.isEmpty == false, "maps URL must come from the lookup")
        #expect(card.body.contains("m away"), "distance should be computed and shown")
        #expect(card.latencyMs != nil, "latency must be recorded")
    }

    // 2) Always-seeing: ingest screen on change, no re-read while static, surface on cue.
    @Test func example2_AlwaysSeeingScreen() async throws {
        let rig = try makeRig()
        await rig.engine.process(sscreen("Slide 1: Q3 revenue overview"))
        #expect(rig.face.cards.isEmpty, "ingesting a screen read must not surface a card")
        await rig.engine.process(tline("数字は概ね順調です", speaker: "Sato"))
        #expect(rig.face.cards.isEmpty, "a non-screen line must not re-read or surface")
        await rig.engine.process(sscreen("Slide 2: Q4 roadmap and hiring plan"))
        #expect(rig.face.cards.isEmpty, "a screen change stores a fresh read, still no card")
        await rig.engine.process(tline("画面を見てください", speaker: "Sato"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.trigger == .screenReference)
        #expect(card.body.contains("Q4 roadmap"), "surfaces the current stored read")
        #expect(!card.body.contains("Q3"), "must not surface the stale slide")
    }

    // 3) Japanese prepared line with furigana + translation + attribution, meeting mode on.
    @Test func example3_JapanesePreparedLine() async throws {
        let rig = try makeRig(Config(floorLanguage: .ja, meetingMode: true))
        await rig.engine.process(tline("それでは、ご意見をお願いできますか？", speaker: "Sato"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.trigger == .reference)
        #expect(card.tier == .critical)
        #expect(card.body.contains("確認"), "floor line carries the kanji (plain; ruby in the UI)")
        let floor = card.body.components(separatedBy: "\n").first ?? ""
        #expect(Readings.units(floor, language: .ja).contains { $0.reading?.contains("かくにん") == true },
                "local furigana for 確認 is かくにん")
        #expect(card.body.contains("Understood"), "interface-language translation present")
        #expect(card.body.contains("Sato"), "who-said-what attribution")
        #expect(card.body.contains("Adjust as needed"), "teleprompter framing")
    }

    // 4) Chinese prepared line with pinyin, floor zh.
    @Test func example4_ChinesePreparedLine() async throws {
        let rig = try makeRig(Config(floorLanguage: .zh, meetingMode: true))
        await rig.engine.process(tline("你怎么看？请说一下你的想法。", speaker: "Wang"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.trigger == .reference)
        #expect(card.body.contains("确认"), "floor line carries the hanzi (plain; ruby in the UI)")
        let floor = card.body.components(separatedBy: "\n").first ?? ""
        #expect(Readings.units(floor, language: .zh).contains { $0.base == "确" && ($0.reading ?? "").hasPrefix("qu") },
                "local pinyin for 确 is què")
        #expect(card.body.contains("Wang"))
    }

    // 5) Delight fun fact, no action.
    @Test func example5_FunFact() async throws {
        let rig = try makeRig()
        await rig.engine.process(tline("i'm going to Malaysia next month", speaker: "Jon"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.trigger == .intent)
        #expect(card.action == nil, "fun facts carry no action")
        #expect(!card.body.isEmpty)
    }

    // 6) Recipe: ingredients + rough time, no fabricated link.
    @Test func example6_Recipe() async throws {
        let rig = try makeRig()
        await rig.engine.process(tline("i wanna make pudding but i wonder how", speaker: "Mia"))
        #expect(rig.face.cards.count == 1)
        let card = try #require(rig.face.cards.first)
        #expect(card.action == nil, "no fabricated link")
        #expect(card.body.lowercased().contains("ingredients") || card.body.lowercased().contains("min"))
    }

    // 7) Negative case: mundane lines surface nothing.
    @Test func example7_BoringLinesStayQuiet() async throws {
        let rig = try makeRig()
        for s in ["hey how was your weekend?",
                  "pretty chill, just relaxed at home.",
                  "haha let's figure it out later.",
                  "おはようございます。",
                  "なるほど、いい計画ですね。",
                  "ありがとうございます。"] {
            await rig.engine.process(tline(s))
        }
        #expect(rig.face.cards.isEmpty, "noise control failed: boring lines produced cards")
    }

    // Fixture replay: a scripted JA/EN meeting fires place + screen + prepared line.
    @Test func fixtureMeetingJaEn() async throws {
        let rig = try makeRig()
        await replayFixture("meeting_ja_en", into: rig.engine)
        let kinds = Set(rig.face.cards.map { $0.trigger })
        #expect(kinds.contains(.place))
        #expect(kinds.contains(.screenReference))
        #expect(kinds.contains(.reference))
        #expect(rig.face.cards.count == 3, "exactly the three trigger moments surface")
        for c in rig.face.cards { #expect(c.latencyMs != nil) }
    }

    @Test func fixtureCasualStaysMostlyQuiet() async throws {
        let rig = try makeRig()
        await replayFixture("casual", into: rig.engine)
        // sushi (place), Malaysia (fun fact), pudding (recipe) = 3; the rest are quiet.
        #expect(rig.face.cards.count == 3)
        #expect(rig.face.cards.filter { $0.action != nil }.count == 1, "only the place card has an action")
    }

    // The always-on entry point real capture will use: a merged stream of ears + eyes.
    @Test func alwaysOnMergedStream() async throws {
        let rig = try makeRig()
        let ears = SimulatedEars()
        let eyes = SimulatedEyes()
        let runTask = Task { await rig.engine.run(mergedStream(ears: ears, eyes: eyes)) }
        eyes.inject("Slide 7: launch checklist")
        try? await Task.sleep(nanoseconds: 80_000_000)
        ears.injectLine("画面を見てください", speaker: "Sato")
        var got = false
        for _ in 0..<200 {
            if !rig.face.cards.isEmpty { got = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(got, "card surfaced through the merged always-on stream")
        #expect(rig.face.cards.first?.body.contains("launch checklist") == true)
        ears.finish(); eyes.finish()
        _ = await runTask.value
    }

    // MARK: - helpers

    private func replayFixture(_ name: String, into engine: Engine) async {
        let text = Self.fixtureText(name)
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.hasPrefix("[SCREEN]") {
                let content = String(t.dropFirst("[SCREEN]".count)).trimmingCharacters(in: .whitespaces)
                await engine.process(sscreen(content))
            } else {
                let (speaker, body) = splitSpeaker(t)
                await engine.process(tline(body, speaker: speaker))
            }
        }
    }
    private func splitSpeaker(_ s: String) -> (String?, String) {
        if let colon = s.firstIndex(of: ":") {
            let name = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.count <= 24, !name.contains(" "), !rest.isEmpty { return (name, rest) }
        }
        return (nil, s)
    }
    static func fixtureText(_ name: String) -> String {
        if let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return (try? String(contentsOfFile: "Tests/MaiCoreTests/Fixtures/\(name).txt", encoding: .utf8)) ?? ""
    }
}
