import Foundation

// MARK: - WorkoutReorderPlanner

/// Turns a drag-and-drop reorder inside a training week into the date rewrite a plan
/// actually stores.
///
/// This is the piece that made `reorderable()` a deferred item rather than a modifier
/// (U7). A plan has no notion of "the third workout": `ScheduledWorkout` is anchored to
/// a `scheduledDate`, and a week's shape — three runs, a gym session, three rest days —
/// is nothing but a set of days with a session on each. So "put Thursday's tempo on
/// Tuesday" cannot be an array move. It is a permutation of *which* session holds
/// *which* day, and the set of days has to come out of it untouched: a week that gains
/// or loses a date is a week whose volume changed without anyone asking.
///
/// The rules below are the plan's rather than the gesture's, which is why they live in a
/// service and not in the view's `move` closure:
///
/// - **A day that has already happened is not a target.** Sessions that are completed,
///   or scheduled before today, keep their dates and are left out of the pool the
///   movable ones are dealt from. Dragging Friday's session up cannot retroactively
///   move a run the runner already did.
/// - **Race day does not move** when the plan carries a fixed race date — the same
///   session `PlanLifecycleService.shiftMissedWorkoutsForward` holds still, for the same
///   reason: that date is the runner's commitment, not the plan's suggestion.
/// - **Rest days move like anything else.** They are the useful half of the feature.
///   "I'll rest Tuesday and run Thursday instead" *is* a swap of a rest day and a run,
///   and pinning rest would make most real reorders impossible to express.
enum WorkoutReorderPlanner {

    // MARK: Slot

    /// One session as the planner sees it: an identity, the day it holds, and whether
    /// that day is still its to give up.
    struct Slot: Equatable, Sendable {
        let id: UUID
        let date: Date
        let isMovable: Bool

        init(id: UUID, date: Date, isMovable: Bool) {
            self.id = id
            self.date = date
            self.isMovable = isMovable
        }
    }

    // MARK: Planning

    /// The new dates a reorder implies, keyed by session ID.
    ///
    /// - Parameters:
    ///   - slots: Every session in the week, pinned ones included. Order is irrelevant;
    ///     the planner sorts by date itself, because a SwiftData relationship has no
    ///     defined order and the offsets below are meaningless against a different one.
    ///   - movingIDs: The sessions the runner lifted, in the order they picked them up.
    ///   - offset: Where they dropped, as an insertion offset into **every** session in
    ///     date order — pinned ones included. That is deliberately the whole week rather
    ///     than the movable subset, because a reorder container counts the rows it
    ///     rendered, and the week renders a completed Monday alongside a free Thursday.
    /// - Returns: Only the sessions whose date changes. An empty result means the drag
    ///   was a no-op and the caller has nothing to save.
    static func plan(
        slots: [Slot],
        moving movingIDs: [UUID],
        toOffset offset: Int
    ) -> [UUID: Date] {
        // Two orderings matter and they are not the same: `ordered` is what the runner
        // sees and what `offset` indexes, `movable` is what may actually change hands.
        let ordered = slots.sorted(by: isOrderedBefore)
        let movable = ordered.filter(\.isMovable)
        guard movable.count > 1 else { return [:] }

        // A session the gesture names but the plan pins is dropped rather than honoured,
        // so a stale drag cannot move a run that has since been completed.
        let movableIDs = Set(movable.map(\.id))
        let moving = movingIDs.filter(movableIDs.contains)
        // Moving every row is the identity permutation — the same sessions land on the
        // same days — so it is a no-op rather than a rotation.
        guard !moving.isEmpty, moving.count < movable.count else { return [:] }

        let movingIDSet = Set(moving)
        let stationary = movable.filter { !movingIDSet.contains($0.id) }

        // The drop offset counts every rendered row — pinned ones, and the ones currently
        // in the air — so it has to be re-expressed as an insertion index into the rows
        // that both stay put and can hold a different day.
        let clampedOffset = min(max(offset, 0), ordered.count)
        let insertionIndex = ordered.prefix(clampedOffset)
            .filter { $0.isMovable && !movingIDSet.contains($0.id) }
            .count

        let movingSlots = moving.compactMap { id in movable.first { $0.id == id } }
        var reordered = stationary
        reordered.insert(contentsOf: movingSlots, at: insertionIndex)

        // The days themselves are never invented or dropped: the same ascending list of
        // dates is dealt back out to whichever session now sits in that position.
        let days = movable.map(\.date)
        var changes: [UUID: Date] = [:]
        for (slot, day) in zip(reordered, days) where slot.date != day {
            changes[slot.id] = day
        }
        return changes
    }

    // MARK: Classification

    /// Classifies a week's sessions into the ones a runner may drag and the ones the
    /// plan pins in place.
    ///
    /// Kept here rather than in the view so "what is movable" is one rule with tests
    /// behind it, and so the view's `move` closure stays a handful of lines.
    static func slots(
        for workouts: [ScheduledWorkout],
        hasFixedRaceDate: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Slot] {
        let startOfToday = calendar.startOfDay(for: now)
        return workouts.map { workout in
            Slot(
                id: workout.id,
                date: workout.scheduledDate,
                isMovable: isMovable(
                    workout,
                    startOfToday: startOfToday,
                    hasFixedRaceDate: hasFixedRaceDate,
                    calendar: calendar
                )
            )
        }
    }

    /// Whether the week holds enough free sessions for a reorder to mean anything.
    /// The container's drag gesture is disabled below two, where every drop is a no-op.
    static func isReorderable(
        _ workouts: [ScheduledWorkout],
        hasFixedRaceDate: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        slots(
            for: workouts,
            hasFixedRaceDate: hasFixedRaceDate,
            now: now,
            calendar: calendar
        )
        .filter(\.isMovable)
        .count > 1
    }

    private static func isMovable(
        _ workout: ScheduledWorkout,
        startOfToday: Date,
        hasFixedRaceDate: Bool,
        calendar: Calendar
    ) -> Bool {
        if workout.isCompleted { return false }
        // Compared by day rather than by instant: a session scheduled at 00:00 today is
        // still today's and still movable, which `scheduledDate >= startOfToday` alone
        // gets right only by accident of the time component.
        if calendar.startOfDay(for: workout.scheduledDate) < startOfToday { return false }
        if hasFixedRaceDate && workout.workoutType == .race { return false }
        return true
    }

    /// Date order, with a stable tie-break so two sessions on the same day cannot swap
    /// places between passes. Mirrors `ScheduledDayResolver`'s reasoning: relationship
    /// order is undefined, so anything indexed has to be fully determined first.
    private static func isOrderedBefore(_ lhs: Slot, _ rhs: Slot) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
