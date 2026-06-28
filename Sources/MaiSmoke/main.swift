import Foundation
import MaiCore

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

switch which {
case "llm": await smokeLLM()
case "places": await smokePlaces()
case "vision": await smokeVision()
default:
    await smokeLLM(); await smokePlaces(); await smokeVision()
}
line(); print("Smoke tests done.")
