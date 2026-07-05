import Foundation
import CoreGraphics
import CoreText
import AppKit
import Darwin
import MaiCore
import MaiCapture

// Live smoke tests. Validate your keys early, end to end, against the real APIs.
// Reads config.toml and .env from the current directory. Run from the package root:
//   swift run MaiSmoke            (runs all)
//   swift run MaiSmoke llm        (Anthropic + Groq)
//   swift run MaiSmoke places     (real Google + Hot Pepper merge, query "sushi")
//   swift run MaiSmoke vision     (Gemini vision on a small embedded image)
//   swift run MaiSmoke health     (provider health + Gemini quota/billing hints)
//   swift run MaiSmoke golden     (replay golden anonymized bad-session traces)
//   swift run MaiSmoke soak       (30-minute synthetic meeting soak, fast replay)
//   swift run MaiSmoke wall-soak 30  (30-minute synthetic meeting soak, wall-clock)
//   swift run MaiSmoke budget     (deterministic p95/p99 latency budget check)
//
// This is the only caller of GeminiVision and the real provider HTTP paths in this
// step; the engine path is exercised by `swift test` with stubs.

let config = Config.load()
let secrets = Secrets()
let args = Array(CommandLine.arguments.dropFirst())
let which = args.first ?? "all"

func line() { print(String(repeating: "-", count: 60)) }

@discardableResult
func runProcess(_ path: String, _ arguments: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

final class SonioxCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _finals: [SonioxSegment] = []
    func add(_ update: SonioxSegmenter.Update) { lock.withLock { _finals.append(contentsOf: update.finals) } }
    var finals: [SonioxSegment] { lock.withLock { _finals } }
}

final class SmokeRichSink: RichCardSink, @unchecked Sendable {
    private let lock = NSLock()
    private var cards: [String: RichCard] = [:]
    private var order: [String] = []
    func upsert(_ card: RichCard) {
        lock.withLock {
            if cards[card.id] == nil { order.append(card.id) }
            cards[card.id] = card
        }
    }
    func suppressed(headline: String, trigger: TriggerType, reason: String) {
        let card = RichCard(trigger: trigger, timestamp: Date(), route: .pending,
                            tier: .noise, score: 0, headline: headline,
                            pending: [], suppressed: true, note: reason)
        upsert(card)
    }
    var all: [RichCard] { lock.withLock { order.compactMap { cards[$0] } } }
    var counts: (cards: Int, pending: Int) {
        lock.withLock {
            let all = order.compactMap { cards[$0] }
            return (all.count, all.filter { !$0.suppressed && !$0.pending.isEmpty }.count)
        }
    }
}

struct SmokeResourceSample {
    let elapsedSeconds: Int
    let rssMB: Double
    let taskCount: Int
    let cards: Int
    let pending: Int
}

struct SmokeReplayResult {
    let cards: [RichCard]
    let elapsed: TimeInterval
    let report: SyntheticSoakReport
}

