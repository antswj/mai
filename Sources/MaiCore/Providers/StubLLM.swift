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
        // reference (asks the user to respond)
        if has(["your turn", "what do you think", "answer that", "どう思います", "お願いできます", "ご意見", "你怎么看", "你来回答", "你来说"]) {
            let speaker = speakerOfLine(containing: ["your turn", "what do you think", "どう思います", "お願いできます", "ご意見", "你怎么看", "你来回答", "你来说"], in: window)
            var payload: [String: Any] = ["query": "respond"]
            if let speaker { payload["speaker"] = speaker }
            return triggers([["type": "reference", "span": "asked to respond", "reason": "user is asked to reply", "confidence": 0.85, "payload": payload]])
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
