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
        case unauthorized
        case forbidden
        case rateLimited
        case serverError(statusCode: Int)
        case unexpectedStatusCode(Int)
        case invalidResponse
        case noRouteFound
        case decodingError
        case invalidRequestURL

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "ORS API key not configured. See Secrets.plist.example."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .unauthorized:
                return "Route API key is invalid or missing permissions (401)."
            case .forbidden:
                return "Route API request is forbidden (403). Check your API key and account limits."
            case .rateLimited:
                return "Route API rate limit reached (429). Please try again in a moment."
            case .serverError:
                return "Route service is temporarily unavailable. Please try again."
            case .unexpectedStatusCode(let code):
                return "Route service returned an unexpected response (\(code))."
            case .invalidResponse:
                return "Route service returned an invalid response."
            case .noRouteFound:
                return "No route could be generated for the given parameters. Try a different starting point or distance."
            case .decodingError:
                return "Unexpected response from routing service."
            case .invalidRequestURL:
                return "Route service address is misconfigured. Please report this if it keeps happening."
            }
        }
    }

    // MARK: Configuration

    private let baseURL = "https://api.openrouteservice.org"
    private let session: any StrideURLSessionProtocol

    /// Defaults to a plain `URLSession` so the service fails closed: a diagnostics-
    /// capturing session is only ever used when a caller asks for one, and callers
    /// obtain it from `PulseIntegrationService.makeInstrumentedURLSession()`, which
    /// guarantees header/query redaction is installed first (S5).
    init(session: any StrideURLSessionProtocol = URLSession(configuration: .default)) {
        self.session = session
    }

    // MARK: Public API

    /// Generates three distinct route options in parallel.
    ///
    /// Loop routes use different ORS seeds; out-and-back routes head in three
    /// compass directions (NE / SE / SW) so every option looks meaningfully different.
    /// If every option fails, the first encountered ``RouteError`` is surfaced.
    func generateRouteOptions(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        routeType: RouteType,
        apiKey: String
    ) async throws -> [GeneratedRoute] {
        guard !apiKey.isEmpty else { throw RouteError.missingAPIKey }

        let generationResult: (routes: [GeneratedRoute], firstError: Error?) = await withTaskGroup(of: Result<GeneratedRoute, Error>.self) { group in
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
                            return .success(try await self.generateLoop(
                                start: start,
                                distanceMeters: distanceMeters,
                                apiKey: apiKey,
                                seed: cfg.seed,
                                label: cfg.label
                            ))
                        } catch {
                            return .failure(error)
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
                            return .success(try await self.generateOutAndBack(
                                start: start,
                                distanceMeters: distanceMeters,
                                apiKey: apiKey,
                                bearing: cfg.bearing,
                                label: cfg.label
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }

            var collected: [GeneratedRoute] = []
            var firstError: Error?
            for await item in group {
                switch item {
                case .success(let route):
                    collected.append(route)
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
            return (collected.sorted { $0.label < $1.label }, firstError)
        }

        if !generationResult.routes.isEmpty {
            return generationResult.routes
        }
        if let routeError = generationResult.firstError as? RouteError {
            throw routeError
        }
        throw RouteError.noRouteFound
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

    /// Typical ratio of walked road distance to straight-line distance between two
    /// nearby urban points. Placing the turnaround at the full half-distance as the
    /// crow flies makes the routed leg — and therefore the finished out-and-back —
    /// systematically longer than the runner asked for, so the first guess is
    /// shortened by this factor.
    static let assumedDetourFactor = 1.25

    /// Tolerance, as a fraction of the target, within which a routed leg is accepted
    /// without spending another request refining it.
    static let outAndBackTolerance = 0.1

    /// Straight-line turnaround offset to try first for a given total distance.
    static func initialTurnaroundOffsetMeters(targetTotalMeters: Double) -> Double {
        max(targetTotalMeters, 0) / 2 / assumedDetourFactor
    }

    /// Corrected straight-line turnaround offset given how long the routed leg
    /// actually came back.
    ///
    /// Scales the previous offset by how far off the routed leg was, then clamps the
    /// correction to half/double so one pathological response cannot fling the
    /// turnaround point into the next county.
    static func refinedTurnaroundOffsetMeters(
        previousOffsetMeters: Double,
        routedLegMeters: Double,
        targetLegMeters: Double
    ) -> Double {
        guard routedLegMeters > 0, previousOffsetMeters > 0, targetLegMeters > 0 else {
            return previousOffsetMeters
        }
        let ratio = min(max(targetLegMeters / routedLegMeters, 0.5), 2.0)
        return previousOffsetMeters * ratio
    }

    /// Whether a routed leg is close enough to the target to stop refining.
    static func isLegWithinTolerance(
        routedLegMeters: Double,
        targetLegMeters: Double,
        tolerance: Double = outAndBackTolerance
    ) -> Bool {
        guard targetLegMeters > 0 else { return true }
        return abs(routedLegMeters - targetLegMeters) / targetLegMeters <= tolerance
    }

    private func generateOutAndBack(
        start: CLLocationCoordinate2D,
        distanceMeters: Double,
        apiKey: String,
        bearing: Double,
        label: String
    ) async throws -> GeneratedRoute {
        let targetLegMeters = distanceMeters / 2
        var offsetMeters = Self.initialTurnaroundOffsetMeters(targetTotalMeters: distanceMeters)

        // One correction round at most: each attempt is a network request, and three
        // route options are generated concurrently against a rate-limited API.
        var outLeg = try await fetchOutLeg(
            start: start, bearing: bearing, offsetMeters: offsetMeters, apiKey: apiKey, label: label
        )

        if !Self.isLegWithinTolerance(routedLegMeters: outLeg.distanceMeters, targetLegMeters: targetLegMeters) {
            offsetMeters = Self.refinedTurnaroundOffsetMeters(
                previousOffsetMeters: offsetMeters,
                routedLegMeters: outLeg.distanceMeters,
                targetLegMeters: targetLegMeters
            )
            if let refined = try? await fetchOutLeg(
                start: start, bearing: bearing, offsetMeters: offsetMeters, apiKey: apiKey, label: label
            ) {
                let previousMiss = abs(outLeg.distanceMeters - targetLegMeters)
                let refinedMiss = abs(refined.distanceMeters - targetLegMeters)
                if refinedMiss < previousMiss { outLeg = refined }
            }
        }

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

    private func fetchOutLeg(
        start: CLLocationCoordinate2D,
        bearing: Double,
        offsetMeters: Double,
        apiKey: String,
        label: String
    ) async throws -> GeneratedRoute {
        let turnaround = coordinate(from: start, bearing: bearing, distanceMeters: offsetMeters)
        let body: [String: Any] = [
            "coordinates": [
                [start.longitude, start.latitude],
                [turnaround.longitude, turnaround.latitude]
            ]
        ]
        return try await fetchRoute(body: body, apiKey: apiKey, label: label)
    }

    // MARK: Network

    private func fetchRoute(body: [String: Any], apiKey: String, label: String) async throws -> GeneratedRoute {
        // A failure here is a bug in the configured base URL, not an absence of
        // walkable roads — report it as its own error rather than "no route found".
        guard let url = URL(string: "\(baseURL)/v2/directions/foot-walking/json") else {
            throw RouteError.invalidRequestURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw RouteError.decodingError
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performRequestWithRetry(request, retryAttempts: 2)
        } catch {
            throw RouteError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RouteError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            throw RouteError.unauthorized
        case 403:
            throw RouteError.forbidden
        case 429:
            throw RouteError.rateLimited
        case 500...599:
            throw RouteError.serverError(statusCode: httpResponse.statusCode)
        default:
            throw RouteError.unexpectedStatusCode(httpResponse.statusCode)
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

    private func performRequestWithRetry(
        _ request: URLRequest,
        retryAttempts: Int
    ) async throws -> (Data, URLResponse) {
        var attempt = 0

        while true {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 429 || (500...599).contains(http.statusCode),
                   attempt < retryAttempts {
                    let delayNs = UInt64(Double(250_000_000) * pow(2, Double(attempt)))
                    try await Task.sleep(nanoseconds: delayNs)
                    attempt += 1
                    continue
                }
                return (data, response)
            } catch {
                let shouldRetry: Bool
                if let urlError = error as? URLError {
                    shouldRetry = [.timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost].contains(urlError.code)
                } else {
                    shouldRetry = false
                }

                if shouldRetry && attempt < retryAttempts {
                    let delayNs = UInt64(Double(250_000_000) * pow(2, Double(attempt)))
                    try await Task.sleep(nanoseconds: delayNs)
                    attempt += 1
                    continue
                }
                throw error
            }
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
