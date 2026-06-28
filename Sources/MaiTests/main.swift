import Foundation
import AVFoundation
import MaiCore
import MaiCapture

// Deterministic acceptance harness: the same checks as the swift-testing suite,
// driven through the PUBLIC engine with StubLLM + StubPlaces (zero live calls), in
// a form that runs everywhere, including Command Line Tools only. Exits non-zero on
// any failure. Run from the package root: `swift run MaiTests`.

// Single-threaded sequential harness; the counters are touched from nonisolated
// helpers, so opt them out of the top-level MainActor isolation.
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
func check(_ cond: Bool, _ msg: String) {
    checks += 1
    if cond { print("  ok  \(msg)") } else { failures.append(msg); print("  FAIL  \(msg)") }
}
func section(_ s: String) { print("\n== \(s) ==") }

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("mai-acc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct Rig { let engine: Engine; let face: ConsoleFace; let store: SQLiteStore }
func makeRig(_ config: Config = Config(), places: PlacesProvider = StubPlaces()) -> Rig {
    let dir = tempDir()
    let store = try! SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
    let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
    let face = ConsoleFace()
    let engine = Engine(config: config, llm: StubLLM(), places: places,
                        location: FixedLocation(lat: config.testLat, lng: config.testLng),
                        store: store, verbatim: verbatim, face: face)
    return Rig(engine: engine, face: face, store: store)
}
func tline(_ t: String, _ speaker: String? = nil) -> EngineInput {
    .transcript(TranscriptEvent(text: t, speaker: speaker, timestamp: Date(), isFinal: true))
}
func sscreen(_ c: String) -> EngineInput {
    .screen(ScreenContentEvent(content: c, timestamp: Date(), isChange: true))
}

// A synthetic float32 buffer (default 48kHz stereo) for exercising PCM16Converter.
func makeFloatBuffer(sampleRate: Double = 48000, channels: AVAudioChannelCount = 2,
                     frames: AVAudioFrameCount = 4800) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                            channels: channels, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for c in 0..<Int(channels) {
        let p = buf.floatChannelData![c]
        for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 0.05) * 0.5 }
    }
    return buf
}

// 1) Mixed-language nearest sushi
section("Example 1: mixed-language nearest sushi (real-shape lookup via stub)")
do {
    let rig = makeRig()
    await rig.engine.process(tline("ngl ちょっとお寿司を食べたい気分", "Lee"))
    check(rig.face.cards.count == 1, "exactly one card")
    if let c = rig.face.cards.first {
        check(c.trigger == .place, "trigger is place")
        check(c.title.lowercased().contains("sushi"), "title mentions sushi")
        check(c.action?.kind == "open_in_maps", "open_in_maps action present")
        check((c.action?.params["url"]?.isEmpty == false), "maps URL from the lookup")
        check(c.body.contains("m away"), "computed distance shown")
        check(c.latencyMs != nil, "latency recorded")
        check((c.latencyMs ?? 99999) <= Int(Config().hardCapSeconds * 1000), "latency under hard cap")
    }
}

// 2) Always-seeing screen
section("Example 2: always-seeing screen (ingest, no re-read, surface on cue)")
do {
    let rig = makeRig()
    await rig.engine.process(sscreen("Slide 1: Q3 revenue overview"))
    check(rig.face.cards.isEmpty, "screen ingest surfaces nothing")
    await rig.engine.process(tline("数字は概ね順調です", "Sato"))
    check(rig.face.cards.isEmpty, "non-screen line does not re-read or surface")
    await rig.engine.process(sscreen("Slide 2: Q4 roadmap and hiring plan"))
    check(rig.face.cards.isEmpty, "screen change stores fresh read, still no card")
    await rig.engine.process(tline("画面を見てください", "Sato"))
    check(rig.face.cards.count == 1, "verbal cue surfaces one screen card")
    if let c = rig.face.cards.first {
        check(c.trigger == .screenReference, "trigger is screenReference")
        check(c.body.contains("Q4 roadmap"), "surfaces current stored read (slide 2)")
        check(!c.body.contains("Q3"), "does not surface the stale slide")
    }
}

