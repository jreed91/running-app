import Testing
import Foundation
import CoreGraphics
import CoreLocation
@testable import Stride

// MARK: - ShareCardModel tests (B5 — run share cards)
//
// Covers the pure card-model mapping: headline/secondary formatting, route projection
// (aspect-fit, north-up, degenerate fallbacks), and split-summary bar/fastest selection.

struct ShareCardModelTests {

    // MARK: Headline & secondary formatting

    @Test("Headline and secondary stats format in metric")
    func metricFormatting() {
        let run = RunWorkout(distanceMeters: 10_000, durationSeconds: 3_000, workoutType: .easy)
        run.averageHeartRate = 152.4
        run.elevationGainMeters = 42

        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.distance == "10.0 km")
        #expect(model.duration == "50:00")
        #expect(model.pace == "5:00 min/km")
        #expect(model.heartRate == "152 bpm")
        #expect(model.elevation == "42 m")
    }

    @Test("Headline and secondary stats convert for imperial")
    func imperialFormatting() {
        let run = RunWorkout(distanceMeters: 1_609.344, durationSeconds: 480, workoutType: .easy)
        run.elevationGainMeters = 30.48   // 100 ft

        let model = ShareCardModel.make(from: run, unit: .imperial)
        #expect(model.distance == "1.0 mi")
        // ~8:00/mi; assert the unit rather than the exact second (the km→mi constants aren't
        // exact inverses, so 8:00/mi rounds to 7:59 — not worth a brittle exact assertion).
        #expect(model.pace.hasSuffix("min/mi"))
        #expect(model.pace.hasPrefix("7:") || model.pace.hasPrefix("8:"))
        #expect(model.elevation == "100 ft")
    }

    @Test("Absent HR and elevation produce nil secondary stats")
    func missingSecondaryStats() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        // No averageHeartRate; elevation nil.
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.heartRate == nil)
        #expect(model.elevation == nil)
    }

    @Test("Zero elevation gain is treated as absent")
    func zeroElevationHidden() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        run.elevationGainMeters = 0
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.elevation == nil)
    }

    // MARK: Route projection

    @Test("Route points normalize into the unit square")
    func routeWithinUnitSquare() {
        let coords = [
            Coordinate(.init(latitude: 51.500, longitude: -0.120)),
            Coordinate(.init(latitude: 51.505, longitude: -0.110)),
            Coordinate(.init(latitude: 51.503, longitude: -0.100))
        ]
        let points = ShareCardModel.normalizedRoute(from: coords)
        #expect(points.count == 3)
        for point in points {
            #expect(point.x >= -0.0001 && point.x <= 1.0001)
            #expect(point.y >= -0.0001 && point.y <= 1.0001)
        }
    }

    @Test("North maps to a smaller y (screen up)")
    func northIsUp() {
        // Two points differing only in latitude; the more-northern one should have smaller y.
        let south = Coordinate(.init(latitude: 40.000, longitude: -105.0))
        let north = Coordinate(.init(latitude: 40.010, longitude: -105.0))
        let points = ShareCardModel.normalizedRoute(from: [south, north])
        #expect(points.count == 2)
        #expect(points[1].y < points[0].y)   // north (index 1) is higher on screen
    }

    @Test("Aspect ratio is preserved (a wide route stays wide)")
    func aspectPreserved() {
        // ~10x wider in longitude than tall in latitude → x-span should dominate, y-span small.
        let coords = [
            Coordinate(.init(latitude: 40.000, longitude: -105.000)),
            Coordinate(.init(latitude: 40.001, longitude: -104.900))
        ]
        let points = ShareCardModel.normalizedRoute(from: coords)
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let xSpan = xs.max()! - xs.min()!
        let ySpan = ys.max()! - ys.min()!
        #expect(xSpan > ySpan)          // wide route stays wide
        #expect(abs(xSpan - 1) < 0.01)  // the dominant axis fills the unit square
    }

    @Test("Fewer than two coordinates yields no route")
    func tooFewCoordinates() {
        #expect(ShareCardModel.normalizedRoute(from: []).isEmpty)
        #expect(ShareCardModel.normalizedRoute(
            from: [Coordinate(.init(latitude: 1, longitude: 1))]
        ).isEmpty)
    }

    @Test("Coincident coordinates yield no route (nothing to draw)")
    func coincidentCoordinates() {
        let same = Coordinate(.init(latitude: 45.0, longitude: 9.0))
        #expect(ShareCardModel.normalizedRoute(from: [same, same, same]).isEmpty)
    }

    @Test("Indoor run (no route) reports hasRoute == false")
    func indoorHasNoRoute() {
        let run = RunWorkout(
            distanceMeters: 5_000, durationSeconds: 1_500,
            workoutType: .easy, workoutLocation: .indoor
        )
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.hasRoute == false)
        #expect(model.routePoints.isEmpty)
    }

    // MARK: Split summary

    @Test("Fastest split is tallest and called out in the run's unit")
    func fastestSplitSelection() {
        let run = RunWorkout(distanceMeters: 3_000, durationSeconds: 900)
        run.splitUnit = .metric
        run.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 320, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 1_000),
            Split(kilometer: 2, paceSecondsPerKm: 300, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 2_000),
            Split(kilometer: 3, paceSecondsPerKm: 310, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 3_000)
        ]

        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.splitBars.count == 3)

        // Split 2 (300 s/km) is fastest → full height and flagged.
        let fastestBar = model.splitBars.first { $0.id == 2 }
        #expect(fastestBar?.isFastest == true)
        #expect(fastestBar?.height == 1)

        // Slowest split (320) is floored, not zero.
        let slowestBar = model.splitBars.first { $0.id == 1 }
        #expect(slowestBar?.isFastest == false)
        #expect((slowestBar?.height ?? 0) >= 0.39)

        #expect(model.fastestSplit == "Fastest km 2 · 5:00 min/km")
        #expect(model.splitUnitLabel == "KM")
    }

    @Test("Mile-bucketed splits keep their MI label and unit in the callout")
    func imperialSplitLabel() {
        let run = RunWorkout(distanceMeters: 3_218, durationSeconds: 960)
        run.splitUnit = .imperial
        run.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 300, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 1_609),
            Split(kilometer: 2, paceSecondsPerKm: 280, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 3_218)
        ]

        // Card viewed in imperial; splits recorded in imperial.
        let model = ShareCardModel.make(from: run, unit: .imperial)
        #expect(model.splitUnitLabel == "MI")
        // 280 s/km → per-mile pace; label uses the run's split unit ("mi").
        #expect(model.fastestSplit?.hasPrefix("Fastest mi 2 · ") == true)
        #expect(model.fastestSplit?.hasSuffix("min/mi") == true)
    }

    @Test("Non-positive split paces are ignored and never crowned fastest")
    func invalidSplitPacesIgnored() {
        let run = RunWorkout(distanceMeters: 2_000, durationSeconds: 600)
        run.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 0, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 1_000),
            Split(kilometer: 2, paceSecondsPerKm: 300, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 2_000)
        ]
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.splitBars.count == 1)          // the 0-pace split is dropped
        #expect(model.splitBars.first?.id == 2)
        #expect(model.fastestSplit == "Fastest km 2 · 5:00 min/km")
    }

    @Test("Equal-pace splits all render full height")
    func equalPaceSplits() {
        let run = RunWorkout(distanceMeters: 2_000, durationSeconds: 600)
        run.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 300, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 1_000),
            Split(kilometer: 2, paceSecondsPerKm: 300, heartRate: nil, elevationGainMeters: 0, cumulativeDistanceMeters: 2_000)
        ]
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.splitBars.allSatisfy { $0.height == 1 })
        #expect(model.splitBars.allSatisfy { $0.isFastest })
    }

    @Test("No splits yields an empty strip and no callout")
    func noSplits() {
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_500)
        let model = ShareCardModel.make(from: run, unit: .metric)
        #expect(model.splitBars.isEmpty)
        #expect(model.fastestSplit == nil)
    }
}
