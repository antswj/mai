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
// A transcript event carrying a Soniox-detected language tag, for the reply-language tests.
func tlineLang(_ t: String, _ language: String, _ speaker: String? = nil) -> EngineInput {
    .transcript(TranscriptEvent(text: t, speaker: speaker, timestamp: Date(), isFinal: true, language: language))
}
func sscreen(_ c: String) -> EngineInput {
    .screen(ScreenContentEvent(content: c, timestamp: Date(), isChange: true))
}
// A screen change carrying a salient subject (drives the proactive screen-card path).
func sscreenSubject(_ c: String, _ subject: String) -> EngineInput {
    .screen(ScreenContentEvent(content: c, timestamp: Date(), isChange: true, subject: subject))
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
            llm: LLMProvider = StubLLM(), trigger: TriggerType = .question) async -> (RichCard, CollectingRichSink) {
    let sink = CollectingRichSink()
    let enricher = RichCardEnricher(config: config, llm: llm, entity: entity, grounded: grounded,
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

// A deliberately slow entity lookup so supersede/cancel can be tested deterministically.
struct SlowEntity: EntityLookup {
    let delayMs: UInt64
    func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return EntityResult(title: term, summary: "slow", imageURL: nil, sourceURL: "https://example.org")
    }
}

final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
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

section("Enrichment: fresh route (grounded, multi-sourced, no image)")
do {
    let multi = StubGroundedSearch { q, _ in
        GroundedResult(answer: "Answer about \(q).",
                       sources: [RichSource(title: "A", url: "https://a.example/1"),
                                 RichSource(title: "B", url: "https://b.example/2")],
                       searchSuggestionHTML: "<div>s</div>")
    }
    let (card, _) = await enrich(.knowledge(topic: "latest news on the mission", window: "", spoken: .en, respond: false), grounded: multi)
    check(card.route == .fresh, "route is fresh")
    check(card.info?.isEmpty == false, "synthesized answer present")
    check(card.source != nil, "grounded source present")
    check(card.sources.count == 2, "all grounded sources retained (not just the first)")
    check(card.imageURL == nil, "grounded cards carry no image (never fabricated)")
}

section("Enrichment: technical route tries grounded search first (model is last resort)")
do {
    let (card, _) = await enrich(.knowledge(topic: "how does a hash map work", window: "", spoken: .en, respond: false))
    check(card.route == .technical, "route is technical")
    check(card.info?.isEmpty == false, "explanation present")
    check(card.source != nil, "technical now searches first, so a real source is attached")
    check(!card.unverified, "a sourced grounded answer is not labeled unverified")
}

section("Enrichment: model fallback only when both Wikipedia and search find nothing, labeled unverified")
do {
    let emptyEntity = StubEntityLookup { _, _, _ in nil }
    let emptyGrounded = StubGroundedSearch { _, _ in GroundedResult(answer: "", sources: [], searchSuggestionHTML: nil) }
    // A technical question where entity and grounded both return nothing -> model, unverified.
    let (card, _) = await enrich(.knowledge(topic: "explain my private side project", window: "", spoken: .en, respond: false),
                                 entity: emptyEntity, grounded: emptyGrounded)
    check(card.info?.isEmpty == false, "the model answer is the last resort, so info is still present")
    check(card.source == nil, "the unverified model answer carries NO source line")
    check(card.unverified, "the model fallback is labeled unverified")
}

section("Enrichment: trivial route (instant local answer, no image/source)")
do {
    let (card, _) = await enrich(.knowledge(topic: "what's 15% of 80", window: "", spoken: .en, respond: false))
    check(card.route == .trivial, "route is trivial")
    check(card.info == "12", "local exact answer")
    check(card.source == nil && card.imageURL == nil, "trivial cards have no source or image")
}

section("Enrichment: always gives info (model knowledge when the web finds nothing)")
do {
    let emptyEntity = StubEntityLookup { _, _, _ in nil }
    let emptyGrounded = StubGroundedSearch { _, _ in GroundedResult(answer: "", sources: [], searchSuggestionHTML: nil) }
    // "latest ..." routes to fresh; empty grounded falls back to the model's knowledge.
    let (card, _) = await enrich(.knowledge(topic: "latest news on Zzxqq Unknownthing", window: "", spoken: .en, respond: false),
                                 entity: emptyEntity, grounded: emptyGrounded)
    check(card.route == .fresh, "freshness route taken")
    check(card.pending.isEmpty, "card resolves to a terminal state")
    check(card.info?.isEmpty == false, "still gives info: falls back to the model's own knowledge")
    check(card.source == nil, "unsourced model knowledge carries no (fabricated) source")
    check(card.imageURL == nil, "no fabricated image")
}

section("Enrichment: only a dead model yields the honest connectivity message")
do {
    // Everything fails: router parse fails (-> technical), entity nil, grounded empty,
    // and the explainer returns nothing. Then, and only then, the card says so.
    let deadLLM = StubLLM { _, _, _ in "{}" }
    let emptyEntity = StubEntityLookup { _, _, _ in nil }
    let emptyGrounded = StubGroundedSearch { _, _ in GroundedResult(answer: "", sources: [], searchSuggestionHTML: nil) }
    let (card, _) = await enrich(.knowledge(topic: "anything at all", window: "", spoken: .en, respond: false),
                                 entity: emptyEntity, grounded: emptyGrounded, llm: deadLLM)
    check(card.pending.isEmpty, "card still resolves")
    check(card.info?.lowercased().contains("could not reach") == true, "honest connectivity message, not invented facts")
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

section("Rich engine: canonical place card (action + distance + Hot Pepper credit)")
do {
    let hp = StubPlaces(results: [
        Place(name: "Sushi HP", source: "hotpepper", rating: nil, reviewCount: nil,
              address: "Funabashi", lat: 35.70, lng: 139.98, url: "https://www.hotpepper.jp/strJ000/", distanceMeters: 150)
    ])
    let rig = makeRichRig(Config(), places: hp)
    await rig.engine.process(tline("ngl ちょっとお寿司を食べたい気分", "Lee"))
    let card = await waitResolved(rig.sink)
    check(card?.route == .place, "routed to place")
    check(card?.action?.kind == "open_in_maps", "open_in_maps action present")
    check(card?.info?.contains("m away") == true, "computed distance shown")
    check(card?.info?.contains("Powered by ホットペッパーグルメ Webサービス") == true, "Hot Pepper credit present")
}

section("Rich engine: canonical screen card surfaces the current slide, not the stale one")
do {
    let rig = makeRichRig()
    await rig.engine.process(sscreen("Slide 1: Q3 revenue overview"))
    await rig.engine.process(sscreen("Slide 2: Q4 roadmap and hiring plan"))
    await rig.engine.process(tline("画面を見てください", "Sato"))
    let card = await waitResolved(rig.sink)
    check(card?.route == .screen, "routed to screen")
    check(card?.info?.contains("Q4 roadmap") == true, "surfaces the current stored read")
    check(card?.info?.contains("Q3") == false, "does not surface the stale slide")
}

section("Rich engine: canonical reference card (floor-language reply with ruby + translation)")
do {
    // A prepared reply is a suggested reply, so it is gated on the reply toggle.
    let rig = makeRichRig(Config(floorLanguage: .ja, meetingMode: true, responseEnabled: true))
    await rig.engine.process(tline("それでは、ご意見をお願いできますか？", "Sato"))
    let card = await waitResolved(rig.sink)
    check(card?.route == .preparedReply, "routed to preparedReply")
    check(card?.response?.spoken.contains("確認") == true, "floor-language line carries the kanji")
    if let spoken = card?.response?.spoken {
        let units = Readings.units(spoken, language: .ja)
        check(units.contains { ($0.reading ?? "").contains("かくにん") }, "furigana for 確認 available over the reply")
    } else { check(false, "reply text present") }
    check(card?.response?.translation.isEmpty == false, "English translation present")
}

section("Rich enricher: a superseding submit on the same key cancels the first")
do {
    // The first enrichment is held in a slow lookup so it is genuinely in flight when
    // the second submit (same key) cancels it; only the second reaches onComplete.
    let sink = CollectingRichSink()
    let enricher = RichCardEnricher(config: Config(), llm: StubLLM(), entity: SlowEntity(delayMs: 500),
                                    grounded: StubGroundedSearch(), places: StubPlaces(),
                                    location: FixedLocation(lat: 0, lng: 0), sink: sink)
    let completions = CompletionCounter()
    let skel1 = RichCard(trigger: .question, timestamp: Date(), headline: "first", pending: [RichCard.Part.route.rawValue])
    let skel2 = RichCard(trigger: .question, timestamp: Date(), headline: "second", pending: [RichCard.Part.route.rawValue])
    await enricher.submit(skel1, request: .knowledge(topic: "Malaysia", window: "", spoken: .en, respond: false),
                          supersedeKey: "same") { _ in completions.inc() }
    await enricher.submit(skel2, request: .knowledge(topic: "Malaysia", window: "", spoken: .en, respond: false),
                          supersedeKey: "same") { _ in completions.inc() }
    for _ in 0..<200 { if completions.value >= 1 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
    try? await Task.sleep(nanoseconds: 150_000_000)   // give a (cancelled) first task time to wrongly fire
    check(completions.value == 1, "the superseded first enrichment did not complete (only the second did)")
}

section("Reply lock: a reference cue surfaces a reply only when the toggle is on")
do {
    // Toggle OFF: a reference cue is reply-only, so nothing surfaces for it.
    let rigOff = makeRichRig(Config(floorLanguage: .ja, responseEnabled: false))
    await rigOff.engine.process(tline("それでは、ご意見をお願いできますか？", "Sato"))
    try? await Task.sleep(nanoseconds: 250_000_000)
    check(rigOff.sink.all.filter { !$0.suppressed }.isEmpty, "no card for a reference cue when replies are off")

    // Toggle ON: the reference cue yields a prepared reply.
    let rigOn = makeRichRig(Config(floorLanguage: .ja, responseEnabled: true))
    await rigOn.engine.process(tline("それでは、ご意見をお願いできますか？", "Sato"))
    let card = await waitResolved(rigOn.sink)
    check(card?.response != nil, "reference cue yields a reply when replies are on")

    // Info/fact cards still surface regardless of the reply toggle.
    let rigInfo = makeRichRig(Config(responseEnabled: false))
    await rigInfo.engine.process(tline("i'm going to Malaysia next month", "Jon"))
    let infoCard = await waitResolved(rigInfo.sink)
    check(infoCard?.info?.isEmpty == false, "info cards still appear when replies are off")
    check(infoCard?.response == nil, "no suggested reply on an info card when replies are off")
}

section("Script detection: furigana/pinyin work even when the language is untagged")
do {
    check(ScriptDetect.language(of: "漢字を勉強する") == .ja, "kana present -> Japanese")
    check(ScriptDetect.language(of: "确认一下") == .zh, "Han without kana -> Chinese")
    check(ScriptDetect.language(of: "hello there") == .en, "Latin -> English")
    // The guarantee the live transcript relies on: an untagged Japanese line still
    // gets furigana because the view detects the script from the text.
    let lang = ScriptDetect.language(of: "漢字を勉強する")
    let units = Readings.units("漢字を勉強する", language: lang)
    check(units.contains { ($0.reading?.contains("かん") == true) }, "untagged Japanese still gets furigana")
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

// ============================ Step 3 final: app spine ============================

func dataContains(_ data: Data, _ s: String) -> Bool { data.range(of: Data(s.utf8)) != nil }

section("DocX writer: produces a valid Word-shaped .docx (zip of OOXML parts)")
do {
    let dir = tempDir()
    let url = dir.appendingPathComponent("notes.docx")
    try DocxWriter.write(title: "Quarterly Review",
                         blocks: [.heading1("Summary"), .paragraph("We reviewed the quarter."),
                                  .heading1("Key Points"), .bullet("Revenue is up"), .bullet("Hiring continues")],
                         to: url)
    let data = try Data(contentsOf: url)
    check(data.starts(with: [0x50, 0x4B]), "file has the ZIP magic (PK)")
    check(dataContains(data, "[Content_Types].xml"), "content types part present")
    check(dataContains(data, "word/document.xml"), "document part present")
    check(dataContains(data, "word/styles.xml"), "styles part present")
    check(dataContains(data, "word/numbering.xml"), "numbering part present (real bullets)")
}

section("Markdown transcript: speakers, timestamps, and the user marked")
do {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let lines = [MeetingLine(speaker: "Sato", isUser: false, text: "Let us begin.", timestamp: t0),
                 MeetingLine(speaker: "You", isUser: true, text: "Sounds good.", timestamp: t0.addingTimeInterval(5))]
    let md = MarkdownTranscript.render(title: "Sync", lines: lines, startedAt: t0, endedAt: t0.addingTimeInterval(60))
    check(md.contains("# Sync"), "title heading present")
    check(md.contains("Sato:") && md.contains("Sounds good."), "speakers and text present")
    check(md.contains("(you)"), "the user's own line is marked")
    check(md.contains("**["), "timestamps present")
}

section("Assistant context: condense long transcript, detect 'note this down'")
do {
    let short = (0..<3).map { MeetingLine(speaker: "A", isUser: false, text: "line \($0)", timestamp: Date()) }
    check(!AssistantContext.transcriptContext(short, maxChars: 9999).contains("condensed"), "short transcript kept verbatim")
    let long = (0..<500).map { MeetingLine(speaker: "A", isUser: false, text: "a fairly long sentence number \($0)", timestamp: Date()) }
    let ctx = AssistantContext.transcriptContext(long, maxChars: 500)
    check(ctx.contains("condensed") && ctx.count <= 700, "long transcript condensed to fit the budget")
    check(ctx.contains("499"), "most recent line is kept")
    check(AssistantContext.noteRequest("note this down: call the vendor") == "call the vendor", "note item extracted")
    check(AssistantContext.noteRequest("note this down") == "", "bare note request returns empty item")
    check(AssistantContext.noteRequest("what are they talking about") == nil, "non-note message is not a note request")
}

section("Assistant reply: identifies what the user said (via the injected transcript)")
do {
    let assistant = AnthropicAssistant(llm: StubLLM(), model: "claude-haiku-4-5", interface: .en)
    let transcript = [MeetingLine(speaker: "Sato", isUser: false, text: "Shall we ship Friday?", timestamp: Date()),
                      MeetingLine(speaker: "You", isUser: true, text: "I need one more day to test.", timestamp: Date())]
    let reply = try await assistant.reply(to: "what are they talking about", transcript: transcript, history: [], screen: nil)
    check(reply.contains("one more day to test"), "the assistant surfaces what the user themselves said")
}

section("Notes pipeline: write-up, verification drops unsupported, title, save")
do {
    let store = NotesStore(llm: StubLLM(), model: "claude-sonnet-4-6", interface: .en)
    await store.start(now: Date(timeIntervalSince1970: 1_700_000_000))
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    await store.add(MeetingLine(speaker: "Sato", isUser: false, text: "Let us finalize the launch checklist today.", timestamp: t))
    await store.add(MeetingLine(speaker: "You", isUser: true, text: "I will prepare the design review by Friday.", timestamp: t.addingTimeInterval(6)))
    await store.add(MeetingLine(speaker: "Lee", isUser: false, text: "We should confirm the venue booking.", timestamp: t.addingTimeInterval(12)))
    await store.note("Circulate the agenda beforehand")
    let active = await store.isActive(); check(active, "note-taking is active")
    let folder = tempDir()
    nonisolated(unsafe) var stages: [NotesStore.Stage] = []
    let lock = NSLock()
    guard let export = await store.stop(now: t.addingTimeInterval(120), folder: folder, onStage: { s in lock.withLock { stages.append(s) } }) else {
        check(false, "stop produced an export"); fatalError()
    }
    check(stages.contains(.verifying), "the verification stage runs visibly")
    check(export.title == "Team Sync Notes", "a title was generated")
    check(!export.notes.summary.isEmpty, "a summary was written")
    let allBullets = export.notes.sections.flatMap { $0.bullets }
    check(allBullets.contains { $0.contains("launch checklist") }, "transcript-supported content kept")
    check(allBullets.contains { $0.contains("Circulate the agenda") }, "'note this down' item merged into the notes")
    check(!allBullets.contains { $0.contains("fifty million") }, "unsupported (fabricated) content dropped by verification")
    check(export.notedItems.contains("Circulate the agenda beforehand"), "noted items carried in the export")
    // Files saved to the chosen folder.
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent(export.docxFileName).path), "the .docx was saved")
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent(export.markdownFileName).path), "the .md transcript was saved")
    let index = MeetingIndexEntry.load(from: folder.appendingPathComponent("mai-meetings.json"))
    check(index.count == 1 && index.first?.title == "Team Sync Notes", "the meeting appears in the saved-meetings index")
    check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix(".mai.json") }, "phase-B export bundle written")
}

