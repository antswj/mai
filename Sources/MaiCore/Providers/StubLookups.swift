import Foundation

// Deterministic stand-ins for the entity and grounded-search lookups, so the rich
// card pipeline is exercised end to end with no live calls. The defaults recognize
// the canonical fixtures (Malaysia, sushi) across English/Japanese/Chinese and
// always return an interface-language summary, mirroring real cross-language
// resolution. A custom handler can be injected for bespoke cases.
public struct StubEntityLookup: EntityLookup {
    private let handler: @Sendable (_ term: String, _ spoken: Language, _ interface: Language) -> EntityResult?
    public init(_ handler: @escaping @Sendable (String, Language, Language) -> EntityResult?) { self.handler = handler }
    public init() { self.handler = StubEntityLookup.defaultHandler }

    public func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
        handler(term, spoken, interface)
    }

    static func defaultHandler(_ term: String, _ spoken: Language, _ interface: Language) -> EntityResult? {
        let t = term.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { t.contains($0.lowercased()) || term.contains($0) } }
        if has(["malaysia", "マレーシア", "马来西亚", "馬來西亞"]) {
            return EntityResult(
                title: "Malaysia",
                summary: "Malaysia is a country in Southeast Asia, made up of a peninsula and part of the island of Borneo, known for rainforests, beaches, and a mix of Malay, Chinese, and Indian cultures.",
                imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/Malaysia.jpg",
                sourceURL: "https://en.wikipedia.org/wiki/Malaysia")
        }
        if has(["sushi", "寿司", "お寿司", "壽司"]) {
            return EntityResult(
                title: "Sushi",
                summary: "Sushi is a Japanese dish of vinegared rice combined with seafood, vegetables, and sometimes tropical fruits, served in many forms such as nigiri and maki.",
                imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/Sushi.jpg",
                sourceURL: "https://en.wikipedia.org/wiki/Sushi")
        }
        return nil
    }
}

public struct StubGroundedSearch: GroundedSearch {
    private let handler: @Sendable (_ query: String, _ interface: Language) -> GroundedResult
    public init(_ handler: @escaping @Sendable (String, Language) -> GroundedResult) { self.handler = handler }
    public init() { self.handler = StubGroundedSearch.defaultHandler }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        handler(query, interface)
    }

    static func defaultHandler(_ query: String, _ interface: Language) -> GroundedResult {
        GroundedResult(
            answer: "Based on current sources, here is a concise answer about \(query).",
            sources: [RichSource(title: "Example News", url: "https://example.com/article")],
            searchSuggestionHTML: "<div>Search suggestions</div>")
    }
}
