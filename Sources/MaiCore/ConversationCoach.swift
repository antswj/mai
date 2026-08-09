import Foundation

public struct CoachingInsight: Sendable, Equatable {
    public let key: String
    public let headline: String
    public let info: String
    public let tier: Tier
    public let score: Double
    public let trust: [TrustSignal]
    /// A sentence the user could say back, in the language the other person is speaking,
    /// with an interface-language translation. Reuses RichResponse because both card
    /// renderers already display it with ruby (furigana over kanji, pinyin over hanzi).
    public let response: RichResponse?

    public init(key: String, headline: String, info: String, tier: Tier, score: Double,
                trust: [TrustSignal], response: RichResponse? = nil) {
        self.key = key
        self.headline = headline
        self.info = info
        self.tier = tier
        self.score = score
        self.trust = trust
        self.response = response
    }

    /// The same insight with its reply dropped, keeping the analysis. Used when a prepared
    /// reply card already covered this moment.
    public func withoutResponse() -> CoachingInsight {
        CoachingInsight(key: key, headline: headline, info: info, tier: tier,
                        score: score, trust: trust, response: nil)
    }
}

public enum ConversationCoach {
    private enum CoachingAIError: Error { case noInsight }

    /// Which side spoke. `TranscriptEvent.source` is the direct signal; the vocal signal
    /// carries the same thing and is the fallback for producers not yet updated.
    public static func speakerSource(of event: TranscriptEvent) -> SpeakerSource? {
        event.source ?? event.vocalSignal?.source
    }

    // The instant, local, zero-cost layer. It never carries a suggested reply: with no
    // model call, any reply it produced would be a canned template, which is exactly what
    // the reply feature must not be. Analysis only; the AI path carries the replies.
    //
    // The wording follows the interface language. `interfaceLanguage` has no default so
    // the compiler flags every call site rather than silently keeping English.
    public static func insight(for event: TranscriptEvent, window: String,
                               interfaceLanguage: Language) -> CoachingInsight? {
        guard event.isFinal else { return nil }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return nil }
        let low = text.lowercased()
        let speaker = event.speaker?.isEmpty == false ? event.speaker! : "the speaker"