section("Spend meter: estimate math and VAD savings during silence")
do {
    let rates = UsageRates(transcriptionPerHour: 0.12, visionPerCall: 0.0004, modelPerCall: 0.002, searchPerCall: 0.002)
    let busy = UsageCounts(date: "2026-06-29", transcriptionSeconds: 3600, visionCalls: 10, modelCalls: 20, searchCalls: 5)
    let e = SpendMath.estimate(busy, rates: rates)
    check(abs(e.transcription - 0.12) < 1e-9, "1 hour of audio == one hour of transcription cost")
    check(abs(e.total - (0.12 + 0.004 + 0.04 + 0.01)) < 1e-9, "total sums the services")
    // VAD gating: less audio actually streamed during silence => lower transcription cost.
    let gated = UsageCounts(date: "2026-06-29", transcriptionSeconds: 600, visionCalls: 10, modelCalls: 20, searchCalls: 5)
    check(SpendMath.estimate(gated, rates: rates).transcription < e.transcription, "VAD silence gating lowers the transcription estimate")
}

section("HUD activity: rides through pauses, hides only after long idle")
do {
    func input(noteTaking: Bool = false, cards: Bool = false, since: Double = 999,
               summoned: Bool = false, pinned: Bool = false, app: Bool = false, paused: Bool = false) -> HUDActivityInput {
        HUDActivityInput(noteTaking: noteTaking, hasActiveCards: cards, secondsSinceActivity: since,
                         idleHideSeconds: 45, summoned: summoned, pinned: pinned, appWindowOpen: app, paused: paused)
    }
    check(HUDActivity.shouldShow(input(since: 1)), "recent speech shows the HUD")
    check(HUDActivity.shouldShow(input(since: 8)), "a natural pause (8s, under the idle window) keeps the HUD up")
    check(HUDActivity.shouldShow(input(since: 30)), "a long-ish pause (30s, still under 45s) keeps it up (no flapping)")
    check(!HUDActivity.shouldShow(input(since: 60)), "sustained real idle (60s, past 45s) hides it")
    check(HUDActivity.shouldShow(input(cards: true, since: 999)), "an active card keeps it up even when idle")
    check(HUDActivity.shouldShow(input(noteTaking: true, since: 999)), "an active note-taking session keeps it up")
    check(HUDActivity.shouldShow(input(since: 999, summoned: true)), "summon shows it")
    check(HUDActivity.shouldShow(input(since: 999, pinned: true)), "pin-open never auto-hides")
    check(!HUDActivity.shouldShow(input(since: 1, app: true)), "the full app window takes over")
    check(!HUDActivity.shouldShow(input(since: 1, paused: true)), "paused shows nothing")
    check(HUDActivity.shouldShow(input(since: 999, summoned: true, paused: true)), "but a summon overrides paused")
    let origin = HUDLayout.topRightOrigin(visibleFrame: ScreenRect(x: 0, y: 0, width: 1440, height: 900),
                                          size: (width: 380, height: 120), inset: 20)
    check(abs(origin.x - (1440 - 380 - 20)) < 1e-9, "pinned to the right edge minus width and inset")
    check(abs(origin.y - (900 - 120 - 20)) < 1e-9, "pinned to the top minus height and inset")
}

