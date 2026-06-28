import Foundation

// Entity lookup over Wikipedia, resolved into the interface language. Verified
// shapes (2026-06):
//   REST summary:  https://{lang}.wikipedia.org/api/rest_v1/page/summary/{title}
//                  -> extract, thumbnail.source, content_urls.desktop.page
//   langlinks:     https://{lang}.wikipedia.org/w/api.php?action=query&prop=langlinks
//                  &lllang={interface}&redirects=1&formatversion=2&titles={title}
//                  -> query.pages[0].langlinks[0].title
// A descriptive User-Agent is required or the API returns 403.
//
// Cross-language: if the spoken term is in another script (e.g. 寿司), resolve its
// langlink to the interface-language article and use THAT summary (already in the
// interface language). If there is no langlink, fall back to the native summary and
// translate it. The returned summary is therefore always in the interface language,
// and the image and source URL are always real (or nil), never fabricated.
public struct WikipediaLookup: EntityLookup {
    private let session: URLSession
    private let llm: LLMProvider?     // used only to translate a native summary fallback
    private let translateModel: String
    private static let userAgent = "Mai/0.3 (https://github.com/antswj/mai; ambient awareness app)"

    public init(session: URLSession = .shared, llm: LLMProvider? = nil, translateModel: String = "claude-haiku-4-5") {
        self.session = session; self.llm = llm; self.translateModel = translateModel
    }

    public func lookup(term: String, spoken: Language, interface: Language) async throws -> EntityResult? {
        let termLang = wikiCode(ScriptDetect.language(of: term))   // the script the name is in
        let interfaceCode = wikiCode(interface)

        // Term already in (or mappable to) the interface-language wiki: one call.
        if termLang == interfaceCode {
            return try await summary(lang: interfaceCode, title: term, translateTo: nil)
        }

        // Otherwise resolve the cross-language link to the interface article.
        if let crossTitle = try await langlink(lang: termLang, title: term, to: interfaceCode),
           let res = try await summary(lang: interfaceCode, title: crossTitle, translateTo: nil) {
            return res
        }

        // No langlink: take the native summary and translate it into the interface language.
        return try await summary(lang: termLang, title: term, translateTo: interface)
    }

    // MARK: - REST summary

    private func summary(lang: String, title: String, translateTo: Language?) async throws -> EntityResult? {
        guard let encoded = title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: Self.pathAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if (json["type"] as? String) == "https://mediawiki.org/wiki/HyperSwitch/errors/not_found" { return nil }
        guard var extract = json["extract"] as? String, !extract.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let resolvedTitle = (json["title"] as? String) ?? title
        let image = ((json["thumbnail"] as? [String: Any])?["source"] as? String)
            ?? ((json["originalimage"] as? [String: Any])?["source"] as? String)
        let page = (((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String)
            ?? "https://\(lang).wikipedia.org/wiki/\(encoded)"

        if let target = translateTo {
            extract = (try? await translate(extract, to: target)) ?? extract
        }
        return EntityResult(title: resolvedTitle, summary: extract, imageURL: image, sourceURL: page)
    }

    // MARK: - Cross-language link

    private func langlink(lang: String, title: String, to: String) async throws -> String? {
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://\(lang).wikipedia.org/w/api.php?action=query&format=json&formatversion=2&prop=langlinks&lllang=\(to)&redirects=1&titles=\(encodedTitle)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let links = pages.first?["langlinks"] as? [[String: Any]],
              let title = links.first?["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    // MARK: - Translation fallback

    private func translate(_ text: String, to: Language) async throws -> String {
        guard let llm else { return text }
        let system = "Translate the user's text into \(LookupRouter.name(to)). Output only the translation, with no preamble, notes, or quotation marks."
        let out = try await llm.complete(system: system, user: text, model: translateModel)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    private func wikiCode(_ l: Language) -> String {
        switch l { case .en: return "en"; case .ja: return "ja"; case .zh: return "zh" }
    }

    // Path-segment-safe set: percent-encode the title but keep it a single segment.
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%")
        return set
    }()
}