func makeSmokeEngine(sink: SmokeRichSink, directoryPrefix: String) -> Engine {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(directoryPrefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try! SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
    let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
    let cfg = Config(hardCapSeconds: 3, responseEnabled: true, onlineCapSeconds: 5)
    return Engine(config: cfg,
                  llm: StubLLM(),
                  places: CachedPlacesProvider(base: StubPlaces(),
                                               cacheURL: dir.appendingPathComponent("places.json")),
                  location: FixedLocation(lat: cfg.testLat, lng: cfg.testLng),
                  store: store,
                  verbatim: verbatim,
                  face: ConsoleFace(),
                  richSink: sink,
                  entity: CachedEntityLookup(base: StubEntityLookup(),
                                             cacheURL: dir.appendingPathComponent("entity.json")),
                  grounded: CachedGroundedSearch(base: StubGroundedSearch(),
                                                 cacheURL: dir.appendingPathComponent("grounded.json")))
}

func waitForCardsToSettle(_ sink: SmokeRichSink, maxTicks: Int = 500) async {
    for _ in 0..<maxTicks {
        if !sink.all.contains(where: { !$0.suppressed && !$0.pending.isEmpty }) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func replayTraceFast(_ trace: MaiTrace, durationMinutes: Int, directoryPrefix: String) async -> SmokeReplayResult {
    let sink = SmokeRichSink()
    let engine = makeSmokeEngine(sink: sink, directoryPrefix: directoryPrefix)
    let started = Date()
    for event in trace.events {
        await engine.process(trace.input(for: event))
    }
    await waitForCardsToSettle(sink)
    let elapsed = Date().timeIntervalSince(started)
    let cards = sink.all
    let report = SyntheticSoak.report(cards: cards, durationMinutes: durationMinutes, eventCount: trace.events.count)
    return SmokeReplayResult(cards: cards, elapsed: elapsed, report: report)
}

func latencyBudgetOK(cards: [RichCard], p95Budget: Int = 3000, p99Budget: Int = 3000) -> Bool {
    let rows = LatencyTelemetryStats.percentileRows(from: cards.map(\.telemetry))
    guard !rows.isEmpty else {
        print("  budget: FAIL (no telemetry rows)")
        return false
    }
    var ok = true
    for row in rows {
        let pass = row.p95 <= p95Budget && row.p99 <= p99Budget
        ok = ok && pass
        print("  budget \(row.route.rawValue)/\(row.provider): p50=\(row.p50) p95=\(row.p95) p99=\(row.p99) n=\(row.count) \(pass ? "ok" : "ALERT")")
    }
    return ok
}

func currentResourceFootprint(sink: SmokeRichSink, elapsedSeconds: Int) -> SmokeResourceSample {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let rss = kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : 0
    var threads: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                      vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
    }
    let counts = sink.counts
    return SmokeResourceSample(elapsedSeconds: elapsedSeconds, rssMB: rss,
                               taskCount: Int(threadCount), cards: counts.cards, pending: counts.pending)
}

func chart(_ label: String, _ values: [Double], suffix: String = "") {
    guard !values.isEmpty else { return }
    let chars = Array(" .:-=+*#%@")
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? minValue
    let span = max(maxValue - minValue, 0.0001)
    let points = values.map { value -> Character in
        let idx = Int(((value - minValue) / span * Double(chars.count - 1)).rounded())
        return chars[max(0, min(chars.count - 1, idx))]
    }
    print("  \(label): \(String(points))  min=\(String(format: "%.1f", minValue))\(suffix) max=\(String(format: "%.1f", maxValue))\(suffix)")
}

func smokeLLM() async {
    line(); print("LLM smoke test")
    if let key = secrets.get("ANTHROPIC_API_KEY") {
        do {
            let out = try await AnthropicLLM(apiKey: key)
                .complete(system: "You reply with one word.", user: "Say: ok", model: config.classifierModel)
            print("  Anthropic (\(config.classifierModel)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch { print("  Anthropic ERROR: \(error)") }
    } else { print("  Anthropic: no ANTHROPIC_API_KEY, skipped") }

    if let key = secrets.get("GROQ_API_KEY") {
        do {
            let out = try await GroqLLM(apiKey: key)
                .complete(system: "You reply with one word.", user: "Say: ok", model: GroqLLM.smokeModel)
            print("  Groq (\(GroqLLM.smokeModel)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch { print("  Groq ERROR: \(error)") }
    } else { print("  Groq: no GROQ_API_KEY, skipped") }
}

func smokePlaces() async {
    line(); print("Places smoke test (real Google + Hot Pepper merge), query \"sushi\"")
    let google = secrets.get("GOOGLE_PLACES_API_KEY").map { GooglePlaces(apiKey: $0) }
    let hotpepper = secrets.get("HOTPEPPER_API_KEY").map { HotPepper(apiKey: $0) }
    let merged = MergedPlaces(google: google, hotpepper: hotpepper)
    do {
        let results = try await merged.nearby(query: "sushi", lat: config.testLat, lng: config.testLng, language: .ja)
        if results.isEmpty { print("  No results (check that Places API (New) is enabled and keys are valid).") }
        for p in results {
            let rating = p.rating.map { "★\($0)" } ?? "no rating"
            let dist = p.distanceMeters.map { " ~\(Int($0.rounded()))m" } ?? ""
            print("  [\(p.source)] \(p.name)  \(rating)\(dist)")
            if let url = p.url { print("        \(url)") }
        }
    } catch { print("  Places ERROR: \(error)") }
}

// 24x24 PNG (border + diagonal) to exercise the vision input path.
let smokeImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAY0lEQVR4nM3SwQ0AIAgDQPZfWn/GIEJbfdABToSa9c1Q4xXZCsbRrPhfgnVdEGtlm6as4mS4Vd8etKASIRbaxtIial2+hEK5xUGJRUM3S4FCS4ROS4ec9QTt1iu0rA+QV3plAp2ab8lm3KDUAAAAAElFTkSuQmCC"

func smokeVision() async {
    line(); print("Gemini vision smoke test (\(config.screenModel))")
    guard let key = secrets.get("GEMINI_API_KEY") else { print("  no GEMINI_API_KEY, skipped"); return }
    guard let data = Data(base64Encoded: smokeImageBase64) else { print("  bad embedded image"); return }
    do {
        let text = try await GeminiVision(apiKey: key, model: config.screenModel)
            .read(imageData: data, mimeType: "image/png",
                  prompt: "Describe this small image in one short sentence.")
        print("  read: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    } catch { print("  Gemini ERROR: \(error)") }
}

// Live Soniox transcription via locally-generated speech (no microphone needed):
// `say` makes an audio clip, `afconvert` makes raw PCM16 mono 16k, we stream it to
// Soniox through the real SonioxClient and assert real finalized tokens come back
// with language tags. This exercises the audio-format + Soniox protocol + token
// parsing end to end (everything but the ScreenCaptureKit mic tap).
func smokeSoniox() async {
    line(); print("Soniox smoke test (model \(config.sttModel)) via local 'say' speech")
    guard let key = secrets.get("SONIOX_API_KEY") else { print("  no SONIOX_API_KEY, skipped"); return }
    let phrase = "I would really like to get some sushi after this meeting."
    let aiff = NSTemporaryDirectory() + "mai_smoke.aiff"
    let wav = NSTemporaryDirectory() + "mai_smoke.wav"
    guard runProcess("/usr/bin/say", ["-o", aiff, phrase]) else { print("  'say' failed"); return }
    guard runProcess("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav]) else {
        print("  'afconvert' failed"); return
    }
    guard let fileData = FileManager.default.contents(atPath: wav), fileData.count > 44 else {
        print("  could not read converted WAV"); return
    }
    let pcm = fileData.subdata(in: 44..<fileData.count)   // strip the 44-byte WAV header

    let collector = SonioxCollector()
    let cfg = SonioxConfig.json(apiKey: key, model: config.sttModel, sampleRate: 16000, channels: 1,
                                languageHints: config.sttLanguageHints, languageId: true,
                                diarization: false, translationTarget: nil)
    let client = SonioxClient(configJSON: cfg, onUpdate: { collector.add($0) },
                              onError: { print("  soniox: \($0)") })
    client.connect()
    var i = 0
    let chunk = 3840
    while i < pcm.count {
        let end = min(i + chunk, pcm.count)
        client.sendAudio(pcm.subdata(in: i..<end))
        i = end
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    client.finalize()
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    client.close()

    let finals = collector.finals
    let text = finals.map { $0.text }.joined()
    let langs = Set(finals.compactMap { $0.language })
    if finals.isEmpty {
        print("  RESULT: FAIL (no transcript returned; check key/network)")
    } else {
        print("  transcript: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("  languages: \(langs.sorted())")
        print("  RESULT: ok (\(finals.count) final segment(s), language tags: \(!langs.isEmpty))")
    }
}

// Render a small sanitized slide (no real data) for the screen-read check.
func renderSlidePNG() -> Data? {
    let w = 640, h = 360
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    func draw(_ s: String, size: CGFloat, y: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let lineToDraw = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(lineToDraw, ctx)
    }
    draw("Q3 Revenue Overview", size: 44, y: CGFloat(h - 90))
    draw("Revenue up 18% year over year", size: 28, y: CGFloat(h - 170))
    guard let cg = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

func smokeScreen() async {
    line(); print("Screen-read smoke (Gemini \(config.screenModel)) on a generated slide")
    guard let key = secrets.get("GEMINI_API_KEY") else { print("  no GEMINI_API_KEY, skipped"); return }
    guard let png = renderSlidePNG() else { print("  could not render slide"); return }
    do {
        // Use the SAME prompt the app uses, so this checks the real subject extraction
        // that drives a useful, sourced screen card (not just a description).
        let text = try await GeminiVision(apiKey: key, model: config.screenModel)
            .read(imageData: png, mimeType: "image/png", prompt: RealEyes.screenReadPrompt)
        let parsed = RealEyes.parseScreenRead(text)
        print("  content: \(parsed.content)")
        print("  subject: \(parsed.subject ?? "(none)")")
        let ok = parsed.subject?.isEmpty == false
        print("  RESULT: \(ok ? "ok (extracted a salient subject to look up)" : "uncertain (no subject extracted)")")
    } catch { print("  Gemini ERROR: \(error)") }
}

func smokeVAD() {
    line(); print("Silero VAD smoke (on-device ONNX, no network)")
    guard let vad = SileroVAD.bundled(sampleRate: config.sttSampleRate) else {
        print("  could not load the bundled model"); return
    }
    let silence = (try? vad.probability(frame: [Float](repeating: 0, count: vad.frameSize))) ?? -1
    var tone = [Float](repeating: 0, count: vad.frameSize)
    for i in 0..<vad.frameSize { tone[i] = 0.6 * sinf(Float(i) * 0.18) }
    let toneProb = (try? vad.probability(frame: tone)) ?? -1
    print(String(format: "  silence p=%.3f, tone p=%.3f", silence, toneProb))
    let ok = silence >= 0 && silence <= 1 && silence < 0.5 && toneProb >= 0 && toneProb <= 1
    print("  RESULT: \(ok ? "ok (model runs on-device, silence reads low)" : "uncertain")")
}

func smokeGrounded() async {
    line(); print("Grounded-search smoke (Gemini \(config.screenModel), Google Search tool)")
    guard let key = secrets.get("GEMINI_API_KEY") else { print("  no GEMINI_API_KEY, skipped"); return }
    do {
        let r = try await GeminiGroundedSearch(apiKey: key, model: config.screenModel)
            .answer(query: "who is the current secretary-general of the united nations", interface: config.interfaceLanguage)
        print("  answer: \(r.answer.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("  sources: \(r.sources.count) (\(r.sources.first?.url ?? "none"))")
        print("  RESULT: \(r.answer.isEmpty ? "uncertain (empty answer)" : "ok (grounded answer with sources)")")
    } catch { print("  Gemini grounded ERROR: \(error)") }
}

func smokeEntity() async {
    line(); print("Entity smoke (Wikipedia summary + cross-language resolution)")
    let entity = MaiFactory.makeEntityLookup(config: config, secrets: secrets)
    let cases: [(String, Language)] = [("Malaysia", .en), ("寿司", .ja), ("马来西亚", .zh)]
    for (term, spoken) in cases {
        do {
            if let r = try await entity.lookup(term: term, spoken: spoken, interface: .en) {
                print("  \(term) [\(spoken.rawValue)] -> \(r.title): \(r.summary.prefix(70))...")
                print("    image: \(r.imageURL != nil ? "yes" : "none")  source: \(r.sourceURL)")
            } else { print("  \(term): no result") }
        } catch { print("  \(term) ERROR: \(error)") }
    }
}

func smokeHealth() async {
    line(); print("Provider health smoke")
    let results = await ProviderHealth.check(config: config, secrets: secrets)
    for result in results {
        print("  \(result.provider): \(result.state.rawValue) - \(result.message)")
        if let hint = result.billingHint { print("    billing: \(hint)") }
    }
    let issueCount = results.filter { ![.ok, .setOnly, .notSet].contains($0.state) }.count
    print("  RESULT: \(issueCount == 0 ? "ok" : "attention (\(issueCount) issue(s))")")
}

func smokeSoak(minutes: Int = 30) async {
    line(); print("Synthetic meeting soak (\(minutes) min simulated, fast replay)")
    print("  generated audio turns, screen changes, language switches, interruptions, repeated topics")
    let trace = SyntheticSoak.trace(durationMinutes: minutes)
    let result = await replayTraceFast(trace, durationMinutes: minutes, directoryPrefix: "mai-soak")
    let report = result.report
    print("  replay wall time: \(String(format: "%.2f", result.elapsed))s")
    print("  events: \(report.eventCount), resolved cards: \(report.resolvedCards), suppressed: \(report.suppressedCards), weak: \(report.weakCards)")
    print("  max first-paint: \(report.maxFirstPaintMs) ms, max final-fill: \(report.maxFinalFillMs) ms")
    print("  routes: \(report.routeCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    for note in report.notes { print("  note: \(note)") }
    let ok = report.resolvedCards > 0 && report.weakCards == 0 && report.maxFirstPaintMs <= 3000
    print("  RESULT: \(ok ? "ok" : "attention")")
}

func smokeGolden() async {
    line(); print("Golden trace regression smoke")
    let pack = GoldenTracePacks.badSessionV1
    let result = await replayTraceFast(pack.trace, durationMinutes: 1, directoryPrefix: "mai-golden")
    let cards = result.cards.filter { !$0.suppressed && $0.pending.isEmpty }
    let routes = Set(cards.map(\.route.rawValue))
    let weak = cards.filter { ($0.rating?.score ?? 0) < CardRating.usefulThreshold }.count
    let maxFirst = cards.compactMap(\.latencyMs).max() ?? 0
    let assertions = GoldenTraceAssert.evaluate(pack: pack, cards: result.cards)
    let failed = assertions.filter { !$0.passed }
    print("  replay wall time: \(String(format: "%.2f", result.elapsed))s")
    print("  events: \(pack.trace.events.count), cards: \(cards.count), weak: \(weak), max first-paint: \(maxFirst) ms")
    print("  routes: \(routes.sorted().joined(separator: ", "))")
    for assertion in assertions {
        print("  assertion \(assertion.label): \(assertion.passed ? "ok" : "FAIL") - \(assertion.detail)")
    }
    let ok = cards.count >= 6 && weak == 0 && maxFirst <= 3000
        && routes.contains("fresh") && routes.contains("technical") && routes.contains("preparedReply")
        && failed.isEmpty
    print("  RESULT: \(ok ? "ok" : "attention")")
}

func smokeWallClockSoak(minutes: Double = 30) async {
    let seconds = max(1, Int((minutes * 60).rounded()))
    line(); print("Synthetic meeting soak (\(String(format: "%.1f", minutes)) min wall-clock)")
    let trace = SyntheticSoak.trace(durationSeconds: seconds)
    let sink = SmokeRichSink()
    let engine = makeSmokeEngine(sink: sink, directoryPrefix: "mai-wall-soak")
    let started = Date()
    var samples: [SmokeResourceSample] = []
    var nextEvent = 0
    while true {
        let elapsed = Date().timeIntervalSince(started)
        while nextEvent < trace.events.count && Double(trace.events[nextEvent].offsetMs) / 1000.0 <= elapsed {
            await engine.process(trace.input(for: trace.events[nextEvent]))
            nextEvent += 1
        }
        samples.append(currentResourceFootprint(sink: sink, elapsedSeconds: Int(elapsed.rounded())))
        if elapsed >= Double(seconds), nextEvent >= trace.events.count { break }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    await waitForCardsToSettle(sink)
    let cards = sink.all
    let report = SyntheticSoak.report(cards: cards, durationMinutes: max(1, Int(minutes.rounded())),
                                      eventCount: trace.events.count)
    print("  events: \(report.eventCount), resolved cards: \(report.resolvedCards), suppressed: \(report.suppressedCards), weak: \(report.weakCards)")
    print("  max first-paint: \(report.maxFirstPaintMs) ms, max final-fill: \(report.maxFinalFillMs) ms")
    chart("rss", samples.map(\.rssMB), suffix: " MB")
    chart("tasks", samples.map { Double($0.taskCount) })
    chart("cards", samples.map { Double($0.cards) })
    chart("pending", samples.map { Double($0.pending) })
    let ok = report.resolvedCards > 0 && report.weakCards == 0
        && report.maxFirstPaintMs <= 3000 && latencyBudgetOK(cards: cards)
    print("  RESULT: \(ok ? "ok" : "attention")")
}

func smokeBudget() async {
    line(); print("Latency budget smoke (p95/p99 by route/provider)")
    let golden = await replayTraceFast(GoldenTracePacks.badSessionV1.trace, durationMinutes: 1, directoryPrefix: "mai-budget-golden")
    let soak = await replayTraceFast(SyntheticSoak.trace(durationMinutes: 30), durationMinutes: 30, directoryPrefix: "mai-budget-soak")
    let goldenOK = latencyBudgetOK(cards: golden.cards)
    let soakOK = latencyBudgetOK(cards: soak.cards)
    let goldenAssertions = GoldenTraceAssert.evaluate(pack: GoldenTracePacks.badSessionV1, cards: golden.cards)
    let assertionsOK = goldenAssertions.allSatisfy(\.passed)
    print("  golden assertions: \(assertionsOK ? "ok" : "ALERT")")
    let ok = goldenOK && soakOK && assertionsOK
    print("  RESULT: \(ok ? "ok" : "ALERT")")
    if !ok { exit(1) }
}

switch which {
case "llm": await smokeLLM()
case "places": await smokePlaces()
case "vision": await smokeVision()
case "soniox": await smokeSoniox()
case "screen": await smokeScreen()
case "vad": smokeVAD()
case "grounded": await smokeGrounded()
case "entity": await smokeEntity()
case "health": await smokeHealth()
case "golden": await smokeGolden()
case "soak":
    let minutes = args.dropFirst().first.flatMap(Int.init) ?? 30
    await smokeSoak(minutes: minutes)
case "wall-soak":
    let minutes = args.dropFirst().first.flatMap(Double.init) ?? 30
    await smokeWallClockSoak(minutes: minutes)
case "budget": await smokeBudget()
default:
    await smokeLLM(); await smokePlaces(); await smokeVision(); await smokeSoniox(); await smokeScreen()
    smokeVAD(); await smokeEntity(); await smokeGrounded(); await smokeHealth(); await smokeGolden(); await smokeSoak(minutes: 30)
}
line(); print("Smoke tests done.")
