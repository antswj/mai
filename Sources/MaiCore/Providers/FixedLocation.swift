import Foundation

// Returns a fixed PUBLIC test coordinate (Funabashi Station area, from config),
// standing in for CoreLocation which arrives in a later step. Deliberately a
// public landmark, never a home address.
public struct FixedLocation: LocationProvider {
    private let lat: Double
    private let lng: Double
    public init(lat: Double, lng: Double) { self.lat = lat; self.lng = lng }
    public func current() async -> (lat: Double, lng: Double) { (lat, lng) }
}
