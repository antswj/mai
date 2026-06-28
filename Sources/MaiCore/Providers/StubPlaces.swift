import Foundation

// Deterministic places stand-in for tests. Returns a canned, ranked result with a
// real-shaped maps URL so the engine path (card + open_in_maps action) is exercised
// without a live lookup.
public struct StubPlaces: PlacesProvider {
    private let results: [Place]
    public init(results: [Place]? = nil) {
        self.results = results ?? [
            Place(name: "Sushi Toodenninoya", source: "google", rating: 4.6, reviewCount: 312,
                  address: "1-1 Funabashi, Chiba", lat: 35.7019, lng: 139.9851,
                  url: "https://maps.google.com/?cid=123456789", distanceMeters: 120),
            Place(name: "Edomae Sushi Mori-ichi", source: "hotpepper", rating: nil, reviewCount: nil,
                  address: "Minamiguchi, Funabashi", lat: 35.7008, lng: 139.9860,
                  url: "https://www.hotpepper.jp/strJ000000000/", distanceMeters: 210),
        ]
    }
    public func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place] {
        results
    }
}
