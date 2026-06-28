import Foundation

// Calls Google and Hot Pepper concurrently, de-dupes places that are clearly the
// same (close coordinates plus a similar name), ranks by a sensible default
// (rating, then review count, then distance), and returns the best few.
public struct MergedPlaces: PlacesProvider {
    private let google: PlacesProvider?
    private let hotpepper: PlacesProvider?
    private let limit: Int
    public init(google: PlacesProvider?, hotpepper: PlacesProvider?, limit: Int = 5) {
        self.google = google; self.hotpepper = hotpepper; self.limit = limit
    }

    public func nearby(query: String, lat: Double, lng: Double, language: Language) async throws -> [Place] {
        async let g: [Place] = fetch(google, query: query, lat: lat, lng: lng, language: language)
        async let h: [Place] = fetch(hotpepper, query: query, lat: lat, lng: lng, language: language)
        let combined = await g + h
        return Array(dedupe(rank(combined)).prefix(limit))
    }

    private func fetch(_ p: PlacesProvider?, query: String, lat: Double, lng: Double, language: Language) async -> [Place] {
        guard let p else { return [] }
        return (try? await p.nearby(query: query, lat: lat, lng: lng, language: language)) ?? []
    }

    private func rank(_ places: [Place]) -> [Place] {
        places.sorted { a, b in
            let ra = a.rating ?? 0, rb = b.rating ?? 0
            if ra != rb { return ra > rb }
            let ca = a.reviewCount ?? 0, cb = b.reviewCount ?? 0
            if ca != cb { return ca > cb }
            let da = a.distanceMeters ?? .greatestFiniteMagnitude
            let db = b.distanceMeters ?? .greatestFiniteMagnitude
            return da < db
        }
    }

    private func dedupe(_ ranked: [Place]) -> [Place] {
        var kept: [Place] = []
        for p in ranked {
            let dup = kept.contains { k in coordClose(k, p) && nameSimilar(k.name, p.name) }
            if !dup { kept.append(p) }
        }
        return kept
    }

    private func coordClose(_ a: Place, _ b: Place) -> Bool {
        guard let la = a.lat, let na = a.lng, let lb = b.lat, let nb = b.lng else { return false }
        return Geo.haversineMeters(lat1: la, lng1: na, lat2: lb, lng2: nb) < 60
    }
    private func nameSimilar(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na == nb { return true }
        if na.count >= 4 && (na.contains(nb) || nb.contains(na)) { return true }
        return false
    }
    private func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
