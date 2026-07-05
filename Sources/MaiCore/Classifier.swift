import Foundation

// Reads the rolling window, asks the LLM for strict JSON, and returns [Trigger].
// Conservative by design (the prompt does the heavy lifting). A parse failure
// yields zero triggers, never a crash. Tracks recently fired triggers so the same
// thing is not re-emitted within the configured cooldown.
//
// An actor, so its mutable cooldown state is never raced and its async classify
// call composes cleanly with the Engine actor under Swift 6 strict concurrency.
actor Classifier {
    private let llm: LLMProvider
    private let model: String
    private let enabled: Set<TriggerType>
    private let cooldownSeconds: Double
    private let systemPrompt: String
    private var recentlyFired: [String: Date] = [:]

    init(llm: LLMProvider, model: String, enabled: [String], cooldownSeconds: Double) {
        self.llm = llm
        self.model = model
        self.enabled = Set(enabled.compactMap { TriggerType(rawValue: $0) })
        self.cooldownSeconds = cooldownSeconds
        self.systemPrompt = Prompts.classifier
    }

    func classify(window: String, now: Date) async -> [Trigger] {
        guard !window.isEmpty else { return [] }
        guard !Self.isLowInformationUtterance(window) else { return [] }
        if let local = Self.fastClassify(window) {
            return filterAndCooldown(local, now: now)
        }
        let user = "Conversation window (oldest first):\n\(window)\n\nReturn the JSON object now."
        let raw: String
        do {
            raw = try await llm.complete(system: systemPrompt, user: user, model: model)
        } catch {
            // Network or provider error must not crash the always-on loop.
            return []
        }
        let parsed = parse(raw)
        return filterAndCooldown(parsed, now: now)
    }

    private func parse(_ raw: String) -> [Trigger] {
        guard let obj = JSONExtract.decodeObject(raw),
              let arr = obj["triggers"] as? [[String: Any]] else { return [] }
        var out: [Trigger] = []
        for item in arr {
            guard let typeStr = item["type"] as? String,
                  let type = TriggerType(rawValue: typeStr) else { continue }
            let span = (item["span"] as? String) ?? ""
            let reason = (item["reason"] as? String) ?? ""
            let confidence = doubleValue(item["confidence"]) ?? 0.5
            var payload: [String: String] = [:]
            if let p = item["payload"] as? [String: Any] {
                for (k, v) in p { payload[k] = stringValue(v) }
            }
            out.append(Trigger(type: type, span: span, reason: reason,
                               confidence: max(0, min(1, confidence)), payload: payload))
        }
        return out
    }

    private func filterAndCooldown(_ triggers: [Trigger], now: Date) -> [Trigger] {
        var result: [Trigger] = []
        for t in triggers {
            guard enabled.contains(t.type) else { continue }
            let key = cooldownKey(t)
            if let last = recentlyFired[key], now.timeIntervalSince(last) < cooldownSeconds {
                Self.logTrigger(t, key: key, suppressed: true)
                continue // still cooling down; do not re-emit
            }
            recentlyFired[key] = now
            Self.logTrigger(t, key: key, suppressed: false)
            result.append(t)
        }
        return result
    }

    // Cooldown/dedup key keyed on the ACTUAL normalized query text (the specific thing
    // asked about), so two different queries never collide. Prefers payload.query (the
    // model's specific topic); falls back to the verbatim span. Whitespace-normalized.
    private func cooldownKey(_ t: Trigger) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .joined(separator: " ")
        }
        let q = norm(t.payload["query"] ?? "")
        let span = norm(t.span)
        let topic = q.isEmpty ? span : q
        return "\(t.type.rawValue)|\(topic)"
    }

    // Diagnostic for the stale-result symptom: shows each trigger's type, span, query,
    // derived key, and whether the cooldown suppressed it. Set MAI_DEBUG_TRIGGERS=1.
    nonisolated static func logTrigger(_ t: Trigger, key: String, suppressed: Bool) {
        guard ProcessInfo.processInfo.environment["MAI_DEBUG_TRIGGERS"] == "1" else { return }
        let q = t.payload["query"] ?? ""
        FileHandle.standardError.write(Data(
            "Mai trigger: type=\(t.type.rawValue) span=\"\(t.span)\" query=\"\(q)\" key=\"\(key)\" \(suppressed ? "SUPPRESSED(cooldown)" : "fired")\n".utf8))
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
    private func stringValue(_ any: Any) -> String {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(d) }
        if let b = any as? Bool { return String(b) }
        return ""
    }

    nonisolated static func isLowInformationUtterance(_ window: String) -> Bool {
        let text = latestUtterance(window).text
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return true }
        let normalized = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let filler: Set<String> = [
            "ok", "okay", "yeah", "yep", "yes", "thanks", "thank you", "got it",
            "sounds good", "sure", "cool", "great", "nice",
            "はい", "うん", "なるほど", "了解", "ありがとうございます", "おはようございます",
            "好的", "好", "嗯", "谢谢", "明白", "收到"
        ]
        return filler.contains(normalized)
    }

    nonisolated static func fastClassify(_ window: String) -> [Trigger]? {
        let latest = latestUtterance(window)
        let text = latest.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let low = text.lowercased()
        func has(_ needles: [String]) -> Bool {
            needles.contains { low.contains($0.lowercased()) || text.contains($0) }
        }
        func trigger(_ type: TriggerType, span: String, reason: String, confidence: Double,
                     query: String? = nil, speaker: String? = nil) -> [Trigger] {
            var payload: [String: String] = [:]
            if let query, !query.isEmpty { payload["query"] = query }
            if let speaker, !speaker.isEmpty { payload["speaker"] = speaker }
            return [Trigger(type: type, span: span, reason: reason, confidence: confidence, payload: payload)]
        }

        if has(["look at the screen", "this slide", "on screen", "share my screen", "画面", "スライド", "请看屏幕", "看屏幕", "屏幕"]) {
            return trigger(.screenReference, span: text, reason: "local screen-reference cue", confidence: 0.92)
        }
        if has(["what do you think", "your thoughts", "your take", "can you answer", "your turn",
                "どう思います", "お願いできます", "ご意見", "你怎么看", "你来回答", "你来说"]) {
            return trigger(.reference, span: text, reason: "local reply cue", confidence: 0.90,
                           query: text, speaker: latest.speaker)
        }
        if let answer = TrivialAnswer.answer(text), !answer.isEmpty {
            return trigger(.question, span: text, reason: "local exact-answer cue", confidence: 0.93, query: text)
        }
        if let place = placeQuery(in: text), has(["hungry", "eat", "food", "restaurant", "nearby", "near me", "craving", "want", "please",
                                                  "食べ", "お腹", "ご飯", "近く", "吃", "饿", "附近"]) {
            return trigger(.place, span: place, reason: "local place/food cue", confidence: 0.86, query: place)
        }
        if let recipe = recipeQuery(in: text), has(["recipe", "how to make", "how do i make", "make", "cook",
                                                    "作り方", "どうやって作", "レシピ", "怎么做", "做法"]) {
            return trigger(.intent, span: "make \(recipe)", reason: "local recipe cue", confidence: 0.82, query: recipe)
        }
        if has(["latest", "news", "weather", "price", "stock", "score", "release date",
                "最新", "ニュース", "天気", "新闻", "天气"]) {
            return trigger(.question, span: text, reason: "local fresh-info cue", confidence: 0.78, query: text)
        }
        if looksLikeDirectQuestion(low) {
            return trigger(.question, span: text, reason: "local direct-question cue", confidence: 0.72, query: text)
        }
        return nil
    }

    private nonisolated static func latestUtterance(_ window: String) -> (speaker: String?, text: String) {
        guard let latest = window.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last else { return (nil, "") }
        let line = String(latest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = line.firstIndex(of: ":") else { return (nil, line) }
        let speaker = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (speaker.isEmpty ? nil : speaker, text)
    }

    private nonisolated static func placeQuery(in text: String) -> String? {
        let low = text.lowercased()
        let pairs = [
            ("お寿司", "sushi"), ("寿司", "sushi"), ("sushi", "sushi"),
            ("ラーメン", "ramen"), ("ramen", "ramen"),
            ("coffee", "coffee"), ("カフェ", "coffee"), ("cafe", "coffee"),
            ("restaurant", "restaurant"), ("ご飯", "restaurant"), ("food", "restaurant")
        ]
        return pairs.first { low.contains($0.0.lowercased()) || text.contains($0.0) }?.1
    }

    private nonisolated static func recipeQuery(in text: String) -> String? {
        let low = text.lowercased()
        let dishes = ["pudding", "プリン", "布丁", "cake", "curry", "パスタ", "pasta"]
        if let dish = dishes.first(where: { low.contains($0.lowercased()) || text.contains($0) }) {
            switch dish {
            case "プリン", "布丁": return "pudding"
            default: return dish
            }
        }
        return nil
    }

    private nonisolated static func looksLikeDirectQuestion(_ low: String) -> Bool {
        low.hasPrefix("what is ") || low.hasPrefix("what's ")
        || low.hasPrefix("what are ") || low.hasPrefix("who is ")
        || low.hasPrefix("who won ") || low.hasPrefix("when is ")
        || low.hasPrefix("where is ") || low.hasPrefix("how does ")
        || low.hasPrefix("how do i ") || low.hasPrefix("why does ")
        || low.hasPrefix("explain ") || low.hasPrefix("tell me about ")
    }
}
