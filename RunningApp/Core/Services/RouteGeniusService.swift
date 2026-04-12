import Foundation
import CoreLocation

// MARK: - RouteGeniusService

/// Generates running routes via the OpenRouteService (ORS) Directions API.
///
/// ORS docs: https://openrouteservice.org/dev/#/api-docs/v2/directions/{profile}/json/post
///
/// **API key setup**: add a `Secrets.plist` to the app bundle with the key
/// `ORSAPIKey` containing your ORS token.  Copy `Secrets.plist.example` as a
/// starting point.  The simulator build accepts an empty key so the UI renders,
/// but actual route generation requires a valid token.
struct RouteGeniusService: Sendable {

    // MARK: Errors

    enum RouteError: LocalizedError {
        case missingAPIKey
        case networkError(Error)
        case noRouteFound
        case decodingError

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ORS API key not configured. See Secrets.plist.example."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .noRouteFound:
                return "No route could be generated for the given parameters. Try a different starting point or distance."
            case .decodingError:
                return "Unexpected response from routing service."
            }
        }
    }

    // MARK: Configuration

    private let baseURL = "https://api.openrouteservice.org"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Public API

    /// Generates a running route from `start` of approximately `distanceMeters`.
    ///
    /// - Parameters:
    ///   - start: Starting GPS coordinate.
    ///   - distanceMeters: Requested distance in metres (±10% tolerance).
    ///   - routeType: `.loop` or `.outAndBack`.
    ///   - apiKey: OpenRouteService API token (set once in Settings → Route Genius).
    /// - Returns: A ``GeneratedRoute`` with decoded coordinates and turn-by-turn steps.
    func generateRoute(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        routeType: RouteType,
        apiKey: String
    ) async throws -> GeneratedRoute {
        guard !apiKey.isEmpty else { throw RouteError.missingAPIKey }

        switch routeType {
        case .loop:
            return try await generateLoop(start: start, distanceMeters: distanceMeters, apiKey: apiKey)
        case .outAndBack:
            return try await generateOutAndBack(start: start, distanceMeters: distanceMeters, apiKey: apiKey)
        }
    }

    // MARK: Loop generation

    private func generateLoop(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        apiKey: String
    ) async throws -> GeneratedRoute {
        let body: [String: Any] = [
            "coordinates": [[start.longitude, start.latitude]],
            "options": [
                "round_trip": [
                    "length": distanceMeters,
                    "points": 3,
                    "seed": Int.random(in: 0...100)
                ]
            ]
        ]
        return try await fetchRoute(body: body, apiKey: apiKey)
    }

    // MARK: Out-and-back generation

    private func generateOutAndBack(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        apiKey: String
    ) async throws -> GeneratedRoute {
        // Place the turnaround point at half the requested distance in a random bearing.
        let bearing = Double.random(in: 0..<360)
        let midpoint = coordinate(from: start, bearing: bearing, distanceMeters: distanceMeters / 2)

        let body: [String: Any] = [
            "coordinates": [
                [start.longitude, start.latitude],
                [midpoint.longitude, midpoint.latitude]
            ]
        ]

        // Fetch the outward leg.
        let outLeg = try await fetchRoute(body: body, apiKey: apiKey)

        // Build the return leg by reversing the outward coordinates.
        let returnCoords = Array(outLeg.coordinates.reversed())
        // Return steps are the outward steps reversed with "(return)" appended.
        let returnSteps = outLeg.steps.reversed().map { step in
            RouteStep(
                instruction: step.instruction + " (return)",
                name: step.name,
                distanceMeters: step.distanceMeters,
                durationSeconds: step.durationSeconds
            )
        }

        return GeneratedRoute(
            coordinates: outLeg.coordinates + returnCoords,
            steps: outLeg.steps + returnSteps,
            distanceMeters: outLeg.distanceMeters * 2,
            durationSeconds: outLeg.durationSeconds * 2
        )
    }

    // MARK: Network

    private func fetchRoute(body: [String: Any], apiKey: String) async throws -> GeneratedRoute {
        guard let url = URL(string: "\(baseURL)/v2/directions/foot-walking/json") else {
            throw RouteError.noRouteFound
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw RouteError.decodingError
        }

        let data: Data
        do {
            let (responseData, _) = try await session.data(for: request)
            data = responseData
        } catch {
            throw RouteError.networkError(error)
        }

        do {
            let response = try JSONDecoder().decode(ORSResponse.self, from: data)
            guard let route = response.routes.first else { throw RouteError.noRouteFound }
            return try parse(route: route)
        } catch let error as RouteError {
            throw error
        } catch {
            throw RouteError.decodingError
        }
    }

    // MARK: Parsing

    private func parse(route: ORSRoute) throws -> GeneratedRoute {
        let coordinates = decodePolyline(route.geometry)
        guard !coordinates.isEmpty else { throw RouteError.decodingError }

        let steps: [RouteStep] = route.segments.flatMap { segment in
            segment.steps.compactMap { step -> RouteStep? in
                // ORS type 10 = arrive, skip it for cleaner list
                guard step.type != 10 else { return nil }
                return RouteStep(
                    instruction: step.instruction,
                    name: step.name.isEmpty ? "unnamed path" : step.name,
                    distanceMeters: step.distance,
                    durationSeconds: step.duration
                )
            }
        }

        return GeneratedRoute(
            coordinates: coordinates.map { Coordinate($0) },
            steps: steps,
            distanceMeters: route.summary.distance,
            durationSeconds: route.summary.duration
        )
    }

    // MARK: Google-encoded polyline decoder (precision 5)

    private func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var lat = 0
        var lng = 0

        while index < encoded.endIndex {
            // Decode latitude delta
            var shift = 0
            var result = 0
            var byte: Int
            repeat {
                guard index < encoded.endIndex,
                      let ascii = encoded[index].asciiValue else { return coordinates }
                byte = Int(ascii) - 63
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            // Decode longitude delta
            shift = 0
            result = 0
            repeat {
                guard index < encoded.endIndex,
                      let ascii = encoded[index].asciiValue else { return coordinates }
                byte = Int(ascii) - 63
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1)

            coordinates.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lng) / 1e5
            ))
        }

        return coordinates
    }

    // MARK: Geodesy helpers

    /// Returns a coordinate that is `distanceMeters` from `start` along `bearing` (degrees, 0 = north).
    private func coordinate(
        from start: CLLocationCoordinate2D,
        bearing: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let bearingRad = bearing * .pi / 180
        let latRad = start.latitude * .pi / 180
        let lonRad = start.longitude * .pi / 180
        let d = distanceMeters / earthRadius

        let destLatRad = asin(
            sin(latRad) * cos(d) +
            cos(latRad) * sin(d) * cos(bearingRad)
        )
        let destLonRad = lonRad + atan2(
            sin(bearingRad) * sin(d) * cos(latRad),
            cos(d) - sin(latRad) * sin(destLatRad)
        )

        return CLLocationCoordinate2D(
            latitude: destLatRad * 180 / .pi,
            longitude: destLonRad * 180 / .pi
        )
    }
}

// MARK: - ORS Decodable types (private)

private struct ORSResponse: Decodable {
    let routes: [ORSRoute]
}

private struct ORSRoute: Decodable {
    let summary: ORSSummary
    let segments: [ORSSegment]
    let geometry: String
}

private struct ORSSummary: Decodable {
    let distance: Double
    let duration: Double
}

private struct ORSSegment: Decodable {
    let steps: [ORSStep]
}

private struct ORSStep: Decodable {
    let instruction: String
    let name: String
    let distance: Double
    let duration: Double
    let type: Int

    enum CodingKeys: String, CodingKey {
        case instruction, name, distance, duration, type
    }
}

