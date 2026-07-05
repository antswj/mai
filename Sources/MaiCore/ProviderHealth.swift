import Foundation

public enum ProviderHealthState: String, Codable, Sendable, Equatable {
    case ok
    case notSet
    case quotaLimited
    case invalidKey
    case outOfBalance
    case error
    case setOnly
}

public struct ProviderHealthResult: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let provider: String
    public let keyName: String
    public let state: ProviderHealthState
    public let message: String
    public let billingHint: String?

    public init(provider: String, keyName: String, state: ProviderHealthState, message: String, billingHint: String? = nil) {
        self.id = provider
        self.provider = provider
        self.keyName = keyName
        self.state = state
        self.message = message
        self.billingHint = billingHint
    }
}

public enum ProviderHealth {
    public static func check(config: Config, secrets: Secrets) async -> [ProviderHealthResult] {
        async let anthropic = checkAnthropic(config: config, secrets: secrets)
        async let groq = checkGroq(secrets: secrets)
        async let gemini = checkGemini(config: config, secrets: secrets)
        let rest = [
            presence(provider: "Soniox", key: "SONIOX_API_KEY", secrets: secrets),
            presence(provider: "Google Places", key: "GOOGLE_PLACES_API_KEY", secrets: secrets),
            presence(provider: "Hot Pepper", key: "HOTPEPPER_API_KEY", secrets: secrets),
        ]
        return await [anthropic, groq, gemini] + rest
    }

    private static func checkAnthropic(config: Config, secrets: Secrets) async -> ProviderHealthResult {
        let key = "ANTHROPIC_API_KEY"
        guard let value = secrets.get(key) else {
            return ProviderHealthResult(provider: "Anthropic", keyName: key, state: .notSet, message: "No key set")
        }
        do {
            _ = try await withTimeout(seconds: 6) {
                try await AnthropicLLM(apiKey: value).complete(system: "Reply with one word.", user: "ok", model: config.classifierModel)
            }
            return ProviderHealthResult(provider: "Anthropic", keyName: key, state: .ok, message: "Live check OK")
        } catch {
            return classified(provider: "Anthropic", key: key, error: error)
        }
    }

    private static func checkGroq(secrets: Secrets) async -> ProviderHealthResult {
        let key = "GROQ_API_KEY"
        guard let value = secrets.get(key) else {
            return ProviderHealthResult(provider: "Groq", keyName: key, state: .notSet, message: "No key set")
        }
        do {
            _ = try await withTimeout(seconds: 6) {
                try await GroqLLM(apiKey: value).complete(system: "Reply with one word.", user: "ok", model: GroqLLM.smokeModel)
            }
            return ProviderHealthResult(provider: "Groq", keyName: key, state: .ok, message: "Live check OK")
        } catch {
            return classified(provider: "Groq", key: key, error: error)
        }
    }

    private static func checkGemini(config: Config, secrets: Secrets) async -> ProviderHealthResult {
        let key = "GEMINI_API_KEY"
        guard let value = secrets.get(key) else {
            return ProviderHealthResult(provider: "Gemini", keyName: key, state: .notSet, message: "No key set")
        }
        do {
            _ = try await withTimeout(seconds: 8) {
                try await geminiTextProbe(apiKey: value, model: config.screenModel)
            }
            return ProviderHealthResult(provider: "Gemini", keyName: key, state: .ok,
                                        message: "Live check OK",
                                        billingHint: "No quota/billing warning returned by Gemini.")
        } catch {
            return classified(provider: "Gemini", key: key, error: error)
        }
    }

    private static func presence(provider: String, key: String, secrets: Secrets) -> ProviderHealthResult {
        secrets.get(key) == nil
            ? ProviderHealthResult(provider: provider, keyName: key, state: .notSet, message: "No key set")
            : ProviderHealthResult(provider: provider, keyName: key, state: .setOnly, message: "Key present; validated by smoke/live use")
    }

    private static func classified(provider: String, key: String, error: Error) -> ProviderHealthResult {
        let message = String(describing: error)
        let low = message.lowercased()
        if low.contains("free_tier") || low.contains("free tier") {
            return ProviderHealthResult(provider: provider, keyName: key, state: .quotaLimited,
                                        message: message,
                                        billingHint: "Provider labeled this key/request as free-tier quota. Check that this exact API key belongs to the billed project.")
        }
        if low.contains("quota") || low.contains("rate limit") || low.contains("429") {
            return ProviderHealthResult(provider: provider, keyName: key, state: .quotaLimited,
                                        message: message,
                                        billingHint: "Quota-limited or rate-limited. Billing may be active, but this key/model quota is exhausted.")
        }
        if low.contains("401") || low.contains("403") || low.contains("invalid") || low.contains("permission") {
            return ProviderHealthResult(provider: provider, keyName: key, state: .invalidKey, message: message)
        }
        if low.contains("402") || low.contains("balance") || low.contains("credit") {
            return ProviderHealthResult(provider: provider, keyName: key, state: .outOfBalance, message: message)
        }
        return ProviderHealthResult(provider: provider, keyName: key, state: .error, message: message)
    }

    private static func geminiTextProbe(apiKey: String, model: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [["parts": [["text": "Reply with exactly: ok"]]]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Gemini: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Gemini health error: \(msg)")
        }
        let candidates = json?["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        return (parts ?? []).compactMap { $0["text"] as? String }.joined()
    }
}
