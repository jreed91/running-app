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
        case invalidResponse
        case unauthorized
        case rateLimited
        case serverError(Int)
        case httpError(Int)
        case networkError(Error)
        case noRouteFound
        case decodingError

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ORS API key not configured. See Secrets.plist.example."
            case .invalidResponse:
                return "Unexpected response from routing service."
            case .unauthorized:
                return "Invalid ORS API key. Check Secrets.plist and try again."
            case .rateLimited:
                return "Route service quota exceeded. Please try again later."
            case .serverError(let statusCode):
                return "Routing service is temporarily unavailable (HTTP \(statusCode))."
            case .httpError(let statusCode):
                return "Routing service returned an unexpected error (HTTP \(statusCode))."
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

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: Public API

    /// Generates three distinct route options in parallel.
    ///
    /// Loop routes use different ORS seeds; out-and-back routes head in three
    /// compass directions (NE / SE / SW) so every option looks meaningfully different.
    /// Options whose individual request fails are silently dropped; at least one must
    /// succeed or ``RouteError/noRouteFound`` is thrown.
    func generateRouteOptions(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        routeType: RouteType,
        apiKey: String
    ) async throws -> [GeneratedRoute] {
        guard !apiKey.isEmpty else { throw RouteError.missingAPIKey }

        let groupResults: ([GeneratedRoute], [RouteError]) = await withTaskGroup(of: Result<GeneratedRoute, RouteError>.self) { group in
            switch routeType {
            case .loop:
                let configs: [(seed: Int, label: String)] = [
                    (1,  "Option A"),
                    (42, "Option B"),
                    (99, "Option C")
                ]
                for cfg in configs {
                    group.addTask {
                        do {
                            let route = try await self.generateLoop(
                                start: start,
                                distanceMeters: distanceMeters,
                                apiKey: apiKey,
                                seed: cfg.seed,
                                label: cfg.label
                            )
                            return .success(route)
                        } catch let routeError as RouteError {
                            return .failure(routeError)
                        } catch {
                            return .failure(.networkError(error))
                        }
                    }
                }
            case .outAndBack:
                let configs: [(bearing: Double, label: String)] = [
                    (45,  "Heading Northeast"),
                    (135, "Heading Southeast"),
                    (225, "Heading Southwest")
                ]
                for cfg in configs {
                    group.addTask {
                        do {
                            let route = try await self.generateOutAndBack(
                                start: start,
                                distanceMeters: distanceMeters,
                                apiKey: apiKey,
                                bearing: cfg.bearing,
                                label: cfg.label
                            )
                            return .success(route)
                        } catch let routeError as RouteError {
                            return .failure(routeError)
                        } catch {
                            return .failure(.networkError(error))
                        }
                    }
                }
            }

            var collected: [GeneratedRoute] = []
            var failures: [RouteError] = []
            for await result in group {
                switch result {
                case .success(let route):
                    collected.append(route)
                case .failure(let error):
                    failures.append(error)
                }
            }
            // Sort so Option A / NE always appears first regardless of which finished first.
            return (collected.sorted { $0.label < $1.label }, failures)
        }

        let (results, failures) = groupResults
        guard !results.isEmpty else {
            throw failures.first ?? RouteError.noRouteFound
        }
        return results
    }

    // MARK: Loop generation

    private func generateLoop(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        apiKey: String,
        seed: Int,
        label: String
    ) async throws -> GeneratedRoute {
        let body: [String: Any] = [
            "coordinates": [[start.longitude, start.latitude]],
            "options": [
                "round_trip": [
                    "length": distanceMeters,
                    "points": 3,
                    "seed": seed
                ]
            ]
        ]
        return try await fetchRoute(body: body, apiKey: apiKey, label: label)
    }

    // MARK: Out-and-back generation

    private func generateOutAndBack(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        apiKey: String,
        bearing: Double,
        label: String
    ) async throws -> GeneratedRoute {
        let midpoint = coordinate(from: start, bearing: bearing, distanceMeters: distanceMeters / 2)

        let body: [String: Any] = [
            "coordinates": [
                [start.longitude, start.latitude],
                [midpoint.longitude, midpoint.latitude]
            ]
        ]

        // Fetch the outward leg.
        let outLeg = try await fetchRoute(body: body, apiKey: apiKey, label: label)

        // Build the return leg by reversing the outward coordinates.
        let returnCoords = Array(outLeg.coordinates.reversed())
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
            durationSeconds: outLeg.durationSeconds * 2,
            label: label
        )
    }

    // MARK: Network

    private func fetchRoute(body: [String: Any], apiKey: String, label: String) async throws -> GeneratedRoute {
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
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RouteError.invalidResponse
            }
            switch http.statusCode {
            case 200...299:
                break
            case 401, 403:
                throw RouteError.unauthorized
            case 429:
                throw RouteError.rateLimited
            case 500...599:
                throw RouteError.serverError(http.statusCode)
            default:
                throw RouteError.httpError(http.statusCode)
            }
            data = responseData
        } catch let error as RouteError {
            throw error
        } catch {
            throw RouteError.networkError(error)
        }

        do {
            let response = try JSONDecoder().decode(ORSResponse.self, from: data)
            guard let route = response.routes.first else { throw RouteError.noRouteFound }
            return try parse(route: route, label: label)
        } catch let error as RouteError {
            throw error
        } catch {
            throw RouteError.decodingError
        }
    }

    // MARK: Parsing

    private func parse(route: ORSRoute, label: String) throws -> GeneratedRoute {
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
            durationSeconds: route.summary.duration,
            label: label
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
