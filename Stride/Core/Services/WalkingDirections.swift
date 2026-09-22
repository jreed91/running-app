import Foundation
import CoreLocation
import MapKit

// MARK: - WalkingDirectionsProvider

/// Point-to-point walking directions, the one primitive Route Genius needs from a routing
/// backend once it builds loops and out-and-backs itself.
///
/// The seam exists so the loop/out-and-back geometry in ``RouteGeniusService`` can be
/// unit-tested against a fake that answers instantly, without MapKit or a network.
protocol WalkingDirectionsProvider: Sendable {
    /// The walking route from `start` to `end`. The returned route's `label` is unused.
    func walkingRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> GeneratedRoute
}

// MARK: - MapKitWalkingDirections

/// Apple Maps walking directions via `MKDirections`. Needs no API key and no account, which
/// is why it is Route Genius's default backend: a runner who never opens Settings still gets
/// routes. Apple throttles `MKDirections` per app, so a burst of requests can fail with
/// `MKError.loadingThrottled`; that surfaces as ``RouteGeniusService/RouteError/rateLimited``.
struct MapKitWalkingDirections: WalkingDirectionsProvider {

    func walkingRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> GeneratedRoute {
        try await Self.calculate(from: start, to: end)
    }

    /// Main-actor isolated so the non-`Sendable` MapKit request and response never leave
    /// the actor they were created on — the same shape `RouteGeniusViewModel` uses for
    /// `MKLocalSearch`. Only the `Sendable` ``GeneratedRoute`` crosses back.
    @MainActor
    private static func calculate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> GeneratedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError {
            switch error.code {
            case .loadingThrottled:
                throw RouteGeniusService.RouteError.rateLimited
            case .directionsNotFound, .placemarkNotFound:
                throw RouteGeniusService.RouteError.noRouteFound
            default:
                throw RouteGeniusService.RouteError.networkError(error)
            }
        } catch {
            throw RouteGeniusService.RouteError.networkError(error)
        }

        guard let route = response.routes.first else {
            throw RouteGeniusService.RouteError.noRouteFound
        }

        let coordinates = Self.coordinates(of: route.polyline)
        guard !coordinates.isEmpty else { throw RouteGeniusService.RouteError.decodingError }

        // MapKit gives each step a distance but no duration, so a step's share of the
        // leg's expected time is its share of the leg's distance.
        let secondsPerMeter = route.distance > 0 ? route.expectedTravelTime / route.distance : 0
        let steps: [RouteStep] = route.steps.compactMap { step in
            // The first step is usually an empty "start here" marker.
            let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            return RouteStep(
                instruction: instruction,
                name: "",
                distanceMeters: step.distance,
                durationSeconds: step.distance * secondsPerMeter
            )
        }

        return GeneratedRoute(
            coordinates: coordinates.map { Coordinate($0) },
            steps: steps,
            distanceMeters: route.distance,
            durationSeconds: route.expectedTravelTime,
            label: ""
        )
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }
}
