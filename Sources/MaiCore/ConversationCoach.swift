import Foundation

public struct CoachingInsight: Sendable, Equatable {
    public let key: String
    public let headline: String
    public let info: String
    public let tier: Tier
    public let score: Double
    public let trust: [TrustSignal]

    public init(key: String, headline: String, info: String, tier: Tier, score: Double, trust: [TrustSignal]) {
        self.key = key
        self.headline = headline
        self.info = info
        self.tier = tier
        self.score = score
        self.trust = trust
    }
}

public enum ConversationCoach {
    private enum CoachingAIError: Error { case noInsight }

    public static func insight(for event: TranscriptEvent, window: String) -> CoachingInsight? {
        guard event.isFinal else { return nil }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        let low = text.lowercased()
        let speaker = event.speaker?.isEmpty == false ? event.speaker! : "the speaker"

        if containsAny(low, text, uncertaintyTerms) {
            return CoachingInsight(
                key: "uncertainty|\(speaker)",
                headline: "Possible uncertainty",
                info: "\(speaker) used hedging language. A good move is to ask what would make them confident, what is still unknown, or what evidence would change the decision.",
                tier: .medium,
                score: 0.68,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.72),
                    TrustSignal(label: "Coach type", detail: "Uncertainty/hesitation, not deception detection.", confidence: 0.86),
                    TrustSignal(label: "Safety", detail: "No lie or intent claim; tone alone is not treated as proof.", confidence: 0.98)
                ])
        }

        if containsAny(low, text, concernTerms) {
            return CoachingInsight(
                key: "concern|\(speaker)",
                headline: "Address the concern",
                info: "\(speaker) surfaced risk or friction. Acknowledge it first, then ask for the concrete blocker and the smallest next step that would reduce the risk.",
                tier: .critical,
                score: 0.78,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.76),
                    TrustSignal(label: "Coach type", detail: "Objection/concern pattern from transcript wording, not deception detection.", confidence: 0.82),
                    TrustSignal(label: "Safety", detail: "No lie or intent claim; tone alone is not treated as proof.", confidence: 0.98)
                ])
        }

        if containsAny(low, text, commitmentTerms) {
            return CoachingInsight(
                key: "commitment|\(speaker)",
                headline: "Capture the next step",
                info: "A possible commitment or follow-up appeared. Confirm owner, deadline, and success criteria before the meeting moves on.",
                tier: .medium,
                score: 0.66,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.70),
                    TrustSignal(label: "Coach type", detail: "Action-item pattern, not deception detection.", confidence: 0.78),
                    TrustSignal(label: "Safety", detail: "No lie or intent claim; tone alone is not treated as proof.", confidence: 0.98)
                ])
        }

        return nil
    }

    public static func aiInsight(for event: TranscriptEvent, window: String, llm: LLMProvider,
                                 model: String, interfaceLanguage: Language) async throws -> CoachingInsight? {
        guard event.isFinal, let vocal = event.vocalSignal else { return nil }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, vocal.capturedSeconds >= 0.4 else { return nil }

        let speaker = event.speaker?.isEmpty == false ? event.speaker! : "the speaker"
        let user = """
        Interface language: \(LookupRouter.name(interfaceLanguage))
        Speaker: \(speaker)
        Current utterance:
        \(text)

        Vocal feature summary from local PCM analysis:
        \(vocal.summary)

        Recent transcript context:
        \(clipped(window, max: 1800))

        Return the JSON now.
        """
        let raw = try await llm.complete(system: aiCoachSystemPrompt, user: user, model: model)
        guard let json = JSONExtract.decodeObject(raw),
              bool(json["should_surface"]) == true else { return nil }

        let headline = string(json["headline"]) ?? "Voice-aware coaching"
        let recommendation = string(json["recommended_move"])
        var info = string(json["info"]) ?? recommendation ?? ""
        if let recommendation, !info.localizedCaseInsensitiveContains(recommendation) {
            info = info.isEmpty ? recommendation : "\(info) \(recommendation)"
        }
        info = info.trimmingCharacters(in: .whitespacesAndNewlines)
        guard info.count >= 24 else { return nil }
        guard !containsForbiddenInference(headline + " " + info) else { return nil }

        let tier = Tier(rawValue: (string(json["tier"]) ?? "medium").lowercased()) ?? .medium
        let score = max(0.55, min(0.92, number(json["score"]) ?? 0.74))
        let cues = stringArray(json["observed_voice_cues"]).prefix(3).joined(separator: " | ")
        let cueDetail = cues.isEmpty ? vocal.summary : cues

        return CoachingInsight(
            key: "ai-vocal|\(speaker)",
            headline: headline,
            info: info,
            tier: tier,
            score: score,
            trust: [
                TrustSignal(label: "Voice features", detail: clipped(cueDetail, max: 180), confidence: 0.74),
                TrustSignal(label: "Transcript evidence", detail: clipped(text), confidence: 0.76),
                TrustSignal(label: "AI review", detail: "Vocal features plus recent transcript context.", confidence: 0.70),
                TrustSignal(label: "Safety", detail: "No lie, deception, diagnosis, or intent claim; coaching only.", confidence: 0.98)
            ])
    }

    public static func requireAIInsight(for event: TranscriptEvent, window: String, llm: LLMProvider,
                                        model: String, interfaceLanguage: Language) async throws -> CoachingInsight {
        guard let insight = try await aiInsight(for: event, window: window, llm: llm,
                                                model: model, interfaceLanguage: interfaceLanguage)
        else { throw CoachingAIError.noInsight }
        return insight
    }

    public static func operatorChecklist(lines: [MeetingLine], cards: [RichCard], savedTitle: String? = nil) -> RichCard? {
        guard !lines.isEmpty || cards.contains(where: { !$0.suppressed }) || savedTitle != nil else { return nil }
        let actions = extractedActions(from: lines)
        let questions = extractedOpenQuestions(from: lines)
        let usefulCards = cards.filter { !$0.suppressed && $0.pending.isEmpty }

        var bullets: [String] = []
        if let savedTitle { bullets.append("Saved notes: \(savedTitle)") }
        if !actions.isEmpty {
            bullets.append("Follow-ups to confirm: \(actions.prefix(3).joined(separator: " | "))")
        } else {
            bullets.append("No explicit owner/deadline follow-up was captured; confirm next steps before this goes cold.")
        }
        if !questions.isEmpty {
            bullets.append("Open questions: \(questions.prefix(2).joined(separator: " | "))")
        }
        if !usefulCards.isEmpty {
            bullets.append("Useful cards surfaced: \(usefulCards.prefix(4).map(\.headline).joined(separator: ", "))")
        }
        bullets.append("Suggested close-out: send recap, decisions, owners, dates, and unresolved questions.")

        var card = RichCard(trigger: .intent, timestamp: Date(), route: .sessionOperator,
                            tier: .critical, score: 0.86,
                            headline: "Session operator",
                            info: bullets.joined(separator: "\n"),
                            pending: [],
                            trust: [
                                TrustSignal(label: "Inputs", detail: "\(lines.count) transcript line(s), \(usefulCards.count) useful card(s).", confidence: 0.94),
                                TrustSignal(label: "Purpose", detail: "End-of-session checklist from captured context.", confidence: 0.90)
                            ])
        card.rating = CardRating.evaluate(card)
        return card
    }

    private static let uncertaintyTerms = [
        "not sure", "maybe", "i think", "i guess", "probably", "possibly", "might", "could be",
        "たぶん", "かもしれない", "と思います", "不确定", "可能", "也许"
    ]
    private static let concernTerms = [
        "concern", "worried", "worry", "risk", "risky", "issue", "problem", "blocker", "blocked",
        "but ", "however", "budget", "timeline", "deadline", "懸念", "心配", "問題", "リスク", "但是", "问题", "风险"
    ]
    private static let commitmentTerms = [
        "i'll", "i will", "we will", "we should", "follow up", "next step", "action item",
        "対応します", "確認します", "フォロー", "下一步", "跟进", "我会", "我们会"
    ]

    private static let aiCoachSystemPrompt = """
    You are Mai's live vocal coaching analyst. You help the user navigate a live conversation.

    You receive:
    - The current utterance.
    - A compact vocal feature summary extracted locally from PCM audio.
    - Recent transcript context.

    Decide whether a coaching card would genuinely help right now. If yes, give one short, actionable move.

    Rules:
    - Use observable signals only: pace, pauses, vocal energy, rough pitch movement, interruption/hesitation patterns, and transcript context.
    - Never claim someone is lying, deceptive, honest, dishonest, guilty, nervous, afraid, or hiding something.
    - Never diagnose mental state or intent. Phrase uncertainty as "may indicate", "could be a good moment", or "observed cue".
    - Prefer a concrete next move: ask a clarifying question, slow down, recap, invite a quieter person, confirm owner/deadline, or acknowledge friction.
    - If the vocal signal is weak, noisy, too short, or the coaching would be generic, set should_surface=false.
    - Output only JSON:
      {
        "should_surface": true,
        "headline": "short title",
        "info": "one to two concise sentences in the interface language",
        "recommended_move": "one concrete sentence",
        "tier": "medium",
        "score": 0.74,
        "observed_voice_cues": ["cue 1", "cue 2"]
      }
    """

    private static func containsAny(_ low: String, _ original: String, _ needles: [String]) -> Bool {
        needles.contains { low.contains($0.lowercased()) || original.contains($0) }
    }

    private static func containsForbiddenInference(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.contains("lying")
            || low.contains(" liar")
            || low.contains("deceptive")
            || low.contains("deception")
            || low.contains("dishonest")
            || low.contains("truthful")
            || low.contains("guilty")
            || low.contains("hiding something")
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        return false
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { string($0) }.filter { !$0.isEmpty } ?? []
    }

    private static func clipped(_ text: String, max: Int = 120) -> String {
        text.count <= max ? text : String(text.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func extractedActions(from lines: [MeetingLine]) -> [String] {
        lines.map(\.text).filter { text in
            let low = text.lowercased()
            return containsAny(low, text, commitmentTerms) || low.contains("due") || low.contains("owner")
        }
    }

    private static func extractedOpenQuestions(from lines: [MeetingLine]) -> [String] {
        lines.map(\.text).filter { text in
            text.contains("?") || text.contains("？")
        }
    }
}
