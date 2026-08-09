import Foundation

public struct AdaptiveQuietDecision: Sendable, Equatable {
    public let suppress: Bool
    public let reason: String?
    public let threshold: Double

    public init(suppress: Bool, reason: String?, threshold: Double) {
        self.suppress = suppress
        self.reason = reason
        self.threshold = threshold
    }
}

public enum AdaptiveQuietPolicy {
    public static let notePrefix = "adaptive quiet"

    public static func decision(for card: RichCard, recentCards: [RichCard],
                                feedbackSummary: CardFeedbackSummary,
                                config: Config, now: Date = Date()) -> AdaptiveQuietDecision {
        let baseThreshold = feedbackSummary.adjustedUsefulThreshold(for: card.route)
        guard config.adaptiveQuietMode else {
            return AdaptiveQuietDecision(suppress: false, reason: nil, threshold: baseThreshold)
        }
        guard !isProtected(card) else {
            return AdaptiveQuietDecision(suppress: false, reason: nil, threshold: baseThreshold)
        }

        let recent = recentCards.filter {
            $0.id != card.id &&
            !$0.suppressed &&
            now.timeIntervalSince($0.timestamp) <= config.adaptiveQuietWindowSeconds
        }
        let sameRoute = recent.filter { $0.route == card.route || $0.trigger == card.trigger }
        var threshold = baseThreshold
        var reasons: [String] = []
        let strength = max(0, min(1, config.adaptiveQuietLearningStrength))

        if recent.count >= config.adaptiveQuietMaxVisibleCards {
            threshold += 0.08 * strength
            reasons.append("recent density")
        }
        if sameRoute.count >= 2 {
            threshold += 0.06 * strength
            reasons.append("route fatigue")
        }
        if let routeFeedback = feedbackSummary.byRoute[card.route.rawValue],
           routeFeedback.total >= 3,
           routeFeedback.notUseful + routeFeedback.wrongContext > routeFeedback.useful {
            threshold += 0.05 * strength
            reasons.append("learned feedback")
        }

        threshold = min(0.88, threshold)
        guard !reasons.isEmpty else {
            return AdaptiveQuietDecision(suppress: false, reason: nil, threshold: threshold)
        }

        let quality = card.rating?.score ?? card.score
        guard quality < threshold else {
            return AdaptiveQuietDecision(suppress: false, reason: nil, threshold: threshold)
        }

        let reason = "\(notePrefix): \(reasons.joined(separator: ", ")); \(String(format: "%.2f", quality)) < \(String(format: "%.2f", threshold))"
        return AdaptiveQuietDecision(suppress: true, reason: reason, threshold: threshold)
    }

    public static func isAdaptiveQuietNote(_ note: String?) -> Bool {
        note?.hasPrefix(notePrefix) == true
    }

    private static func isProtected(_ card: RichCard) -> Bool {
        if card.tier == .critical { return true }
        switch card.route {
        case .sessionOperator, .preparedReply, .coaching:
            return true
        default:
            return false
        }
    }
}