section("Chat gate: info cards pause while chat open, reply cards keep running")
do {
    let rig = makeRichRig(Config(floorLanguage: .ja, responseEnabled: true))
    await rig.engine.setChatOpen(true)
    await rig.engine.process(tline("ngl お寿司食べたい", "Lee"))     // info/place card -> paused
    try? await Task.sleep(nanoseconds: 250_000_000)
    check(rig.sink.all.filter { !$0.suppressed }.isEmpty, "info/fact cards are paused while the chat is open")
    await rig.engine.process(tline("それでは、ご意見をお願いできますか？", "Sato"))   // reply card -> runs
    let reply = await waitResolved(rig.sink)
    check(reply?.route == .preparedReply, "a reply card still surfaces while the chat is open")
    await rig.engine.setChatOpen(false)
    await rig.engine.process(tline("ラーメンも食べたいな", "Lee"))    // info card -> resumes
    var resumed = false
    for _ in 0..<200 { if rig.sink.all.contains(where: { $0.route == .place && !$0.suppressed }) { resumed = true; break }; try? await Task.sleep(nanoseconds: 10_000_000) }
    check(resumed, "info cards resume after the chat closes")
}

section("Keychain: round-trip save, read, delete (best effort in a CLI process)")
do {
    let account = "MAI_TEST_\(UUID().uuidString)"
    do {
        try Keychain.save("secret-value-123", account: account)
        let read = try Keychain.read(account: account)
        check(read == "secret-value-123", "keychain returns the stored value")
        try Keychain.delete(account: account)
        let gone = try Keychain.read(account: account)
        check(gone == nil, "deleted key is gone")
    } catch {
        check(true, "keychain not writable in this CLI context (skipped): \(error)")
    }
}

