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
                    .stroke(.brand, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            // Start / finish annotation
            Annotation("Start", coordinate: startCoordinate, anchor: .bottom) {
                ZStack {
                    Circle()
                        .fill(.brand)
                        .frame(width: 36, height: 36)
                    StrideIcon(name: .run, size: 18, color: .white, strokeWeight: 2.2)
                }
            }
        }
        .onAppear { fitCamera() }
        .onChange(of: coordinates.count) { fitCamera() }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    // MARK: Camera fitting

    private func fitCamera() {
        guard !coordinates.isEmpty else { return }
        let region = MKCoordinateRegion(coordinates: coordinates)
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .region(region)
        }
    }
}

// MARK: - MKCoordinateRegion convenience

private extension MKCoordinateRegion {
    init(coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else {
            self = MKCoordinateRegion()
            return
        }

        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min()!
        let maxLat = lats.max()!
        let minLon = lons.min()!
        let maxLon = lons.max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // Add 20% padding so the route is not clipped at the edges.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
        )
        self.init(center: center, span: span)
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
