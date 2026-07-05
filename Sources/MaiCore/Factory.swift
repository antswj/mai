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
        let provider: PlacesProvider
        switch config.placesProvider {
        case "google": provider = google ?? StubPlaces()
        case "hotpepper": provider = hotpepper ?? StubPlaces()
        case "stub": provider = StubPlaces()
        default:
            provider = (google == nil && hotpepper == nil)
                ? StubPlaces()
                : MergedPlaces(google: google, hotpepper: hotpepper)
        }
        return CachedPlacesProvider(base: provider)
    }

    public static func makeLocation(config: Config) -> LocationProvider {
        FixedLocation(lat: config.testLat, lng: config.testLng)
    }

    public static func makeGemini(config: Config, secrets: Secrets) -> GeminiVision? {
        guard let key = secrets.get("GEMINI_API_KEY") else { return nil }
        return GeminiVision(apiKey: key, model: config.screenModel)
    }

    // Entity lookups resolve cross-language to the interface article; the LLM (when
    // available) handles the native-summary translation fallback.
    public static func makeEntityLookup(config: Config, secrets: Secrets) -> EntityLookup {
        let llm = secrets.get("ANTHROPIC_API_KEY").map { AnthropicLLM(apiKey: $0) }
        return CachedEntityLookup(base: WikipediaLookup(llm: llm, translateModel: config.lookupRouterModel))
    }

    // Grounded web search for the fresh/technical routes. Gemini is primary when a key
    // is present; quota/rate/billing failures fall through to a no-key web lookup so
    // useful fresh/technical cards do not collapse just because one provider is capped.
    public static func makeGroundedSearch(config: Config, secrets: Secrets) -> GroundedSearch {
        CachedGroundedSearch(base: makeGroundedSearchBase(config: config, secrets: secrets))
    }

    public static func makeGroundedSearchBase(config: Config, secrets: Secrets) -> GroundedSearch {
        let webFallback = DuckDuckGoGroundedSearch(fallback: WikipediaGroundedSearch())
        let wiki = WikipediaGroundedSearch()
        var candidates: [RoutedGroundedCandidate] = [
            RoutedGroundedCandidate(
                profile: GroundedProviderProfile(id: "duckduckgo", estimatedQuality: 0.68,
                                                 estimatedLatencyMs: 800, costUnits: 0,
                                                 supportedRoutes: [.fresh, .technical]),
                provider: webFallback),
            RoutedGroundedCandidate(
                profile: GroundedProviderProfile(id: "wikipedia", estimatedQuality: 0.72,
                                                 estimatedLatencyMs: 500, costUnits: 0,
                                                 supportedRoutes: [.entity, .technical, .screen]),
                provider: wiki),
        ]
        if let key = secrets.get("GEMINI_API_KEY") {
            candidates.append(RoutedGroundedCandidate(
                profile: GroundedProviderProfile(id: "gemini-grounded", estimatedQuality: 0.94,
                                                 estimatedLatencyMs: 1800, costUnits: 0.2,
                                                 supportedRoutes: [.fresh, .technical]),
                provider: GeminiGroundedSearch(apiKey: key, model: config.screenModel)))
        }
        return PolicyGroundedSearch(candidates: candidates)
    }
}
