import Foundation

// Recruit Hot Pepper Gourmet search API (verified current 2026-06). GET with
// lat/lng/range/order/keyword/format=json. No numeric rating is provided; distance
// is computed locally. Displaying this data requires the Hot Pepper credit, which
// the card adds ("Powered by ホットペッパーグルメ Webサービス").
public struct HotPepper: PlacesProvider {
    private let apiKey: String
    private let session: URLSession
    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place] {
        var comps = URLComponents(string: "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lng", value: String(lng)),
            URLQueryItem(name: "range", value: "3"),   // 1000 m
            URLQueryItem(name: "order", value: "4"),   // recommended
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError(message: "Hot Pepper: bad response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        if let err = results?["error"] { throw ProviderError(message: "Hot Pepper error: \(err)") }
        let shops = (results?["shop"] as? [[String: Any]]) ?? []
        return shops.map { s in
            let name = (s["name"] as? String) ?? "Unknown"
            let address = s["address"] as? String
            let plat = doubleOf(s["lat"])
            let plng = doubleOf(s["lng"])
            let url = (s["urls"] as? [String: Any])?["pc"] as? String
            let dist: Double? = (plat != nil && plng != nil)
                ? Geo.haversineMeters(lat1: lat, lng1: lng, lat2: plat!, lng2: plng!) : nil
            return Place(name: name, source: "hotpepper", rating: nil, reviewCount: nil,
                         address: address, lat: plat, lng: plng, url: url, distanceMeters: dist)
        }
    }

    private func doubleOf(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