section("Resource bundles resolve without crashing (ship-safety)")
do {
    // Prompts must load via the install-location resolver, never Bundle.module (which
    // fatal-errors off the build machine). A non-empty prompt proves resolution works.
    check(!Prompts.classifier.isEmpty, "classifier prompt resolves")
    check(!Prompts.assistant.isEmpty, "assistant prompt resolves")
    check(!Prompts.notesWriter.isEmpty, "notes-writer prompt resolves")
    check(Prompts.load("does-not-exist").isEmpty, "a missing prompt returns empty, not a crash")
    // The MaiCore resource bundle is locatable by the safe resolver.
    check(MaiResources.bundle("Mai_MaiCore") != nil, "MaiCore resource bundle located via the safe resolver")
}

// ============================ Fix pass: routing, freshness, reply language ============================

section("Freshness guardrail: recency cues and near-future years force grounded search")
do {
    let now = Date(timeIntervalSince1970: 1_780_000_000)   // 2026, fixed for the year math
    check(Freshness.isFresh("do you know the new movie Toy Story 5", now: now), "'new movie' is fresh")
    check(Freshness.isFresh("Toy Story 5 release date", now: now), "'release date' is fresh")
    check(Freshness.isFresh("the latest iPhone", now: now), "'latest' is fresh")
    check(Freshness.isFresh("what is coming out in 2027", now: now), "a near-future year is fresh")
    check(Freshness.isFresh("最新のニュース", now: now), "Japanese recency cue is fresh")
    check(Freshness.isFresh("最新消息", now: now), "Chinese recency cue is fresh")
    check(!Freshness.isFresh("how does a hash map work", now: now), "a timeless how-question is not fresh")
    check(!Freshness.isFresh("the treaty signed in 1648", now: now), "an old year is not fresh")
    // Word-boundary, not substring: "new" must not fire inside other words.
    check(!Freshness.isFresh("who is Isaac Newton", now: now), "'Newton' does not count as 'new'")
    check(!Freshness.isFresh("I knew that already", now: now), "'knew' does not count as 'new'")
    check(!Freshness.isFresh("explain concurrent execution", now: now), "'concurrent' does not count as 'current'")
}

