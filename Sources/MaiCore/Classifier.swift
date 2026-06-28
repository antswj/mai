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
                continue // still cooling down; do not re-emit
            }
            recentlyFired[key] = now
            result.append(t)
        }
        return result
    }

    private func cooldownKey(_ t: Trigger) -> String {
        let span = t.span.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let q = (t.payload["query"] ?? "").lowercased()
        return "\(t.type.rawValue)|\(span)|\(q)"
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
}
