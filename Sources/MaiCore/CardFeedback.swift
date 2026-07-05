import Foundation

public enum CardFeedbackKind: String, Codable, Sendable, CaseIterable, Equatable {
    case useful
    case notUseful
    case tooSlow
    case wrongContext

    public var label: String {
        switch self {
        case .useful: return "Useful"
        case .notUseful: return "Not useful"
        case .tooSlow: return "Too slow"
        case .wrongContext: return "Wrong context"
        }
    }
}

public struct CardFeedbackEntry: Codable, Sendable, Equatable {
    public let id: String
    public let cardId: String
    public let headline: String
    public let route: String
    public let ratingScore: Double?
    public let latencyMs: Int?
    public let feedback: CardFeedbackKind
    public let createdAt: Date

    public init(card: RichCard, feedback: CardFeedbackKind, now: Date = Date()) {
        self.id = UUID().uuidString
        self.cardId = card.id
        self.headline = card.headline
        self.route = card.route.rawValue
        self.ratingScore = card.rating?.score
        self.latencyMs = card.latencyMs
        self.feedback = feedback
        self.createdAt = now
    }
}

public struct CardFeedbackCounts: Codable, Sendable, Equatable {
    public var useful: Int = 0
    public var notUseful: Int = 0
    public var tooSlow: Int = 0
    public var wrongContext: Int = 0

    public init(useful: Int = 0, notUseful: Int = 0, tooSlow: Int = 0, wrongContext: Int = 0) {
        self.useful = useful
        self.notUseful = notUseful
        self.tooSlow = tooSlow
        self.wrongContext = wrongContext
    }

    public var total: Int { useful + notUseful + tooSlow + wrongContext }

    public mutating func record(_ feedback: CardFeedbackKind) {
        switch feedback {
        case .useful: useful += 1
        case .notUseful: notUseful += 1
        case .tooSlow: tooSlow += 1
        case .wrongContext: wrongContext += 1
        }
    }

    public func adjustedUsefulThreshold(base: Double = CardRating.usefulThreshold) -> Double {
        guard total > 0 else { return base }
        let negative = notUseful + wrongContext
        let slowPenalty = min(0.08, Double(tooSlow) * 0.01)
        let qualityPenalty = min(0.12, Double(negative) * 0.015)
        let usefulCredit = min(0.08, Double(useful) * 0.006)
        return max(0.40, min(0.75, base + qualityPenalty + slowPenalty - usefulCredit))
    }
}

public struct RouteFeedbackThreshold: Identifiable, Sendable, Equatable {
    public let route: String
    public let threshold: Double
    public let total: Int

    public var id: String { route }
}

public struct CardFeedbackSummary: Codable, Sendable, Equatable {
    public var useful: Int = 0
    public var notUseful: Int = 0
    public var tooSlow: Int = 0
    public var wrongContext: Int = 0
    public var byRoute: [String: CardFeedbackCounts] = [:]

    public init(useful: Int = 0, notUseful: Int = 0, tooSlow: Int = 0,
                wrongContext: Int = 0, byRoute: [String: CardFeedbackCounts] = [:]) {
        self.useful = useful
        self.notUseful = notUseful
        self.tooSlow = tooSlow
        self.wrongContext = wrongContext
        self.byRoute = byRoute
    }

    public var total: Int { useful + notUseful + tooSlow + wrongContext }

    public func adjustedUsefulThreshold(base: Double = CardRating.usefulThreshold) -> Double {
        CardFeedbackCounts(useful: useful, notUseful: notUseful, tooSlow: tooSlow,
                           wrongContext: wrongContext).adjustedUsefulThreshold(base: base)
    }

    public func adjustedUsefulThreshold(for route: LookupRoute, base: Double = CardRating.usefulThreshold) -> Double {
        guard let counts = byRoute[route.rawValue], counts.total > 0 else {
            return adjustedUsefulThreshold(base: base)
        }
        return counts.adjustedUsefulThreshold(base: base)
    }

    public func routeThresholds(base: Double = CardRating.usefulThreshold) -> [RouteFeedbackThreshold] {
        byRoute
            .map { route, counts in
                RouteFeedbackThreshold(route: route,
                                       threshold: counts.adjustedUsefulThreshold(base: base),
                                       total: counts.total)
            }
            .sorted { lhs, rhs in
                if lhs.total == rhs.total { return lhs.route < rhs.route }
                return lhs.total > rhs.total
            }
    }

    public static func summarize(_ entries: [CardFeedbackEntry]) -> CardFeedbackSummary {
        var summary = CardFeedbackSummary()
        for entry in entries {
            summary.byRoute[entry.route, default: CardFeedbackCounts()].record(entry.feedback)
            switch entry.feedback {
            case .useful: summary.useful += 1
            case .notUseful: summary.notUseful += 1
            case .tooSlow: summary.tooSlow += 1
            case .wrongContext: summary.wrongContext += 1
            }
        }
        return summary
    }
}

public actor CardFeedbackStore {
    private let url: URL
    private var entries: [CardFeedbackEntry]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.mai.decode([CardFeedbackEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    public func record(_ entry: CardFeedbackEntry) {
        entries.append(entry)
        persist()
    }

    public func all() -> [CardFeedbackEntry] { entries }

    public func summary() -> CardFeedbackSummary {
        CardFeedbackSummary.summarize(entries)
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder.prettyMai.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

public extension JSONEncoder {
    static var prettyMai: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var mai: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
