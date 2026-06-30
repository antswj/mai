import Foundation

// Deterministic stand-in for the LLM, so `swift test` exercises the whole engine
// with no live calls. The default responder understands the classifier and
// drafter prompts and produces canned, fixture-aligned JSON (including real
// furigana/pinyin parentheticals so the prepared-line assertions are meaningful).
// A custom responder can be injected for bespoke cases.
public struct StubLLM: LLMProvider {
    private let responder: @Sendable (_ system: String, _ user: String, _ model: String) -> String

    public init(responder: @escaping @Sendable (String, String, String) -> String) {
        self.responder = responder
    }
    public init() { self.responder = StubLLM.defaultResponder }

    public func complete(system: String, user: String, model: String) async throws -> String {
        responder(system, user, model)
    }

    // MARK: - Default heuristic responder

    static func defaultResponder(system: String, user: String, model: String) -> String {
        if system.contains("trigger classifier") { return classify(user) }
        if system.contains("Mai's drafter") { return draft(user) }
        if system.contains("lookup router") { return route(user) }
        if system.contains("Mai's explainer") { return explain(user) }
        if system.contains("Mai's responder") { return respond(user) }
        if system.contains("meeting assistant") { return assistantReply(user) }
        if system.contains("meeting notes writer") { return notesWriter(user) }
        if system.contains("notes verifier") { return notesVerify(user) }
        if system.contains("meeting title") { return object(["title": "Team Sync Notes"]) }
        if system.lowercased().contains("translate") {
            // Translation fallback (Wikipedia native-summary path): echo the input.
            return user
        }
        return "{}"
    }

    // MARK: - Step 3 routing / explanation / response stubs

