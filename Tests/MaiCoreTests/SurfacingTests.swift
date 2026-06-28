import Testing
import Foundation
@testable import MaiCore

@Suite struct SurfacingTests {
    private func card(_ score: Double, title: String = "Topic") -> Card {
        Card(title: title, body: "b", trigger: .question, tier: .medium, score: score,
             timestamp: Date(), action: nil, latencyMs: nil)
    }
    private func trig(_ type: TriggerType = .question, _ conf: Double) -> Trigger {
        Trigger(type: type, span: "x", reason: "r", confidence: conf, payload: [:])
    }

    @Test func belowThresholdSuppressed() {
        let s = Surfacing(threshold: 0.6)
        if case .suppress(let c, let why) = s.evaluate(card: card(0.5), trigger: trig(.question, 0.5), now: Date()) {
            #expect(c.tier == .noise)
            #expect(why.contains("threshold"))
        } else { Issue.record("expected suppress below threshold") }
    }

    @Test func atThresholdSurfacesAsMedium() {
        let s = Surfacing(threshold: 0.6)
        if case .surface(let c) = s.evaluate(card: card(0.7), trigger: trig(.question, 0.7), now: Date()) {
            #expect(c.tier == .medium)
        } else { Issue.record("expected surface at/above threshold") }
    }

    @Test func highScoreIsCritical() {
        let s = Surfacing(threshold: 0.6)
        if case .surface(let c) = s.evaluate(card: card(0.9), trigger: trig(.question, 0.9), now: Date()) {
            #expect(c.tier == .critical)
        } else { Issue.record("expected surface critical") }
    }

    @Test func referenceBoostLifts() {
        // 0.78 + 0.10 reference boost = 0.88 -> critical
        let s = Surfacing(threshold: 0.6)
        if case .surface(let c) = s.evaluate(card: card(0.78), trigger: trig(.reference, 0.78), now: Date()) {
            #expect(c.tier == .critical)
            #expect(c.score > 0.85)
        } else { Issue.record("reference boost should lift the score") }
    }

    @Test func groupingSuppressesBackToBack() {
        let s = Surfacing(threshold: 0.6)
        let now = Date()
        let first = s.evaluate(card: card(0.9, title: "Nearby: sushi"), trigger: trig(.place, 0.9), now: now)
        if case .surface = first {} else { Issue.record("first should surface") }
        let second = s.evaluate(card: card(0.9, title: "Nearby: sushi"), trigger: trig(.place, 0.9), now: now.addingTimeInterval(3))
        if case .suppress(_, let why) = second {
            #expect(why.contains("grouped"))
        } else { Issue.record("second same-topic card should be grouped/suppressed") }
    }
}
