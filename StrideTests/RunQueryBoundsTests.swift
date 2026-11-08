import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import Stride

// MARK: - Bounded run fetches (P3)
//
// The Plan tab used to query every run ever logged, and the HealthKit dedup paths fetched
// every stored workout in full to read two ids off each one. None of the run blobs (route,
// splits, distance series, samples) is external storage, so a full fetch reads all of them.
// These pin the narrower fetches that replaced them.

@MainActor
struct RunQueryBoundsTests {

    private func workout(
        daysAgo: Double,
        type: WorkoutType = .easy,
        now: Date
    ) -> RunWorkout {
        RunWorkout(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            distanceMeters: 8_000,
            durationSeconds: 2_400,
            workoutType: type
        )
    }

    @Test("runsOnlyDescriptor(since:) keeps runs inside the window and drops walks and older runs")
    func sinceWindowFiltersInTheFetch() throws {
        let context = TestStore.makeContext()
        let now = Date()
        let recent = workout(daysAgo: 3, now: now)
        let older = workout(daysAgo: 40, now: now)
        context.insert(recent)
        context.insert(older)
        context.insert(workout(daysAgo: 2, type: .walk, now: now))
        context.insert(workout(daysAgo: 1, type: .crossTraining, now: now))
        try context.save()

        let start = now.addingTimeInterval(-30 * 86_400)
        let fetched = try context.fetch(RunWorkout.runsOnlyDescriptor(since: start))
        #expect(fetched.map(\.id) == [recent.id])

        let wider = try context.fetch(RunWorkout.runsOnlyDescriptor(since: now.addingTimeInterval(-60 * 86_400)))
        // Newest first, like every other runs-only fetch.
        #expect(wider.map(\.id) == [recent.id, older.id])
    }

    @Test("The Plan tab's window starts at midnight, 12 weeks back, and holds through the day")
    func planHistoryStartIsStableThroughTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 7)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 22)))

        let start = PlanTabView.historyStart(now: morning, calendar: calendar)
        #expect(start == PlanTabView.historyStart(now: evening, calendar: calendar))
        #expect(start == calendar.startOfDay(for: start))
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: morning)).day
        #expect(days == 7 * PlanTabView.historyWeeks)
        // Wider than the widest read on the tab, the 8-week fitness estimate.
        #expect(PlanTabView.historyWeeks > RaceDayPlan.fitnessLookbackWeeks)
    }

    @Test("identityDescriptor returns every stored workout, walks included, with the rest still readable")
    func identityFetchCoversEverythingAndFaultsTheRestIn() throws {
        let context = TestStore.makeContext()
        let now = Date()
        let run = workout(daysAgo: 400, now: now)
        run.healthKitWorkoutID = "hk-run"
        run.routeCoordinates = [
            Coordinate(CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63)),
            Coordinate(CLLocationCoordinate2D(latitude: 41.89, longitude: -87.62)),
        ]
        let walk = workout(daysAgo: 1, type: .walk, now: now)
        walk.healthKitWorkoutID = "hk-walk"
        context.insert(run)
        context.insert(walk)
        try context.save()

        // A second context, so the objects come from the store rather than from the
        // first context's registered copies.
        let reader = ModelContext(context.container)
        let fetched = try reader.fetch(RunWorkout.identityDescriptor)
        #expect(Set(fetched.map(\.id)) == [run.id, walk.id])
        #expect(Set(fetched.compactMap(\.healthKitWorkoutID)) == ["hk-run", "hk-walk"])

        let readBack = try #require(fetched.first { $0.id == run.id })
        #expect(readBack.distanceMeters == 8_000)
        #expect(readBack.routeCoordinates.count == 2)
    }

    @Test("Own-export relinking still works on an identity-only fetch")
    func relinkOnIdentityFetch() throws {
        let context = TestStore.makeContext()
        let now = Date()
        let stored = workout(daysAgo: 0, now: now)
        context.insert(stored)
        try context.save()

        let reader = ModelContext(context.container)
        let identities = try reader.fetch(RunWorkout.identityDescriptor)

        let export = workout(daysAgo: 0, now: now)
        export.id = stored.id
        export.healthKitWorkoutID = "hk-export"

        let remaining = WorkoutSyncService.withoutOwnExports([export], stored: identities)
        #expect(remaining.isEmpty)
        #expect(identities.first?.healthKitWorkoutID == "hk-export")
    }
}
