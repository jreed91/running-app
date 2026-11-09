import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - RaceCourse

/// A race course as the pacing needs it: how high the road is at each point along it.
///
/// Built once, from the course GPX the race publishes, by ``RaceCourse/fromGPX(_:)``. Only
/// the elevation profile is kept — a sample every ``sampleSpacingMeters`` — because that is
/// all grade-adjusted splits read, and it keeps a marathon to under a thousand pairs of
/// numbers. The line on the map is not kept.
///
/// Pure Foundation, so the parsing and the smoothing are assertable without a device.
struct RaceCourse: Codable, Sendable, Equatable {

    /// One point on the profile.
    struct Sample: Codable, Sendable, Equatable {
        /// Distance from the start along the course, in metres.
        let distanceMeters: Double
        /// Smoothed elevation, in metres.
        let elevationMeters: Double
    }

    /// The course's own name from the file, when it has one.
    let name: String?
    /// The profile from start to finish: the first sample is at 0 m and the last at the
    /// finish, so the spacing of the final pair is usually shorter than the rest.
    let samples: [Sample]
    /// Total climb along the smoothed profile, counted through ``ElevationGainAccumulator``.
    let climbMeters: Double
    /// Total descent, counted the same way.
    let descentMeters: Double

    /// The course's length as drawn in the file.
    var lengthMeters: Double { samples.last?.distanceMeters ?? 0 }

    var lowestElevationMeters: Double { samples.map(\.elevationMeters).min() ?? 0 }
    var highestElevationMeters: Double { samples.map(\.elevationMeters).max() ?? 0 }

    /// The profile's elevation at a distance along the course, interpolated between
    /// samples and held at the ends.
    func elevation(atMeters distance: Double) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if distance <= first.distanceMeters { return first.elevationMeters }
        if distance >= last.distanceMeters { return last.elevationMeters }

        // Samples are evenly spaced apart from the last pair, so the index is a division
        // rather than a search.
        var index = min(Int(distance / Self.sampleSpacingMeters), samples.count - 2)
        while index > 0, samples[index].distanceMeters > distance { index -= 1 }
        while index < samples.count - 2, samples[index + 1].distanceMeters < distance { index += 1 }

        let lower = samples[index]
        let upper = samples[index + 1]
        let span = upper.distanceMeters - lower.distanceMeters
        guard span > 0 else { return lower.elevationMeters }
        let fraction = (distance - lower.distanceMeters) / span
        return lower.elevationMeters + (upper.elevationMeters - lower.elevationMeters) * fraction
    }
}

// MARK: - Building

extension RaceCourse {

    /// Spacing of the stored profile. Fifty metres keeps a marathon to 845 samples, and no
    /// split is shorter than a kilometre, so finer detail would never reach a split.
    static let sampleSpacingMeters = 50.0

    /// Spacing the track is first laid onto before smoothing. Fine enough that a dense
    /// GPS-drawn track keeps its shape, coarse enough that a sparse hand-drawn route with
    /// points a few hundred metres apart is interpolated rather than stepped.
    static let resampleSpacingMeters = 10.0

    /// Elevation is averaged over this far either side of each point.
    ///
    /// Course files are drawn on a map and take their heights from a terrain model, which
    /// puts bridges in the river below them and steps the road along the model's grid. A
    /// 200 m window is short against any hill a runner would pace for and long against
    /// that noise, which on a road course otherwise reads as a dozen one-percent "climbs"
    /// a kilometre.
    static let smoothingHalfWindowMeters = 100.0

    /// Shortest course worth pacing. Anything shorter is not a race course.
    static let minimumLengthMeters = 1_000.0

    /// The share of track points that must carry an elevation. Below it the file is a
    /// route without heights — common from mapping sites — and pacing it would be pacing
    /// a flat line.
    static let minimumElevationCoverage = 0.5

    /// Mean Earth radius used for the distances, the same value the route code uses.
    static let earthRadiusMeters = 6_371_000.0

