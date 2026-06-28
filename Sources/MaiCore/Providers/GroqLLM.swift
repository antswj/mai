import Foundation

// Groq via its OpenAI-compatible chat completions endpoint (verified current
// 2026-06). Alternative LLM provider: set providers.llm = "groq" and use
// openai/gpt-oss-20b (classifier) / openai/gpt-oss-120b (drafter); the Llama
// models are on the deprecation path and avoided.
public struct GroqLLM: LLMProvider {
    private let apiKey: String
    private let maxTokens: Int
    private let session: URLSession

    public init(apiKey: String, maxTokens: Int = 2048, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.session = session
    }

    public func complete(system: String, user: String, model: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Groq: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Groq error: \(msg)")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError(message: "Groq: unexpected response shape")
        }
        return content
    }
}
