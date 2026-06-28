import Foundation

// Google Places API (New) Text Search (verified current 2026-06). POST
// places:searchText with an X-Goog-FieldMask; distance is computed locally with
// haversine (the API does not return it). URLs come only from real responses.
public struct GooglePlaces: PlacesProvider {
    private let apiKey: String
    private let session: URLSession
    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.session = session
    }

    public func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place] {
        var req = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("places.displayName,places.rating,places.userRatingCount,places.formattedAddress,places.location,places.googleMapsUri,places.id",
                     forHTTPHeaderField: "X-Goog-FieldMask")
        let body: [String: Any] = [
            "textQuery": query,
            "locationBias": ["circle": ["center": ["latitude": lat, "longitude": lng], "radius": 1500.0]],
            "languageCode": language.rawValue,
            "pageSize": 10,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError(message: "Places: no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "status \(http.statusCode)"
            throw ProviderError(message: "Places error: \(msg)")
        }
        let places = (json?["places"] as? [[String: Any]]) ?? []
        return places.map { p in
            let name = ((p["displayName"] as? [String: Any])?["text"] as? String) ?? "Unknown"
            let rating = p["rating"] as? Double
            let reviews = p["userRatingCount"] as? Int
            let address = p["formattedAddress"] as? String
            let loc = p["location"] as? [String: Any]
            let plat = loc?["latitude"] as? Double
            let plng = loc?["longitude"] as? Double
            let url = p["googleMapsUri"] as? String
            let dist: Double? = (plat != nil && plng != nil)
                ? Geo.haversineMeters(lat1: lat, lng1: lng, lat2: plat!, lng2: plng!) : nil
            return Place(name: name, source: "google", rating: rating, reviewCount: reviews,
                         address: address, lat: plat, lng: plng, url: url, distanceMeters: dist)
        }
    }
}
