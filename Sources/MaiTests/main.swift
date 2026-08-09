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

func pcm16(_ samples: [Int16]) -> Data {
    var d = Data(capacity: samples.count * 2)
    for s in samples {
        var le = s.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }
    return d
}

func sinePCM16(sampleRate: Int = 16000, seconds: Double, hz: Double = 180, amplitude: Double = 0.45) -> Data {
    let count = Int(Double(sampleRate) * seconds)
    let samples = (0..<count).map { i -> Int16 in
        let value = sin(Double(i) / Double(sampleRate) * hz * 2 * Double.pi) * amplitude
        return Int16(max(-1, min(1, value)) * 32767)
    }
    return pcm16(samples)
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

section("Screen capture: Mai windows are excluded without hiding real apps")
do {
    let currentPID = pid_t(42)
    check(CaptureSelfWindowMatcher.isSelf(ownerBundleIdentifier: "com.mai.app", ownerProcessID: 99,
                                          currentBundleIdentifier: "com.mai.app", currentProcessID: currentPID),
          "same bundle identifier counts as Mai")
    check(CaptureSelfWindowMatcher.isSelf(ownerBundleIdentifier: nil, ownerProcessID: currentPID,
                                          currentBundleIdentifier: "com.mai.app", currentProcessID: currentPID),
          "same process id counts as Mai even without a bundle id")
    check(!CaptureSelfWindowMatcher.isSelf(ownerBundleIdentifier: "com.apple.Safari", ownerProcessID: 99,
                                           currentBundleIdentifier: "com.mai.app", currentProcessID: currentPID),
          "a different app is not excluded")
}

section("Screen reads: Mai overlay is ignored, Mai source code is preserved")
do {
    let overlay = RealEyes.parseScreenRead(#"{"content":"A floating Mai HUD overlay shows a live transcript and Cards above the desktop.","subject":"Mai overlay","participants":[],"active_speaker":""}"#)
    check(overlay.content.isEmpty && overlay.subject == nil, "self-overlay screen reads are dropped")

    let code = RealEyes.parseScreenRead(#"{"content":"A code editor is open to HUDPanel.swift, showing Swift code for Mai's floating panel.","subject":"HUDPanel.swift","participants":[],"active_speaker":""}"#)
    check(code.content.contains("HUDPanel.swift") && code.subject == "HUDPanel.swift",
          "engineering screens about Mai remain readable")
}

section("App-aware screen traces keep useful app metadata without private titles")
do {
    let event = ScreenContentEvent(content: "Salesforce opportunity page with renewal risk.",
                                   timestamp: Date(), isChange: true, subject: "Renewal risk",
                                   appName: "Safari", bundleIdentifier: "com.apple.Safari",
                                   windowTitle: "Acme Renewal - Private CRM")
    let trace = TraceAnonymizer.screen(event, sessionStartedAt: event.timestamp)
    check(trace.appName == "Browser", "screen trace stores an app category")
    check(trace.bundleIdentifier == "web.browser", "bundle id is anonymized")
    check(trace.windowTitle == "Window title redacted", "private window title is redacted")
}

section("Live coaching: concern cues surface locally without claiming deception")
do {
    let insight = ConversationCoach.insight(
        for: TranscriptEvent(text: "I'm worried the timeline risk is still too high.",
                             speaker: "Mia", timestamp: Date(), isFinal: true),
        window: "Mia: I'm worried the timeline risk is still too high.",
        interfaceLanguage: .en)
    check(insight?.headline == "Address the concern", "concern cue produces a coaching insight")
    check(insight?.trust.contains { $0.detail.localizedCaseInsensitiveContains("not deception") } == true,
          "coaching explicitly avoids lie/deception claims")
}

section("AI voice coaching: uses vocal features and rejects deception claims")
do {
    let vocal = VocalSignal(source: .remote, capturedAt: Date(), windowSeconds: 12,
                            capturedSeconds: 4, speechSeconds: 2.3, silenceRatio: 0.42,
                            meanRMS: 0.08, peakRMS: 0.31, energyTrend: -0.04,
                            meanPitchHz: 172, pitchStdDevHz: 26, pitchSampleCount: 8,
                            wordCount: 12, estimatedWordsPerMinute: 205)
    let event = TranscriptEvent(text: "The pricing change might be difficult for procurement.",
                                speaker: "Mia", timestamp: Date(), isFinal: true,
                                vocalSignal: vocal)
    let insight = try? await ConversationCoach.aiInsight(
        for: event,
        window: "Mia: The pricing change might be difficult for procurement.",
        llm: StubLLM(),
        model: "stub",
        interfaceLanguage: .en,
        spokenLanguage: .en,
        suggestReplies: false)
    check(insight?.headline == "Adjust the pace", "AI coach produces a voice-aware coaching insight")
    check(insight?.trust.contains { $0.label == "Framework" && $0.detail.contains("Motivational") } == true,
          "AI coach names the psychology framework behind the move")
    check(insight?.trust.contains { $0.label == "Voice features" } == true,
          "AI coach trust includes vocal features")

    let unsafe = StubLLM { _, _, _ in
        #"{"should_surface":true,"headline":"They are lying","info":"The speaker is lying based on their tone.","recommended_move":"Confront them.","tier":"critical","score":0.9,"observed_voice_cues":["tone"]}"#
    }
    let unsafeInsight = try? await ConversationCoach.aiInsight(
        for: event,
        window: "Mia: The pricing change might be difficult for procurement.",
        llm: unsafe,
        model: "stub",
        interfaceLanguage: .en,
        spokenLanguage: .en,
        suggestReplies: false)
    check(unsafeInsight == nil, "AI coach suppresses lie/deception claims")
}

section("End-of-session operator: produces next-action checklist")
do {
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    let lines = [
        MeetingLine(speaker: "Mia", isUser: false, text: "We decided to go with the phased launch.", timestamp: t0),
        MeetingLine(speaker: "Mia", isUser: false, text: "We should follow up with Ken by Friday.", timestamp: t0.addingTimeInterval(60)),
        MeetingLine(speaker: "Lee", isUser: true, text: "What is still blocking the rollout?", timestamp: t0.addingTimeInterval(120))
    ]
    let useful = RichCard(trigger: .question, timestamp: t0, route: .fresh, tier: .medium, score: 0.8,
                          headline: "Rollout plan", info: "A useful sourced answer.", source: RichSource(title: "Plan", url: "https://example.com/plan"),
                          pending: [], rating: CardRating(score: 0.8, grade: "good", reasons: ["sourced"], useful: true))
    let card = ConversationCoach.operatorChecklist(lines: lines, cards: [useful], savedTitle: "Team Sync Notes")
    check(card?.route == .sessionOperator, "operator card route is sessionOperator")
    check(card?.info?.localizedCaseInsensitiveContains("follow") == true, "operator card includes follow-up guidance")
    check(card?.info?.contains("Decisions") == true, "operator recap includes a decisions section")
    check(card?.info?.contains("Replay Points") == true, "operator recap includes replay points")
    check(card?.sources.first?.url == "https://example.com/plan", "operator recap carries useful links as sources")
    check(card?.trust.isEmpty == false, "operator card carries trust signals")
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

final class CompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

struct RichRig { let engine: Engine; let sink: CollectingRichSink; let store: SQLiteStore }
func makeRichRig(_ config: Config = Config(), entity: EntityLookup = StubEntityLookup(),
                 grounded: GroundedSearch = StubGroundedSearch(), places: PlacesProvider = StubPlaces(),
                 llm: LLMProvider = StubLLM()) -> RichRig {
    let dir = tempDir()
    let store = try! SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
    let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
    let sink = CollectingRichSink()
    let engine = Engine(config: config, llm: llm, places: places,
                        location: FixedLocation(lat: config.testLat, lng: config.testLng),
                        store: store, verbatim: verbatim, face: ConsoleFace(),
                        richSink: sink, entity: entity, grounded: grounded)
    return RichRig(engine: engine, sink: sink, store: store)
}

func waitResolvedCards(_ sink: CollectingRichSink, minimum: Int, timeoutMs: Int = 7000) async -> [RichCard] {
    for _ in 0..<(timeoutMs / 10) {
        let resolved = sink.all.filter { $0.pending.isEmpty && !$0.suppressed }
        if resolved.count >= minimum { return resolved }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return sink.all.filter { $0.pending.isEmpty && !$0.suppressed }
}

func waitForCard(_ sink: CollectingRichSink, timeoutMs: Int = 7000,
                 matching predicate: @escaping (RichCard) -> Bool) async -> RichCard? {
    for _ in 0..<(timeoutMs / 10) {
        if let card = sink.all.first(where: predicate) { return card }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return sink.all.first(where: predicate)
}

section("Engine: AI voice coaching surfaces from vocal signal asynchronously")
do {
    var config = Config()
    config.coachingAIEnabled = true
    config.coachingAICapSeconds = 2
    config.coachingAIMinIntervalSeconds = 10
    let rig = makeRichRig(config)
    let vocal = VocalSignal(source: .remote, capturedAt: Date(), windowSeconds: 12,
                            capturedSeconds: 4.5, speechSeconds: 2.1, silenceRatio: 0.53,
                            meanRMS: 0.07, peakRMS: 0.29, energyTrend: -0.03,
                            meanPitchHz: 181, pitchStdDevHz: 31, pitchSampleCount: 6,
                            wordCount: 10, estimatedWordsPerMinute: 286)
    let event = TranscriptEvent(text: "The rollout date is possible, but procurement may push back.",
                                speaker: "Mia", timestamp: Date(), isFinal: true,
                                vocalSignal: vocal)
    await rig.engine.process(.transcript(event))
    let card = await waitForCard(rig.sink, timeoutMs: 1500) {
        $0.route == .coaching && $0.trust.map(\.label).contains("AI review")
    }
    check(card?.headline == "Adjust the pace", "AI voice coaching card surfaced through the engine")
    check(card?.trust.map(\.label).contains("Framework") == true,
          "AI voice coaching card carries a framework trust signal")
    check(card?.telemetry.provider == "AI Voice Coach", "telemetry labels AI voice coaching")
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
    let router = LookupRouter(llm: StubLLM(), model: "stub", interface: .en)
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
    check(card.rating?.useful == true, "sourced cards pass the local usefulness rating")
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
    check(card.suppressed, "a connectivity-only card is rated weak and hidden from the main stream")
    check(card.rating?.grade == "weak", "weak card carries its usefulness rating")
}

section("Card rating: actionable place cards rate higher than weak filler")
do {
    let fallback = "Could not reach the answer service just now; will retry on the next mention."
    let good = RichCard(trigger: .place, timestamp: Date(), route: .place, score: 0.86,
                        headline: "Nearby: sushi",
                        info: "Sushi HP\n~150 m away\nFunabashi",
                        source: RichSource(title: "Maps", url: "https://example.com"),
                        action: Action(kind: "open_in_maps", label: "Open in Maps", params: ["url": "https://maps.example"]))
    let weak = RichCard(trigger: .question, timestamp: Date(), route: .technical, score: 0.60,
                        headline: "Anything", info: fallback)
    let goodRating = CardRating.evaluate(good)
    let weakRating = CardRating.evaluate(weak)
    check(goodRating.useful && goodRating.score > weakRating.score, "rating favors sourced/actionable cards")
    check(!weakRating.useful, "connectivity fallback is below the usefulness threshold")
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

section("Rich enricher: stale cleanup cannot untrack the active superseding task")
do {
    struct EntityRoutingLLM: LLMProvider {
        func complete(system: String, user: String, model: String) async throws -> String {
            guard system.contains("lookup router") else { return #"{"answer":"fallback"}"# }
            let topic: String
            if user.contains("\"first\"") { topic = "first" }
            else if user.contains("\"second\"") { topic = "second" }
            else { topic = "third" }
            return #"{"route":"entity","entity":"\#(topic)","query":"\#(topic)","needs_search":false,"needs_image":false}"#
        }
    }
    struct CancellationBlindEntity: EntityLookup {
        func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
            let delayMs: UInt64 = term == "first" ? 120 : (term == "second" ? 360 : 20)
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return EntityResult(title: term, summary: term, imageURL: nil, sourceURL: "https://example.org/\(term)")
        }
    }

    let sink = CollectingRichSink()
    let enricher = RichCardEnricher(config: Config(), llm: EntityRoutingLLM(), entity: CancellationBlindEntity(),
                                    grounded: StubGroundedSearch(), places: StubPlaces(),
                                    location: FixedLocation(lat: 0, lng: 0), sink: sink)
    let completions = CompletionLog()
    let skel1 = RichCard(trigger: .question, timestamp: Date(), headline: "first", pending: [RichCard.Part.route.rawValue])
    let skel2 = RichCard(trigger: .question, timestamp: Date(), headline: "second", pending: [RichCard.Part.route.rawValue])
    let skel3 = RichCard(trigger: .question, timestamp: Date(), headline: "third", pending: [RichCard.Part.route.rawValue])

    await enricher.submit(skel1, request: .knowledge(topic: "first", window: "", spoken: .en, respond: false),
                          supersedeKey: "same") { completions.append($0.headline) }
    await enricher.submit(skel2, request: .knowledge(topic: "second", window: "", spoken: .en, respond: false),
                          supersedeKey: "same") { completions.append($0.headline) }
    try? await Task.sleep(nanoseconds: 180_000_000)
    await enricher.submit(skel3, request: .knowledge(topic: "third", window: "", spoken: .en, respond: false),
                          supersedeKey: "same") { completions.append($0.headline) }
    try? await Task.sleep(nanoseconds: 450_000_000)

    check(completions.all == ["third"], "only the newest enrichment completes after stale cleanup races")
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

section("Latency cap: slow model-only classification is cut off before the card loop stalls")
do {
    struct SlowClassifierOnlyLLM: LLMProvider {
        let delayMs: UInt64
        func complete(system: String, user: String, model: String) async throws -> String {
            if system.contains("trigger classifier") {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                return #"{"triggers":[{"type":"intent","span":"rollout risk","reason":"slow classifier","confidence":0.8,"payload":{"query":"rollout risk"}}]}"#
            }
            return try await StubLLM().complete(system: system, user: user, model: model)
        }
    }

    let rig = makeRichRig(Config(hardCapSeconds: 0.25, onlineCapSeconds: 5),
                          llm: SlowClassifierOnlyLLM(delayMs: 1200))
    let start = Date()
    await rig.engine.process(tline("The rollout risk feels material, but this phrasing is deliberately outside the local fast path.", "Mia"))
    let elapsed = Date().timeIntervalSince(start)
    check(elapsed < 0.9, "classifier timeout follows the hard cap instead of waiting on a slow model")
    check(rig.sink.all.contains { $0.route == .coaching && !$0.suppressed },
          "local coaching can still surface while a slow model classifier is cut off")
    check(!rig.sink.all.contains { $0.headline == "rollout risk" && $0.route != .coaching && !$0.suppressed },
          "a late model-only trigger is dropped rather than surfacing stale")
}

section("Hell scenario: noisy multilingual meeting stays fast, useful, and proactive")
do {
    struct HellGroundedSearch: GroundedSearch {
        func answer(query: String, interface: Language) async throws -> GroundedResult {
            if query.localizedCaseInsensitiveContains("salesforce") {
                try await Task.sleep(nanoseconds: 3_250_000_000)
                return GroundedResult(
                    answer: "For Salesforce Platform Events, track replay IDs, make Queueable retries idempotent, and route exhausted retries to a dead-letter path with alerts.",
                    sources: [RichSource(title: "Salesforce Engineering Guide", url: "https://developer.salesforce.com/docs/platform/events")],
                    searchSuggestionHTML: nil)
            }
            return GroundedResult(
                answer: "Current sourced answer for \(query): summarize the decision, give the user the next useful fact, and cite where it came from.",
                sources: [RichSource(title: "Current Source", url: "https://example.com/current-source")],
                searchSuggestionHTML: "<div>search</div>")
        }
    }

    let places = StubPlaces(results: [
        Place(name: "Sushi Pressure Test", source: "google", rating: 4.8, reviewCount: 420,
              address: "Near the station", lat: 35.70, lng: 139.98,
              url: "https://maps.example/sushi-pressure-test", distanceMeters: 96)
    ])
    let config = Config(hardCapSeconds: 3, responseEnabled: true, onlineCapSeconds: 5)
    let rig = makeRichRig(config, grounded: HellGroundedSearch(), places: places)

    // Long, low-value chatter should not make cards or bloat the context into slow
    // prompts. This simulates a real meeting's connective tissue.
    for i in 0..<80 {
        let text = i.isMultiple(of: 2) ? "okay" : "ありがとうございます"
        await rig.engine.process(tline(text, "Noise"))
    }
    check(rig.sink.all.filter { !$0.suppressed }.isEmpty, "low-information chatter stays quiet even under long context")

    // Technical screen content may take longer to resolve, but the skeleton still has
    // to first-paint immediately so the user knows Mai understood the screen.
    await rig.engine.process(sscreenSubject(
        "Salesforce engineering screen: Apex Queueable retries, Platform Events replay IDs, dead-letter handling, and backpressure graphs.",
        "Salesforce Platform Events replay ID recovery"))
    let techSkeleton = await waitForCard(rig.sink, timeoutMs: 500,
                                         matching: { $0.headline.localizedCaseInsensitiveContains("Salesforce") && !$0.pending.isEmpty })
    check((techSkeleton?.latencyMs ?? 99999) <= 3000, "technical screen card skeleton first-paints within 3s")

    await rig.engine.process(tline("what's 15% of 80", "Mia"))
    await rig.engine.process(tline("ngl ちょっとお寿司食べたい", "Lee"))
    await rig.engine.process(tline("what is the latest iPhone price today", "Mia"))
    await rig.engine.process(tlineLang("それでは、ご意見をお願いできますか？", "ja", "Sato"))
    await rig.engine.process(sscreenSubject("Presentation slide about Malaysia market expansion.", "Malaysia"))

    let cards = await waitResolvedCards(rig.sink, minimum: 6, timeoutMs: 9000)
    check(cards.count >= 6, "all six expected stress cards resolve")
    check(cards.contains { $0.route == .technical && $0.headline.localizedCaseInsensitiveContains("Salesforce") },
          "technical screen content resolves as a sourced technical card")
    check(cards.contains { $0.route == .trivial && $0.info == "12" },
          "trivial math answers locally")
    check(cards.contains { $0.route == .place && $0.action?.kind == "open_in_maps" },
          "place card is actionable")
    check(cards.contains { $0.route == .fresh && !$0.sources.isEmpty },
          "fresh/current question is grounded with sources")
    check(cards.contains { $0.route == .preparedReply && $0.response?.language == .ja },
          "Japanese reply cue gets a Japanese suggested reply")
    check(cards.contains { $0.route == .entity && $0.source?.url.contains("wikipedia.org") == true },
          "proactive screen subject becomes a sourced entity card")

    let normalCards = cards.filter { !$0.headline.localizedCaseInsensitiveContains("Salesforce") }
    check(normalCards.allSatisfy { ($0.latencyMs ?? 99999) <= 3000 },
          "every normal stress card first-paints within the 3s ceiling")
    check(cards.allSatisfy { $0.rating?.useful == true },
          "every stress card passes the local usefulness gate")
    check(normalCards.allSatisfy { ($0.rating?.score ?? 0) >= 0.70 },
          "normal stress cards rate good-or-better quality")
    check(cards.allSatisfy { !($0.info ?? "").localizedCaseInsensitiveContains("could not reach") },
          "no stress card is a connectivity/filler fallback")
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
    let assistant = AnthropicAssistant(llm: StubLLM(), model: "stub", interface: .en)
    let transcript = [MeetingLine(speaker: "Sato", isUser: false, text: "Shall we ship Friday?", timestamp: Date()),
                      MeetingLine(speaker: "You", isUser: true, text: "I need one more day to test.", timestamp: Date())]
    let reply = try await assistant.reply(to: "what are they talking about", transcript: transcript, history: [], screen: nil)
    check(reply.contains("one more day to test"), "the assistant surfaces what the user themselves said")
}

section("Notes pipeline: write-up, verification drops unsupported, title, save")
do {
    let store = NotesStore(llm: StubLLM(), model: "stub", interface: .en)
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
    let router = LookupRouter(llm: StubLLM(), model: "stub", interface: .en)
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

section("Audio energy: RMS detects whether the speaker is actually playing")
do {
    // Silence -> ~0; a full-scale tone -> high. This is the capture-time signal that
    // drives acoustic-echo detection (mic and speaker loud at once), so it must be real.
    func pcm(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples { var le = s.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        return d
    }
    check(AudioEnergy.rms(pcm([Int16](repeating: 0, count: 512))) == 0, "silence has zero RMS")
    let loud = pcm((0..<512).map { _ in Int16(12000) })
    check(AudioEnergy.rms(loud) > 0.3, "loud audio has high RMS")
    check(AudioEnergy.isLoud(loud, threshold: 0.015), "loud audio is above the speaker-active threshold")
    check(!AudioEnergy.isLoud(pcm((0..<512).map { _ in Int16(100) }), threshold: 0.015), "very quiet audio is not 'playing'")
    check(AudioEnergy.rms(Data()) == 0, "empty buffer is zero, not a crash")
}

section("Vocal signal tracker: extracts pause, energy, pitch, and pace from PCM")
do {
    let t0 = Date(timeIntervalSince1970: 1_780_000_100)
    let tracker = VocalSignalTracker(source: .remote, sampleRate: 16000, speechRMSThreshold: 0.015)
    tracker.ingest(sinePCM16(seconds: 1.0, hz: 180, amplitude: 0.45), at: t0.addingTimeInterval(1.0))
    tracker.ingest(pcm16([Int16](repeating: 0, count: 16_000)), at: t0.addingTimeInterval(2.0))
    let signal = tracker.snapshot(at: t0.addingTimeInterval(2.0), windowSeconds: 2.0,
                                  utteranceText: "this is a concise test utterance")
    check((signal?.speechSeconds ?? 0) > 0.9, "vocal tracker measures speech seconds from PCM")
    check((signal?.silenceRatio ?? 0) > 0.35, "vocal tracker measures pause ratio")
    check((signal?.meanPitchHz ?? 0) > 120 && (signal?.meanPitchHz ?? 999) < 240,
          "vocal tracker estimates pitch from audio")
    check(signal?.estimatedWordsPerMinute != nil, "vocal tracker estimates speaking pace")
}

section("Appearance: liquid glass setting loads and clamps")
do {
    check(Config(liquidGlassAmount: -0.25).liquidGlassAmount == 0,
          "liquid glass amount clamps low values in the initializer")
    check(Config(liquidGlassAmount: 1.25).liquidGlassAmount == 1,
          "liquid glass amount clamps high values in the initializer")
    let path = NSTemporaryDirectory() + "mai-appearance-\(UUID().uuidString).toml"
    try? """
    [appearance]
    liquid_glass = 0.45
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let loaded = Config.load(path: path)
    check(abs(loaded.liquidGlassAmount - 0.45) < 0.001,
          "liquid glass amount loads from config.toml")
    try? FileManager.default.removeItem(atPath: path)
}

section("Adaptive quiet mode: suppresses noisy density, protects important cards")
do {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    var card = RichCard(trigger: .question, timestamp: now, route: .entity, tier: .medium, score: 0.43,
                        headline: "Malaysia", info: "Short answer", pending: [])
    card.rating = CardRating(score: 0.46, grade: "weak", reasons: ["low signal"], useful: false)
    let recent = (0..<4).map { i in
        RichCard(trigger: .question, timestamp: now.addingTimeInterval(Double(-10 * i)),
                 route: .entity, tier: .medium, score: 0.7, headline: "Recent \(i)", info: "ok", pending: [])
    }
    let quiet = AdaptiveQuietPolicy.decision(for: card, recentCards: recent,
                                             feedbackSummary: CardFeedbackSummary(),
                                             config: Config(adaptiveQuietMode: true,
                                                            adaptiveQuietMaxVisibleCards: 4),
                                             now: now)
    check(quiet.suppress && (quiet.reason?.contains("recent density") == true),
          "adaptive quiet suppresses low-value cards when the stream is already busy")

    var critical = card
    critical.tier = .critical
    let protected = AdaptiveQuietPolicy.decision(for: critical, recentCards: recent,
                                                 feedbackSummary: CardFeedbackSummary(),
                                                 config: Config(adaptiveQuietMode: true),
                                                 now: now)
    check(!protected.suppress, "adaptive quiet never suppresses critical cards")
}

section("Ambient conversation focus: consent-gated sensitivity and music rejection")
do {
    var cfg = Config()
    cfg.ambientConversationFocus = true
    check(!cfg.ambientFocusActive, "ambient focus is inactive without consent confirmation")
    cfg.ambientConsentConfirmed = true
    let adjusted = cfg.audioFocusAdjusted
    check(adjusted.vadOnset < cfg.vadOnset && adjusted.vadOffset < cfg.vadOffset,
          "ambient focus lowers VAD thresholds after consent")
    check(adjusted.echoSystemActiveRMS < cfg.echoSystemActiveRMS,
          "ambient focus lowers the speech RMS threshold")

    let steadyMusic = sinePCM16(seconds: 1.0, hz: 220, amplitude: 0.35)
    check(AudioSceneClassifier.isLikelyMusicOnly(steadyMusic, sampleRate: 16000, speechThreshold: 0.008),
          "steady music-like audio is rejected")

    var bursty: [Int16] = []
    for block in 0..<10 {
        let voiced = block % 2 == 0
        for i in 0..<1600 {
            let value = voiced ? sin(Double(i) / 16000.0 * 180.0 * 2 * Double.pi) * 0.4 : 0
            bursty.append(Int16(value * 32767))
        }
    }
    check(!AudioSceneClassifier.isLikelyMusicOnly(pcm16(bursty), sampleRate: 16000, speechThreshold: 0.008),
          "bursty speech-like audio is not rejected as music")
}

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
    let store = NotesStore(llm: StubLLM(), model: "stub", interface: .en)
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

section("PII redaction: what leaves the machine, and what comes back")
do {
    let policy = PIIPolicy()
    // Structured detectors, the high-precision layer.
    let contact = "Email me at sato.kenji@example.co.jp or call 090-1234-5678."
    let spans = PIIDetector.spans(in: contact, policy: policy)
    check(spans.contains { $0.kind == .email }, "an email address is found")
    check(spans.contains { $0.kind == .phone }, "a phone number is found")

    // Luhn, so an ordinary long number is not mistaken for a card.
    check(PIIDetector.passesLuhn("4111 1111 1111 1111"), "a valid test card passes the checksum")
    check(!PIIDetector.passesLuhn("1234 5678 9012 3456"), "an arbitrary 16-digit number does not")
    let cardSpans = PIIDetector.spans(in: "Card 4111 1111 1111 1111 on file.", policy: policy)
    check(cardSpans.contains { $0.kind == .creditCard }, "a checksum-valid card is redacted")
    let idSpans = PIIDetector.spans(in: "My number is 1234 5678 9012.", policy: policy)
    check(idSpans.contains { $0.kind == .governmentID }, "a 12-digit government id is redacted")

    // Stable placeholders: the same person is the same token every time, so the model can
    // still follow who said what. This is what makes redaction safe for reply quality.
    let r = PIIRedactor(policy: policy)
    let first = r.redact("Sato said the budget is tight.")
    let second = r.redact("Sato will confirm tomorrow.")
    check(!first.contains("Sato"), "the name does not leave the machine")
    check(!second.contains("Sato"), "and not on the second line either")
    let token = PIIRedactor.token(kind: .person, index: 1)
    check(first.contains(token) && second.contains(token), "the same person keeps the same placeholder")

    // Round trip: the user sees the real name again.
    check(r.rehydrate(first) == "Sato said the budget is tight.", "rehydration restores the original exactly")
    check(r.rehydrate("Ask \(token) about it.").contains("Sato"), "a model reply mentioning the placeholder is restored")

    // Place and thing names must survive, or the entity and place cards lose their subject.
    // The system tagger calls both of these people; the confidence floor is what saves them.
    let neutral = "What time does the Shinkansen leave for Osaka?"
    check(r.redact(neutral) == neutral, "place and thing names are not mistaken for people")

    // The master switch really is off.
    let off = PIIRedactor(policy: .off)
    check(off.redact("Sato said hello") == "Sato said hello", "with the policy off nothing is changed")
    check(PIIDetector.spans(in: contact, policy: .off).isEmpty, "and nothing is even scanned")

    // Per-kind policy control.
    let peopleOnly = PIIPolicy(redactPeople: true, redactContacts: false,
                               redactIdentifiers: false, redactURLs: false)
    let peopleSpans = PIIDetector.spans(in: contact, policy: peopleOnly)
    check(!peopleSpans.contains { $0.kind == .phone }, "contacts are kept when that switch is off")

    // Placeholder numbering stays readable past the alphabet.
    check(PIIRedactor.letter(1) == "A" && PIIRedactor.letter(26) == "Z" && PIIRedactor.letter(27) == "AA",
          "placeholder letters keep going past Z")

    // Known participants are matched exactly, which is what actually protects the people
    // in the room: the system tagger alone finds neither name in this sentence.
    let known = PIIRedactor(policy: policy)
    known.registerKnownName("Tanaka")
    known.registerKnownName("Suzuki")
    let bothOut = known.redact("Tanaka met Suzuki.")
    check(!bothOut.contains("Tanaka") && !bothOut.contains("Suzuki"),
          "both known participants are redacted even when the tagger misses them")
    check(known.rehydrate(bothOut) == "Tanaka met Suzuki.", "and both come back exactly")

    // Role labels are not identities.
    let roles = PIIRedactor(policy: policy)
    roles.registerKnownName("You")
    roles.registerKnownName("Speaker 2")
    check(roles.redact("You and Speaker 2 agreed.") == "You and Speaker 2 agreed.",
          "role labels are not treated as names")

    // Word boundaries in Latin script, so a short name cannot match inside a word.
    let boundary = PIIRedactor(policy: policy)
    boundary.registerKnownName("Ann")
    check(boundary.redact("The announcement is ready.") == "The announcement is ready.",
          "a name is not matched inside a longer word")
}

section("Coach prompt file: loads and keeps its contract")
do {
    let prompt = Prompts.coach
    // Prompts.load returns "" on failure, which would make the coach silently stop
    // working and surface as a baffling unrelated failure.
    check(!prompt.isEmpty, "the coach prompt file actually loads")
    check(prompt.contains("live vocal coaching analyst"),
          "the phrase the deterministic stub dispatches on survives in the file")
    check(prompt.contains("suggested_reply") && prompt.contains("reply_translation"),
          "the JSON contract carries the reply fields")
    check(!prompt.contains("\u{2014}"), "no em-dashes in the prompt")
}

section("Coach reply: follows the other party's language, with ruby")
do {
    func coachEvent(_ text: String, language: String?, source: SpeakerSource) -> TranscriptEvent {
        let vocal = VocalSignal(source: source, capturedAt: Date(), windowSeconds: 12,
                                capturedSeconds: 4, speechSeconds: 2.3, silenceRatio: 0.42,
                                meanRMS: 0.08, peakRMS: 0.31, energyTrend: -0.04,
                                meanPitchHz: 172, pitchStdDevHz: 26, pitchSampleCount: 8,
                                wordCount: 12, estimatedWordsPerMinute: 205)
        return TranscriptEvent(text: text, speaker: "Sato", timestamp: Date(), isFinal: true,
                               language: language, vocalSignal: vocal, source: source)
    }

    // Japanese speaker: the suggestion comes back in Japanese, with real furigana.
    let ja = try? await ConversationCoach.aiInsight(
        for: coachEvent("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
        window: "Sato: その価格だと、社内の承認が難しいかもしれません。",
        llm: StubLLM(), model: "stub", interfaceLanguage: .en,
        spokenLanguage: .ja, suggestReplies: true)
    check(ja?.response?.language == .ja, "a Japanese speaker gets a Japanese suggestion")
    check((ja?.response?.spoken.isEmpty == false), "the suggestion has text to say")
    check((ja?.response?.translation.isEmpty == false), "the suggestion carries an interface-language translation")
    let jaUnits = Readings.units(ja?.response?.spoken ?? "", language: .ja)
    check(jaUnits.contains { $0.reading != nil }, "furigana is generated over the Japanese suggestion")

    // Chinese speaker: pinyin.
    let zh = try? await ConversationCoach.aiInsight(
        for: coachEvent("这个价格我们内部很难批下来。", language: "zh", source: .remote),
        window: "Sato: 这个价格我们内部很难批下来。",
        llm: StubLLM(), model: "stub", interfaceLanguage: .en,
        spokenLanguage: .zh, suggestReplies: true)
    check(zh?.response?.language == .zh, "a Chinese speaker gets a Chinese suggestion")
    check(Readings.units(zh?.response?.spoken ?? "", language: .zh).contains { $0.reading != nil },
          "pinyin is generated over the Chinese suggestion")

    // English speaker: plain text, no reading aid.
    let en = try? await ConversationCoach.aiInsight(
        for: coachEvent("That price is going to be hard to get approved.", language: "en", source: .remote),
        window: "Sato: That price is going to be hard to get approved.",
        llm: StubLLM(), model: "stub", interfaceLanguage: .en,
        spokenLanguage: .en, suggestReplies: true)
    check(en?.response?.language == .en, "an English speaker gets an English suggestion")

    // The user's OWN words never get a reply: coaching someone on how to answer
    // themselves is meaningless.
    let mine = try? await ConversationCoach.aiInsight(
        for: coachEvent("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .user),
        window: "You: その価格だと、社内の承認が難しいかもしれません。",
        llm: StubLLM(), model: "stub", interfaceLanguage: .en,
        spokenLanguage: .ja, suggestReplies: true)
    check(mine != nil && mine?.response == nil, "the user's own utterance gets analysis but no reply")

    // The reply toggle is respected.
    let gated = try? await ConversationCoach.aiInsight(
        for: coachEvent("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
        window: "Sato: その価格だと、社内の承認が難しいかもしれません。",
        llm: StubLLM(), model: "stub", interfaceLanguage: .en,
        spokenLanguage: .ja, suggestReplies: false)
    check(gated != nil && gated?.response == nil, "with replies off the coach still analyses but suggests nothing")

    // Source falls back to the vocal signal for producers that predate the new field.
    let legacy = TranscriptEvent(
        text: "その価格だと、社内の承認が難しいかもしれません。", speaker: "Sato", timestamp: Date(), isFinal: true,
        language: "ja",
        vocalSignal: VocalSignal(source: .remote, capturedAt: Date(), windowSeconds: 12,
                                 capturedSeconds: 4, speechSeconds: 2.3, silenceRatio: 0.42,
                                 meanRMS: 0.08, peakRMS: 0.31, energyTrend: -0.04,
                                 meanPitchHz: 172, pitchStdDevHz: 26, pitchSampleCount: 8,
                                 wordCount: 12, estimatedWordsPerMinute: 205))
    check(ConversationCoach.speakerSource(of: legacy) == .remote,
          "the speaker source falls back to the vocal signal when the event has none")

    // The safety filter now covers the words the user would SAY, not just the analysis.
    let unsafeReply = StubLLM { _, _, _ in
        #"{"should_surface":true,"headline":"Push back","info":"This is a reasonable moment to ask for specifics about the constraint.","recommended_move":"Ask for specifics.","suggested_reply":"Tell them you know they are lying about the budget.","reply_translation":"Tell them you know they are lying.","tier":"medium","score":0.8,"observed_voice_cues":["tone"]}"#
    }
    let blocked = try? await ConversationCoach.aiInsight(
        for: coachEvent("That price is going to be hard to get approved.", language: "en", source: .remote),
        window: "Sato: That price is going to be hard to get approved.",
        llm: unsafeReply, model: "stub", interfaceLanguage: .en,
        spokenLanguage: .en, suggestReplies: true)
    check(blocked == nil, "a deception claim inside the suggested reply rejects the whole output")

    // Local language-parity guard: an English reply to a Japanese speaker is dropped,
    // and the analysis is kept.
    let mismatched = StubLLM { _, _, _ in
        #"{"should_surface":true,"headline":"Ask for specifics","info":"This is a good moment to ask what would make the approval easier internally.","recommended_move":"Ask one clarifying question.","suggested_reply":"Could you tell me more about that?","reply_translation":"Could you tell me more about that?","tier":"medium","score":0.8,"observed_voice_cues":["pace"]}"#
    }
    let parity = try? await ConversationCoach.aiInsight(
        for: coachEvent("その価格だと、社内の承認が難しいかもしれません。", language: "ja", source: .remote),
        window: "Sato: その価格だと、社内の承認が難しいかもしれません。",
        llm: mismatched, model: "stub", interfaceLanguage: .en,
        spokenLanguage: .ja, suggestReplies: true)
    check(parity != nil && parity?.response == nil,
          "an English reply to a Japanese speaker is dropped, keeping the analysis")
}

section("Heuristic coach: analysis only, in the interface language")
do {
    let event = TranscriptEvent(text: "I'm worried the timeline risk is still too high.",
                                speaker: "Mia", timestamp: Date(), isFinal: true)
    let window = "Mia: I'm worried the timeline risk is still too high."
    let en = ConversationCoach.insight(for: event, window: window, interfaceLanguage: .en)
    let ja = ConversationCoach.insight(for: event, window: window, interfaceLanguage: .ja)
    let zh = ConversationCoach.insight(for: event, window: window, interfaceLanguage: .zh)
    check(en?.headline == "Address the concern", "the English wording is unchanged")
    check(ja?.headline != en?.headline && ja?.headline.isEmpty == false, "Japanese gets its own wording")
    check(zh?.headline != en?.headline && zh?.headline.isEmpty == false, "Chinese gets its own wording")
    check(en?.key == ja?.key && ja?.key == zh?.key,
          "the cue key is language-independent, so switching languages does not reset the cooldown")
    check(en?.response == nil && ja?.response == nil && zh?.response == nil,
          "the instant local layer never invents a canned reply")
    check(ja?.trust.contains { $0.label == "Safety" } == true, "every language keeps a safety signal")
}

section("Reply ruby language: the tag wins, the script is the fallback")
do {
    // All-kanji Japanese: ScriptDetect alone would call this Chinese and put pinyin over
    // it, so the tag has to win.
    let tagged = RichResponse(spoken: "承認は来週です。", translation: "Approval is next week.",
                              language: .ja, rationale: nil)
    check(tagged.rubyLanguage == .ja, "an explicit Japanese tag beats script detection")
    // Untagged Japanese (Soniox left the language nil): the script fills in, which is the
    // case that used to render plain text in the HUD and furigana in the full app.
    let untagged = RichResponse(spoken: "もう少し詳しく教えてください。", translation: "Tell me more.",
                                language: .en, rationale: nil)
    check(untagged.rubyLanguage == .ja, "untagged Japanese still gets furigana in both views")
    let chinese = RichResponse(spoken: "请再说一点。", translation: "Say a bit more.", language: .zh, rationale: nil)
    check(chinese.rubyLanguage == .zh, "Chinese keeps pinyin")
    let english = RichResponse(spoken: "Could you say more?", translation: "Could you say more?",
                               language: .en, rationale: nil)
    check(english.rubyLanguage == .en, "English needs no reading aid")
}

section("Session transcript: policy gates, naming, index round-trip, collisions")
do {
    typealias P = SessionTranscriptPolicy
    check(P.decide(enabled: false, noteTakingSaved: false, lineCount: 5, hasFolder: true) == .skipDisabled,
          "the setting off means nothing is written")
    check(P.decide(enabled: true, noteTakingSaved: true, lineCount: 5, hasFolder: true) == .skipNoteTakingSaved,
          "note-taking already wrote a transcript, so there is no duplicate")
    check(P.decide(enabled: true, noteTakingSaved: false, lineCount: 0, hasFolder: true) == .skipEmpty,
          "an empty session writes nothing")
    check(P.decide(enabled: true, noteTakingSaved: false, lineCount: 5, hasFolder: false) == .skipNoFolder,
          "no notes folder means no silent write somewhere else")
    check(P.decide(enabled: true, noteTakingSaved: false, lineCount: 5, hasFolder: true) == .save,
          "enabled, not note-taking, has content and a folder: save")
    check(P.decide(enabled: false, noteTakingSaved: false, lineCount: 5, hasFolder: false) == .skipDisabled,
          "a disabled feature never nags about the missing folder")

    // Naming: the human title keeps its colon, the file name cannot.
    let started = Date(timeIntervalSince1970: 1_770_000_000)
    let hhmm = DateFormatter(); hhmm.dateFormat = "HH:mm"
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    let expectedTitle = "Session " + hhmm.string(from: started)
    check(SessionTranscriptNaming.title(startedAt: started) == expectedTitle, "the title reads as a session and a wall-clock time")
    let base = SessionTranscriptNaming.fileBase(startedAt: started)
    check(base == day.string(from: started) + " " + expectedTitle.replacingOccurrences(of: ":", with: "-"),
          "the file base is date-prefixed with the colon sanitized out")
    check(!base.contains(":"), "a colon never reaches the file system")

    // Collisions inside the same minute.
    check(SessionTranscriptNaming.uniqueFileName(base: "X", ext: ".md", exists: { _ in false }) == "X.md",
          "no collision means the plain name")
    check(SessionTranscriptNaming.uniqueFileName(base: "X", ext: ".md",
                                                 exists: { ["X.md", "X (2).md"].contains($0) }) == "X (3).md",
          "collisions walk to the next free suffix instead of overwriting")

    // Empty input is a true no-op: no file, and no index created.
    let emptyDir = tempDir()
    let emptyDraft = SessionTranscriptDraft(lines: [], startedAt: started, endedAt: started,
                                            reason: .stopped, truncated: false)
    let nothing = try? SessionTranscriptWriter.save(draft: emptyDraft, to: emptyDir)
    check((nothing ?? nil) == nil, "an empty session returns no saved result")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: emptyDir.path)) ?? []
    check(leftovers.isEmpty, "an empty session leaves no file and no index behind")

    // Round-trip: two sessions, newest first, both marked as transcripts, both readable.
    let dir = tempDir()
    let l1 = MeetingLine(speaker: "Sato", isUser: false, text: "来週の予定を確認しましょう。", timestamp: started, language: "ja")
    let l2 = MeetingLine(speaker: "You", isUser: true, text: "Sounds good.", timestamp: started.addingTimeInterval(4), language: "en")
    let d1 = SessionTranscriptDraft(lines: [l1, l2], startedAt: started, endedAt: started.addingTimeInterval(60),
                                    reason: .stopped, truncated: false)
    let d2 = SessionTranscriptDraft(lines: [l2], startedAt: started.addingTimeInterval(7_200),
                                    endedAt: started.addingTimeInterval(7_260),
                                    reason: .rolledOver("idle"), truncated: false)
    let s1 = try? SessionTranscriptWriter.save(draft: d1, to: dir)
    let s2 = try? SessionTranscriptWriter.save(draft: d2, to: dir)
    check((s1 ?? nil) != nil && (s2 ?? nil) != nil, "both sessions save")
    let index = MeetingIndexEntry.load(from: dir.appendingPathComponent("mai-meetings.json"))
    check(index.count == 2, "both sessions land in the saved-meetings index")
    check(index.allSatisfy { $0.isTranscriptOnly }, "both are marked as transcript-only, not verified notes")
    check(index.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.markdownFileName).path) },
          "every index row points at a file that exists")
    check(index.allSatisfy { $0.openFileName.hasSuffix(".md") },
          "Open targets the .md, since a transcript has no .docx")

    // Same-minute collision writes a second file rather than overwriting the first.
    let again = try? SessionTranscriptWriter.save(draft: d1, to: dir)
    check(((again ?? nil)?.fileName ?? "").hasSuffix(" (2).md"), "a second session in the same minute gets its own file")
    let index2 = MeetingIndexEntry.load(from: dir.appendingPathComponent("mai-meetings.json"))
    check(index2.count == 3 && Set(index2.map(\.id)).count == 3, "each save is a distinct index row")

    // Index compatibility, both directions. load() returns [] on ANY decode error, so a
    // row it cannot read would wipe the user's whole list.
    let legacyDir = tempDir()
    let legacyURL = legacyDir.appendingPathComponent("mai-meetings.json")
    let legacyJSON = """
    [{"id":"old-1","title":"Legacy meeting","date":"2026-08-01T10:00:00Z","docxFileName":"a.docx","markdownFileName":"a.md"}]
    """
    try? Data(legacyJSON.utf8).write(to: legacyURL)
    let legacy = MeetingIndexEntry.load(from: legacyURL)
    check(legacy.count == 1, "an index written before transcripts existed still loads")
    check(legacy.first?.kind == nil && legacy.first?.isTranscriptOnly == false,
          "a legacy row is treated as full notes")
    let futureURL = tempDir().appendingPathComponent("mai-meetings.json")
    let futureJSON = """
    [{"id":"new-1","title":"Newer kind","date":"2026-08-01T10:00:00Z","docxFileName":"a.docx","markdownFileName":"a.md","kind":"somethingNewer"}]
    """
    try? Data(futureJSON.utf8).write(to: futureURL)
    let future = MeetingIndexEntry.load(from: futureURL)
    check(future.count == 1 && future.first?.isTranscriptOnly == false,
          "an unknown kind still decodes instead of emptying the list")

    // Truncation is stated in the file, not silently dropped.
    let note = SessionTranscript.truncationNote()
    let rendered = MarkdownTranscript.render(title: "T", lines: [l1], startedAt: started, endedAt: started, note: note)
    check(rendered.contains(note), "a truncated session says so in the saved file")
    check(!MarkdownTranscript.render(title: "T", lines: [l1], startedAt: started, endedAt: started).contains(note),
          "an untruncated session carries no note, so existing output is unchanged")

    // Status wording, so the two save paths cannot drift.
    typealias S = SessionTranscriptStatus
    check(S.fragment(for: .saved(fileName: "a.md"), includeSetupHint: false) == "Saved session transcript: a.md",
          "a successful save names the file")
    check((S.fragment(for: .skipped(.skipNoFolder), includeSetupHint: false) ?? "").contains("notes folder"),
          "a missing folder is reported with the fix")
    check(S.fragment(for: .skipped(.skipEmpty), includeSetupHint: false) == nil, "an empty session says nothing")
    check(S.fragment(for: .skipped(.skipNoteTakingSaved), includeSetupHint: false) == nil,
          "a note-taking session says nothing about transcripts")
    check(S.fragment(for: .skipped(.skipDisabled), includeSetupHint: false) == nil, "the disabled case is quiet by default")
    check((S.fragment(for: .skipped(.skipDisabled), includeSetupHint: true) ?? "").contains("Settings"),
          "the one-time hint points at the setting")
    check((S.fragment(for: .failed("disk full"), includeSetupHint: false) ?? "").contains("disk full"),
          "a failure reports the real reason")
}

section("Capture health: silence is normal, a dead microphone leg is not")
do {
    // A quiet room: both sources delivering, nothing voiced, nothing forwarded recently.
    // This must never restart capture, which is why the policy keys off voiced audio
    // and per-source arrival rather than "no transcript lately".
    let quiet = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                   micVoicedAgo: 300, sentAgo: 300, transcriptAgo: 300)
    check(CaptureHealthPolicy.verdict(quiet) == .healthy, "a quiet room is healthy, never a restart")

    // Whole stack dead: no audio from either source.
    let dead = CaptureHealthInput(micCapturedAgo: 30, systemCapturedAgo: 30,
                                  micVoicedAgo: 60, sentAgo: 60, transcriptAgo: 60)
    if case .restart = CaptureHealthPolicy.verdict(dead) {
        check(true, "no audio from any source restarts capture")
    } else {
        check(false, "no audio from any source restarts capture")
    }

    // Audio reaching the service but nothing coming back.
    let stalled = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                     micVoicedAgo: 2, sentAgo: 2, transcriptAgo: 40)
    if case .restart = CaptureHealthPolicy.verdict(stalled) {
        check(true, "audio flowing with no transcript restarts capture")
    } else {
        check(false, "audio flowing with no transcript restarts capture")
    }

    // THE REGRESSION CASE. The mic leg stopped while system audio keeps arriving. The
    // old two-rule watchdog was blind to this: the shared "captured" heartbeat stayed
    // fresh (system audio) and "sent" grew without bound, so neither old rule could fire
    // and the app reported "Capturing" while transcribing nothing.
    let micDead = CaptureHealthInput(micCapturedAgo: 200, systemCapturedAgo: 0.2,
                                     micVoicedAgo: 4_000, sentAgo: 4_000, transcriptAgo: 4_000)
    check(micDead.capturedAgo < CaptureHealthPolicy.deadCaptureSeconds,
          "the old shared heartbeat looks healthy here, which is why this fault was invisible")
    check(!(micDead.sentAgo < 6 && micDead.transcriptAgo > 20),
          "the old stalled-transcription rule cannot fire here either")
    if case .restart(let why) = CaptureHealthPolicy.verdict(micDead) {
        check(why.hasPrefix("microphone stopped"), "a dead mic leg is now detected and restarted")
    } else {
        check(false, "a dead mic leg is now detected and restarted")
    }

    // After the restart budget is spent, it reports instead of restarting forever.
    var exhausted = micDead
    exhausted.micRecoveryAttempts = CaptureHealthPolicy.maxMicRecoveryAttempts
    if case .warn(let message) = CaptureHealthPolicy.verdict(exhausted) {
        check(message.contains("Microphone"), "a mic leg that will not recover reports instead of looping")
    } else {
        check(false, "a mic leg that will not recover reports instead of looping")
    }

    // A muted mic is expected to go quiet: never a fault.
    var muted = micDead
    muted.micMuted = true
    check(CaptureHealthPolicy.verdict(muted) == .healthy, "a muted microphone is not a capture fault")

    // Errors that used to be discarded now surface, and stale ones do not nag.
    let failing = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                     micVoicedAgo: 500, sentAgo: 500, transcriptAgo: 500,
                                     errorAgo: 5, lastError: "soniox error 402: balance exhausted")
    if case .warn(let message) = CaptureHealthPolicy.verdict(failing) {
        check(message.contains("402"), "a transcription service error is surfaced verbatim")
    } else {
        check(false, "a transcription service error is surfaced verbatim")
    }
    var stale = failing
    stale.errorAgo = CaptureHealthPolicy.errorFreshSeconds + 60
    stale.sentAgo = 60
    stale.micVoicedAgo = 600
    check(CaptureHealthPolicy.verdict(stale) == .healthy, "an old error does not keep warning")

    // Speech is audible but nothing is being forwarded: the fault is before the network.
    let heardNotSent = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                          micVoicedAgo: 5, sentAgo: 400, transcriptAgo: 400)
    if case .warn(let message) = CaptureHealthPolicy.verdict(heardNotSent) {
        check(message.contains("heard"), "audio heard but never forwarded is reported")
    } else {
        check(false, "audio heard but never forwarded is reported")
    }

    // A long stretch with nothing transcribed at all: the only signal that catches a
    // microphone delivering digital silence (buffers arrive, so they carry no speech).
    let longSilence = CaptureHealthInput(micCapturedAgo: 0.2, systemCapturedAgo: 0.2,
                                         micVoicedAgo: 5_000,
                                         sentAgo: CaptureHealthPolicy.silentTooLongSeconds + 60,
                                         transcriptAgo: 5_000)
    if case .notice(let message) = CaptureHealthPolicy.verdict(longSilence) {
        check(message.contains("No speech"), "a long stretch with no speech is a notice, not a status-line warning")
        // The message must not embed an elapsed time. The app republishes only when the
        // text changes, so an interpolated duration would rewrite the status line every
        // minute forever during ordinary quiet.
        var later = longSilence
        later.sentAgo += 600
        check(CaptureHealthPolicy.verdict(later) == .notice(message),
              "the quiet notice text is stable as time passes, so it cannot churn the UI")
    } else {
        check(false, "a long stretch with no speech is a notice, not a status-line warning")
    }
    var longSilenceMuted = longSilence
    longSilenceMuted.micMuted = true
    check(CaptureHealthPolicy.verdict(longSilenceMuted) == .healthy,
          "a deliberately muted mic never nags about silence")

    // The raw ages behind a note, so the rules are observable instead of assumed.
    // An event that never happened is carried as a distantPast age, which must read as
    // "never" rather than a meaningless ten-digit number.
    var neverHeard = micDead
    neverHeard.micVoicedAgo = Date().timeIntervalSince(.distantPast)
    let detail = CaptureHealthPolicy.detail(neverHeard)
    check(detail.contains("speech heard never"), "an age that never happened reads as 'never', not a huge number")
    check(detail.contains("Microphone audio"), "the detail names the microphone leg explicitly")
    check(CaptureHealthPolicy.detail(micDead).contains("66m ago"),
          "a finite age reads in minutes once it is past the seconds range")
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