    /// A point as read from the file.
    struct TrackPoint: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let elevation: Double?
    }

    /// Reads a GPX 1.0 or 1.1 document. Track points win over route points when a file has
    /// both, because a track is the line actually drawn and a route is often just the
    /// turns.
    static func fromGPX(_ data: Data) throws(RaceCourseImportError) -> RaceCourse {
        let collector = GPXPointCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw .unreadable }

        let points = collector.trackPoints.isEmpty ? collector.routePoints : collector.trackPoints
        return try make(points: points, name: collector.name)
    }

    /// The course from points in order along it.
    static func make(points: [TrackPoint], name: String?) throws(RaceCourseImportError) -> RaceCourse {
        guard points.count >= 2 else { throw .noPoints }

        let withElevation = points.filter { $0.elevation?.isFinite == true }
        guard withElevation.count >= 2,
              Double(withElevation.count) / Double(points.count) >= minimumElevationCoverage
        else { throw .noElevation }

        // Distance along the line, through the points that carry a height. A point with no
        // height is dropped rather than given one, since any height made up for it would
        // be a guess the pacing then takes as fact.
        var distances: [Double] = [0]
        var elevations: [Double] = [withElevation[0].elevation ?? 0]
        distances.reserveCapacity(withElevation.count)
        elevations.reserveCapacity(withElevation.count)
        for index in 1..<withElevation.count {
            let step = distanceMeters(from: withElevation[index - 1], to: withElevation[index])
            // A repeated point (a paused recorder, a doubled vertex) adds no distance and
            // would make two heights claim the same spot.
            guard step > 0.01 else { continue }
            distances.append(distances[distances.count - 1] + step)
            elevations.append(withElevation[index].elevation ?? 0)
        }

        let length = distances[distances.count - 1]
        guard length >= minimumLengthMeters else { throw .tooShort }

        let fine = resample(distances: distances, elevations: elevations, spacing: resampleSpacingMeters, length: length)
        let smoothed = movingAverage(fine, halfWindow: Int((smoothingHalfWindowMeters / resampleSpacingMeters).rounded()))

        // Every fifth 10 m point is a 50 m sample; the finish is always kept.
        let stride = Int((sampleSpacingMeters / resampleSpacingMeters).rounded())
        var samples: [Sample] = []
        samples.reserveCapacity(smoothed.count / stride + 2)
        for index in Swift.stride(from: 0, to: smoothed.count, by: stride) {
            samples.append(Sample(distanceMeters: Double(index) * resampleSpacingMeters, elevationMeters: smoothed[index]))
        }
        if let last = samples.last, length - last.distanceMeters > 0.5 {
            samples.append(Sample(distanceMeters: length, elevationMeters: smoothed[smoothed.count - 1]))
        }

        var climbing = ElevationGainAccumulator()
        var descending = ElevationGainAccumulator()
        var climb = 0.0
        var descent = 0.0
        for sample in samples {
            climb += climbing.add(sample.elevationMeters)
            descent += descending.add(-sample.elevationMeters)
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RaceCourse(
            name: trimmedName?.isEmpty == false ? trimmedName : nil,
            samples: samples,
            climbMeters: climb,
            descentMeters: descent
        )
    }

    /// Great-circle distance between two points.
    static func distanceMeters(from start: TrackPoint, to end: TrackPoint) -> Double {
        let radians = Double.pi / 180
        let lat1 = start.latitude * radians
        let lat2 = end.latitude * radians
        let dLat = lat2 - lat1
        let dLon = (end.longitude - start.longitude) * radians
        let haversine = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(haversine)))
    }

    /// Heights every `spacing` metres from the start, interpolated along the line. The
    /// last value is at `length` itself, so the result covers the whole course.
    static func resample(distances: [Double], elevations: [Double], spacing: Double, length: Double) -> [Double] {
        let count = Int(length / spacing) + 1
        var result: [Double] = []
        result.reserveCapacity(count + 1)
        var segment = 0
        for index in 0..<count {
            let target = Double(index) * spacing
            result.append(interpolate(at: target, distances: distances, elevations: elevations, segment: &segment))
        }
        if length - Double(count - 1) * spacing > 0.01 {
            result.append(elevations[elevations.count - 1])
        }
        return result
    }

    private static func interpolate(
        at target: Double,
        distances: [Double],
        elevations: [Double],
        segment: inout Int
    ) -> Double {
        while segment < distances.count - 2, distances[segment + 1] < target { segment += 1 }
        let lower = distances[segment]
        let upper = distances[segment + 1]
        guard upper > lower else { return elevations[segment] }
        let fraction = min(max((target - lower) / (upper - lower), 0), 1)
        return elevations[segment] + (elevations[segment + 1] - elevations[segment]) * fraction
    }

    /// A centred moving average that shrinks its window at the ends rather than padding
    /// them, so the start and finish heights are averages of real points only.
    static func movingAverage(_ values: [Double], halfWindow: Int) -> [Double] {
        guard halfWindow > 0, values.count > 2 else { return values }
        var prefix: [Double] = [0]
        prefix.reserveCapacity(values.count + 1)
        for value in values { prefix.append(prefix[prefix.count - 1] + value) }

        return values.indices.map { index in
            let lower = max(0, index - halfWindow)
            let upper = min(values.count - 1, index + halfWindow)
            return (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
        }
    }
}

