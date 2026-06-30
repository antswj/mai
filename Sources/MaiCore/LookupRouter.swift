import Foundation

// The card brain. Given the thing the user wondered about, picks how to look it up.
// Trivial is decided LOCALLY (instant, no model, no web) so the common numeric ask
// lands well under the local latency target. Everything else takes ONE fast model
// call to choose entity / fresh / technical and to extract a native-script entity.
// Routing is the first enrichment step; the card is already on screen before this
// runs, and the enricher gives this call its own timeout with a default-route
// fallback so a hung router can never leave a card stuck as a skeleton.
public struct LookupPlan: Sendable, Equatable {
    public let route: LookupRoute       // .trivial | .entity | .fresh | .technical
    public let trivialAnswer: String?   // set iff route == .trivial
    public let entity: String?          // native-script entity term, for the entity route
    public let query: String            // normalized search query
    public let needsImage: Bool
    public let needsSearch: Bool
    public let spoken: Language
}

public struct LookupRouter: Sendable {
    let llm: LLMProvider
    let model: String
    let interface: Language

    public init(llm: LLMProvider, model: String, interface: Language) {
        self.llm = llm; self.model = model; self.interface = interface
    }

    public func plan(topic: String, window: String, spoken: Language) async -> LookupPlan {
        // 1) Local trivial: arithmetic, percentages, exact unit/temperature conversions.
        if let local = TrivialAnswer.answer(topic) {
            return LookupPlan(route: .trivial, trivialAnswer: local, entity: nil,
                              query: topic, needsImage: false, needsSearch: false, spoken: spoken)
        }
        // 2) Local freshness guardrail: recency cues or a near-future year force grounded
        // search FIRST, so a current thing (a new movie, a release date) can never be
        // misrouted into a model answer. Checked against the topic and the surrounding
        // utterance, since the cue ("new movie") often sits outside the extracted topic.
        if Freshness.isFresh(topic + " " + window) {
            return LookupPlan(route: .fresh, trivialAnswer: nil, entity: nil,
                              query: topic, needsImage: false, needsSearch: true, spoken: spoken)
        }
        // 3) One model call to classify and extract.
        let user = """
        Interface language: \(Self.name(interface))
        What the user wondered about: "\(topic)"
        Recent conversation (for context, newest last):
        \(window)
        Produce the JSON now.
        """
        guard let raw = try? await llm.complete(system: Prompts.router, user: user, model: model),
              let obj = JSONExtract.decodeObject(raw) else {
            return Self.fallback(topic: topic, spoken: spoken)
        }
        let route: LookupRoute
        switch (obj["route"] as? String)?.lowercased() {
        case "entity": route = .entity
        case "fresh": route = .fresh
        default: route = .technical
        }
        let entity = (obj["entity"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let query = (obj["query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? topic
        let needsImage = (obj["needs_image"] as? Bool) ?? (route == .entity)
        let needsSearch = route == .fresh ? true : ((obj["needs_search"] as? Bool) ?? false)
        return LookupPlan(route: route, trivialAnswer: nil, entity: entity,
                          query: query, needsImage: needsImage, needsSearch: needsSearch, spoken: spoken)
    }

    // Default route when the router call fails or times out: a plain model
    // explanation, no web, no image. Always answers something, never fabricates a
    // source it did not consult.
    static func fallback(topic: String, spoken: Language) -> LookupPlan {
        LookupPlan(route: .technical, trivialAnswer: nil, entity: nil,
                   query: topic, needsImage: false, needsSearch: false, spoken: spoken)
    }

    static func name(_ l: Language) -> String {
        switch l { case .en: return "English"; case .ja: return "Japanese"; case .zh: return "Chinese" }
    }
}
