import Foundation

// Turns a dispatch result into a candidate Card. Two distinct kinds, kept separate:
//   info cards          -> rendered in the interface/info language (facts, recipes, places)
//   prepared-line cards -> rendered in the floor language with reading aids (furigana/pinyin)
//                          plus the interface-language translation, framed as a teleprompter
// Drafting, translation, and reading aids are folded into a single model call to
// protect latency. Score is the classifier confidence; Surfacing assigns the tier.
struct Cardize: Sendable {
    let llm: LLMProvider
    let model: String
    let interfaceLanguage: Language
    let floorLanguage: Language
    let meetingMode: Bool
    let furigana: Bool
    let pinyin: Bool

    func make(trigger: Trigger, result: Dispatcher.Result, now: Date) async -> Card? {
        switch result {
        case .places(let query, let results):
            return placeCard(query: query, results: results, trigger: trigger, now: now)
        case .knowledge(let topic, let isRecipe):
            return await knowledgeCard(topic: topic, isRecipe: isRecipe, trigger: trigger, now: now)
        case .preparedReply(let context, let asker):
            return await preparedReplyCard(context: context, asker: asker, trigger: trigger, now: now)
        case .screen(let text):
            return screenCard(text: text, trigger: trigger, now: now)
        case .none:
            return nil
        }
    }

    // MARK: - Info: places (built from real lookup data, no extra LLM call)

    private func placeCard(query: String, results: [Place], trigger: Trigger, now: Date) -> Card? {
        guard let best = results.first else {
            return Card(title: "Nearby: \(query)", body: "No nearby matches found right now.",
                        trigger: trigger.type, tier: .medium, score: trigger.confidence,
                        timestamp: now, action: nil, latencyMs: nil)
        }
        var lines: [String] = []
        var head = best.name
        if let r = best.rating { head += "  ★\(trimmed(r))" + (best.reviewCount.map { " (\($0))" } ?? "") }
        lines.append(head)
        if let d = best.distanceMeters { lines.append("~\(Int(d.rounded())) m away") }
        if let addr = best.address, !addr.isEmpty { lines.append(addr) }
        lines.append(why(for: best, query: query))
        if best.source == "hotpepper" {
            // Hot Pepper API terms require this credit when displaying its data.
            lines.append("Powered by ホットペッパーグルメ Webサービス")
        }
        let action: Action?
        if let url = best.url, !url.isEmpty {
            action = Action(kind: "open_in_maps", label: "Open in Maps", params: ["url": url])
        } else if let lat = best.lat, let lng = best.lng {
            let url = "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)"
            action = Action(kind: "open_in_maps", label: "Open in Maps", params: ["url": url])
        } else {
            action = nil
        }
        return Card(title: "Nearby: \(query)", body: lines.joined(separator: "\n"),
                    trigger: trigger.type, tier: .medium, score: trigger.confidence,
                    timestamp: now, action: action, latencyMs: nil)
    }

    private func why(for p: Place, query: String) -> String {
        if let r = p.rating, let d = p.distanceMeters {
            return "Top pick: \(trimmed(r))-star \(query), about \(Int(d.rounded())) m away."
        }
        if let d = p.distanceMeters { return "Closest \(query), about \(Int(d.rounded())) m away." }
        return "A nearby \(query) option."
    }

    // MARK: - Info: fun fact / recipe (model general knowledge)

    private func knowledgeCard(topic: String, isRecipe: Bool, trigger: Trigger, now: Date) async -> Card? {
        let kind = isRecipe ? "recipe" : "fun_fact"
        let inputLabel = isRecipe ? "Dish" : "Topic"
        let user = """
        CARD KIND: \(kind)
        Interface language: \(name(interfaceLanguage))
        \(inputLabel): \(topic)
        Produce the JSON now.
        """
        guard let obj = await draft(user: user) else { return nil }
        let title = (obj["title"] as? String) ?? topic
        let body = (obj["body"] as? String) ?? ""
        if body.isEmpty { return nil }
        return Card(title: title, body: body, trigger: trigger.type, tier: .medium,
                    score: trigger.confidence, timestamp: now, action: nil, latencyMs: nil)
    }

    // MARK: - Prepared line (floor language) / interface-language suggestion

    private func preparedReplyCard(context: String, asker: String?, trigger: Trigger, now: Date) async -> Card? {
        let who = asker?.isEmpty == false ? asker! : "the other party"
        if meetingMode {
            let aids: String
            switch floorLanguage {
            case .ja: aids = furigana ? "furigana ON (annotate hard kanji)" : "furigana OFF"
            case .zh: aids = pinyin ? "pinyin ON (annotate hard characters)" : "pinyin OFF"
            case .en: aids = "none"
            }
            let user = """
            CARD KIND: prepared_line
            Floor language: \(name(floorLanguage))
            Interface language: \(name(interfaceLanguage))
            Reading aids: \(aids)
            Who is asking: \(who)
            Conversation context:
            \(context)
            Produce the JSON now.
            """
            guard let obj = await draft(user: user) else { return nil }
            let line = (obj["line"] as? String) ?? ""
            let translation = (obj["translation"] as? String) ?? ""
            if line.isEmpty { return nil }
            var body = line
            if !translation.isEmpty { body += "\n\n\(translation)" }
            body += "\n\nSuggested reply for \(who). Adjust as needed."
            let title = "Suggested reply (\(floorLanguage.rawValue.uppercased()))"
            return Card(title: title, body: body, trigger: trigger.type, tier: .critical,
                        score: trigger.confidence, timestamp: now, action: nil, latencyMs: nil)
        } else {
            // Meeting mode off: a plain interface-language suggestion.
            let user = """
            CARD KIND: prepared_line
            Floor language: \(name(interfaceLanguage))
            Interface language: \(name(interfaceLanguage))
            Reading aids: none
            Who is asking: \(who)
            Conversation context:
            \(context)
            Produce the JSON now.
            """
            guard let obj = await draft(user: user) else { return nil }
            let line = (obj["line"] as? String) ?? ""
            if line.isEmpty { return nil }
            return Card(title: "Suggested reply", body: "\(line)\n\nAdjust as needed.",
                        trigger: trigger.type, tier: .medium, score: trigger.confidence,
                        timestamp: now, action: nil, latencyMs: nil)
        }
    }

    // MARK: - Screen (surface the current stored read)

    private func screenCard(text: String, trigger: Trigger, now: Date) -> Card? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Card(title: "On screen", body: t, trigger: trigger.type, tier: .critical,
                    score: trigger.confidence, timestamp: now, action: nil, latencyMs: nil)
    }

    // MARK: - Summary (interface language, on demand)

    func summary(window: String) async -> String? {
        let user = """
        CARD KIND: summary
        Interface language: \(name(interfaceLanguage))
        Conversation so far:
        \(window)
        Produce the JSON now.
        """
        guard let obj = await draft(user: user) else { return nil }
        return (obj["body"] as? String)
    }

    // MARK: - Helpers

    private func draft(user: String) async -> [String: Any]? {
        guard let raw = try? await llm.complete(system: Prompts.drafter, user: user, model: model) else { return nil }
        return JSONExtract.decodeObject(raw)
    }
    private func name(_ l: Language) -> String {
        switch l { case .en: return "English"; case .ja: return "Japanese"; case .zh: return "Chinese" }
    }
    private func trimmed(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}