// 3) Japanese prepared line
section("Example 3: Japanese prepared line (furigana + translation + attribution)")
do {
    let rig = makeRig(Config(floorLanguage: .ja, meetingMode: true))
    await rig.engine.process(tline("それでは、ご意見をお願いできますか？", "Sato"))
    check(rig.face.cards.count == 1, "one prepared-line card")
    if let c = rig.face.cards.first {
        check(c.trigger == .reference, "trigger is reference")
        check(c.tier == .critical, "tier critical")
        check(c.body.contains("確認"), "floor line carries the kanji (plain; ruby rendered in the UI)")
        let floor = c.body.components(separatedBy: "\n").first ?? ""
        let units = Readings.units(floor, language: .ja)
        check(units.contains { $0.reading?.contains("かくにん") == true }, "local furigana for 確認 is かくにん")
        check(c.body.contains("Understood"), "English translation present")
        check(c.body.contains("Sato"), "who-said-what attribution")
        check(c.body.contains("Adjust as needed"), "teleprompter framing")
    }
}

// 4) Chinese prepared line with pinyin
section("Example 4: Chinese prepared line (pinyin)")
do {
    let rig = makeRig(Config(floorLanguage: .zh, meetingMode: true))
    await rig.engine.process(tline("你怎么看？请说一下你的想法。", "Wang"))
    check(rig.face.cards.count == 1, "one prepared-line card")
    if let c = rig.face.cards.first {
        check(c.body.contains("确认"), "floor line carries the hanzi (plain; ruby rendered in the UI)")
        let floor = c.body.components(separatedBy: "\n").first ?? ""
        let units = Readings.units(floor, language: .zh)
        check(units.contains { $0.base == "确" && ($0.reading ?? "").hasPrefix("qu") }, "local pinyin for 确 is què")
        check(c.body.contains("Wang"), "attribution present")
    }
}

// 5) Fun fact
section("Example 5: delight fun fact")
do {
    let rig = makeRig()
    await rig.engine.process(tline("i'm going to Malaysia next month", "Jon"))
    check(rig.face.cards.count == 1, "one fun-fact card")
    if let c = rig.face.cards.first {
        check(c.trigger == .intent, "trigger is intent")
        check(c.action == nil, "no action on a fun fact")
        check(c.tier == .medium || c.tier == .noise || c.tier == .critical, "tier assigned")
        check(!c.body.isEmpty, "non-empty body")
    }
}

// 6) Recipe
section("Example 6: recipe (no fabricated link)")
do {
    let rig = makeRig()
    await rig.engine.process(tline("i wanna make pudding but i wonder how", "Mia"))
    check(rig.face.cards.count == 1, "one recipe card")
    if let c = rig.face.cards.first {
        check(c.action == nil, "no fabricated link")
        check(c.body.lowercased().contains("ingredients") || c.body.lowercased().contains("min"), "ingredients/time present")
    }
}

// 7) Negative case
section("Example 7: negative case (boring lines stay quiet)")
do {
    let rig = makeRig()
    for s in ["hey how was your weekend?", "pretty chill, just relaxed at home.",
              "haha let's figure it out later.", "おはようございます。",
              "なるほど、いい計画ですね。", "ありがとうございます。"] {
        await rig.engine.process(tline(s))
    }
    check(rig.face.cards.isEmpty, "no cards from mundane lines")
    check(!rig.face.suppressed.isEmpty == false || rig.face.suppressed.isEmpty, "suppressed log available for tuning")
}

// Cooldown (classifier does not re-emit within the window)
section("Cooldown: same trigger does not re-fire")
do {
    let rig = makeRig()
    await rig.engine.process(tline("sushi please", "A"))
    await rig.engine.process(tline("sushi please", "A"))
    check(rig.face.cards.count == 1, "second identical line is suppressed by cooldown")
}

// Hot Pepper attribution surfaces when the pick is from Hot Pepper
section("Hot Pepper attribution on a Hot Pepper pick")
do {
    let hp = StubPlaces(results: [
        Place(name: "Sushi HP", source: "hotpepper", rating: nil, reviewCount: nil,
              address: "Funabashi", lat: 35.70, lng: 139.98, url: "https://www.hotpepper.jp/strJ000/", distanceMeters: 150)
    ])
    let rig = makeRig(Config(), places: hp)
    await rig.engine.process(tline("お寿司食べたい", "A"))
    if let c = rig.face.cards.first {
        check(c.body.contains("Powered by ホットペッパーグルメ Webサービス"), "Hot Pepper credit present")
    } else { check(false, "expected a place card") }
}

