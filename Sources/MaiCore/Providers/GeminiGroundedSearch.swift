import Foundation

// Grounded web search via Gemini with the Google Search tool. Verified shapes
// (2026-06): POST {model}:generateContent with tools:[{google_search:{}}], the
// answer in candidates[0].content.parts[].text, real sources in
// groundingMetadata.groundingChunks[].web.{uri,title}, and Google's Search
// Suggestions widget in groundingMetadata.searchEntryPoint.renderedContent. The
// answer is synthesized in the interface language; the sources are real (the card
// links through Google's grounding redirect URI, which is the required attribution).
public struct GeminiGroundedSearch: GroundedSearch {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "gemini-2.5-flash", session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let system = "Answer the question accurately and concisely in \(LookupRouter.name(interface)), in 1 to 3 sentences. Base the answer on the search results. If the results do not contain a reliable answer, say so plainly. Do not invent facts, numbers, or sources."
        let body: [String: Any] = [
            "contents": [["parts": [["text": query]]]],
            "tools": [["google_search": [:] as [String: Any]]],
            "system_instruction": ["parts": [["text": system]]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Gemini: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Gemini grounded error: \(msg)")
        }
        let candidate = (json?["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let answer = (parts ?? []).compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

        let grounding = candidate?["groundingMetadata"] as? [String: Any]
        var sources: [RichSource] = []
        if let chunks = grounding?["groundingChunks"] as? [[String: Any]] {
            for chunk in chunks {
                guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String, !uri.isEmpty else { continue }
                let title = (web["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.host(uri)
                if !sources.contains(where: { $0.url == uri }) { sources.append(RichSource(title: title, url: uri)) }
            }
        }
        let html = (grounding?["searchEntryPoint"] as? [String: Any])?["renderedContent"] as? String
        return GroundedResult(answer: answer, sources: sources, searchSuggestionHTML: html)
    }

    private static func host(_ uri: String) -> String {
        URL(string: uri)?.host ?? "source"
    }
}
