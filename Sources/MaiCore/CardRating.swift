import Foundation

public struct CardRating: Sendable, Equatable {
    public static let usefulThreshold = 0.52

    public let score: Double
    public let grade: String
    public let reasons: [String]
    public let useful: Bool

    public init(score: Double, grade: String, reasons: [String], useful: Bool) {
        self.score = score
        self.grade = grade
        self.reasons = reasons
        self.useful = useful
    }

    public static func evaluate(_ card: RichCard) -> CardRating {
        var score = 0.22 + max(0, min(1, card.score)) * 0.40
        var reasons: [String] = []
        let info = card.info?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !info.isEmpty {
            score += 0.16
            reasons.append("has answer")
            if info.count >= 40 { score += 0.05; reasons.append("specific") }
            if info.count < 8, card.route != .trivial { score -= 0.10; reasons.append("too short") }
        }
        if let response = card.response, !response.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 0.28
            reasons.append("reply ready")
            if !response.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                score += 0.04
                reasons.append("translated")
            }
            if response.rationale?.isEmpty == false {
                score += 0.02
            }
        }
        if card.source != nil || !card.sources.isEmpty {
            score += 0.16
            reasons.append("sourced")
        }
        if card.action != nil {
            score += 0.12
            reasons.append("actionable")
        }
        if card.imageURL != nil {
            score += 0.03
            reasons.append("visual")
        }

        switch card.route {
        case .trivial:
            if !info.isEmpty { score += 0.20; reasons.append("instant exact answer") }
        case .place:
            if info.localizedCaseInsensitiveContains("m away") { score += 0.06; reasons.append("distance") }
            if info.localizedCaseInsensitiveContains("no nearby matches") { score -= 0.28; reasons.append("no match") }
        case .preparedReply:
            if card.response == nil { score -= 0.25; reasons.append("missing reply") }
        case .entity, .fresh:
            if card.source == nil && card.sources.isEmpty { score -= 0.10; reasons.append("no source") }
        case .technical:
            if card.unverified { reasons.append("unverified") }
        case .screen:
            if !info.isEmpty { score += 0.04 }
        case .pending:
            break
        }

        if card.unverified {
            score -= 0.10
            if !reasons.contains("unverified") { reasons.append("unverified") }
        }
        if looksLikeConnectivityFallback(info) {
            score -= 0.36
            reasons.append("fallback only")
        }
        if info.localizedCaseInsensitiveContains("i don't know")
            || info.localizedCaseInsensitiveContains("not enough information") {
            score -= 0.18
            reasons.append("low information")
        }

        let slowest = max(card.timings.values.max() ?? 0, card.latencyMs ?? 0)
        if slowest > 10_000 {
            score -= 0.14
            reasons.append("very slow")
        } else if slowest > 5_000 {
            score -= 0.08
            reasons.append("slow")
        } else if slowest > 0 && slowest <= 1_000 {
            score += 0.03
            reasons.append("fast")
        }

        score = max(0, min(1, score))
        let grade: String
        if score >= 0.85 { grade = "excellent" }
        else if score >= 0.70 { grade = "good" }
        else if score >= usefulThreshold { grade = "okay" }
        else { grade = "weak" }
        if reasons.isEmpty { reasons = ["trigger confidence"] }
        return CardRating(score: score, grade: grade, reasons: reasons, useful: score >= usefulThreshold)
    }

    private static func looksLikeConnectivityFallback(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("could not reach")
        || text.localizedCaseInsensitiveContains("unable to fetch")
        || text.localizedCaseInsensitiveContains("情報を取得できません")
        || text.localizedCaseInsensitiveContains("无法获取")
    }
}
