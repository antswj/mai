import Foundation

public struct CardTelemetry: Identifiable, Sendable, Equatable {
    public let id: String
    public let headline: String
    public let route: LookupRoute
    public let provider: String
    public let trigger: TriggerType
    public let firstPaintMs: Int?
    public let routeMs: Int?
    public let sourceLookupMs: Int?
    public let responseMs: Int?
    public let finalFillMs: Int?
    public let qualityScore: Double?
    public let qualityGrade: String?
    public let suppressed: Bool
    public let suppressionReason: String?

    public init(card: RichCard) {
        self.id = card.id
        self.headline = card.headline
        self.route = card.route
        self.provider = Self.provider(for: card)
        self.trigger = card.trigger
        self.firstPaintMs = card.latencyMs
        self.routeMs = card.timings["route"]
        self.sourceLookupMs = card.timings["content"] ?? card.timings["info"] ?? card.timings["source"]
        self.responseMs = card.timings["response"]
        let values = [routeMs, sourceLookupMs, responseMs, firstPaintMs].compactMap { $0 }
        self.finalFillMs = values.max()
        self.qualityScore = card.rating?.score
        self.qualityGrade = card.rating?.grade
        self.suppressed = card.suppressed
        self.suppressionReason = card.suppressed ? card.note : nil
    }

    private static func provider(for card: RichCard) -> String {
        switch card.route {
        case .trivial:
            return "Local"
        case .preparedReply:
            return "LLM"
        case .place:
            if card.info?.localizedCaseInsensitiveContains("Hot Pepper") == true { return "Hot Pepper" }
            if card.action != nil { return "Places" }
            return "Places"
        case .entity:
            return sourceProvider(card) ?? "Wikipedia"
        case .fresh, .technical:
            if card.searchSuggestionHTML?.isEmpty == false { return "Gemini Grounded" }
            return sourceProvider(card) ?? (card.unverified ? "LLM fallback" : "Grounded Web")
        case .screen:
            return sourceProvider(card) ?? "Screen"
        case .coaching:
            return "Local Coach"
        case .sessionOperator:
            return "Local Operator"
        case .pending:
            return "Pending"
        }
    }

    private static func sourceProvider(_ card: RichCard) -> String? {
        let urls = ([card.source].compactMap { $0 } + card.sources).map(\.url)
        guard let url = urls.first, let host = URL(string: url)?.host?.lowercased() else { return nil }
        if host.contains("wikipedia.org") { return "Wikipedia" }
        if host.contains("duckduckgo.com") { return "DuckDuckGo" }
        if host.contains("google") || host.contains("vertexaisearch") { return "Gemini Grounded" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

public struct LatencyPercentileRow: Identifiable, Sendable, Equatable {
    public let route: LookupRoute
    public let provider: String
    public let count: Int
    public let p50: Int
    public let p95: Int
    public let p99: Int

    public var id: String { "\(route.rawValue)-\(provider)" }
}

public enum LatencyTelemetryStats {
    public static func percentileRows(from rows: [CardTelemetry]) -> [LatencyPercentileRow] {
        let grouped = Dictionary(grouping: rows.compactMap { row -> (LookupRoute, String, Int)? in
            guard let ms = row.finalFillMs ?? row.firstPaintMs else { return nil }
            return (row.route, row.provider, ms)
        }) { item in
            "\(item.0.rawValue)\u{1F}\(item.1)"
        }
        return grouped.values.compactMap { values in
            guard let first = values.first else { return nil }
            let sorted = values.map(\.2).sorted()
            return LatencyPercentileRow(route: first.0, provider: first.1, count: sorted.count,
                                        p50: percentile(sorted, 0.50),
                                        p95: percentile(sorted, 0.95),
                                        p99: percentile(sorted, 0.99))
        }
        .sorted { lhs, rhs in
            if lhs.route.rawValue == rhs.route.rawValue { return lhs.provider < rhs.provider }
            return lhs.route.rawValue < rhs.route.rawValue
        }
    }

    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int(ceil(p * Double(sorted.count))) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }
}

public extension RichCard {
    var telemetry: CardTelemetry { CardTelemetry(card: self) }
}
