import Foundation

public struct FallbackGroundedSearch: GroundedSearch {
    private let primary: GroundedSearch
    private let fallback: GroundedSearch

    public init(primary: GroundedSearch, fallback: GroundedSearch) {
        self.primary = primary
        self.fallback = fallback
    }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        do {
            return try await primary.answer(query: query, interface: interface)
        } catch {
            guard Self.shouldFallback(error) else { throw error }
            return try await fallback.answer(query: query, interface: interface)
        }
    }

    public static func shouldFallback(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("quota")
            || message.contains("rate limit")
            || message.contains("too many requests")
            || message.contains("resource_exhausted")
            || message.contains("free_tier")
            || message.contains("free tier")
            || message.contains("billing")
            || message.contains("429")
            || message.contains("503")
            || message.contains("temporarily unavailable")
    }
}

public struct DuckDuckGoGroundedSearch: GroundedSearch {
    private let session: URLSession
    private let fallback: GroundedSearch?

    public init(session: URLSession = .shared, fallback: GroundedSearch? = WikipediaGroundedSearch()) {
        self.session = session
        self.fallback = fallback
    }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        guard let url = Self.url(query: query) else { return try await fallbackAnswer(query: query, interface: interface) }
        var req = URLRequest(url: url)
        req.setValue("Mai/0.3 (ambient awareness app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "DuckDuckGo: no HTTP response") }
        guard http.statusCode == 200 else { throw ProviderError(message: "DuckDuckGo error: status \(http.statusCode)") }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return try await fallbackAnswer(query: query, interface: interface)
        }

        if let result = Self.directResult(json) {
            return result
        }
        if let result = Self.relatedResult(json) {
            return result
        }
        return try await fallbackAnswer(query: query, interface: interface)
    }

    private func fallbackAnswer(query: String, interface: Language) async throws -> GroundedResult {
        guard let fallback else { return GroundedResult(answer: "", sources: []) }
        return try await fallback.answer(query: query, interface: interface)
    }

    private static func directResult(_ json: [String: Any]) -> GroundedResult? {
        let answer = firstNonEmpty(json["AbstractText"] as? String, json["Answer"] as? String)
        guard let answer else { return nil }
        let title = firstNonEmpty(json["Heading"] as? String, "DuckDuckGo") ?? "DuckDuckGo"
        let url = firstNonEmpty(json["AbstractURL"] as? String)
        let sources = url.map { [RichSource(title: title, url: $0)] } ?? []
        return GroundedResult(answer: answer, sources: sources)
    }

    private static func relatedResult(_ json: [String: Any]) -> GroundedResult? {
        guard let topics = json["RelatedTopics"] as? [[String: Any]] else { return nil }
        for topic in flatten(topics) {
            guard let text = firstNonEmpty(topic["Text"] as? String) else { continue }
            let url = firstNonEmpty(topic["FirstURL"] as? String)
            let title = text.split(separator: "-").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            let sourceTitle = firstNonEmpty(title, "DuckDuckGo") ?? "DuckDuckGo"
            let sources = url.map { [RichSource(title: sourceTitle, url: $0)] } ?? []
            return GroundedResult(answer: text, sources: sources)
        }
        return nil
    }

    private static func flatten(_ topics: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for topic in topics {
            if topic["Text"] != nil {
                out.append(topic)
            }
            if let nested = topic["Topics"] as? [[String: Any]] {
                out.append(contentsOf: flatten(nested))
            }
        }
        return out
    }

    private static func url(query: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.duckduckgo.com"
        comps.path = "/"
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "0"),
        ]
        return comps.url
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

public struct WikipediaGroundedSearch: GroundedSearch {
    private let session: URLSession
    private static let userAgent = "Mai/0.3 (https://github.com/antswj/mai; ambient awareness app)"

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func answer(query: String, interface: Language) async throws -> GroundedResult {
        let lang = wikiCode(interface)
        guard let title = try await searchTitle(query: query, lang: lang),
              let result = try await summary(lang: lang, title: title) else {
            return GroundedResult(answer: "", sources: [])
        }
        let source = RichSource(title: result.sourceTitle, url: result.sourceURL)
        return GroundedResult(answer: result.summary, sources: [source])
    }

    private func searchTitle(query: String, lang: String) async throws -> String? {
        guard let url = Self.searchURL(query: query, lang: lang) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let search = query["search"] as? [[String: Any]] else { return nil }
        return search.first?["title"] as? String
    }

    private func summary(lang: String, title: String) async throws -> EntityResult? {
        guard let encoded = title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: Self.pathAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let extract = json["extract"] as? String,
              !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let resolvedTitle = (json["title"] as? String) ?? title
        let page = (((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String)
            ?? "https://\(lang).wikipedia.org/wiki/\(encoded)"
        return EntityResult(title: resolvedTitle, summary: extract, imageURL: nil,
                            sourceURL: page, sourceTitle: "Wikipedia")
    }

    private static func searchURL(query: String, lang: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "\(lang).wikipedia.org"
        comps.path = "/w/api.php"
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "srsearch", value: query),
        ]
        return comps.url
    }

    private func wikiCode(_ l: Language) -> String {
        switch l { case .en: return "en"; case .ja: return "ja"; case .zh: return "zh" }
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%")
        return set
    }()
}
