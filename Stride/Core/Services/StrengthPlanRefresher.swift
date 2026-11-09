import Foundation

// MARK: - StrengthPlanRefresher

/// Rewrites the exercises on the strength sessions still ahead in a plan, after the runner
/// changed their equipment or focus in Settings.
///
/// Only sessions from today on that are not done: a finished session is history, and its
/// logged sets point into the plan it was run from. Each session gets what the plan
/// generator would have given it for its week's phase, and on a pregnancy plan the same
/// trimester adaptation the pregnancy generator applies, so a Settings change can never
/// put a supine exercise back into the third trimester.
///
/// ``refresh(_:equipment:focus:minutes:now:calendar:)`` changes exercises, never days.
/// ``reschedule(_:profile:preferences:now:calendar:)`` changes days, and only when the
/// runner changed how many sessions a week they want.
@MainActor
enum StrengthPlanRefresher {

    /// Rewrites the sessions and returns how many changed.
    @discardableResult
    static func refresh(
        _ plan: TrainingPlan,
        equipment: [StrengthEquipment],
        focus: StrengthFocus,
        minutes: Int? = nil,
        excluding excluded: Set<String> = [],
        except inProgressID: UUID? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        // A pregnancy plan keeps bodyweight sessions when nothing is chosen, as its
        // generator does; elsewhere Settings never saves an empty choice.
        let effective = equipment.isEmpty ? [StrengthEquipment.bodyweight] : equipment
        var changed = 0

        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] {
                // The session on screen keeps its plan: its logged sets point into it.
                guard workout.workoutType == .strength,
                      workout.id != inProgressID,
                      !workout.isCompleted,
                      calendar.startOfDay(for: workout.scheduledDate) >= today
                else { continue }

                var next = StrengthLibrary.plan(for: effective, focus: focus, phase: week.phase, minutes: minutes, excluding: excluded)
                if plan.isPregnancyPlan, let dueDate = plan.dueDate {
                    let gestationalWeek = GestationalAge.on(week.startDate, dueDate: dueDate, calendar: calendar).weeks
                    next = PregnancyStrengthAdapter.adapt(next, atGestationalWeek: gestationalWeek)
                }
                guard !next.exercises.isEmpty, next != workout.strengthPlan else { continue }

                workout.strengthPlan = next
                if plan.planKind == .standard {
                    // The note the standard generator writes, so the day reads the new focus.
                    workout.notes = "\(focus.displayName) strength — \(next.estimatedDurationMinutes) min"
                }
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Sessions a week

    /// Re-places the strength days still ahead in a standard plan after the runner chose a
    /// different number of sessions a week, and returns the sessions it took out so the
    /// caller can delete them from the store.
    ///
    /// Days already past and sessions already done stay, and count towards the week's
    /// number. The rest are taken out and put back the way the generator places them:
    /// free days, not next to a quality session or long run, never from the day before
    /// the race. Pregnancy and Start Running plans set their own number of sessions and
    /// are left alone.
    ///
    /// Only call this when the number changed: it puts sessions on the generator's days,
    /// so a session moved by hand with "Move to…" goes back.
    static func reschedule(
        _ plan: TrainingPlan,
        profile: UserProfile,
        preferences: StrengthPreferences,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ScheduledWorkout] {
        guard plan.planKind == .standard, !profile.selectedEquipment.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let focus = profile.strengthFocus
        var removed: [ScheduledWorkout] = []

        for week in plan.weeks ?? [] {
            let weekStart = calendar.startOfDay(for: week.startDate)
            guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart), weekEnd > today else { continue }

            func offset(_ date: Date) -> Int {
                calendar.dateComponents([.day], from: weekStart, to: calendar.startOfDay(for: date)).day ?? 0
            }

            let workouts = week.workouts ?? []
            let movable = workouts.filter { workout in
                workout.workoutType == .strength
                    && !workout.isCompleted
                    && calendar.startOfDay(for: workout.scheduledDate) >= today
            }
            let movableIDs = Set(movable.map(\.id))
            let kept = workouts.filter { !movableIDs.contains($0.id) }

            let wanted = preferences.strengthDays(
                phase: week.phase,
                focus: focus,
                isBeginner: profile.fitnessLevel == .beginner
            )
            let alreadyHad = kept.filter { $0.workoutType == .strength }.count
            let pastDays = (0...6).filter { day in
                guard let date = calendar.date(byAdding: .day, value: day, to: weekStart) else { return true }
                return date < today
            }
            var occupied = Set(profile.preferredRunDayIndices).union(pastDays)
            var hardDays = Set<Int>()
            var raceDay: Int?
            for workout in kept {
                let day = offset(workout.scheduledDate)
                occupied.insert(day)
                if workout.workoutType == .longRun || workout.workoutType.isQualitySession {
                    hardDays.insert(day)
                }
                if workout.workoutType == .race { raceDay = day }
            }

            let days = StrengthPreferences.strengthDayOffsets(
                count: max(0, wanted - alreadyHad),
                occupied: occupied,
                hardDays: hardDays,
                raceDay: raceDay
            )
            let session = StrengthLibrary.plan(
                for: profile.selectedEquipment, focus: focus, phase: week.phase,
                minutes: preferences.sessionMinutes,
                excluding: preferences.excluded
            )
            var added: [ScheduledWorkout] = []
            for day in days {
                guard let date = calendar.date(byAdding: .day, value: day, to: weekStart) else { continue }
                let workout = ScheduledWorkout(
                    scheduledDate: date,
                    workoutType: .strength,
                    notes: "\(focus.displayName) strength — \(session.estimatedDurationMinutes) min"
                )
                workout.strengthPlan = session
                week.modelContext?.insert(workout)
                added.append(workout)
            }

            guard !movable.isEmpty || !added.isEmpty else { continue }
            week.workouts = kept + added
            removed += movable
        }
        return removed
    }
}
