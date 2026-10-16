import SwiftUI
import MapKit

// MARK: - RouteMapView

/// Displays a generated or saved route as a polyline on a MapKit map.
///
/// The map automatically fits the camera to encompass all route coordinates.
/// A start annotation marks the beginning of the route.
struct RouteMapView: View {

    let coordinates: [CLLocationCoordinate2D]
    let startCoordinate: CLLocationCoordinate2D

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            // Route polyline
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            // Start / finish annotation
            // The Route Loop's start pin, where the loop begins and ends.
            Annotation("Start", coordinate: startCoordinate, anchor: .center) {
                StartPin(diameter: 26, pulses: true)
                    .appShadow(.e2)
            }
        }
        .onAppear { fitCamera() }
        .onChange(of: routeBounds) { _, _ in fitCamera() }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    // MARK: Camera fitting

    /// The extent of what is currently plotted, including the start pin.
    ///
    /// Refitting keyed on `coordinates.count` alone left the camera parked over the
    /// previous route whenever the user switched to a different option with the same
    /// number of points — which is common, since the three generated options are the
    /// same requested distance. Comparing the actual bounds catches every real move.
    private var routeBounds: RouteBounds? {
        RouteBounds(coordinates: coordinates + [startCoordinate])
    }

    private func fitCamera() {
        guard let region = routeBounds?.region else { return }
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .region(region)
        }
    }
}

// MARK: - RouteBounds

/// Equatable bounding box for a set of coordinates, used both to decide when the
/// camera needs refitting and to compute the region it should fit to.
private struct RouteBounds: Equatable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init?(coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = Swift.min(minLat, coordinate.latitude)
            maxLat = Swift.max(maxLat, coordinate.latitude)
            minLon = Swift.min(minLon, coordinate.longitude)
            maxLon = Swift.max(maxLon, coordinate.longitude)
        }
        self.minLatitude = minLat
        self.maxLatitude = maxLat
        self.minLongitude = minLon
        self.maxLongitude = maxLon
    }

    var region: MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        // Add 20% padding so the route is not clipped at the edges.
        let span = MKCoordinateSpan(
            latitudeDelta: Swift.max((maxLatitude - minLatitude) * 1.4, 0.005),
            longitudeDelta: Swift.max((maxLongitude - minLongitude) * 1.4, 0.005)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - SavedRouteMapView

/// Same map view driven from a ``SavedRoute`` model.
struct SavedRouteMapView: View {
    let route: SavedRoute

    var body: some View {
        RouteMapView(
            coordinates: route.coordinates.map(\.clCoordinate),
            startCoordinate: route.startCoordinate.clCoordinate
        )
    }
}