// MARK: - RaceCourseImportError

/// Why a file could not become a course, in the words the import sheet shows.
enum RaceCourseImportError: Error, Equatable, Sendable, LocalizedError {
    case unreadable
    case noPoints
    case noElevation
    case tooShort

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "That file isn't a GPX file Stride can read.", comment: "Course import error")
        case .noPoints:
            return String(localized: "That file has no route or track in it.", comment: "Course import error")
        case .noElevation:
            return String(
                localized: "That file has no elevation, so there are no hills to pace for. Try the GPX from the race website or a Strava route.",
                comment: "Course import error: the GPX has no <ele> heights"
            )
        case .tooShort:
            return String(localized: "That course is under 1 km, so it can't be your race.", comment: "Course import error")
        }
    }
}

// MARK: - GPXPointCollector

/// Collects `trkpt` and `rtept` positions and heights from a GPX document.
///
/// Matches on local element names, so a file that prefixes the GPX namespace
/// (`<gpx:trkpt>`) reads the same as one that declares it as the default.
private final class GPXPointCollector: NSObject, XMLParserDelegate {

    private(set) var trackPoints: [RaceCourse.TrackPoint] = []
    private(set) var routePoints: [RaceCourse.TrackPoint] = []
    private(set) var name: String?

    private enum Kind { case track, route }

    private var currentKind: Kind?
    private var currentLatitude = 0.0
    private var currentLongitude = 0.0
    private var currentElevation: Double?
    private var text = ""

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Self.localName(elementName)
        switch element {
        case "trkpt", "rtept":
            guard let latitude = attributeDict["lat"].flatMap(Double.init),
                  let longitude = attributeDict["lon"].flatMap(Double.init),
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude)
            else {
                currentKind = nil
                return
            }
            currentKind = element == "trkpt" ? .track : .route
            currentLatitude = latitude
            currentLongitude = longitude
            currentElevation = nil
        case "ele", "name":
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.localName(elementName) {
        case "ele":
            if currentKind != nil {
                currentElevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "name":
            // The first name outside a point names the course: the metadata's, else the
            // track's or route's.
            if currentKind == nil, name == nil {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { name = trimmed }
            }
        case "trkpt":
            if currentKind == .track {
                trackPoints.append(.init(latitude: currentLatitude, longitude: currentLongitude, elevation: currentElevation))
            }
            currentKind = nil
        case "rtept":
            if currentKind == .route {
                routePoints.append(.init(latitude: currentLatitude, longitude: currentLongitude, elevation: currentElevation))
            }
            currentKind = nil
        default:
            break
        }
    }
}