        // The cue key stays language-independent, so switching the interface language
        // never resets the refire cooldown.
        if containsAny(low, text, uncertaintyTerms) {
            let t = template(.uncertainty, interfaceLanguage, speaker: speaker)
            return CoachingInsight(
                key: "uncertainty|\(speaker)",
                headline: t.headline, info: t.info,
                tier: .medium, score: 0.68,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.72),
                    TrustSignal(label: "Coach type", detail: t.coachType, confidence: 0.86),
                    TrustSignal(label: "Safety", detail: t.safety, confidence: 0.98)
                ])
        }

        if containsAny(low, text, concernTerms) {
            let t = template(.concern, interfaceLanguage, speaker: speaker)
            return CoachingInsight(
                key: "concern|\(speaker)",
                headline: t.headline, info: t.info,
                tier: .critical, score: 0.78,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.76),
                    TrustSignal(label: "Coach type", detail: t.coachType, confidence: 0.82),
                    TrustSignal(label: "Safety", detail: t.safety, confidence: 0.98)
                ])
        }

        if containsAny(low, text, commitmentTerms) {
            let t = template(.commitment, interfaceLanguage, speaker: speaker)
            return CoachingInsight(
                key: "commitment|\(speaker)",
                headline: t.headline, info: t.info,
                tier: .medium, score: 0.66,
                trust: [
                    TrustSignal(label: "Observed cue", detail: clipped(text), confidence: 0.70),
                    TrustSignal(label: "Coach type", detail: t.coachType, confidence: 0.78),
                    TrustSignal(label: "Safety", detail: t.safety, confidence: 0.98)
                ])
        }

        return nil
    }

    private enum Cue { case uncertainty, concern, commitment }
    private struct CoachTemplate { let headline: String; let info: String; let coachType: String; let safety: String }

    // Trust LABELS stay in English: they are structural keys the telemetry view groups on.
    // The detail text, which is what the user actually reads, follows the interface language.
    private static func template(_ cue: Cue, _ language: Language, speaker: String) -> CoachTemplate {
        switch (cue, language) {
        case (.uncertainty, .en):
            return CoachTemplate(
                headline: "Possible uncertainty",
                info: "\(speaker) used hedging language. A good move is to ask what would make them confident, what is still unknown, or what evidence would change the decision.",
                coachType: "Uncertainty/hesitation, not deception detection.",
                safety: "No lie or intent claim; tone alone is not treated as proof.")
        case (.uncertainty, .ja):
            return CoachTemplate(
                headline: "迷いが見えるかもしれません",
                info: "\(speaker)がぼかした言い方をしました。何があれば確信を持てるか、まだ分かっていないことは何か、どんな材料があれば判断が変わるかを聞いてみましょう。",
                coachType: "迷いやためらいの兆候であり、うそ発見ではありません。",
                safety: "うそや意図の断定はしません。話し方だけを証拠として扱いません。")
        case (.uncertainty, .zh):
            return CoachTemplate(
                headline: "可能存在不确定",
                info: "\(speaker)使用了模糊的说法。可以问对方需要什么才能确定、目前还有哪些未知，或者什么证据会改变判断。",
                coachType: "这是犹豫或不确定的迹象，不是测谎。",
                safety: "不断定谎言或意图，仅凭语气不作为证据。")
        case (.concern, .en):
            return CoachTemplate(
                headline: "Address the concern",
                info: "\(speaker) surfaced risk or friction. Acknowledge it first, then ask for the concrete blocker and the smallest next step that would reduce the risk.",
                coachType: "Objection/concern pattern from transcript wording, not deception detection.",
                safety: "No lie or intent claim; tone alone is not treated as proof.")
        case (.concern, .ja):
            return CoachTemplate(
                headline: "懸念に向き合う",
                info: "\(speaker)がリスクや摩擦を口にしました。まず受け止めたうえで、具体的な障害と、リスクを下げる最小の次の一歩を聞きましょう。",
                coachType: "発言の言葉づかいから見た懸念のパターンであり、うそ発見ではありません。",
                safety: "うそや意図の断定はしません。話し方だけを証拠として扱いません。")
        case (.concern, .zh):
            return CoachTemplate(
                headline: "回应对方的顾虑",
                info: "\(speaker)提到了风险或阻力。先表示理解，再询问具体的障碍，以及能降低风险的最小下一步。",
                coachType: "这是根据用词判断的顾虑模式，不是测谎。",
                safety: "不断定谎言或意图，仅凭语气不作为证据。")
        case (.commitment, .en):
            return CoachTemplate(
                headline: "Capture the next step",
                info: "A possible commitment or follow-up appeared. Confirm owner, deadline, and success criteria before the meeting moves on.",
                coachType: "Action-item pattern, not deception detection.",
                safety: "No lie or intent claim; tone alone is not treated as proof.")
        case (.commitment, .ja):
            return CoachTemplate(
                headline: "次の一歩を確認する",
                info: "約束やフォローアップになりそうな発言が出ました。話が進む前に、担当者、期限、完了の条件を確認しましょう。",
                coachType: "アクションアイテムのパターンであり、うそ発見ではありません。",
                safety: "うそや意図の断定はしません。話し方だけを証拠として扱いません。")
        case (.commitment, .zh):
            return CoachTemplate(
                headline: "确认下一步",
                info: "出现了可能的承诺或后续事项。在话题继续之前，确认负责人、截止时间和完成标准。",
                coachType: "这是行动事项的模式，不是测谎。",
                safety: "不断定谎言或意图，仅凭语气不作为证据。")
        }
    }

    public static func aiInsight(for event: TranscriptEvent, window: String, llm: LLMProvider,
                                 model: String, interfaceLanguage: Language,
                                 spokenLanguage: Language, suggestReplies: Bool) async throws -> CoachingInsight? {
        guard event.isFinal, let vocal = event.vocalSignal else { return nil }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, vocal.capturedSeconds >= 0.4 else { return nil }

        let speaker = event.speaker?.isEmpty == false ? event.speaker! : "the speaker"
        // Only the other party's words get a reply. Coaching the user on how to answer
        // their own sentence is meaningless, and this rule lives here (not in the Engine)
        // so the acceptance harness covers it directly.
        let source = speakerSource(of: event)
        let allowReply = suggestReplies && source == .remote
        let whoSpoke = source == .user ? "the user themselves; do not suggest a reply" : "the other party"
        let user = """
        Interface language: \(LookupRouter.name(interfaceLanguage))
        Spoken language: \(LookupRouter.name(spokenLanguage))
        Speaker: \(speaker)
        Who spoke: \(whoSpoke)
        Suggested reply requested: \(allowReply ? "yes" : "no")
        Current utterance:
        \(text)

        Vocal feature summary from local PCM analysis:
        \(vocal.summary)

        Recent transcript context:
        \(clipped(window, max: 1800))

        Return the JSON now.
        """
        let raw = try await llm.complete(system: Prompts.coach, user: user, model: model)
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

        let replyText = (string(json["suggested_reply"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let replyTranslation = (string(json["reply_translation"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The reply is the text the user says OUT LOUD, so it is the highest-consequence
        // surface here and the safety filter must cover it. A hit rejects the whole
        // output: an answer that produced a deception claim anywhere is not one to trust
        // the analysis from either.
        guard !containsForbiddenInference([headline, info, replyText, replyTranslation].joined(separator: " ")) else { return nil }

        var response: RichResponse?
        if allowReply, !replyText.isEmpty {
            // Local, free language-parity guard. The real failure mode is answering a
            // Japanese speaker in English. ScriptDetect maps Han-without-kana to zh, never
            // to en, so all-kanji Japanese cannot trip this by accident.
            let looksEnglish = ScriptDetect.language(of: replyText) == .en
            if spokenLanguage == .en || !looksEnglish {
                response = RichResponse(spoken: replyText,
                                        translation: replyTranslation,
                                        language: spokenLanguage,
                                        rationale: "Draft suggestion. Adjust or ignore as you like.")
            }
        }

        let tier = Tier(rawValue: (string(json["tier"]) ?? "medium").lowercased()) ?? .medium
        let score = max(0.55, min(0.92, number(json["score"]) ?? 0.74))
        let cues = stringArray(json["observed_voice_cues"]).prefix(3).joined(separator: " | ")
        let cueDetail = cues.isEmpty ? vocal.summary : cues
        let framework = string(json["framework"]) ?? "Motivational Interviewing OARS + active listening"

        return CoachingInsight(
            key: "ai-vocal|\(speaker)",
            headline: headline,
            info: info,
            tier: tier,
            score: score,
            trust: [
                TrustSignal(label: "Framework", detail: clipped(framework, max: 160), confidence: 0.80),
                TrustSignal(label: "Voice features", detail: clipped(cueDetail, max: 180), confidence: 0.74),
                TrustSignal(label: "Transcript evidence", detail: clipped(text), confidence: 0.76),
                TrustSignal(label: "AI review", detail: "Vocal features plus recent transcript context.", confidence: 0.70),
                TrustSignal(label: "Safety", detail: "No lie, deception, diagnosis, or intent claim; coaching only. Suggested wording is a draft you choose whether to say.", confidence: 0.98)
            ],
            response: response)
    }

    public static func requireAIInsight(for event: TranscriptEvent, window: String, llm: LLMProvider,
                                        model: String, interfaceLanguage: Language,
                                        spokenLanguage: Language, suggestReplies: Bool) async throws -> CoachingInsight {
        guard let insight = try await aiInsight(for: event, window: window, llm: llm,
                                                model: model, interfaceLanguage: interfaceLanguage,
                                                spokenLanguage: spokenLanguage, suggestReplies: suggestReplies)
        else { throw CoachingAIError.noInsight }
        return insight
    }

    public static func operatorChecklist(lines: [MeetingLine], cards: [RichCard], savedTitle: String? = nil) -> RichCard? {
        guard !lines.isEmpty || cards.contains(where: { !$0.suppressed }) || savedTitle != nil else { return nil }
        let actions = extractedActions(from: lines)
        let decisions = extractedDecisions(from: lines)
        let questions = extractedOpenQuestions(from: lines)
        let usefulCards = cards.filter { !$0.suppressed && $0.pending.isEmpty }

        var sections: [String] = []
        var snapshot = ["\(lines.count) transcript line(s)", "\(usefulCards.count) useful card(s)"]
        if let savedTitle { snapshot.insert("Saved notes: \(savedTitle)", at: 0) }
        sections.append(section("Snapshot", snapshot))
        sections.append(section("Decisions", decisions.isEmpty
                                ? ["No explicit decision was captured; ask the room to confirm what was decided."]
                                : Array(decisions.prefix(4))))
        sections.append(section("Follow-ups", actions.isEmpty
                                ? ["No explicit owner/deadline follow-up was captured; confirm next steps before this goes cold."]
                                : Array(actions.prefix(4))))
        if !questions.isEmpty {
            sections.append(section("Open Questions", Array(questions.prefix(3))))
        }
        let continuitySources = usefulSources(from: usefulCards)
        let links = continuitySources.map { "\($0.title) \($0.url)" }
        if !links.isEmpty {
            sections.append(section("Links", Array(links.prefix(4))))
        }
        let replay = replayPoints(from: lines)
        if !replay.isEmpty {
            sections.append(section("Replay Points", Array(replay.prefix(4))))
        }
        sections.append(section("Close-Out", ["Send recap, decisions, owners, dates, links, and unresolved questions."]))

        var card = RichCard(trigger: .intent, timestamp: Date(), route: .sessionOperator,
                            tier: .critical, score: 0.86,
                            headline: "Session recap",
                            info: sections.joined(separator: "\n\n"),
                            sources: Array(continuitySources.prefix(4)),
                            pending: [],
                            trust: [
                                TrustSignal(label: "Inputs", detail: "\(lines.count) transcript line(s), \(usefulCards.count) useful card(s).", confidence: 0.94),
                                TrustSignal(label: "Artifact", detail: "Continuity handoff from captured context.", confidence: 0.90)
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

    // The coaching system prompt lives in Prompts/coach.txt so it can be iterated
    // without recompiling, like every other prompt.

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

    private static func extractedDecisions(from lines: [MeetingLine]) -> [String] {
        let terms = ["decided", "decision", "approved", "approve", "go with", "let's", "ship", "we will",
                     "決定", "決め", "承認", "决定", "批准"]
        return lines.map(\.text).filter { text in
            let low = text.lowercased()
            return containsAny(low, text, terms)
        }
    }

    private static func extractedOpenQuestions(from lines: [MeetingLine]) -> [String] {
        lines.map(\.text).filter { text in
            text.contains("?") || text.contains("？")
        }
    }

    private static func usefulSources(from cards: [RichCard]) -> [RichSource] {
        var out: [RichSource] = []
        var seen = Set<String>()
        for card in cards {
            let candidates = card.sources.isEmpty ? (card.source.map { [$0] } ?? []) : card.sources
            for source in candidates.prefix(2) {
                guard seen.insert(source.url).inserted else { continue }
                out.append(RichSource(title: "\(card.headline): \(source.title)", url: source.url))
            }
            if let action = card.action, let url = action.params["url"], seen.insert(url).inserted {
                out.append(RichSource(title: "\(card.headline): \(action.label)", url: url))
            }
        }
        return out
    }

    private static func replayPoints(from lines: [MeetingLine]) -> [String] {
        let interesting = lines.filter { line in
            let low = line.text.lowercased()
            return line.text.contains("?")
                || containsAny(low, line.text, concernTerms)
                || containsAny(low, line.text, commitmentTerms)
                || containsAny(low, line.text, ["decided", "decision", "approved", "go with", "決定", "决定"])
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm"
        return interesting.map { line in
            "\(stamp.string(from: line.timestamp)) \(line.speaker): \(clipped(line.text, max: 96))"
        }
    }

    private static func section(_ title: String, _ bullets: [String]) -> String {
        ([title] + bullets.map { "- \($0)" }).joined(separator: "\n")
    }
}