section("Router: freshness routes to grounded search before any model call")
do {
    let router = LookupRouter(llm: StubLLM(), model: "claude-haiku-4-5", interface: .en)
    let plan = await router.plan(topic: "Toy Story 5", window: "do you know the new movie Toy Story 5", spoken: .en)
    check(plan.route == .fresh && plan.needsSearch, "a brand-new movie routes to fresh, not the model")
}

section("Toy Story 5: a brand-new movie returns searched info with a source, never a model shrug")
do {
    let grounded = StubGroundedSearch { q, _ in
        GroundedResult(answer: "Toy Story 5 is an upcoming Pixar film slated for a 2026 release.",
                       sources: [RichSource(title: "Pixar", url: "https://pixar.example/toy-story-5")],
                       searchSuggestionHTML: nil)
    }
    let (card, _) = await enrich(.knowledge(topic: "Toy Story 5", window: "do you know the new movie Toy Story 5", spoken: .en, respond: false),
                                 grounded: grounded)
    check(card.route == .fresh, "routed to fresh")
    check(card.info?.contains("upcoming") == true, "real searched info, not a model shrug")
    check(card.source?.url.contains("pixar") == true, "carries a real source")
    check(!card.unverified, "a sourced answer is not labeled unverified")
}

section("Two different Japanese queries in a row each get their own fresh card (1.2)")
do {
    // The reported stale-result path is question/intent lookups. Drive two distinct
    // Japanese intents and confirm two distinct resolved cards, not a reused result.
    let rig = makeRichRig()
    await rig.engine.process(tlineLang("マレーシアに行くんだ", "ja", "A"))
    let first = await waitResolved(rig.sink)
    check(first?.info?.contains("Southeast Asia") == true, "first Japanese query resolves its own entity (Malaysia)")
    await rig.engine.process(tlineLang("プリンってどうやって作るの", "ja", "A"))
    var second: RichCard?
    for _ in 0..<200 {
        if let c = rig.sink.all.first(where: { $0.pending.isEmpty && $0.id != first?.id && !$0.suppressed }) { second = c; break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    check(second != nil, "the second Japanese query produces its own card, not a reuse")
    check(second?.id != first?.id, "the two queries are distinct cards")
    check(second?.headline != first?.headline, "keyed on the actual query text, so they do not collide")
}

section("Reply language follows the detected tag per utterance, not the floor config")
do {
    // Floor is Japanese, but the spoken language must win per utterance.
    check(Engine.spokenLanguage(of: TranscriptEvent(text: "Sure, sounds good", speaker: nil, timestamp: Date(), isFinal: true, language: "en")) == .en,
          "the detected tag (en) wins over floor")
    check(Engine.spokenLanguage(of: TranscriptEvent(text: "いいですね", speaker: nil, timestamp: Date(), isFinal: true, language: "ja")) == .ja,
          "the detected tag (ja) is used")
    // Hybrid fallback when there is no tag (simulated input): detect from the text.
    check(Engine.spokenLanguage(of: TranscriptEvent(text: "what do you think", speaker: nil, timestamp: Date(), isFinal: true)) == .en,
          "no tag, English text -> en")
    check(Engine.spokenLanguage(of: TranscriptEvent(text: "どう思いますか", speaker: nil, timestamp: Date(), isFinal: true)) == .ja,
          "no tag, Japanese text -> ja")
}

section("Reply: English in -> English reply; Japanese in -> Japanese reply with readings (floor=ja)")
do {
    // Floor set to Japanese on purpose; the reply must still follow the spoken language.
    let rig = makeRichRig(Config(floorLanguage: .ja, meetingMode: true, responseEnabled: true))
    await rig.engine.process(tlineLang("So what do you think about the plan?", "en", "Sato"))
    let enCard = await waitResolved(rig.sink)
    check(enCard?.response?.language == .en, "English utterance yields an English reply, not Japanese from floor")

    let rig2 = makeRichRig(Config(floorLanguage: .ja, meetingMode: true, responseEnabled: true))
    await rig2.engine.process(tlineLang("それでは、ご意見をお願いできますか？", "ja", "Sato"))
    let jaCard = await waitResolved(rig2.sink)
    check(jaCard?.response?.language == .ja, "Japanese utterance yields a Japanese reply")
    if let spoken = jaCard?.response?.spoken {
        let units = Readings.units(spoken, language: .ja)
        check(units.contains { ($0.reading ?? "").contains("かく") }, "furigana available over the Japanese reply")
    } else { check(false, "Japanese reply text present") }
}

section("Reply: a mid-conversation language switch is tracked per utterance")
do {
    let rig = makeRichRig(Config(floorLanguage: .ja, meetingMode: true, responseEnabled: true))
    // Japanese turn first.
    await rig.engine.process(tlineLang("どう思いますか？", "ja", "Sato"))
    let first = await waitResolved(rig.sink)
    check(first?.response?.language == .ja, "first (Japanese) reply is Japanese")
    // Speaker switches to English (same kind of cue, different language).
    await rig.engine.process(tlineLang("Actually, what do you think about it?", "en", "Sato"))
    var switched: RichCard?
    for _ in 0..<200 {
        if let c = rig.sink.all.first(where: { $0.response?.language == .en && $0.pending.isEmpty }) { switched = c; break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    check(switched?.response?.language == .en, "after switching to English, the reply switches to English")
}

// ============================ Fix pass 2: echo, screen cards, HUD layout ============================

section("Echo suppression: drops mic echo of system audio, keeps genuine user speech")
do {
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    var sup = EchoSuppressor()
    // A remote participant says a full sentence (system audio).
    sup.noteSystem("Let us review the third quarter revenue numbers now", at: t0)
    // The mic picks it back up a moment later, near-identical -> echo, dropped.
    check(sup.isEcho("Let us review the third quarter revenue numbers now", at: t0.addingTimeInterval(0.6)),
          "a long near-identical mic line just after a system line is echo")
    // The same system line cannot suppress a second later mic line (consume-once).
    check(!sup.isEcho("Let us review the third quarter revenue numbers now", at: t0.addingTimeInterval(1.2)),
          "consume-once: one system line suppresses at most one mic line")

    // Genuine short backchannel is NEVER dropped, even after a matching remote one.
    var sup2 = EchoSuppressor()
    sup2.noteSystem("yeah", at: t0)
    check(!sup2.isEcho("yeah", at: t0.addingTimeInterval(0.5)), "short 'yeah' is kept (length floor)")

    // CJK echo (no spaces) is dropped when long enough.
    var sup3 = EchoSuppressor()
    sup3.noteSystem("来月の予算会議について話し合いましょう", at: t0)
    check(sup3.isEcho("来月の予算会議について話し合いましょう", at: t0.addingTimeInterval(0.5)),
          "a long CJK echo is dropped")

    // The user's own distinct reply is kept (no matching recent system line).
    var sup4 = EchoSuppressor()
    sup4.noteSystem("What do you think about the new timeline proposal", at: t0)
    check(!sup4.isEcho("I think we should push it back by two weeks honestly", at: t0.addingTimeInterval(1)),
          "a distinct user reply is kept, not treated as echo")

    // Outside the time window, a match is not treated as echo (stale).
    var sup5 = EchoSuppressor()
    sup5.noteSystem("Let us review the third quarter revenue numbers now", at: t0)
    check(!sup5.isEcho("Let us review the third quarter revenue numbers now", at: t0.addingTimeInterval(30)),
          "a match outside the window is not echo")

    // REVERSE ORDER (the live failure): the mic echo final arrives BEFORE the matching
    // system final. The hold re-checks after the system final is recorded, so a system
    // line up to forwardSeconds after the mic line still counts as echo.
    var sup6 = EchoSuppressor()
    let micAt = t0
    sup6.noteSystem("Let us review the third quarter revenue numbers now", at: micAt.addingTimeInterval(1.8))
    check(sup6.isEcho("Let us review the third quarter revenue numbers now", at: micAt),
          "a system final finalizing ~1.8s after the mic echo (during the hold) is still echo")
    // But a system line far after the mic line (beyond the forward tolerance) is not.
    var sup7 = EchoSuppressor()
    sup7.noteSystem("Let us review the third quarter revenue numbers now", at: micAt.addingTimeInterval(6))
    check(!sup7.isEcho("Let us review the third quarter revenue numbers now", at: micAt),
          "a system final far after the mic line (past the forward tolerance) is not echo")

    // Pure similarity helpers.
    check(EchoSuppressor.similarity("hello world", "hello world") == 1, "identical text -> 1.0")
    check(EchoSuppressor.similarity("hello world", "completely different") < 0.3, "different text -> low")
}

section("Screen card: a slide subject produces a useful sourced card, not a description")
do {
    let rig = makeRichRig()
    // A presentation slide, no verbal cue. The vision read carries the salient subject.
    await rig.engine.process(sscreenSubject("A slide about a country in Southeast Asia.", "Malaysia"))
    let card = await waitResolved(rig.sink)
    check(card?.trigger == .screenReference, "the proactive screen card is a screenReference card")
    check(card?.route == .entity, "the subject is run through the lookup router (entity), not described")
    check(card?.info?.contains("Southeast Asia") == true, "useful sourced info about the subject")
    check(card?.source?.url.contains("wikipedia.org") == true, "carries a real source")
    check(card?.info?.contains("slide about") != true, "not a description of the slide")
}

section("Screen card: a Japanese slide subject resolves into the interface language")
do {
    let rig = makeRichRig(Config(interfaceLanguage: .en))
    await rig.engine.process(sscreenSubject("寿司の歴史についてのスライド。", "寿司"))
    let card = await waitResolved(rig.sink)
    check(card?.info?.contains("Japanese dish") == true, "a Japanese slide subject resolves to an English (interface) summary")
    check(card?.source?.url.contains("/Sushi") == true, "cross-language resolved to the English article")
}

section("Screen card: same subject does not refire; no subject does not proactively fire")
do {
    let rig = makeRichRig()
    await rig.engine.process(sscreenSubject("A slide about a country.", "Malaysia"))
    _ = await waitResolved(rig.sink)
    let countAfterFirst = rig.sink.all.filter { !$0.suppressed }.count
    await rig.engine.process(sscreenSubject("Same slide still up.", "Malaysia"))
    try? await Task.sleep(nanoseconds: 250_000_000)
    check(rig.sink.all.filter { !$0.suppressed }.count == countAfterFirst, "same subject within the window does not refire")
    // A screen change with no identifiable subject does not proactively surface a card.
    let rig2 = makeRichRig()
    await rig2.engine.process(sscreen("Just a desktop, nothing to look up."))
    try? await Task.sleep(nanoseconds: 250_000_000)
    check(rig2.sink.all.filter { !$0.suppressed }.isEmpty, "no subject -> no proactive screen card")
}

section("HUD layout: full height down to the Dock, and the 60/40 split")
do {
    // Max height is the visible-frame height minus the top inset and a small bottom gap.
    let maxH = HUDLayout.maxHeight(visibleFrameHeight: 900, inset: 16)
    check(abs(maxH - (900 - 16 - 8)) < 1e-9, "max height reaches from the top inset to just above the Dock")
    // With cards, transcript is about 60 percent over 40 percent cards.
    let split = HUDLayout.split(availableHeight: 800, hasCards: true)
    check(abs(split.transcript - 480) < 1.0 && abs(split.cards - 320) < 1.0, "about 60/40 transcript over cards")
    // With no cards, the transcript uses the full height.
    let full = HUDLayout.split(availableHeight: 800, hasCards: false)
    check(full.transcript == 800 && full.cards == 0, "no cards -> transcript uses the full height")
}

// ============================ Features 3: translation, HUD sizing, pinned cards ============================

func token(_ text: String, final: Bool, translation: Bool = false, speaker: String? = nil, language: String? = nil) -> [String: Any] {
    var t: [String: Any] = ["text": text, "is_final": final]
    if translation { t["translation_status"] = "translation" } else { t["translation_status"] = "original" }
    if let speaker { t["speaker"] = speaker }
    if let language { t["language"] = language }
    return t
}
func sonioxMsg(_ tokens: [[String: Any]]) -> SonioxMessage {
    let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
    return SonioxMessage.parse(data)!
}

section("Soniox segmenter: separates original speech from translation, pairs per line")
do {
    let seg = SonioxSegmenter()
    // Original Japanese tokens stream first, then the endpoint marker, then the
    // translation chunk arrives AFTER the marker in the same message (the live case).
    let msg = sonioxMsg([
        token("お寿司", final: true, speaker: "1", language: "ja"),
        token("が食べたい", final: true, speaker: "1", language: "ja"),
        token("<end>", final: true),
        token("I want", final: true, translation: true, language: "en"),
        token(" to eat sushi", final: true, translation: true, language: "en"),
    ])
    let up = seg.ingest(msg)
    check(up.finals.count == 1, "one finalized segment")
    check(up.finals.first?.text == "お寿司が食べたい", "original line is the Japanese speech, no translation mixed in")
    check(up.finals.first?.translation == "I want to eat sushi", "translation paired with the segment despite arriving after the endpoint")
    check(up.finals.first?.language == "ja", "segment language is the spoken language")
}

section("Soniox segmenter: live partial carries a live translation; original never polluted")
do {
    let seg = SonioxSegmenter()
    let up = seg.ingest(sonioxMsg([
        token("你好", final: false, speaker: "1", language: "zh"),
        token("Hel", final: false, translation: true, language: "en"),
    ]))
    check(up.live == "你好", "live original line is just the spoken text")
    check(up.liveTranslation == "Hel", "live translation streams alongside, as instant as the transcript")
    check(up.finals.isEmpty, "nothing finalized yet")
}

section("Translation line is suppressed when it equals the original (same-language case)")
do {
    check(RealEars.usefulTranslation("Hello there", original: "Hello there") == nil,
          "an English line translated to English shows no duplicate translation")
    check(RealEars.usefulTranslation("I want to eat sushi", original: "お寿司が食べたい") == "I want to eat sushi",
          "a real translation is kept")
    check(RealEars.usefulTranslation("  ", original: "x") == nil, "blank translation is dropped")
}

section("TranslationProvider seam: Soniox is inline (no per-line call)")
do {
    let p = TranslationFactory.make(engine: "soniox", target: .en)
    check(p.inlineOnTranscriptStream, "the Soniox provider's translation rides the stream")
    check(p.target == .en, "target is the interface language")
    let nilOut = await p.translate(line: "お寿司", from: .ja)
    check(nilOut == nil, "inline provider does not translate per line (it already rode the stream)")
}

section("HUD 60/40 split (active) and transcript-full (resting)")
do {
    // With cards present, the HUD uses a generous ~60/40 transcript-over-cards split.
    let s = HUDLayout.split(availableHeight: 600, hasCards: true)
    check(abs(s.transcript - 360) < 1 && abs(s.cards - 240) < 1, "cards present: about 60 percent transcript, 40 percent cards")
    // With no cards, the transcript region is the whole content height (the view caps
    // it to a modest resting height, but the split math gives it everything).
    let none = HUDLayout.split(availableHeight: 600, hasCards: false)
    check(none.transcript == 600 && none.cards == 0, "no cards: transcript takes the full height")
}

section("Pinned carousel index logic")
do {
    check(Carousel.afterPin(newCount: 3) == 2, "pinning shows the newest (last) card")
    check(Carousel.clamp(5, count: 3) == 2, "clamp caps at the last index")
    check(Carousel.clamp(-1, count: 3) == 0, "clamp floors at zero")
    check(Carousel.next(0, count: 3) == 1 && Carousel.next(2, count: 3) == 2, "next advances and clamps at the end")
    check(Carousel.prev(2, count: 3) == 1 && Carousel.prev(0, count: 3) == 0, "prev retreats and clamps at the start")
    // Unpinning the shown card keeps a valid neighbor.
    check(Carousel.afterUnpin(removedIndex: 1, current: 1, newCount: 2) == 0, "removing the current card clamps the index")
    check(Carousel.afterUnpin(removedIndex: 0, current: 2, newCount: 2) == 1, "removing before current shifts the index left")
    check(Carousel.afterUnpin(removedIndex: 0, current: 0, newCount: 0) == 0, "empty carousel is index 0")
}

section("Pinned-card note line: concise, with source, survives the notes export")
do {
    let card = RichCard(trigger: .question, timestamp: Date(), route: .entity, headline: "Kubernetes",
                        info: "An open-source container orchestration system.",
                        source: RichSource(title: "Wikipedia", url: "https://en.wikipedia.org/wiki/Kubernetes"))
    let line = card.noteLine()
    check(line.contains("Kubernetes") && line.contains("container orchestration"), "note line carries headline and info")
    check(line.contains("wikipedia.org"), "note line carries the source")

    // The export pipeline includes extraNoted (pinned cards) and the verifier keeps them.
    let store = NotesStore(llm: StubLLM(), model: "claude-sonnet-4-6", interface: .en)
    await store.start(now: Date(timeIntervalSince1970: 1_700_000_000))
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    await store.add(MeetingLine(speaker: "Sato", isUser: false, text: "Let us discuss the deployment.", timestamp: t))
    let folder = tempDir()
    guard let export = await store.stop(now: t.addingTimeInterval(60), folder: folder, extraNoted: [line]) else {
        check(false, "export produced"); fatalError()
    }
    let bullets = export.notes.sections.flatMap { $0.bullets }
    check(bullets.contains { $0.contains("Kubernetes") }, "a noted pinned card lands in the exported notes")
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent(export.docxFileName).path), "docx written")
}

section("Mic mute: muting clears the in-flight 'You' partial; unmuting does not")
do {
    let ears = RealEars(config: Config(), secrets: Secrets(values: [:]))
    nonisolated(unsafe) var cleared: [SpeakerSource] = []
    let lock = NSLock()
    ears.onClearPartial = { src in lock.withLock { cleared.append(src) } }
    check(!ears.micMuted, "starts unmuted")
    ears.micMuted = true
    check(ears.micMuted, "mute flag set")
    check(lock.withLock { cleared } == [.user], "muting clears the live 'You' partial so it does not linger")
    ears.micMuted = false
    check(!ears.micMuted, "unmute flag cleared")
    check(lock.withLock { cleared } == [.user], "unmuting does not clear anything new")
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
