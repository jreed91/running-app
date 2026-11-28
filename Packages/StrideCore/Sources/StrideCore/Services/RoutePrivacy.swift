import Foundation

// MARK: - RoutePrivacy

/// What of a run's route is left out when the route leaves the phone: the first and last
/// stretch of every run, and anything inside a private place such as home.
///
/// A shared run is how most people find Stride, and a share card that draws a line from
/// the runner's front door is the one thing that would stop them posting it. Strava's
/// privacy zones are the expectation runners bring with them.
///
/// Applies to what the runner *shares*: the run card image and a single run's GPX file.
/// The full-data export in Settings keeps every point, because that file is the runner's
/// own backup and leaves the phone only where they put it. The stored route, Health's copy
/// and the run screen's map are never trimmed.
///
/// Kept in `UserDefaults`, like ``StrengthPreferences``: per device, no CloudKit schema
/// change, and a home location that never reaches iCloud key-value storage.
public struct RoutePrivacy: Codable, Equatable, Sendable {

    /// A place whose surroundings never appear on a shared route.
    public struct Place: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var center: Coordinate
        public var radiusMeters: Double

        public init(id: UUID = UUID(), name: String, center: Coordinate, radiusMeters: Double) {
            self.id = id
            self.name = name
            self.center = center
            self.radiusMeters = radiusMeters
        }
    }

    /// Metres hidden from the start and from the finish of every shared run. 0 is off.
    public var hideEndsMeters: Double
    public var places: [Place]

    public init(hideEndsMeters: Double = Self.defaultHideEndsMeters, places: [Place] = []) {
        self.hideEndsMeters = hideEndsMeters
        self.places = places
    }

    // Written out so settings saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideEndsMeters = try container.decodeIfPresent(Double.self, forKey: .hideEndsMeters)
            ?? Self.defaultHideEndsMeters
        places = try container.decodeIfPresent([Place].self, forKey: .places) ?? []
    }

    /// Hides nothing. What the share card did before privacy existed, and what tests of
    /// the card's layout use.
    public static let off = RoutePrivacy(hideEndsMeters: 0, places: [])

    /// On by default: a runner who never opens the setting still doesn't post their door.
    /// 200 m is the smallest that reliably covers a GPS fix settling at the start.
    public static let defaultHideEndsMeters: Double = 200
    public static let hideEndsOptions: [Double] = [0, 200, 400, 800]
    public static let radiusOptions: [Double] = [200, 400, 800]
    public static let defaultRadiusMeters: Double = 400

    public var hidesAnything: Bool { hideEndsMeters > 0 || !places.isEmpty }

    // MARK: Trimming

    /// The parts of `route` that may be shown, as runs of indices into it, in order.
    ///
    /// A point is hidden when it is within ``hideEndsMeters`` of the start or the finish,
    /// measured along the route, or within a place's radius. What is left is split
    /// wherever points were hidden, so a run that passes home mid-way shows two pieces
    /// rather than a straight line drawn across the hidden part. Pieces of a single point
    /// are dropped: there is nothing to draw. Empty when nothing is left, or when the run
    /// is too short to hide both ends and show anything between them.
    ///
    /// Indices rather than coordinates so a caller holding a parallel array (GPX
    /// timestamps) can keep the two aligned.
    public func visibleRanges(of route: [Coordinate]) -> [Range<Int>] {
        guard route.count >= 2 else { return [] }

        var along = [Double](repeating: 0, count: route.count)
        for index in 1..<route.count {
            along[index] = along[index - 1] + Self.distanceMeters(route[index - 1], route[index])
        }
        let total = along[route.count - 1]
        let ends = max(0, hideEndsMeters)

        func isVisible(_ index: Int) -> Bool {
            if ends > 0, along[index] < ends || total - along[index] < ends { return false }
            let point = route[index]
            return !places.contains { Self.distanceMeters($0.center, point) <= $0.radiusMeters }
        }

        var ranges: [Range<Int>] = []
        var start: Int?
        for index in route.indices {
            if isVisible(index) {
                if start == nil { start = index }
            } else if let open = start {
                ranges.append(open..<index)
                start = nil
            }
        }
        if let open = start { ranges.append(open..<route.count) }
        return ranges.filter { $0.count >= 2 }
    }

    /// The visible parts of `route` as coordinate pieces. See ``visibleRanges(of:)``.
    public func visibleSegments(of route: [Coordinate]) -> [[Coordinate]] {
        visibleRanges(of: route).map { Array(route[$0]) }
    }

    // MARK: Geometry

    /// Great-circle distance in metres (haversine, mean Earth radius). Accurate to well
    /// under a metre at the few-hundred-metre scale this works at, and free of CoreLocation
    /// so it can be asserted on directly.
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let earthRadius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    // MARK: Storage

    public static let defaultsKey = "routePrivacy"

    public static func load(from defaults: UserDefaults = .standard) -> RoutePrivacy {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(RoutePrivacy.self, from: data)
        else { return RoutePrivacy() }
        return stored
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
