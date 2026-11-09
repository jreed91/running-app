import Foundation
import Testing
@testable import Stride

/// Covers `StrengthCoachContext`, strength as the coach chat sees it.
struct StrengthCoachContextTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func set(_ name: String, _ reps: Int, _ kg: Double?, skipped: Bool = false) -> LoggedStrengthSet {
        LoggedStrengthSet(exerciseName: name, reps: reps, weightKilograms: kg, skipped: skipped)
    }

    @Test func describesTheLastSessionAndTheWeek() {
        let text = StrengthCoachContext.summary(
            sessions: [
                StrengthSessionLog(date: daysAgo(10), sets: [set("Row", 10, 18)]),
                StrengthSessionLog(date: daysAgo(3), sets: [
                    set("Back Squat", 5, 80), set("Back Squat", 5, 80), set("Back Squat", 5, 80),
                    set("Push-Up", 12, nil), set("Plank", 0, nil, skipped: true),
                ]),
            ],
            plannedThisWeek: 2,
            doneThisWeek: 1,
            unit: .metric,
            now: now,
            calendar: calendar
        )
        #expect(text.contains("Last session: 3 days ago, 4 sets: Back Squat 3 × 5 at 80 kg; Push-Up 1 × 12."))
        #expect(text.contains("Sessions in the last 28 days: 2."))
        #expect(text.contains("This week: 1 of 2 planned strength sessions done."))
        #expect(!text.contains("Plank"))
    }

    @Test func saysSoWhenThereIsNothingRecent() {
        let text = StrengthCoachContext.summary(
            sessions: [StrengthSessionLog(date: daysAgo(40), sets: [set("Row", 10, 18)])],
            plannedThisWeek: 0,
            doneThisWeek: 0,
            unit: .metric,
            now: now,
            calendar: calendar
        )
        #expect(text == "Strength training:\nNo strength sessions in the last 28 days.")
    }

    @Test func namesAtMostFourLifts() {
        let names = ["A", "B", "C", "D", "E"]
        let text = StrengthCoachContext.summary(
            sessions: [StrengthSessionLog(date: daysAgo(1), sets: names.map { set($0, 10, 10) })],
            plannedThisWeek: 0, doneThisWeek: 0, unit: .metric, now: now, calendar: calendar
        )
        #expect(text.contains("yesterday"))
        #expect(text.contains("D 1 × 10"))
        #expect(!text.contains("E 1 × 10"))
    }
}
