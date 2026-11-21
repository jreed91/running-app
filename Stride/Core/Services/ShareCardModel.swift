import CoreGraphics
import Foundation

/// Pure mapping from a `RunWorkout` (+ the viewer's unit preference) to the display data a
/// shareable run card renders: headline strings, a normalized route polyline, secondary
/// HR/elevation stats, and a splits summary. Deliberately free of SwiftUI so the non-trivial
/// layout logic (route projection, fastest-split selection) is unit-testable (B5, per AGENTS.md
/// "keep business logic out of views").
struct ShareCardModel: Equatable {

    // Headline
    let distance: String
    let duration: String
    let pace: String

    /// What the run was, e.g. "Tempo run".
    let sessionName: String

    /// Where the run sat in a plan, e.g. "Week 6 of 16 · Half Marathon". The line a
    /// Strava post can't show, and the reason a friend asks what app it is. `nil` for a
    /// run that isn't linked to a plan day, and for pregnancy plans, which a runner may
    /// not want announced on a public post.
    let planContext: String?

    // Secondary stats — `nil` when the run has no such data (indoor / no-HR runs).
    let heartRate: String?
    let elevation: String?

    /// Polyline points normalized into the unit square `[0,1]×[0,1]`, aspect-fit and centered,
    /// with y already flipped for screen space (north is up → smaller y). Empty when the run
    /// has no usable route (indoor runs, fewer than two distinct fixes, or a single point).
    ///
    /// All the visible pieces joined, in order; ``routeSegments`` keeps them apart for
    /// drawing.
    var routePoints: [CGPoint] { routeSegments.flatMap { $0 } }

    /// The route's visible pieces after ``RoutePrivacy``, normalized together into the unit
    /// square so they keep their places relative to each other. One piece when nothing
    /// mid-route was hidden.
    let routeSegments: [[CGPoint]]

    var hasRoute: Bool { routePoints.count >= 2 }

    /// An outdoor run whose whole route ``RoutePrivacy`` hides — a short loop from home.
    /// The card says the route is private rather than calling it an indoor run.
    let isRouteHidden: Bool

    /// One bar per split, tallest for the fastest split (see `SplitBar`).
    let splitBars: [SplitBar]

    /// Callout for the quickest split, e.g. "Fastest mi 4 · 7:32 min/mi". `nil` with no splits.
    let fastestSplit: String?

    /// Uppercased unit each split bucket represents ("KM" / "MI"), from the run's stored
    /// `splitUnit` so a mile-bucketed run stays labelled "MI" (consistent with A1 / H11).
    let splitUnitLabel: String

    /// A single split rendered as a bar. `height` is in `(0, 1]` with the fastest split at `1`.
    struct SplitBar: Equatable, Identifiable {
        /// The split's bucket number (1-based km or mile), also its stable identity.
        let id: Int
        /// Normalized bar height, faster splits taller.
        let height: Double
        /// Whether this is (one of) the fastest split(s) — highlighted in the card.
        let isFastest: Bool
    }
}

extension ShareCardModel {

    /// Bars shorter than this fraction of the tallest would be visually lost, so the slowest
    /// split is floored here rather than at zero.
    private static let minBarHeight = 0.4

    /// `privacy` decides what of the route the card may draw; ``RoutePrivacy/off`` draws
    /// all of it.
    static func make(
        from workout: RunWorkout,
        unit: UnitPreference,
        privacy: RoutePrivacy = .off
    ) -> ShareCardModel {
        let heartRate = workout.averageHeartRate.map { "\(Int($0.rounded())) bpm" }
        let elevation = workout.elevationGainMeters.flatMap { gain in
            gain > 0 ? gain.elevationString(unit: unit) : nil
        }

        let (bars, fastest) = splitSummary(from: workout.splits, splitUnit: workout.splitUnit)
        let routeSegments = normalizedRoute(
            segments: privacy.visibleSegments(of: workout.routeCoordinates)
        )

        return ShareCardModel(
            sessionName: sessionName(for: workout.workoutType),
            planContext: planContext(
                weekNumber: workout.scheduledWorkout?.week?.weekNumber,
                totalWeeks: workout.scheduledWorkout?.week?.plan?.totalWeeks,
                planTitle: workout.scheduledWorkout?.week?.plan?.displayTitle,
                isPregnancyPlan: workout.scheduledWorkout?.week?.plan?.isPregnancyPlan ?? false
            ),
            distance: workout.distanceMeters.distanceString(unit: unit),
            duration: workout.durationSeconds.durationString,
            pace: workout.averagePaceSecondsPerKm.paceString(unit: unit),
            heartRate: heartRate,
            elevation: elevation,
            routeSegments: routeSegments,
            isRouteHidden: routeSegments.isEmpty
                && !normalizedRoute(from: workout.routeCoordinates).isEmpty,
            splitBars: bars,
            fastestSplit: fastest,
            splitUnitLabel: workout.splitUnit.splitLabel
        )
    }

