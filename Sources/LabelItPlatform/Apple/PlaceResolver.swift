#if canImport(MapKit)
import CoreLocation
import Foundation
import LabelItCore
import MapKit

/// Turns GPS coordinates into a city name. Uses Apple's location service (online),
/// so it only runs when the user turns place names on. Results are cached by area.
public actor PlaceResolver: PlaceLookup {
    private var cache: [String: String?] = [:]

    public init() {}

    public func place(latitude: Double, longitude: Double) async -> String? {
        // ~1 km grid: photos taken around the same spot share a lookup.
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let cached = cache[key] { return cached }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        var name: String?
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            name = item.addressRepresentations?.cityName ?? item.address?.shortAddress
        }
        cache[key] = name
        return name
    }
}
#endif
