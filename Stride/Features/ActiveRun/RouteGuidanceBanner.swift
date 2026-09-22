import SwiftUI

// MARK: - RouteGuidanceBanner

/// The run HUD's route row (A7): before the run, a picker for a saved route to follow;
/// during it, whether the runner is on that route.
///
/// The spoken warning does not live here — `RunRouteGuide` speaks it from the tracker's
/// fix hook, so it still fires with the screen off. This view adds what only an on-screen
/// view can: the warning haptic and the distance back to the route.
struct RouteGuidanceBanner: View {
    let guide: RunRouteGuide
    let trackingState: TrackingState
    let isOutdoor: Bool
    let unit: UnitPreference
    let loadSavedRoutes: () -> [SavedRoute]

    @State private var savedRoutes: [SavedRoute] = []

    private var isIdle: Bool { trackingState == .idle }

    var body: some View {
        // A stack rather than a `Group`: with nothing to show, a `Group` has no child to
        // carry `onAppear`, and the saved routes would never load. An empty stack has
        // zero height, so the HUD looks as it did for a runner with no saved routes.
        VStack(spacing: 0) {
            if let route = guide.route, isOutdoor {
                followingPill(route)
                    .padding(.top, 14)
            } else if isIdle, isOutdoor, !savedRoutes.isEmpty {
                routePicker
                    .padding(.top, 14)
            }
        }
        .foregroundStyle(.white)
        .onAppear { savedRoutes = loadSavedRoutes() }
        // Indoor runs record no GPS, so there is nothing to follow.
        .onChange(of: isOutdoor) { _, outdoor in
            if !outdoor, isIdle { guide.stop() }
        }
        // Leaving the route is the one moment that must be felt without looking. The
        // spoken line says the same; this is for a runner with no audio route.
        .sensoryFeedback(.warning, trigger: guide.isOffRoute) { wasOff, isOff in
            isOff && !wasOff
        }
        .adaptiveAnimation(AppAnimation.gentle, value: guide.isOffRoute)
    }

    // MARK: Picker

    private var routePicker: some View {
        Menu {
            ForEach(savedRoutes) { route in
                Button(route.name) {
                    guide.follow(name: route.name, coordinates: route.coordinates, unit: unit)
                }
            }
        } label: {
            pill(tint: nil) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.dsFootnote.weight(.semibold))
                Text("Follow a saved route")
                    .font(.dsFootnote.bold())
            }
        }
        .accessibilityHint("Warns you, out loud, if you leave the route during the run")
        .accessibilityIdentifier("activeRun.routePicker")
    }

    // MARK: Following

    private func followingPill(_ route: RunRouteGuide.FollowedRoute) -> some View {
        HStack(spacing: 8) {
            pill(tint: guide.isOffRoute ? Color.destructive : nil) {
                Image(systemName: statusSymbol)
                    .font(.dsFootnote.weight(.semibold))
                Text(statusText(routeName: route.name))
                    .font(.dsFootnote.bold())
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("activeRun.routeStatus")

            // The choice can be undone until the run starts; after that the route is
            // part of the run.
            if isIdle {
                Button {
                    guide.stop()
                } label: {
                    pill(tint: nil) {
                        Image(systemName: "xmark")
                            .font(.dsCaption.bold())
                    }
                }
                .accessibilityLabel("Stop following \(route.name)")
            }
        }
    }

    private var statusSymbol: String {
        switch guide.status {
        case .offRoute:    return "exclamationmark.triangle.fill"
        case .onRoute:     return "checkmark.circle.fill"
        case .approaching, nil: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    private func statusText(routeName: String) -> String {
        switch guide.status {
        case .offRoute(let meters):
            return "Off route · \(RunRouteGuide.spokenDistance(meters, unit: unit)) away"
        case .onRoute:
            return "On \(routeName)"
        case .approaching(let meters) where meters.isFinite:
            return "Head to the route · \(RunRouteGuide.spokenDistance(meters, unit: unit))"
        case .approaching, nil:
            return "Following \(routeName)"
        }
    }

    private func pill<Content: View>(tint: Color?, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.7)) } ?? Glass.regular, in: .capsule)
    }
}
