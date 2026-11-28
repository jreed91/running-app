import CoreLocation

// `Coordinate` lives in the StrideCore package, which is Foundation only. Its CoreLocation
// conversions stay here, in the app.
extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Keeps the fix's altitude too, for the heatmap's Hills layer. A negative vertical
    /// accuracy means the altitude is not valid.
    init(_ location: CLLocation) {
        self.init(location.coordinate)
        if location.verticalAccuracy >= 0, location.altitude.isFinite {
            altitude = location.altitude
        }
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
