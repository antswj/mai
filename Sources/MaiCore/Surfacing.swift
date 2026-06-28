import Foundation

// Noise control: the hard problem. Takes a candidate card plus its trigger,
// scores it, assigns a tier, and decides surface vs suppress against the
// configurable threshold. Also de-dupes and lightly groups so two cards for the
// same topic do not fire back to back. Suppressed cards still flow to the Face's
// quiet log (toggle in config) so the threshold can be tuned by watching it.
//
// Owned by the Engine actor; its memory of recently surfaced topics is never raced.
final class Surfacing {
    private let threshold: Double
    private let groupingSeconds: Double
    private var lastSurfaced: [String: Date] = [:]

    init(threshold: Double, groupingSeconds: Double = 20) {
        self.threshold = threshold
        self.groupingSeconds = groupingSeconds
    }

    enum Decision: Sendable {
        case surface(Card)
        case suppress(Card, reason: String)
    }

    // Pre-enrichment decision for the rich-card path: scores and groups from the
    // trigger + headline alone, so the surface/suppress call is made BEFORE any
    // network lookup (the card is shown, or not, instantly). Mirrors evaluate's
    // scoring and grouping exactly; only one of the two paths runs per engine.
    struct PreDecision: Sendable {
        let surface: Bool
        let tier: Tier
        let score: Double
        let reason: String
    }

    func preEvaluate(trigger: Trigger, headline: String, now: Date) -> PreDecision {
        var score = trigger.confidence
        switch trigger.type {
        case .reference, .screenReference: score += 0.10
        case .place: score += 0.05
        case .question, .intent: break
        }
        score = max(0, min(1, score))
        let tier: Tier = score >= 0.85 ? .critical : (score >= threshold ? .medium : .noise)

        if score < threshold {
            return PreDecision(surface: false, tier: tier, score: score,
                               reason: String(format: "below threshold (%.2f < %.2f)", score, threshold))
        }
        let key = "\(trigger.type.rawValue)|\(headline.lowercased())"
        if let last = lastSurfaced[key], now.timeIntervalSince(last) < groupingSeconds {
            return PreDecision(surface: false, tier: tier, score: score,
                               reason: "grouped with a recent card on the same topic")
        }
        lastSurfaced[key] = now
        return PreDecision(surface: true, tier: tier, score: score, reason: "")
    }

    func evaluate(card: Card, trigger: Trigger, now: Date) -> Decision {
        // Base score is the classifier confidence; light heuristics nudge it.
        var score = card.score
        switch trigger.type {
        case .reference, .screenReference: score += 0.10  // directly requested / pointed at
        case .place: score += 0.05
        case .question, .intent: break
        }
        score = max(0, min(1, score))

        let tier: Tier = score >= 0.85 ? .critical : (score >= threshold ? .medium : .noise)
        let scored = withTierAndScore(card, tier: tier, score: score)

        if score < threshold {
            return .suppress(scored, reason: String(format: "below threshold (%.2f < %.2f)", score, threshold))
        }

        let key = topicKey(card: card, trigger: trigger)
        if let last = lastSurfaced[key], now.timeIntervalSince(last) < groupingSeconds {
            return .suppress(scored, reason: "grouped with a recent card on the same topic")
        }
        lastSurfaced[key] = now
        return .surface(scored)
    }

    private func topicKey(card: Card, trigger: Trigger) -> String {
        "\(trigger.type.rawValue)|\(card.title.lowercased())"
    }

    private func withTierAndScore(_ c: Card, tier: Tier, score: Double) -> Card {
        Card(title: c.title, body: c.body, trigger: c.trigger, tier: tier, score: score,
             timestamp: c.timestamp, action: c.action, latencyMs: c.latencyMs)
    }
}
