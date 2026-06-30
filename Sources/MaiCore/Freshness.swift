import Foundation

// Deterministic, local detection of recency/freshness cues, so current things (a
// brand-new movie, a release date, "latest", a near-future year) are routed straight
// to grounded web search instead of being misclassified into a model answer. This is
// a guardrail in front of the model router: it cannot regress on a live model's
// classification because it runs first and forces the fresh route. Bias is toward
// searching (over-routing to fresh just means a real web lookup, which is safe).
public enum Freshness {
    // Cue words across English, Japanese, and Chinese. Latin cues MUST match on word
    // boundaries (a plain substring match would fire "new" inside "Newton" or "knew",
    // wrongly routing a historical entity to search). CJK has no word boundaries, so
    // those cues match as substrings.
    private static let latinCues = [
        "new", "latest", "newest", "upcoming", "release date", "released", "releasing",
        "coming out", "come out", "trailer", "this year", "next year", "recent",
        "just announced", "announced", "out now", "current", "nowadays", "these days",
        "who won", "price", "stock", "weather", "news",
    ]
    private static let cjkCues = [
        "新しい", "最新", "発売", "公開", "今年", "来年", "予定", "ニュース", "最近",
        "新", "上映", "发布", "发售", "今年", "明年", "新闻", "最近", "预告",
    ]

    private static let latinRegex: NSRegularExpression? = {
        let alt = latinCues.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\b(?:\(alt))\\b", options: [.caseInsensitive])
    }()

    public static func isFresh(_ text: String, now: Date = Date()) -> Bool {
        if let re = latinRegex {
            let ns = text as NSString
            if re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil { return true }
        }
        for cue in cjkCues where text.contains(cue) { return true }
        return hasCurrentOrNearFutureYear(text, now: now)
    }

    // A 4-digit year within [thisYear - 1, thisYear + 5] signals something current or
    // upcoming. Older years (history) and far-future years do not.
    private static func hasCurrentOrNearFutureYear(_ text: String, now: Date) -> Bool {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        guard let re = try? NSRegularExpression(pattern: "\\b(\\d{4})\\b") else { return false }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let y = Int(ns.substring(with: m.range(at: 1))), y >= year - 1, y <= year + 5 { return true }
        }
        return false
    }
}