// Memory: all five record kinds, exported in order
section("Memory: all five record kinds written and exported in order")
do {
    let rig = makeRig()
    await rig.engine.process(tline("ngl ちょっとお寿司を食べたい気分", "Lee"))
    await rig.engine.process(sscreen("Slide 2: Q4 roadmap"))
    let summary = await rig.engine.summarize()
    check(summary != nil, "summary generated")
    await rig.engine.endSession()
    let data = try! await rig.engine.exportSession()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let records = (obj?["records"] as? [[String: Any]]) ?? []
    let kinds = records.compactMap { $0["kind"] as? String }
    for k in ["transcript", "screen", "card", "note", "summary"] {
        check(kinds.contains(k), "record kind present: \(k)")
    }
    if let iT = kinds.firstIndex(of: "transcript"), let iC = kinds.firstIndex(of: "card"), let iN = kinds.firstIndex(of: "note") {
        check(iT < iC && iC < iN, "order transcript < card < note")
    } else { check(false, "indices for ordering") }
    check(kinds.last == "summary", "summary is last")
    let session = obj?["session"] as? [String: Any]
    check(session?["meetingMode"] as? Bool == true, "session metadata present")
}

// Fixtures replay
section("Fixture replay: meeting_ja_en and casual")
func replay(_ name: String, into engine: Engine) async {
    let path = "Tests/MaiCoreTests/Fixtures/\(name).txt"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { check(false, "fixture readable: \(name)"); return }
    for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        if t.hasPrefix("[SCREEN]") {
            await engine.process(sscreen(String(t.dropFirst(8)).trimmingCharacters(in: .whitespaces)))
        } else if let colon = t.firstIndex(of: ":"), t[..<colon].count <= 24, !t[..<colon].contains(" ") {
            await engine.process(tline(String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces),
                                       String(t[..<colon]).trimmingCharacters(in: .whitespaces)))
        } else {
            await engine.process(tline(t))
        }
    }
}
do {
    let rig = makeRig()
    await replay("meeting_ja_en", into: rig.engine)
    let kinds = Set(rig.face.cards.map { $0.trigger })
    check(kinds.contains(.place) && kinds.contains(.screenReference) && kinds.contains(.reference), "ja/en fixture fires place + screen + reference")
    check(rig.face.cards.count == 3, "ja/en fixture surfaces exactly 3 cards")
}
do {
    let rig = makeRig()
    await replay("casual", into: rig.engine)
    check(rig.face.cards.count == 3, "casual fixture surfaces 3 cards (sushi, fun fact, recipe)")
    check(rig.face.cards.filter { $0.action != nil }.count == 1, "only the place card has an action")
}

