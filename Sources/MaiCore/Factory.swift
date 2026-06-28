import Foundation

// Wires concrete providers from config + secrets. If a required key is missing the
// LLM falls back to the deterministic stub (so the app still runs and shows the
// shape), and places falls back to the stub. This keeps the app and smoke tests thin.
public enum MaiFactory {
    public static func makeLLM(config: Config, secrets: Secrets) -> LLMProvider {
        switch config.llmProvider {
        case "groq":
            if let key = secrets.get("GROQ_API_KEY") { return GroqLLM(apiKey: key) }
        default:
            if let key = secrets.get("ANTHROPIC_API_KEY") { return AnthropicLLM(apiKey: key) }
        }
        FileHandle.standardError.write(Data("Mai: no LLM key for provider \"\(config.llmProvider)\"; using StubLLM.\n".utf8))
        return StubLLM()
    }

    public static func makePlaces(config: Config, secrets: Secrets) -> PlacesProvider {
        let google = secrets.get("GOOGLE_PLACES_API_KEY").map { GooglePlaces(apiKey: $0) }
        let hotpepper = secrets.get("HOTPEPPER_API_KEY").map { HotPepper(apiKey: $0) }
        switch config.placesProvider {
        case "google": return google ?? StubPlaces()
        case "hotpepper": return hotpepper ?? StubPlaces()
        case "stub": return StubPlaces()
        default:
            if google == nil && hotpepper == nil { return StubPlaces() }
            return MergedPlaces(google: google, hotpepper: hotpepper)
        }
    }

    public static func makeLocation(config: Config) -> LocationProvider {
        FixedLocation(lat: config.testLat, lng: config.testLng)
    }

    public static func makeGemini(config: Config, secrets: Secrets) -> GeminiVision? {
        guard let key = secrets.get("GEMINI_API_KEY") else { return nil }
        return GeminiVision(apiKey: key, model: config.screenModel)
    }
}