    private static func route(_ user: String) -> String {
        let topicRaw = valueAfter("What the user wondered about:", in: user) ?? ""
        let topic = topicRaw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let low = topic.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { low.contains($0.lowercased()) || topic.contains($0) } }
        // Fresh: time-sensitive cues.
        if has(["latest", "news", "today", "weather", "price", "stock", "score", "who won", "現在", "最新", "ニュース", "天気", "今天", "最新", "新闻", "天气"]) {
            return object(["route": "fresh", "entity": "", "query": topic, "needs_search": true, "needs_image": false])
        }
        // Entity: known things (incl. native-script variants).
        if has(["malaysia", "マレーシア", "马来西亚", "馬來西亞", "sushi", "寿司", "お寿司", "壽司", "ada lovelace", "北京", "beijing"]) {
            var entity = topic
            if has(["sushi"]) { entity = "sushi" }
            if has(["お寿司", "寿司"]) { entity = "寿司" }
            if has(["malaysia"]) { entity = "Malaysia" }
            return object(["route": "entity", "entity": entity, "query": topic, "needs_search": false, "needs_image": true])
        }
        // Default: technical, no live search needed.
        return object(["route": "technical", "entity": "", "query": topic, "needs_search": false, "needs_image": false])
    }

    private static func explain(_ user: String) -> String {
        let q = valueAfter("Question:", in: user) ?? "this"
        return object(["answer": "In short: \(q) comes down to a few clear ideas, explained plainly here."])
    }

    private static func respond(_ user: String) -> String {
        let spoken = valueAfter("Spoken language:", in: user) ?? "English"
        if spoken.contains("Japanese") {
            return object(["warranted": true, "spoken": "確認して、後ほどご連絡します。",
                           "translation": "Let me check and get back to you shortly.",
                           "rationale": "You were asked for input."])
        } else if spoken.contains("Chinese") {
            return object(["warranted": true, "spoken": "我确认一下，稍后回复您。",
                           "translation": "Let me confirm and reply to you shortly.",
                           "rationale": "You were asked for input."])
        }
        return object(["warranted": true, "spoken": "Let me check and get back to you shortly.",
                       "translation": "Let me check and get back to you shortly.",
                       "rationale": "You were asked for input."])
    }

    private static func classify(_ window: String) -> String {
        // Classify the newest utterance. The real LLM reads the whole window for
        // cross-turn context; the deterministic stub keys off the latest line so
        // persistent earlier text does not mask newer triggers in a replay.
        let lines = window.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        // Skip the engine's wrapper header/footer; classify the last real line.
        let convo = lines.filter { !$0.contains("Conversation window") && !$0.contains("Return the JSON object") }
        let window = convo.last ?? (lines.last ?? window)
        let low = window.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { low.contains($0.lowercased()) || window.contains($0) } }

        // screenReference (any language)
        if has(["look at the screen", "as you can see", "on the screen", "this slide", "share my screen",
                "画面", "スライド", "共有", "请看屏幕", "看屏幕", "屏幕", "看这张"]) {
            return triggers([["type": "screenReference", "span": "screen reference", "reason": "points at screen", "confidence": 0.9]])
        }
        // place / food craving
        if has(["sushi", "寿司", "お寿司", "ramen", "ラーメン", "coffee", "カフェ", "hungry", "お腹", "ご飯", "eat", "食べ", "吃", "饿"]) {
            var query = "food"
            if has(["sushi", "寿司"]) { query = "sushi" }
            else if has(["ramen", "ラーメン"]) { query = "ramen" }
            else if has(["coffee", "カフェ"]) { query = "coffee" }
            return triggers([["type": "place", "span": query, "reason": "wants food/place", "confidence": 0.85, "payload": ["query": query]]])
        }
        // recipe intent
        if has(["pudding", "プリン", "布丁"]) || (has(["recipe", "レシピ"]) ) || has(["怎么做", "作り方", "どうやって作"]) {
            var dish = "pudding"
            if has(["プリン", "pudding", "布丁"]) { dish = "pudding" }
            return triggers([["type": "intent", "span": "make \(dish)", "reason": "wants a recipe", "confidence": 0.8, "payload": ["query": dish]]])
        }
        // travel fun fact
        if has(["malaysia", "マレーシア", "马来西亚"]) {
            return triggers([["type": "intent", "span": "going to Malaysia", "reason": "travel; a fun fact would delight", "confidence": 0.7, "payload": ["query": "Malaysia"]]])
        }
        // reference (asks the user to respond). Per the classifier contract, the span is
        // the verbatim current line and the query is specific to this utterance, so two
        // different requests in a row do not collide on a coarse cooldown key.
        if has(["your turn", "what do you think", "answer that", "どう思います", "お願いできます", "ご意見", "你怎么看", "你来回答", "你来说"]) {
            let speaker = speakerOfLine(containing: ["your turn", "what do you think", "どう思います", "お願いできます", "ご意見", "你怎么看", "你来回答", "你来说"], in: window)
            var payload: [String: Any] = ["query": window]
            if let speaker { payload["speaker"] = speaker }
            return triggers([["type": "reference", "span": window, "reason": "user is asked to reply", "confidence": 0.85, "payload": payload]])
        }
        return "{\"triggers\":[]}"
    }

    private static func draft(_ user: String) -> String {
        let kind = valueAfter("CARD KIND:", in: user) ?? ""
        switch kind {
        case let k where k.contains("prepared_line"):
            let floor = valueAfter("Floor language:", in: user) ?? "English"
            if floor.contains("Japanese") {
                return object(["line": "承知しました。後ほど確認してご連絡します。",
                               "translation": "Understood. I will check and get back to you shortly."])
            } else if floor.contains("Chinese") {
                return object(["line": "好的，我稍后确认后回复您。",
                               "translation": "OK, I will confirm and reply to you shortly."])
            } else {
                return object(["line": "Sure, let me confirm and get back to you shortly.",
                               "translation": "Sure, let me confirm and get back to you shortly."])
            }
        case let k where k.contains("fun_fact"):
            let topic = valueAfter("Topic:", in: user) ?? "this topic"
            return object(["title": topic, "body": "Did you know? \(topic) has a surprising and delightful side worth exploring."])
        case let k where k.contains("recipe"):
            let dish = valueAfter("Dish:", in: user) ?? "the dish"
            return object(["title": dish, "body": "Main ingredients: eggs, milk, sugar, a little vanilla. Total time: about 45 minutes (for \(dish))."])
        case let k where k.contains("summary"):
            return object(["title": "Session summary", "body": "The group discussed several topics, made a couple of decisions, and left a few items open for follow-up."])
        default:
            return "{}"
        }
    }

    // MARK: - Step 3 assistant / notes stubs

    private static func assistantReply(_ user: String) -> String {
        // Echo the user's own lines so the integration test can confirm the assistant
        // identifies what the user said. The real model does the real summary.
        let youLines = user.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("You: ") }.map { String($0.dropFirst(5)) }
        let said = youLines.isEmpty ? "nothing yet" : youLines.joined(separator: "; ")
        return "The group is discussing the meeting topics. You said: \(said)."
    }

    private static func notesWriter(_ user: String) -> String {
        // Build supported bullets from real transcript lines, then simulate a model
        // that over-claims by adding one fabricated, unsupported bullet (the verifier
        // pass must drop it).
        let transcript = linesBetween("Transcript (lines marked", "Explicitly noted items:", in: user)
        var bullets: [String] = []
        for line in transcript.prefix(4) {
            if let r = line.range(of: ": ") { bullets.append(String(line[r.upperBound...])) }
        }
        // Fold in explicitly noted items (they belong in the notes).
        for item in linesBetween("Explicitly noted items:", "Produce the JSON now.", in: user) {
            bullets.append(item.hasPrefix("- ") ? String(item.dropFirst(2)) : item)
        }
        // Simulate a model that over-claims by adding one fabricated, unsupported bullet.
        bullets.append("The team approved a budget of fifty million dollars.")
        return object(["summary": "The group discussed several topics during the meeting.",
                       "sections": [["heading": "Key Points", "bullets": bullets]]])
    }

    private static func notesVerify(_ user: String) -> String {
        let transcript = linesBetween("Transcript:", "Explicitly noted items", in: user)
            .joined(separator: " ").lowercased()
        let noted = linesBetween("Explicitly noted items", "Candidate bullets:", in: user)
            .map { ($0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0).lowercased() }
        let bullets = linesBetween("Candidate bullets:", "Produce the JSON now.", in: user)
        var results: [[String: Any]] = []
        for line in bullets {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let idx = Int(line[..<colon].trimmingCharacters(in: .whitespaces)) ?? -1
            let text = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 5 }
            // Supported if it overlaps the transcript, or it is one of the noted items.
            let supported = tokens.contains { transcript.contains($0) } || noted.contains { $0.contains(text) || text.contains($0) }
            if idx >= 0 { results.append(["index": idx, "supported": supported]) }
        }
        return object(["results": results])
    }

    private static func linesBetween(_ start: String, _ end: String, in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []; var inside = false
        for line in lines {
            if !inside { if line.contains(start) { inside = true }; continue }
            if line.contains(end) { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
        }
        return out
    }

    // MARK: - tiny JSON builders / parsers

    private static func triggers(_ items: [[String: Any]]) -> String {
        let payload: [String: Any] = ["triggers": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"triggers\":[]}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"triggers\":[]}"
    }
    private static func object(_ dict: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    private static func valueAfter(_ label: String, in text: String) -> String? {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let r = line.range(of: label) {
                return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    private static func speakerOfLine(containing cues: [String], in window: String) -> String? {
        for line in window.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let s = String(line)
            if cues.contains(where: { s.lowercased().contains($0.lowercased()) || s.contains($0) }) {
                if let colon = s.firstIndex(of: ":") {
                    let who = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
                    if !who.isEmpty && who.lowercased() != "speaker" { return who }
                }
            }
        }
        return nil
    }
}