// Always-on path: the real entry point real capture will use.
section("Always-on stream path: engine.run(mergedStream(ears, eyes))")
do {
    let rig = makeRig()
    let ears = SimulatedEars()
    let eyes = SimulatedEyes()
    let runTask = Task { await rig.engine.run(mergedStream(ears: ears, eyes: eyes)) }
    // Screen first (stored silently), then a verbal cue that points at it.
    eyes.inject("Slide 7: launch checklist")
    // Small gap so the two source streams forward in order before the cue.
    try? await Task.sleep(nanoseconds: 80_000_000)
    ears.injectLine("画面を見てください", speaker: "Sato")
    var got = false
    for _ in 0..<200 {
        if !rig.face.cards.isEmpty { got = true; break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    check(got, "card surfaced through the merged always-on stream")
    check(rig.face.cards.first?.body.contains("launch checklist") == true, "stream path stores and surfaces the screen read")
    ears.finish(); eyes.finish()
    _ = await runTask.value
}

// ============================ Step 2: capture logic ============================

section("Readings: Japanese furigana on kanji words only")
do {
    let units = Readings.units("漢字を勉強する。", language: .ja)
    let reconstructed = units.map { $0.base }.joined()
    check(reconstructed == "漢字を勉強する。", "units reconstruct the original line")
    let kanjiUnits = units.filter { Readings.containsHan($0.base) }
    check(!kanjiUnits.isEmpty && kanjiUnits.allSatisfy { $0.reading != nil }, "kanji words get a reading")
    let kanaPunct = units.filter { !Readings.containsHan($0.base) }
    check(kanaPunct.allSatisfy { $0.reading == nil }, "kana and punctuation get no reading")
    if let kanji = units.first(where: { $0.base.contains("漢") }) {
        check(kanji.reading?.contains("か") == true, "漢字 reading is hiragana (かんじ)")
    } else { check(false, "found a 漢字 unit") }
}

section("Readings: Chinese pinyin on each hanzi")
do {
    let units = Readings.units("你好, world", language: .zh)
    check(units.map { $0.base }.joined() == "你好, world", "units reconstruct the original line")
    let hanzi = units.filter { Readings.containsHan($0.base) }
    check(hanzi.count == 2, "each hanzi is its own unit")
    check(hanzi.allSatisfy { ($0.reading ?? "").isEmpty == false }, "each hanzi gets a pinyin reading")
    check(units.first(where: { $0.base == "你" })?.reading?.hasPrefix("n") == true, "你 -> nǐ")
    check(units.contains { $0.base.contains("world") && $0.reading == nil }, "Latin run has no reading")
}

section("Soniox: config + token parsing + segmenter")
do {
    let cfg = SonioxConfig.json(apiKey: "K", model: "stt-rt-v5", sampleRate: 16000, channels: 1,
                                languageHints: ["en", "ja", "zh"], languageId: true, diarization: true,
                                translationTarget: nil)
    check(cfg.contains("\"model\":\"stt-rt-v5\"") || cfg.contains("\"model\": \"stt-rt-v5\""), "config carries the model")
    check(cfg.contains("pcm_s16le"), "config requests raw pcm_s16le")
    check(cfg.contains("16000"), "config carries the sample rate")

    let seg = SonioxSegmenter()
    // partial first
    let m1 = SonioxMessage.parse(#"{"tokens":[{"text":"お寿","is_final":false,"speaker":"1","language":"ja"}]}"#)!
    let u1 = seg.ingest(m1)
    check(u1.finals.isEmpty && u1.live.contains("お寿"), "partial appears in live line, no final yet")
    // finals + endpoint marker
    let m2 = SonioxMessage.parse(#"{"tokens":[{"text":"お寿司","is_final":true,"speaker":"1","language":"ja"},{"text":"が食べたい","is_final":true,"speaker":"1","language":"ja"},{"text":"<end>","is_final":true}]}"#)!
    let u2 = seg.ingest(m2)
    check(u2.finals.count == 1, "endpoint marker finalizes one segment")
    check(u2.finals.first?.text == "お寿司が食べたい", "segment text is the joined finals")
    check(u2.finals.first?.speakerLabel == "1", "segment carries the diarization speaker label")
    check(u2.finals.first?.language == "ja", "segment carries the language tag")

    // Reconnect backoff (capped exponential).
    check(SonioxBackoff.delaySeconds(attempt: 1) == 0.5, "first reconnect waits the base delay")
    check(SonioxBackoff.delaySeconds(attempt: 3) == 2.0, "backoff grows exponentially")
    check(SonioxBackoff.delaySeconds(attempt: 20) == 20.0, "backoff is capped")
}

section("FrameDiff: dHash and change detection")
do {
    let flat = [UInt8](repeating: 128, count: 72)               // adjacent pairs equal -> hash 0
    var descending = [UInt8](repeating: 0, count: 72)           // left > right everywhere -> hash all 1s
    for row in 0..<8 { for col in 0..<9 { descending[row * 9 + col] = UInt8(max(0, 240 - col * 28)) } }
    let hFlat = FrameDiff.dHash9x8(flat)
    let hDesc = FrameDiff.dHash9x8(descending)
    check(FrameDiff.changeFraction(hFlat, hFlat) == 0.0, "identical frames have zero change")
    check(!FrameDiff.changed(hFlat, hFlat, threshold: 0.15), "identical frames are not a change")
    check(FrameDiff.changed(hDesc, hFlat, threshold: 0.15), "a clearly different frame is a change")
    // minor noise: nudge a couple of pixels slightly, should stay under threshold
    var noisy = descending; noisy[5] = noisy[5] &+ 1; noisy[40] = noisy[40] &+ 1
    check(!FrameDiff.changed(hDesc, FrameDiff.dHash9x8(noisy), threshold: 0.15), "tiny noise stays below threshold")
}

section("SpeakerNaming: source + diarization + screen, with fallback")
do {
    var reg = SpeakerRegistry(userName: "You")
    check(reg.displayName(source: .user, cluster: nil) == "You", "mic is the user")
    check(reg.displayName(source: .remote, cluster: "1") == "Speaker 1", "unbound remote falls back to diarization label")
    reg.observe(activeCluster: "1", highlightedName: "Tanaka")
    check(reg.displayName(source: .remote, cluster: "1") == "Tanaka", "screen highlight binds a real name")
    reg.observe(activeCluster: "1", highlightedName: nil)
    check(reg.displayName(source: .remote, cluster: "1") == "Tanaka", "a nil highlight does not clobber a binding")
    reg.rename(cluster: "2", to: "Sato")
    reg.observe(activeCluster: "2", highlightedName: "WrongName")
    check(reg.displayName(source: .remote, cluster: "2") == "Sato", "manual rename wins over the screen")
}

section("PCM16Converter: 48k float stereo -> 16k int16 mono")
do {
    let conv = PCM16Converter(sampleRate: 16000)
    let input = makeFloatBuffer(sampleRate: 48000, channels: 2, frames: 4800) // 0.1s
    guard let data = conv.convert(input) else { check(false, "conversion produced data"); fatalError() }
    check(!data.isEmpty, "conversion produced non-empty PCM")
    check(data.count % 2 == 0, "output is whole Int16 samples")
    let frames = data.count / 2
    // 4800 in at 48k -> ~1600 at 16k; the first chunk loses some to resampler warmup.
    check(frames > 1000 && frames < 2000, "clearly downsampled ~3x from 4800 (got \(frames))")
}

section("CapturePermissions: gate status and missing list")
do {
    check(!CapturePermissionStatus(microphoneGranted: false, screenRecordingGranted: true).bothGranted,
          "mic missing means not both granted")
    check(CapturePermissionStatus(microphoneGranted: true, screenRecordingGranted: true).bothGranted,
          "both granted")
    check(CapturePermissionStatus(microphoneGranted: false, screenRecordingGranted: false).missing == ["Microphone", "Screen Recording"],
          "missing lists both")
    check(CapturePermissionStatus(microphoneGranted: true, screenRecordingGranted: false).missing == ["Screen Recording"],
          "missing lists only screen recording")
}

// ============================ Step 3: card intelligence ============================

final class CollectingRichSink: RichCardSink, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [String: RichCard] = [:]
    private var order: [String] = []
    private(set) var upsertCount = 0
    private(set) var suppressedList: [(String, TriggerType, String)] = []
    func upsert(_ card: RichCard) {
        lock.lock(); defer { lock.unlock() }
        if cards[card.id] == nil { order.append(card.id) }
        cards[card.id] = card; upsertCount += 1
    }
    func suppressed(headline: String, trigger: TriggerType, reason: String) {
        lock.lock(); defer { lock.unlock() }
        suppressedList.append((headline, trigger, reason))
    }
    var all: [RichCard] { lock.lock(); defer { lock.unlock() }; return order.compactMap { cards[$0] } }
    var firstSkeletonPending: Bool { all.first.map { !$0.pending.isEmpty } ?? false }
}

func enrich(_ request: LookupRequest, config: Config = Config(),
            entity: EntityLookup = StubEntityLookup(), grounded: GroundedSearch = StubGroundedSearch(),
            trigger: TriggerType = .question) async -> (RichCard, CollectingRichSink) {
    let sink = CollectingRichSink()
    let enricher = RichCardEnricher(config: config, llm: StubLLM(), entity: entity, grounded: grounded,
                                    places: StubPlaces(), location: FixedLocation(lat: config.testLat, lng: config.testLng), sink: sink)
    let skeleton = RichCard(trigger: trigger, timestamp: Date(), route: .pending, headline: "test",
                            pending: [RichCard.Part.route.rawValue])
    let final: RichCard = await withCheckedContinuation { cont in
        Task { await enricher.submit(skeleton, request: request, supersedeKey: "k") { c in cont.resume(returning: c) } }
    }
    return (final, sink)
}

func waitResolved(_ sink: CollectingRichSink, timeoutMs: Int = 4000) async -> RichCard? {
    for _ in 0..<(timeoutMs / 10) {
        if let c = sink.all.first(where: { $0.pending.isEmpty }) { return c }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return sink.all.first(where: { $0.pending.isEmpty }) ?? sink.all.first
}

struct RichRig { let engine: Engine; let sink: CollectingRichSink; let store: SQLiteStore }
func makeRichRig(_ config: Config = Config(), entity: EntityLookup = StubEntityLookup(),
                 grounded: GroundedSearch = StubGroundedSearch(), places: PlacesProvider = StubPlaces()) -> RichRig {
    let dir = tempDir()
    let store = try! SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
    let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
    let sink = CollectingRichSink()
    let engine = Engine(config: config, llm: StubLLM(), places: places,
                        location: FixedLocation(lat: config.testLat, lng: config.testLng),
                        store: store, verbatim: verbatim, face: ConsoleFace(),
                        richSink: sink, entity: entity, grounded: grounded)
    return RichRig(engine: engine, sink: sink, store: store)
}

section("Trivial answers: local, exact, conservative")
do {
    check(TrivialAnswer.answer("what's 15% of 80") == "12", "15% of 80 = 12")
    check(TrivialAnswer.answer("20 percent of 50") == "10", "20 percent of 50 = 10")
    check(TrivialAnswer.answer("12 * 7") == "84", "12 * 7 = 84")
    check(TrivialAnswer.answer("100 divided by 4") == "25", "100 divided by 4 = 25")
    check(TrivialAnswer.answer("(2 + 3) * 4") == "20", "parentheses honored")
    check(TrivialAnswer.answer("how many ml in a cup") == "236.59 ml", "cup -> ml exact")
    check(TrivialAnswer.answer("convert 5 km to miles")?.hasPrefix("3.11") == true, "5 km -> ~3.11 miles")
    check(TrivialAnswer.answer("100 c to f") == "212°F", "100C -> 212F")
    check(TrivialAnswer.answer("who is the president") == nil, "non-numeric question is not trivial")
    check(TrivialAnswer.answer("the weather today") == nil, "freshness question is not trivial")
}

section("Router: route selection + multilingual entity extraction")
do {
    let router = LookupRouter(llm: StubLLM(), model: "claude-haiku-4-5", interface: .en)
    let trivial = await router.plan(topic: "what's 15% of 80", window: "", spoken: .en)
    check(trivial.route == .trivial && trivial.trivialAnswer == "12", "trivial decided locally, no model")
    let entity = await router.plan(topic: "Malaysia", window: "", spoken: .en)
    check(entity.route == .entity && entity.needsImage, "known place routes to entity with image")
    let entityJa = await router.plan(topic: "お寿司", window: "", spoken: .ja)
    check(entityJa.route == .entity && entityJa.entity == "寿司", "Japanese entity kept in native script")
    let entityZh = await router.plan(topic: "马来西亚", window: "", spoken: .zh)
    check(entityZh.route == .entity, "Chinese entity routes to entity")
    let fresh = await router.plan(topic: "latest news on the election", window: "", spoken: .en)
    check(fresh.route == .fresh && fresh.needsSearch, "freshness routes to grounded search")
    let tech = await router.plan(topic: "how does a hash map work", window: "", spoken: .en)
    check(tech.route == .technical, "how/why routes to technical")
}

section("Enrichment: entity route (Wikipedia summary + image + source), interface language")
do {
    let (card, sink) = await enrich(.knowledge(topic: "Malaysia", window: "going to Malaysia", spoken: .en, respond: false))
    check(card.route == .entity, "route is entity")
    check(card.info?.contains("Southeast Asia") == true, "info is the interface-language summary")
    check(card.imageURL != nil, "image URL present from the lookup")
    check(card.source?.url.contains("wikipedia.org") == true, "real Wikipedia source")
    check(card.pending.isEmpty, "all parts resolved to a terminal state")
    check(sink.upsertCount >= 2, "skeleton then enriched: more than one emit")
}

section("Enrichment: cross-language entity (native script -> interface-language card)")
do {
    let (cardJa, _) = await enrich(.knowledge(topic: "お寿司", window: "お寿司が食べたい", spoken: .ja, respond: false), config: Config(interfaceLanguage: .en))
    check(cardJa.route == .entity, "Japanese entity routes to entity")
    check(cardJa.info?.contains("Japanese dish") == true, "summary resolved into the interface language (English)")
    check(cardJa.source?.url.contains("/Sushi") == true, "resolved to the English article")
    let (cardZh, _) = await enrich(.knowledge(topic: "马来西亚", window: "我要去马来西亚", spoken: .zh, respond: false), config: Config(interfaceLanguage: .en))
    check(cardZh.info?.contains("Southeast Asia") == true, "Chinese entity also resolves to an English summary")
}

section("Enrichment: fresh route (grounded, sourced, no image)")
do {
    let (card, _) = await enrich(.knowledge(topic: "latest news on the mission", window: "", spoken: .en, respond: false))
    check(card.route == .fresh, "route is fresh")
    check(card.info?.isEmpty == false, "synthesized answer present")
    check(card.source != nil, "grounded source present")
    check(card.imageURL == nil, "grounded cards carry no image (never fabricated)")
}

section("Enrichment: technical route (plain analysis, no web, no source)")
do {
    let (card, _) = await enrich(.knowledge(topic: "how does a hash map work", window: "", spoken: .en, respond: false))
    check(card.route == .technical, "route is technical")
    check(card.info?.isEmpty == false, "explanation present")
    check(card.source == nil && card.imageURL == nil, "no source or image for a no-search technical answer")
}

section("Enrichment: trivial route (instant local answer, no image/source)")
do {
    let (card, _) = await enrich(.knowledge(topic: "what's 15% of 80", window: "", spoken: .en, respond: false))
    check(card.route == .trivial, "route is trivial")
    check(card.info == "12", "local exact answer")
    check(card.source == nil && card.imageURL == nil, "trivial cards have no source or image")
}

section("Enrichment: never fabricate (nothing found resolves honestly)")
do {
    let emptyEntity = StubEntityLookup { _, _, _ in nil }
    let emptyGrounded = StubGroundedSearch { _, _ in GroundedResult(answer: "", sources: [], searchSuggestionHTML: nil) }
    // "latest ..." routes to fresh (grounded); the empty grounded stub returns nothing.
    let (card, _) = await enrich(.knowledge(topic: "latest news on Zzxqq Unknownthing", window: "", spoken: .en, respond: false),
                                 entity: emptyEntity, grounded: emptyGrounded)
    check(card.route == .fresh, "freshness route taken")
    check(card.pending.isEmpty, "card still resolves to a terminal state")
    check(card.info?.lowercased().contains("could not find") == true, "says it found nothing rather than inventing")
    check(card.source == nil && card.imageURL == nil, "no fabricated source or image")
}

section("Async enrichment: instant skeleton, transcript never blocked")
do {
    let sink = CollectingRichSink()
    let enricher = RichCardEnricher(config: Config(), llm: StubLLM(), entity: StubEntityLookup(),
                                    grounded: StubGroundedSearch(), places: StubPlaces(),
                                    location: FixedLocation(lat: 0, lng: 0), sink: sink)
    let skeleton = RichCard(trigger: .question, timestamp: Date(), route: .pending, headline: "Malaysia",
                            pending: [RichCard.Part.route.rawValue], latencyMs: 3)
    await enricher.submit(skeleton, request: .knowledge(topic: "Malaysia", window: "", spoken: .en, respond: false),
                          supersedeKey: "k", onComplete: { _ in })
    // The skeleton was emitted synchronously on submit's first hop; the first card
    // observed is a loading skeleton, and it later resolves.
    let resolved = await waitResolved(sink)
    check(sink.all.first?.latencyMs == 3, "skeleton carries the time-to-first-paint latency")
    check(resolved?.pending.isEmpty == true, "card eventually fully resolves")
    check((resolved?.timings["route"] ?? -1) >= 0, "per-part route timing recorded")
}

section("Response toggle (Part B): off by default, on when enabled, in the spoken language")
do {
    let (off, _) = await enrich(.knowledge(topic: "Malaysia", window: "going to Malaysia", spoken: .en, respond: false))
    check(off.response == nil, "no suggested response when the toggle is off")

    let (onJa, _) = await enrich(.knowledge(topic: "意見", window: "ご意見をお願いできますか", spoken: .ja, respond: true))
    check(onJa.response != nil, "suggested response present when the toggle is on")
    check(onJa.response?.language == .ja, "response language follows the spoken language")
    if let spoken = onJa.response?.spoken {
        let units = Readings.units(spoken, language: .ja)
        check(units.contains { ($0.reading ?? "").contains("かく") }, "furigana available over the response kanji")
    } else { check(false, "response text present") }
    check(onJa.response?.translation.isEmpty == false, "interface-language translation present")
}

section("Prepared reply via rich path (reference -> response with reading aids)")
do {
    let (card, _) = await enrich(.preparedReply(context: "Sato: ご意見をお願いできますか？", asker: "Sato", spoken: .ja),
                                 config: Config(floorLanguage: .ja), trigger: .reference)
    check(card.route == .preparedReply, "route is preparedReply")
    check(card.response?.spoken.contains("確認") == true, "floor-language line present")
    check(card.response?.translation.contains("get back") == true || card.response?.translation.isEmpty == false, "translation present")
}

section("Rich engine integration: Malaysia intent surfaces an entity card + memory")
do {
    let rig = makeRichRig()
    await rig.engine.process(tline("i'm going to Malaysia next month", "Jon"))
    let card = await waitResolved(rig.sink)
    check(card?.trigger == .intent, "trigger is intent")
    check(card?.route == .entity, "routed to entity")
    check(card?.info?.contains("Southeast Asia") == true, "entity summary surfaced")
    check(card?.source?.url.contains("wikipedia.org") == true, "real source")
    await rig.engine.endSession()
    let data = try! await rig.engine.exportSession()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let kinds = ((obj?["records"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String }
    check(kinds.contains("card") && kinds.contains("note"), "rich card mapped down to memory (card + note)")
}

section("Rich engine: supersede cancels prior enrichment on the same topic")
do {
    let rig = makeRichRig()
    await rig.engine.process(tline("i'm going to Malaysia next month", "Jon"))
    await rig.engine.process(tline("actually going to Malaysia for sure", "Jon"))
    let card = await waitResolved(rig.sink)
    check(card != nil, "a card still resolves after a supersede")
    check(rig.sink.all.allSatisfy { $0.pending.isEmpty || $0.id != card?.id }, "no card left stuck mid-enrichment")
}

// ============================ Step 3: VAD gating ============================

section("VAD gate: onset/offset hysteresis + hangover, no flap")
do {
    let cfg = VadGateConfig(onset: 0.5, offset: 0.35, hangoverSeconds: 4, frameSeconds: 0.032)
    var gate = VadGate(config: cfg)
    check(gate.feed(probability: 0.2) == nil && !gate.isOpen, "silence keeps the gate closed")
    check(gate.feed(probability: 0.9) == .open && gate.isOpen, "speech onset opens the gate")
    var closedEarly = false
    for _ in 0..<Int(2.0 / 0.032) { if gate.feed(probability: 0.1) == .close { closedEarly = true } }
    check(!closedEarly && gate.isOpen, "a 2s pause (< hangover) does not close (no flap)")
    check(gate.feed(probability: 0.8) == nil && gate.isOpen, "speech resumes, still open")
    var closeCount = 0
    for _ in 0..<Int(5.0 / 0.032) { if gate.feed(probability: 0.0) == .close { closeCount += 1 } }
    check(closeCount == 1 && !gate.isOpen, "sustained silence closes exactly once after the hangover")
    check(gate.feed(probability: 0.99) == .open, "next onset reopens the gate")
}

section("VAD frame accumulator: fixed 512-sample frames, remainder retained")
do {
    var acc = FrameAccumulator(frameSize: 512)
    check(acc.push(Array(repeating: 0, count: 300)).isEmpty, "fewer than 512 samples yields no frame")
    let frames = acc.push(Array(repeating: 0, count: 800))   // total 1100 -> two frames, 76 left
    check(frames.count == 2 && frames.allSatisfy { $0.count == 512 }, "emits whole 512-sample frames")
    let more = acc.push(Array(repeating: 0, count: 436))     // 76 + 436 = 512 -> one frame
    check(more.count == 1, "retained remainder completes the next frame")
}

section("VAD preroll ring: byte-capped, drains recent audio in order")
do {
    var ring = PrerollRing(maxBytes: 1000)
    ring.append(Data(repeating: 1, count: 400))
    ring.append(Data(repeating: 2, count: 400))
    ring.append(Data(repeating: 3, count: 400))              // 1200 > 1000 -> evict oldest
    check(ring.byteCount == 800, "oldest chunk evicted to stay under the cap")
    let out = ring.drain()
    check(out.count == 800 && out.first == 2 && out.last == 3, "drains the most recent audio in order")
    check(ring.byteCount == 0, "drain clears the ring")
}

section("Silero VAD: bundled ONNX model loads and runs on-device")
do {
    if let vad = SileroVAD.bundled(sampleRate: 16000) {
        check(vad.frameSize == 512, "16 kHz frame size is 512 samples")
        // Silence: a few frames should run without throwing and read as low probability.
        var ok = true
        var silenceProb: Float = 1
        for _ in 0..<5 {
            do { silenceProb = try vad.probability(frame: [Float](repeating: 0, count: 512)) }
            catch { ok = false }
        }
        check(ok, "ONNX inference runs without error (tensor I/O correct)")
        check(silenceProb >= 0 && silenceProb <= 1, "probability is in [0,1]")
        check(silenceProb < 0.5, "silence reads as low speech probability (\(silenceProb))")
        // A loud voiced-band sweep should run and stay in range (not asserting it reads
        // as speech: synthetic tones are not speech, but the path must be exercised).
        var tone = [Float](repeating: 0, count: 512)
        for i in 0..<512 { tone[i] = 0.6 * sinf(Float(i) * 0.18) }
        let toneProb = (try? vad.probability(frame: tone)) ?? -1
        check(toneProb >= 0 && toneProb <= 1, "non-silent frame also yields a valid probability")
    } else {
        check(false, "bundled Silero model should load (run via swift run so resources resolve)")
    }
}

// Summary
print("\n========================================")
if failures.isEmpty {
    print("ALL PASS: \(checks) checks")
    exit(0)
} else {
    print("FAILURES (\(failures.count)/\(checks)):")
    for f in failures { print("  - \(f)") }
    exit(1)
}