    /// "Tempo run", "Long run", "Race". The type's own name, with "run" added where the
    /// name alone isn't one.
    static func sessionName(for type: WorkoutType) -> String {
        switch type {
        case .easy:          return String(localized: "Easy run", comment: "Share card session name")
        case .tempo:         return String(localized: "Tempo run", comment: "Share card session name")
        case .interval:      return String(localized: "Intervals", comment: "Share card session name")
        case .longRun:       return String(localized: "Long run", comment: "Share card session name")
        case .race:          return String(localized: "Race", comment: "Share card session name")
        case .walk:          return String(localized: "Walk", comment: "Share card session name")
        case .crossTraining, .strength, .rest:
            return String(localized: "Run", comment: "Share card session name")
        }
    }

    /// "Week 6 of 16 · Half Marathon", or `nil` when the run has no plan week, the plan has
    /// no weeks, or it is a pregnancy plan.
    static func planContext(
        weekNumber: Int?,
        totalWeeks: Int?,
        planTitle: String?,
        isPregnancyPlan: Bool
    ) -> String? {
        guard !isPregnancyPlan,
              let weekNumber, weekNumber > 0,
              let totalWeeks, totalWeeks >= weekNumber
        else { return nil }
        let week = String(localized: "Week \(weekNumber) of \(totalWeeks)", comment: "Share card plan week")
        guard let title = planTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return week
        }
        return "\(week) · \(title)"
    }

    /// Projects GPS coordinates onto a normalized, undistorted, screen-space polyline.
    ///
    /// Uses an equirectangular projection with x scaled by `cos(mean latitude)` so the drawn
    /// shape keeps its true proportions, aspect-fits the bounding box into the unit square, and
    /// flips y so higher latitudes (north) sit toward the top. Returns `[]` for runs with fewer
    /// than two coordinates or where every fix coincides (nothing to draw).
    static func normalizedRoute(from coordinates: [Coordinate]) -> [CGPoint] {
        normalizedRoute(segments: [coordinates]).first ?? []
    }

    /// The same projection over several pieces at once: the bounding box is the pieces'
    /// together, so each keeps its place relative to the others. Pieces under two points
    /// are dropped; `[]` when nothing is left to draw.
    static func normalizedRoute(segments: [[Coordinate]]) -> [[CGPoint]] {
        let pieces = segments.filter { $0.count >= 2 }
        let coordinates = pieces.flatMap { $0 }
        guard coordinates.count >= 2 else { return [] }

        let meanLatRadians = coordinates.map(\.latitude).reduce(0, +)
            / Double(coordinates.count) * .pi / 180
        let cosLat = cos(meanLatRadians)

        let projected = coordinates.map { CGPoint(x: $0.longitude * cosLat, y: $0.latitude) }
        let xs = projected.map(\.x)
        let ys = projected.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return [] }

        let spanX = maxX - minX
        let spanY = maxY - minY
        let span = max(spanX, spanY)
        guard span > 0 else { return [] }   // all fixes coincide

        let scale = 1.0 / span
        let offsetX = (1 - spanX * scale) / 2
        let offsetY = (1 - spanY * scale) / 2

        func place(_ coordinate: Coordinate) -> CGPoint {
            let x = coordinate.longitude * cosLat
            let y = coordinate.latitude
            let nx = (x - minX) * scale + offsetX
            let ny = (y - minY) * scale + offsetY
            return CGPoint(x: nx, y: 1 - ny)   // flip y: north up
        }
        return pieces.map { $0.map(place) }
    }

    /// Builds the split bars (fastest tallest) and the fastest-split callout. Splits with a
    /// non-positive or non-finite pace are ignored so a bad sample can't crown itself fastest.
    static func splitSummary(
        from splits: [Split],
        splitUnit: UnitPreference
    ) -> (bars: [SplitBar], fastest: String?) {
        let valid = splits.filter { $0.paceSecondsPerKm > 0 && $0.paceSecondsPerKm.isFinite }
        let paces = valid.map(\.paceSecondsPerKm)
        // Empty when there are no valid splits — nothing to summarize.
        guard let fastestPace = paces.min(), let slowestPace = paces.max() else {
            return ([], nil)
        }
        let range = slowestPace - fastestPace   // fastest = smallest seconds-per-unit

        let bars: [SplitBar] = valid.map { split in
            // Faster (smaller pace) → taller bar; equal paces all render full height.
            let height = range > 0
                ? 1 - (split.paceSecondsPerKm - fastestPace) / range * (1 - minBarHeight)
                : 1
            return SplitBar(
                id: split.kilometer,
                height: height,
                isFastest: split.paceSecondsPerKm == fastestPace
            )
        }

        let callout = valid.first { $0.paceSecondsPerKm == fastestPace }.map { split in
            "Fastest \(splitUnit.distanceLabel) \(split.kilometer) · "
                + split.paceSecondsPerKm.paceString(unit: splitUnit)
        }

        return (bars, callout)
    }
}
