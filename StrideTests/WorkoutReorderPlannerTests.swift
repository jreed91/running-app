import Testing
import Foundation
@testable import Stride

// MARK: - Dragging a session onto another day (U7)
//
// A reorder gesture speaks in array offsets and a training plan speaks in dates, and the
// translation between them is the whole reason `reorderable()` sat deferred. The
// invariant these tests exist to hold is that the week's *set of days* survives every
// drag: a reorder may permute which session holds which day and nothing else. A week
// that comes out of a drag with a new date, or one fewer, is a week whose volume moved
// without the runner asking.

struct WorkoutReorderPlannerTests {

    // A plain Monday-start week. Only the days matter here, so every session is one day
    // apart and the times are all midnight.
    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base) ?? base
    }

    /// Monday of a week comfortably in the future, so nothing is pinned by the past.
    private var monday: Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func slots(_ count: Int, movable: Bool = true) -> [WorkoutReorderPlanner.Slot] {
        (0..<count).map { index in
            WorkoutReorderPlanner.Slot(id: UUID(), date: day(index, from: monday), isMovable: movable)
        }
    }

    // MARK: The permutation

    @Test("Dragging a session up gives it the earlier day and pushes the rest down")
    func moveUp() {
        let week = slots(4)
        // Thursday's session (index 3) is dropped at the top.
        let changes = WorkoutReorderPlanner.plan(
            slots: week,
            moving: [week[3].id],
            toOffset: 0
        )

        // It takes Monday; Monday, Tuesday and Wednesday's sessions each slide one later.
        #expect(changes[week[3].id] == week[0].date)
        #expect(changes[week[0].id] == week[1].date)
        #expect(changes[week[1].id] == week[2].date)
        #expect(changes[week[2].id] == week[3].date)
        #expect(changes.count == 4)
    }

    @Test("Dragging a session down gives it the later day and pulls the rest up")
    func moveDown() {
        let week = slots(4)
        // Monday's session is dropped past the end.
        let changes = WorkoutReorderPlanner.plan(
            slots: week,
            moving: [week[0].id],
            toOffset: 4
        )

        #expect(changes[week[0].id] == week[3].date)
        #expect(changes[week[1].id] == week[0].date)
        #expect(changes[week[2].id] == week[1].date)
        #expect(changes[week[3].id] == week[2].date)
    }

    @Test("The week's set of days is identical afterwards")
    func daysArePreserved() {
        let week = slots(5)
        let changes = WorkoutReorderPlanner.plan(
            slots: week,
            moving: [week[1].id],
            toOffset: 4
        )

        // Every session's day after the move: the changed ones plus the untouched ones.
        let after = Set(week.map { changes[$0.id] ?? $0.date })
        #expect(after == Set(week.map(\.date)))
        #expect(after.count == week.count)
    }

    @Test("Dropping a session back where it started changes nothing")
    func noOpDrop() {
        let week = slots(4)
        #expect(
            WorkoutReorderPlanner.plan(slots: week, moving: [week[2].id], toOffset: 2).isEmpty
        )
        // Offset 3 is the same resting place: the row is lifted out of index 2, so
        // inserting before index 3 puts it straight back.
        #expect(
            WorkoutReorderPlanner.plan(slots: week, moving: [week[2].id], toOffset: 3).isEmpty
        )
    }

    @Test("A swap of neighbours exchanges exactly two days")
    func swapNeighbours() {
        let week = slots(3)
        let changes = WorkoutReorderPlanner.plan(
            slots: week,
            moving: [week[1].id],
            toOffset: 0
        )

        #expect(changes[week[1].id] == week[0].date)
        #expect(changes[week[0].id] == week[1].date)
        #expect(changes[week[2].id] == nil)
        #expect(changes.count == 2)
    }

    // MARK: Pinned sessions

    @Test("Pinned sessions keep their days and are not dealt out to anyone else")
    func pinnedSessionsAreExcluded() {
        // Monday and Tuesday have already happened; Wednesday, Thursday, Friday are free.
        let pinned = (0..<2).map { index in
            WorkoutReorderPlanner.Slot(id: UUID(), date: day(index, from: monday), isMovable: false)
        }
        let free = (2..<5).map { index in
            WorkoutReorderPlanner.Slot(id: UUID(), date: day(index, from: monday), isMovable: true)
        }

        let changes = WorkoutReorderPlanner.plan(
            slots: pinned + free,
            moving: [free[2].id],
            toOffset: 0
        )

        // Friday's session takes Wednesday — the first *free* day, not the first day.
        #expect(changes[free[2].id] == free[0].date)
        #expect(changes[free[0].id] == free[1].date)
        #expect(changes[free[1].id] == free[2].date)
        // Neither past day was handed to anybody.
        #expect(!changes.values.contains(pinned[0].date))
        #expect(!changes.values.contains(pinned[1].date))
        #expect(changes[pinned[0].id] == nil)
        #expect(changes[pinned[1].id] == nil)
    }

    @Test("Drop offsets count the pinned rows the week still renders")
    func offsetsCountPinnedRows() {
        // Monday and Tuesday are done. Wednesday, Thursday and Friday are free, so the
        // week renders five rows and a drop offset of 3 means "after Wednesday".
        let pinned = (0..<2).map { index in
            WorkoutReorderPlanner.Slot(id: UUID(), date: day(index, from: monday), isMovable: false)
        }
        let free = (2..<5).map { index in
            WorkoutReorderPlanner.Slot(id: UUID(), date: day(index, from: monday), isMovable: true)
        }

        let changes = WorkoutReorderPlanner.plan(
            slots: pinned + free,
            moving: [free[2].id],
            toOffset: 3
        )

        // Friday's session slots in behind Wednesday's and takes Thursday.
        #expect(changes[free[0].id] == nil)
        #expect(changes[free[2].id] == free[1].date)
        #expect(changes[free[1].id] == free[2].date)
        #expect(changes.count == 2)
    }

    @Test("A drag naming a pinned session is ignored rather than honoured")
    func draggingAPinnedSessionDoesNothing() {
        let free = slots(3)
        let pinnedID = UUID()
        let pinned = WorkoutReorderPlanner.Slot(id: pinnedID, date: day(-1, from: monday), isMovable: false)

        #expect(
            WorkoutReorderPlanner.plan(slots: [pinned] + free, moving: [pinnedID], toOffset: 3).isEmpty
        )
    }

    @Test("A week with one free session or none cannot be reordered")
    func tooFewMovableSessions() {
        let single = slots(1)
        #expect(WorkoutReorderPlanner.plan(slots: single, moving: [single[0].id], toOffset: 0).isEmpty)
        #expect(WorkoutReorderPlanner.plan(slots: [], moving: [UUID()], toOffset: 0).isEmpty)

        let allPinned = slots(4, movable: false)
        #expect(WorkoutReorderPlanner.plan(slots: allPinned, moving: [allPinned[0].id], toOffset: 0).isEmpty)
    }

    // MARK: Robustness at the edges

    @Test("An offset past either end is clamped rather than trapping")
    func offsetsAreClamped() {
        let week = slots(4)

        let past = WorkoutReorderPlanner.plan(slots: week, moving: [week[0].id], toOffset: 99)
        #expect(past[week[0].id] == week[3].date)

        let before = WorkoutReorderPlanner.plan(slots: week, moving: [week[3].id], toOffset: -5)
        #expect(before[week[3].id] == week[0].date)
    }

    @Test("An unknown session ID is ignored")
    func unknownIDIsIgnored() {
        let week = slots(3)
        #expect(WorkoutReorderPlanner.plan(slots: week, moving: [UUID()], toOffset: 0).isEmpty)
    }

    @Test("Lifting every session at once is a no-op, not a rotation")
    func movingEverything() {
        let week = slots(3)
        #expect(
            WorkoutReorderPlanner.plan(slots: week, moving: week.map(\.id), toOffset: 0).isEmpty
        )
    }

    @Test("Two sessions on the same day keep a determined order")
    func sameDayTieBreak() {
        // A run and a gym session both on Tuesday, plus a free Wednesday.
        let sameDay = day(1, from: monday)
        let first = WorkoutReorderPlanner.Slot(id: UUID(), date: sameDay, isMovable: true)
        let second = WorkoutReorderPlanner.Slot(id: UUID(), date: sameDay, isMovable: true)
        let wednesday = WorkoutReorderPlanner.Slot(id: UUID(), date: day(2, from: monday), isMovable: true)

        // Whatever order they arrive in, the plan is the same.
        let forward = WorkoutReorderPlanner.plan(
            slots: [first, second, wednesday],
            moving: [wednesday.id],
            toOffset: 0
        )
        let reversed = WorkoutReorderPlanner.plan(
            slots: [wednesday, second, first],
            moving: [wednesday.id],
            toOffset: 0
        )
        #expect(forward == reversed)
    }

    @Test("Multiple lifted sessions land together, in the order they were picked up")
    func multipleSessionsMoveAsABlock() {
        let week = slots(5)
        // Thursday and Friday's sessions are dropped at the top, Friday's picked first.
        let changes = WorkoutReorderPlanner.plan(
            slots: week,
            moving: [week[4].id, week[3].id],
            toOffset: 0
        )

        #expect(changes[week[4].id] == week[0].date)
        #expect(changes[week[3].id] == week[1].date)
        #expect(changes[week[0].id] == week[2].date)
        #expect(changes[week[1].id] == week[3].date)
        #expect(changes[week[2].id] == week[4].date)
    }

    // MARK: What the plan pins

    @Test("Completed and past sessions are pinned; today's is not")
    func classification() {
        let now = calendar.startOfDay(for: monday)

        let yesterday = ScheduledWorkout(scheduledDate: day(-1, from: now), workoutType: .easy)
        let today = ScheduledWorkout(scheduledDate: now, workoutType: .tempo)
        let tomorrow = ScheduledWorkout(scheduledDate: day(1, from: now), workoutType: .easy)
        let done = ScheduledWorkout(scheduledDate: day(2, from: now), workoutType: .longRun)
        done.isCompleted = true

        let classified = WorkoutReorderPlanner.slots(
            for: [yesterday, today, tomorrow, done],
            hasFixedRaceDate: false,
            now: now,
            calendar: calendar
        )

        #expect(classified[0].isMovable == false)   // already happened
        #expect(classified[1].isMovable == true)    // today is still fair game
        #expect(classified[2].isMovable == true)
        #expect(classified[3].isMovable == false)   // run and logged
    }

    @Test("Race day is pinned only when the plan has a race date to honour")
    func raceDayPinning() {
        let now = calendar.startOfDay(for: monday)
        let race = ScheduledWorkout(scheduledDate: day(3, from: now), workoutType: .race)

        let withDate = WorkoutReorderPlanner.slots(
            for: [race], hasFixedRaceDate: true, now: now, calendar: calendar
        )
        #expect(withDate[0].isMovable == false)

        // A plan with no committed race date is only estimating, so the placeholder
        // race session moves like any other long effort.
        let withoutDate = WorkoutReorderPlanner.slots(
            for: [race], hasFixedRaceDate: false, now: now, calendar: calendar
        )
        #expect(withoutDate[0].isMovable == true)
    }

    @Test("Rest days move like anything else")
    func restDaysAreMovable() {
        let now = calendar.startOfDay(for: monday)
        let rest = ScheduledWorkout(scheduledDate: day(1, from: now), workoutType: .rest)

        let classified = WorkoutReorderPlanner.slots(
            for: [rest], hasFixedRaceDate: true, now: now, calendar: calendar
        )
        #expect(classified[0].isMovable == true)
    }

    @Test("A week is reorderable only when two or more sessions are free")
    func reorderability() {
        let now = calendar.startOfDay(for: monday)
        let past = ScheduledWorkout(scheduledDate: day(-2, from: now), workoutType: .easy)
        let future = ScheduledWorkout(scheduledDate: day(1, from: now), workoutType: .tempo)
        let alsoFuture = ScheduledWorkout(scheduledDate: day(2, from: now), workoutType: .rest)

        #expect(
            WorkoutReorderPlanner.isReorderable(
                [past, future], hasFixedRaceDate: false, now: now, calendar: calendar
            ) == false
        )
        #expect(
            WorkoutReorderPlanner.isReorderable(
                [past, future, alsoFuture], hasFixedRaceDate: false, now: now, calendar: calendar
            ) == true
        )
        #expect(
            WorkoutReorderPlanner.isReorderable(
                [], hasFixedRaceDate: false, now: now, calendar: calendar
            ) == false
        )
    }
}
