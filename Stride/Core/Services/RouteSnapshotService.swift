import MapKit
import UIKit

/// Renders a static map image of a run's route for the share card (B5).
///
/// `MKMapSnapshotter` fetches map tiles asynchronously, so this is awaited before the card is
/// rendered and the resulting image is passed in as the route panel's background. The route
/// polyline is drawn onto the snapshot here (using the snapshot's own coordinate conversion) so
/// it always aligns with the tiles, and the whole thing ships to the card as one baked image.
enum RouteSnapshotService {

    /// A map snapshot covering `coordinates` with the route drawn on top, or `nil` for routes with
    /// fewer than two points or if the snapshot fails (e.g. offline). The returned image is sized
    /// `size` (points) at `scale`.
    static func routeSnapshot(
        coordinates: [Coordinate],
        size: CGSize,
        scale: CGFloat,
        lineColor: UIColor,
        lineWidth: CGFloat
    ) async -> UIImage? {
        guard coordinates.count >= 2 else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = mapRegion(for: coordinates)
        options.size = size
        options.scale = scale
        // A dark map matches the card's dark palette; drop POI clutter for a clean route.
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot = try await snapshotter.start()
            return drawRoute(
                coordinates.map(\.clCoordinate),
                on: snapshot,
                lineColor: lineColor,
                lineWidth: lineWidth
            )
        } catch {
            AppLogger.log(
                "Route snapshot failed: \(error.localizedDescription)",
                label: "RouteSnapshotService",
                level: .error
            )
            return nil
        }
    }

    /// The region enclosing `coordinates`, padded ~30 % so the route isn't flush to the edges and
    /// floored to a minimum span so a very short run doesn't zoom in absurdly. Pure — unit-tested.
    static func mapRegion(for coordinates: [Coordinate]) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.002),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.002)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Composites the route polyline onto the snapshot image using the snapshot's coordinate→point
    /// conversion so it lines up exactly with the rendered tiles.
    private static func drawRoute(
        _ coordinates: [CLLocationCoordinate2D],
        on snapshot: MKMapSnapshotter.Snapshot,
        lineColor: UIColor,
        lineWidth: CGFloat
    ) -> UIImage {
        let image = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { context in
            image.draw(at: .zero)

            let cgContext = context.cgContext
            cgContext.setStrokeColor(lineColor.cgColor)
            cgContext.setLineWidth(lineWidth)
            cgContext.setLineJoin(.round)
            cgContext.setLineCap(.round)

            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 {
                    cgContext.move(to: point)
                } else {
                    cgContext.addLine(to: point)
                }
            }
            cgContext.strokePath()
        }
    }
}
