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

    // Secondary stats — `nil` when the run has no such data (indoor / no-HR runs).
    let heartRate: String?
    let elevation: String?

    /// Polyline points normalized into the unit square `[0,1]×[0,1]`, aspect-fit and centered,
    /// with y already flipped for screen space (north is up → smaller y). Empty when the run
    /// has no usable route (indoor runs, fewer than two distinct fixes, or a single point).
    let routePoints: [CGPoint]

    var hasRoute: Bool { routePoints.count >= 2 }

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

    static func make(from workout: RunWorkout, unit: UnitPreference) -> ShareCardModel {
        let heartRate = workout.averageHeartRate.map { "\(Int($0.rounded())) bpm" }
        let elevation = workout.elevationGainMeters.flatMap { gain in
            gain > 0 ? gain.elevationString(unit: unit) : nil
        }

        let (bars, fastest) = splitSummary(from: workout.splits, splitUnit: workout.splitUnit)

        return ShareCardModel(
            distance: workout.distanceMeters.distanceString(unit: unit),
            duration: workout.durationSeconds.durationString,
            pace: workout.averagePaceSecondsPerKm.paceString(unit: unit),
            heartRate: heartRate,
            elevation: elevation,
            routePoints: normalizedRoute(from: workout.routeCoordinates),
            splitBars: bars,
            fastestSplit: fastest,
            splitUnitLabel: workout.splitUnit.splitLabel
        )
    }

    /// Projects GPS coordinates onto a normalized, undistorted, screen-space polyline.
    ///
    /// Uses an equirectangular projection with x scaled by `cos(mean latitude)` so the drawn
    /// shape keeps its true proportions, aspect-fits the bounding box into the unit square, and
    /// flips y so higher latitudes (north) sit toward the top. Returns `[]` for runs with fewer
    /// than two coordinates or where every fix coincides (nothing to draw).
    static func normalizedRoute(from coordinates: [Coordinate]) -> [CGPoint] {
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

        return projected.map { point in
            let nx = (point.x - minX) * scale + offsetX
            let ny = (point.y - minY) * scale + offsetY
            return CGPoint(x: nx, y: 1 - ny)   // flip y: north up
        }
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
