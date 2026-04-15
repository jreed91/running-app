import Foundation
import CoreLocation
import SwiftData

// MARK: - SavedRoute

/// A user-saved running route produced by Route Genius.
///
/// Route coordinates and turn-by-turn steps are stored as JSON blobs using
/// SwiftData external storage so that large arrays stay off the row store.
@Model
final class SavedRoute {

    // MARK: Scalar fields

    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    /// Route type chosen by the user (.loop or .outAndBack).
    var routeType: RouteType = RouteType.loop
    /// Distance the user originally requested, in metres.
    var requestedDistanceMeters: Double = 0
    /// Actual route distance returned by the routing service, in metres.
    var actualDistanceMeters: Double = 0
    /// Estimated running duration in seconds.
    var estimatedDurationSeconds: Double = 0

    // MARK: Start coordinate (scalar to avoid another blob for a single point)

    var startLatitude: Double = 0
    var startLongitude: Double = 0

    // MARK: Large payload

    var coordinatesData: Data?

    var stepsData: Data?

    // MARK: Init

    init(
        name: String,
        routeType: RouteType,
        requestedDistanceMeters: Double,
        actualDistanceMeters: Double,
        estimatedDurationSeconds: Double,
        startLatitude: Double,
        startLongitude: Double,
        coordinates: [Coordinate],
        steps: [RouteStep]
    ) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.routeType = routeType
        self.requestedDistanceMeters = requestedDistanceMeters
        self.actualDistanceMeters = actualDistanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.coordinates = coordinates
        self.steps = steps
    }
}

// MARK: - Computed helpers

extension SavedRoute {

    /// Decode/encode the route path as ``Coordinate`` array.
    var coordinates: [Coordinate] {
        get {
            guard let data = coordinatesData else { return [] }
            return (try? JSONDecoder().decode([Coordinate].self, from: data)) ?? []
        }
        set {
            coordinatesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Decode/encode the turn-by-turn step list.
    var steps: [RouteStep] {
        get {
            guard let data = stepsData else { return [] }
            return (try? JSONDecoder().decode([RouteStep].self, from: data)) ?? []
        }
        set {
            stepsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Convenience accessor for the starting coordinate.
    var startCoordinate: Coordinate {
        Coordinate(CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude))
    }
}
