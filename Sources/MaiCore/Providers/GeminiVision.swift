import Foundation

// Reads an image via the current Gemini Flash-family vision model (verified
// current 2026-06: generateContent with an inline_data part, text in
// candidates[].content.parts[].text). Used by the live smoke test this step; the
// real eyes will call it per changed keyframe in a later step.
public struct GeminiVision: Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    public init(apiKey: String, model: String = "gemini-2.5-flash", session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.session = session
    }

    public func read(imageData: Data, mimeType: String = "image/png",
                     prompt: String = "Transcribe all text in this screenshot and briefly describe its layout.") async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": mimeType, "data": imageData.base64EncodedString()]],
                ],
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Gemini: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Gemini error: \(msg)")
        }
        let candidates = json?["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = (parts ?? []).compactMap { $0["text"] as? String }.joined()
        return text
    }
}
