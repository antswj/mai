import Foundation

// Seams for the two real, sourced lookups the card brain uses. Both are protocols
// so tests can drop in deterministic stubs (no network) and the app wires the real
// HTTP clients (Wikipedia REST + langlinks, Gemini grounded search).

// A known-entity result, already resolved into the interface language. Image and
// source are real or nil; nothing is fabricated.
public struct EntityResult: Sendable, Equatable {
    public let title: String
    public let summary: String       // in the interface language
    public let imageURL: String?     // real thumbnail URL or nil
    public let sourceURL: String     // the article URL
    public let sourceTitle: String   // e.g. "Wikipedia"
    public init(title: String, summary: String, imageURL: String?, sourceURL: String, sourceTitle: String = "Wikipedia") {
        self.title = title; self.summary = summary; self.imageURL = imageURL
        self.sourceURL = sourceURL; self.sourceTitle = sourceTitle
    }
}

// A grounded web-search result: a synthesized answer in the interface language plus
// the real web sources it was grounded on, and (for attribution) Google's Search
// Suggestions widget HTML when present.
public struct GroundedResult: Sendable, Equatable {
    public let answer: String            // in the interface language
    public let sources: [RichSource]     // real web results
    public let searchSuggestionHTML: String?
    public init(answer: String, sources: [RichSource], searchSuggestionHTML: String? = nil) {
        self.answer = answer; self.sources = sources; self.searchSuggestionHTML = searchSuggestionHTML
    }
}

// Looks up a known entity. `term` may be in native script (e.g. 寿司, 北京). The
// implementation resolves cross-language to the interface article when possible and
// falls back to translating the native summary. Returns nil when nothing is found
// (the card then says so, rather than inventing).
public protocol EntityLookup: Sendable {
    func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult?
}

// Answers a query from grounded web search, in the interface language.
public protocol GroundedSearch: Sendable {
    func answer(query: String, interface: Language) async throws -> GroundedResult
}

// Cheap script detection so a suggested response (Part B) and entity resolution can
// follow the language that was actually spoken, without an extra model call.
public enum ScriptDetect {
    public static func language(of text: String) -> Language {
        var hasKana = false
        var hasHan = false
        var hasLatin = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: hasKana = true       // hiragana + katakana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: hasHan = true        // CJK unified
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true             // basic Latin letters
            default: break
            }
        }
        if hasKana { return .ja }            // any kana => Japanese
        if hasHan { return .zh }             // Han without kana => Chinese
        _ = hasLatin
        return .en
    }
}
