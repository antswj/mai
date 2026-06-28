import Foundation
import MaiCore
import MaiCapture

// Live smoke tests. Validate your keys early, end to end, against the real APIs.
// Reads config.toml and .env from the current directory. Run from the package root:
//   swift run MaiSmoke            (runs all)
//   swift run MaiSmoke llm        (Anthropic + Groq)
//   swift run MaiSmoke places     (real Google + Hot Pepper merge, query "sushi")
//   swift run MaiSmoke vision     (Gemini vision on a small embedded image)
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
                .complete(system: "You reply with one word.", user: "Say: ok", model: "openai/gpt-oss-20b")
            print("  Groq (openai/gpt-oss-20b): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
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

switch which {
case "llm": await smokeLLM()
case "places": await smokePlaces()
case "vision": await smokeVision()
case "soniox": await smokeSoniox()
default:
    await smokeLLM(); await smokePlaces(); await smokeVision(); await smokeSoniox()
}
line(); print("Smoke tests done.")
