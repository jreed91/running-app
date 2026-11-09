import Foundation

// MARK: - RouteGenerationState

/// Route Genius's results: nothing asked yet, generating, the options with the one picked,
/// or why it failed.
///
/// `RouteGeniusViewModel` held this as `isGenerating`, `routeOptions`,
/// `selectedRouteIndex` and `errorMessage`, reset together at the top of every request.
/// Options beside an error, or a selection with no options, were writable; here they are
/// not, and a selection outside the options is refused.
///
/// ```
///          begin()               succeed(routes)
///   idle ──────────▶ generating ─────────────────▶ options(routes, selected: first)
///    ▲                   │    ▲                            │   select(i) moves it
///    │                   │    └─────── begin() ────────────┤
///    │                   │  fail(message)                  │
///    │                   └──────────────▶ failed(message) ─┘ begin()
/// ```
///
/// Generic over the route so the transitions are tested without MapKit; the view model
/// uses `RouteGenerationState<GeneratedRoute>`.
enum RouteGenerationState<Route> {
    case idle
    case generating
    /// What came back, and the index shown on the map. An empty result is `options([],
    /// selected: nil)`, which shows nothing — as it always did.
    case options([Route], selected: Int?)
    case failed(String)

    // MARK: Reading

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var routes: [Route] {
        guard case .options(let routes, _) = self else { return [] }
        return routes
    }

    var selectedIndex: Int? {
        guard case .options(_, let selected) = self else { return nil }
        return selected
    }

    var selectedRoute: Route? {
        guard case .options(let routes, let selected?) = self, routes.indices.contains(selected) else {
            return nil
        }
        return routes[selected]
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }

    // MARK: Transitions

    /// A request went out; whatever was shown before is cleared.
    mutating func begin() {
        self = .generating
    }

    /// The routes came back. The first is picked so the map appears at once.
    mutating func succeed(_ routes: [Route]) {
        self = .options(routes, selected: routes.isEmpty ? nil : 0)
    }

    mutating func fail(_ message: String) {
        self = .failed(message)
    }

    /// The runner tapped another option. Ignored outside the options, or with no
    /// options showing.
    mutating func select(_ index: Int?) {
        guard case .options(let routes, _) = self else { return }
        guard let index else {
            self = .options(routes, selected: nil)
            return
        }
        guard routes.indices.contains(index) else { return }
        self = .options(routes, selected: index)
    }
}
