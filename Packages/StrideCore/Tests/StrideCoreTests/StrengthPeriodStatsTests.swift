import Foundation
import Testing
@testable import StrideCore

/// Covers `StrengthPeriodStats`, the strength card on Progress.
struct StrengthPeriodStatsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func session(_ days: Double, _ sets: [(String, Int, Double?)], skipped: Int = 0) -> StrengthSessionLog {
        StrengthSessionLog(
            date: daysAgo(days),
            sets: sets.map { LoggedStrengthSet(exerciseName: $0.0, reps: $0.1, weightKilograms: $0.2, skipped: false) }
                + Array(repeating: LoggedStrengthSet(exerciseName: "Plank", reps: 0, weightKilograms: nil, skipped: true), count: skipped)
        )
    }

    @Test func countsSessionsAndWorkingSetsInThePeriod() {
        let stats = StrengthPeriodStats.make(from: [
            session(2, [("Row", 10, 20), ("Row", 10, 20)], skipped: 1),
            session(9, [("Push-Up", 12, nil)]),
            session(40, [("Row", 10, 18)]), // outside 4 weeks
        ], withinDays: 28, now: now)
        #expect(stats.sessions == 2)
        #expect(stats.workingSets == 3)
        #expect(stats.sessionsPerWeek == 0.5)
    }

    @Test func liftTrendRunsFromFirstToLatest() throws {
        let stats = StrengthPeriodStats.make(from: [
            session(20, [("Squat", 10, 40), ("Squat", 10, 40)]),
            session(10, [("Squat", 10, 42.5)]),
            session(3, [("Squat", 8, 45), ("Squat", 10, 40)]),
        ], withinDays: 28, now: now)
        let squat = try #require(stats.lifts.first)
        #expect(squat.exerciseName == "Squat")
        #expect(squat.sessions == 3)
        #expect(squat.latestWeightKilograms == 45)
        #expect(squat.latestReps == 8)
        let from = 40 * (1 + 10.0 / 30)
        let to = max(45 * (1 + 8.0 / 30), 40 * (1 + 10.0 / 30))
        let change = try #require(squat.change)
        #expect(abs(change - (to / from - 1)) < 0.0001)
    }

    @Test func oneSessionHasNoChangeAndUnloadedWorkIsNotALift() {
        let stats = StrengthPeriodStats.make(from: [
            session(3, [("Row", 10, 20), ("Push-Up", 15, nil)]),
        ], withinDays: 28, now: now)
        #expect(stats.lifts.map(\.exerciseName) == ["Row"])
        #expect(stats.lifts.first?.change == nil)
    }

    @Test func keepsTheMostDoneLifts() {
        let stats = StrengthPeriodStats.make(from: [
            session(1, [("A", 5, 50), ("B", 5, 50), ("C", 5, 50), ("D", 5, 50)]),
            session(5, [("A", 5, 50), ("B", 5, 50), ("C", 5, 50)]),
            session(9, [("A", 5, 50), ("D", 5, 50)]),
        ], withinDays: 28, now: now)
        #expect(stats.lifts.map(\.exerciseName) == ["A", "B", "C"])
    }

    @Test func emptyPeriod() {
        let stats = StrengthPeriodStats.make(from: [], withinDays: 90, now: now)
        #expect(stats.sessions == 0)
        #expect(stats.lifts.isEmpty)
    }
}
