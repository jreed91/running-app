import Testing
import Foundation
import CoreLocation
import MapKit
@testable import Stride

// MARK: - RouteSnapshotService.mapRegion tests (B5 — map behind the share-card route)
//
// The snapshot rendering itself needs MapKit tiles (integration/network), so only the pure
// region math is unit-tested here: centering, padding, and the minimum-span floor.

struct RouteSnapshotServiceTests {

    private func coord(_ lat: Double, _ lon: Double) -> Coordinate {
        Coordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    @Test("Region centers on the bounding-box midpoint")
    func centersOnMidpoint() {
        let region = RouteSnapshotService.mapRegion(for: [
            coord(40.00, -105.00),
            coord(40.02, -105.04)
        ])
        #expect(abs(region.center.latitude - 40.01) < 1e-9)
        #expect(abs(region.center.longitude - (-105.02)) < 1e-9)
    }

    @Test("Span pads the route by ~30%")
    func spanPadsRoute() {
        let region = RouteSnapshotService.mapRegion(for: [
            coord(40.00, -105.00),
            coord(40.02, -105.04)
        ])
        // 0.02 lat span × 1.3 = 0.026; 0.04 lon span × 1.3 = 0.052.
        #expect(abs(region.span.latitudeDelta - 0.026) < 1e-9)
        #expect(abs(region.span.longitudeDelta - 0.052) < 1e-9)
    }

    @Test("Very short routes are floored to a minimum span")
    func minimumSpanFloor() {
        let region = RouteSnapshotService.mapRegion(for: [
            coord(40.0000, -105.0000),
            coord(40.0001, -105.0001)
        ])
        // Raw spans (~0.00013) fall below the 0.002 floor.
        #expect(region.span.latitudeDelta == 0.002)
        #expect(region.span.longitudeDelta == 0.002)
    }
}
