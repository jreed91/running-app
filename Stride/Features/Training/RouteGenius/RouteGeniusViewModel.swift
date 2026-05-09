import Foundation
import CoreLocation
import MapKit

// MARK: - StartMode

enum StartMode: String, CaseIterable, Sendable {
    case currentLocation = "Current Location"
    case address = "Address"

    var systemImage: String {
        switch self {
        case .currentLocation: return "location.fill"
        case .address:         return "magnifyingglass"
        }
    }

    var strideIcon: StrideIconName {
        switch self {
        case .currentLocation: return .location
        case .address:         return .search
        }
    }
}

// MARK: - RouteGeniusViewModel

@Observable
@MainActor
final class RouteGeniusViewModel {

    // MARK: User inputs

    var distanceInput: String = ""
    var routeType: RouteType = .loop
    var startMode: StartMode = .currentLocation
    var addressQuery: String = ""

    // MARK: Address search

    var addressResults: [MKMapItem] = []
    var selectedMapItem: MKMapItem?

    // MARK: State

    var isGenerating: Bool = false
    var routeOptions: [GeneratedRoute] = []
    var selectedRouteIndex: Int? = nil
    var errorMessage: String?

    var selectedRoute: GeneratedRoute? {
        guard let i = selectedRouteIndex, routeOptions.indices.contains(i) else { return nil }
        return routeOptions[i]
    }

    // MARK: Current location

    var currentCoordinate: CLLocationCoordinate2D?
    // nonisolated(unsafe) lets deinit cancel the task without a MainActor hop.
    // Task.cancel() is thread-safe so this is sound.
    nonisolated(unsafe) private var locationTask: Task<Void, Never>?

    // MARK: Saved routes

    var savedRoutes: [SavedRoute] = []

    // MARK: Dependencies

    private let service: RouteGeniusService
    private let repository: RouteRepositoryProtocol
    /// Kept as a reference so the view can observe `unitPreference` and `orsAPIKey` reactively.
    let appSettings: AppSettings

    var unitPreference: UnitPreference { appSettings.unitPreference }

    // MARK: Init

    init(
        service: RouteGeniusService,
        repository: RouteRepositoryProtocol,
        appSettings: AppSettings
    ) {
        self.service = service
        self.repository = repository
        self.appSettings = appSettings
        loadSavedRoutes()
        startLocationUpdates()
    }

    deinit {
        locationTask?.cancel()
    }

    // MARK: Location

    private func startLocationUpdates() {
        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if let loc = update.location {
                        self.currentCoordinate = loc.coordinate
                    }
                    if Task.isCancelled { break }
                }
            } catch {
                // Permission denied or unavailable – UI falls back to address entry.
            }
        }
    }

    // MARK: Address search

    func searchAddress() async {
        guard !addressQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            addressResults = []
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = addressQuery
        let search = MKLocalSearch(request: request)
        if let response = try? await search.start() {
            addressResults = Array(response.mapItems.prefix(5))
        } else {
            addressResults = []
        }
    }

    func selectAddress(_ item: MKMapItem) {
        selectedMapItem = item
        addressQuery = item.name ?? item.placemark.title ?? ""
        addressResults = []
    }

    // MARK: Route generation

    var startCoordinate: CLLocationCoordinate2D? {
        switch startMode {
        case .currentLocation: return currentCoordinate
        case .address:         return selectedMapItem?.placemark.coordinate
        }
    }

    /// Distance in metres parsed from `distanceInput` (which is in the user's unit).
    var requestedDistanceMeters: Double? {
        guard let value = Double(distanceInput), value > 0 else { return nil }
        switch unitPreference {
        case .metric:   return value * 1_000
        case .imperial: return value * 1_609.344
        }
    }

    var canGenerate: Bool {
        startCoordinate != nil && requestedDistanceMeters != nil && !isGenerating
    }

    var canSave: Bool { selectedRoute != nil }

    func generateRouteOptions() async {
        guard let coord = startCoordinate, let distance = requestedDistanceMeters else { return }
        isGenerating = true
        routeOptions = []
        selectedRouteIndex = nil
        errorMessage = nil

        do {
            routeOptions = try await service.generateRouteOptions(
                start: coord,
                distanceMeters: distance,
                routeType: routeType,
                apiKey: appSettings.orsAPIKey
            )
            // Auto-select the first option so the map appears immediately.
            if !routeOptions.isEmpty { selectedRouteIndex = 0 }
        } catch {
            errorMessage = error.localizedDescription
        }

        isGenerating = false
    }

    // MARK: Saving

    func saveRoute(name: String) {
        guard let route = selectedRoute, let coord = startCoordinate else { return }

        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultRouteName
            : name

        let saved = SavedRoute(
            name: finalName,
            routeType: routeType,
            requestedDistanceMeters: requestedDistanceMeters ?? route.distanceMeters,
            actualDistanceMeters: route.distanceMeters,
            estimatedDurationSeconds: route.durationSeconds,
            startLatitude: coord.latitude,
            startLongitude: coord.longitude,
            coordinates: route.coordinates,
            steps: route.steps
        )

        try? repository.save(saved)
        loadSavedRoutes()
    }

    func deleteRoute(_ route: SavedRoute) {
        try? repository.delete(route)
        loadSavedRoutes()
    }

    func loadSavedRoutes() {
        savedRoutes = (try? repository.fetchAll()) ?? []
    }

    // MARK: Formatting helpers

    var unitLabel: String {
        unitPreference.distanceLabel
    }

    private var defaultRouteName: String {
        let distLabel: String
        if let meters = requestedDistanceMeters {
            switch unitPreference {
            case .metric:
                distLabel = String(format: "%.1f km", meters / 1_000)
            case .imperial:
                distLabel = String(format: "%.1f mi", meters / 1_609.344)
            }
        } else {
            distLabel = "Route"
        }
        return "\(routeType.displayName) · \(distLabel)"
    }

    func formattedDistance(_ meters: Double) -> String {
        switch unitPreference {
        case .metric:
            return String(format: "%.2f km", meters / 1_000)
        case .imperial:
            return String(format: "%.2f mi", meters / 1_609.344)
        }
    }

    func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3_600
        let m = (total % 3_600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
