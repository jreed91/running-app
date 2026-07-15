import Testing
import Foundation
@testable import Stride

// MARK: - Strength import dedup tests (M8)

@MainActor
struct StrengthMergeTests {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c)!
    }

    @Test("Sessions logged and synced within a few minutes are the same workout")
    func closeSessionsMerge() {
        let logged = date(2026, 6, 10, 7, 5)
        let synced = date(2026, 6, 10, 7, 0)
        #expect(WorkoutSyncService.isSameStrengthSession(logged, synced))
    }

    @Test("A morning and an evening session on the same day are distinct")
    func distinctSameDaySessionsDoNotMerge() {
        // The old same-day-only match collapsed these into one, discarding the
        // second workout entirely.
        let morning = date(2026, 6, 10, 7, 0)
        let evening = date(2026, 6, 10, 19, 0)
        #expect(!WorkoutSyncService.isSameStrengthSession(morning, evening))
    }

    @Test("Sessions right at the tolerance boundary still merge")
    func boundaryMerges() {
        let base = date(2026, 6, 10, 7, 0)
        let atBoundary = base.addingTimeInterval(WorkoutSyncService.strengthMergeToleranceSeconds)
        let pastBoundary = base.addingTimeInterval(WorkoutSyncService.strengthMergeToleranceSeconds + 60)
        #expect(WorkoutSyncService.isSameStrengthSession(base, atBoundary))
        #expect(!WorkoutSyncService.isSameStrengthSession(base, pastBoundary))
    }
}
