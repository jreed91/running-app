import CoreLocation
import Foundation
import Testing
@testable import Stride

/// Covers the selection rule behind the late-route backfill: which already-imported runs
/// are worth asking HealthKit for a route, and how many per sync pass.
@MainActor
struct RouteBackfillTests {

    private func makeRun(
        daysAgo: Double,
        hkID: String?,
        location: WorkoutLocation = .outdoor,
        route: [Coordinate] = []
    ) -> RunWorkout {
        let run = RunWorkout(
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: 5_000,
            durationSeconds: 1_500,
            workoutLocation: location
        )
        run.healthKitWorkoutID = hkID
        if !route.isEmpty { run.routeCoordinates = route }
        return run
    }

    private let somewhere = [
        Coordinate(CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63)),
        Coordinate(CLLocationCoordinate2D(latitude: 41.89, longitude: -87.62))
    ]

    @Test("An outdoor HealthKit run with no route needs one")
    func outdoorImportWithoutRoute() {
        #expect(RouteBackfill.needsRoute(makeRun(daysAgo: 0, hkID: "hk-1")))
    }

    @Test("Indoor runs, app-recorded runs and runs with a route are left alone")
    func skipsRunsThatCannotGainARoute() {
        #expect(!RouteBackfill.needsRoute(makeRun(daysAgo: 0, hkID: "hk-1", location: .indoor)))
        #expect(!RouteBackfill.needsRoute(makeRun(daysAgo: 0, hkID: nil)))
        #expect(!RouteBackfill.needsRoute(makeRun(daysAgo: 0, hkID: "hk-1", route: somewhere)))
    }

    @Test("Candidates are newest first and capped")
    func newestFirstAndBounded() {
        let runs = (0..<10).map { makeRun(daysAgo: Double($0) / 10, hkID: "hk-\($0)") }

        let candidates = RouteBackfill.runsNeedingRoute(in: runs.shuffled(), limit: 3)

        #expect(candidates.map(\.healthKitWorkoutID) == ["hk-0", "hk-1", "hk-2"])
    }

    /// A run imported by the same pass, or one already asked about too many times, is
    /// skipped: its route was just read, or it genuinely has none.
    @Test("Runs already attempted are skipped")
    func attemptedRunsAreNotRetried() {
        let runs = [makeRun(daysAgo: 0, hkID: "hk-1"), makeRun(daysAgo: 0.5, hkID: "hk-2")]

        let candidates = RouteBackfill.runsNeedingRoute(in: runs, alreadyAttempted: ["hk-1"])

        #expect(candidates.map(\.healthKitWorkoutID) == ["hk-2"])
    }
}
