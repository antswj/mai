import Foundation

// Great-circle distance in meters. Neither Places Text Search nor Hot Pepper
// returns a distance, so the engine computes it from the test/location point.
enum Geo {
    static func haversineMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct ProviderError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
