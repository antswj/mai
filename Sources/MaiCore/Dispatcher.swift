import Foundation

// Routes a trigger to the right lookup and returns a small result plus its source.
//   place               -> PlacesProvider (real Google + Hot Pepper merge) at the current location
//   question / intent    -> model general knowledge (fun fact or recipe), no fabricated links
//   reference            -> a suggested reply drawn from transcript context only
//   screenReference      -> the current stored screen read
struct Dispatcher: Sendable {
    let places: PlacesProvider
    let location: LocationProvider
    let interfaceLanguage: Language
    let floorLanguage: Language

    enum Result: Sendable {
        case places(query: String, results: [Place])
        case knowledge(topic: String, isRecipe: Bool)
        case preparedReply(context: String, asker: String?)
        case screen(text: String)
        case none
    }

    func dispatch(_ trigger: Trigger, window: String, currentScreen: String?) async -> (Result, LookupSource) {
        switch trigger.type {
        case .place:
            let query = (trigger.payload["query"] ?? trigger.span)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let q = query.isEmpty ? "restaurant" : query
            let loc = await location.current()
            let found = (try? await places.nearby(query: q, lat: loc.lat, lng: loc.lng, language: floorLanguage)) ?? []
            return (.places(query: q, results: found), .places)

        case .question, .intent:
            let topic = (trigger.payload["query"] ?? trigger.span)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (.knowledge(topic: topic.isEmpty ? trigger.span : topic, isRecipe: looksLikeRecipe(trigger)), .web)

        case .reference:
            // Phase A draws a suggested reply from transcript context only.
            // The generic seam below is where a future personal-context provider
            // would be consulted; it returns nothing here and is never wired to
            // any external system in this open project.
            let personal = Self.personalContext(for: trigger)
            let context = personal ?? window
            return (.preparedReply(context: context, asker: trigger.payload["speaker"]), .none)

        case .screenReference:
            return (.screen(text: currentScreen ?? ""), .screen)
        }
    }

    private func looksLikeRecipe(_ trigger: Trigger) -> Bool {
        let hay = (trigger.span + " " + (trigger.payload["query"] ?? "")).lowercased()
        let cues = ["recipe", "make ", "cook", "bake", "作", "どうやって作", "做", "怎么做", "レシピ"]
        return cues.contains { hay.contains($0) }
    }

    /// Neutral seam for a future personal-context source. Returns nil in this
    /// open project; no external system is referenced.
    private static func personalContext(for trigger: Trigger) -> String? { nil }
}
