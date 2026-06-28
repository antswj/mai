import Foundation

// Anthropic Messages API via raw HTTP (no official Swift SDK). Verified current
// 2026-06: POST /v1/messages, x-api-key + anthropic-version: 2023-06-01, text in
// content[].text. Default models claude-haiku-4-5 (classifier) / claude-sonnet-4-6
// (drafter); claude-opus-4-8 is available for heavy reasoning.
public struct AnthropicLLM: LLMProvider {
    private let apiKey: String
    private let maxTokens: Int
    private let session: URLSession

    public init(apiKey: String, maxTokens: Int = 1024, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.session = session
    }

    public func complete(system: String, user: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Anthropic: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Anthropic error: \(msg)")
        }
        guard let content = json?["content"] as? [[String: Any]] else {
            throw ProviderError(message: "Anthropic: unexpected response shape")
        }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? (block["text"] as? String) : nil
        }.joined()
        return text
    }
}
