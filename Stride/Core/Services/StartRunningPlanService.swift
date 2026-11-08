import Foundation

// MARK: - StartRunningPlanService

/// Builds a Start Running plan: run/walk sessions for someone new to running, or coming
/// back to it, that end with thirty minutes of running without a break.
///
/// A sibling of `TrainingPlanService` and `PregnancyPlanService`, not a mode of either. A
/// race plan prescribes distance at a VDOT pace; this one prescribes minutes of running and
/// walking at a pace the runner could talk at, because someone who cannot yet run for five
/// minutes has no meaningful pace to train at. It shares only the SwiftData models, so the
/// Plan tab, the widgets, the Watch, history and HealthKit sync all handle it as they would
/// any plan.
///
/// What it builds, week by week, is `StartRunningProgram`'s table; this type only decides
/// which days and dates the sessions land on. Every session leaves its pace bounds nil and
/// the plan is `.startRunning`, which keeps the VDOT machinery off it (see
/// ``PlanKind/prescribesByTime``).
struct StartRunningPlanService {

    /// Walking pace, used only to turn prescribed minutes into the distance estimate the
    /// rest of the app renders. Nothing is prescribed in distance. The same figure
    /// `PregnancyPlanService` uses.
    static let walkPaceSecondsPerKm: Double = 12 * 60

    /// A gentle jog for someone starting out, 8:00 per km, used when the runner has no 5K
    /// time on file. Like the walking pace, it only feeds the distance estimate.
    static let fallbackJogPaceSecondsPerKm: Double = 8 * 60

    // MARK: - Public API

    /// Builds a plan that starts at `firstStage` and runs one stage a week to the end of
    /// the program.
    ///
    /// Weeks run Monday to Sunday, so the runner's chosen weekdays land on the right days.
    /// A session that would fall before `startDate` in the first week is left out, and a
    /// plan started after the week's last run day begins the following Monday instead of
    /// with an empty week.
    func generatePlan(
        profile: UserProfile,
        startDate: Date,
        firstStage: Int = 1
    ) -> TrainingPlan {
        let first = min(max(firstStage, 1), StartRunningProgram.stageCount)
        let numberOfWeeks = StartRunningProgram.stageCount - first + 1
        let runOffsets = Self.runOffsets(
            preferred: profile.preferredRunDayIndices,
            weeklyRunDays: profile.weeklyRunDays
        )

        let startDay = startDate.startOfDay
        var firstMonday = startDay.startOfWeek
        let lastRunDay = firstMonday.adding(days: runOffsets.last ?? 6)
        if lastRunDay < startDay {
            firstMonday = firstMonday.adding(weeks: 1)
        }

        let plan = TrainingPlan(
            targetRace: .maintainFitness,
            goalTimeSeconds: 0,
            startDate: firstMonday,
            endDate: firstMonday.adding(weeks: numberOfWeeks)
        )
        plan.planKind = .startRunning

        let schedule = WeekSchedule(profile: profile, runOffsets: runOffsets)
        for index in 0..<numberOfWeeks {
            let week = makeWeek(
                number: index + 1,
                stage: StartRunningProgram.stage(first + index),
                weekStart: firstMonday.adding(weeks: index),
                notBefore: startDay,
                schedule: schedule,
                isFinalWeek: index == numberOfWeeks - 1
            )
            plan.weeks = (plan.weeks ?? []) + [week]
        }
        return plan
    }

    // MARK: - Repeating a week

    /// Whether the week the runner is in can be run again next week.
    ///
    /// Not the program's last week: that one ends the plan, and a 5K plan picks up from it.
    /// Not outside the plan's dates, where there is no "this week". And not when a later
    /// week already holds a completed session, which moving the weeks back would put on a
    /// day it was not run.
    static func canRepeatWeek(in plan: TrainingPlan, now: Date = Date()) -> Bool {
        guard plan.isStartRunningPlan,
              let current = Self.currentWeek(in: plan, now: now),
              let stage = Self.stage(of: current), !stage.isGraduation else { return false }
        let later = (plan.weeks ?? []).filter { $0.weekNumber > current.weekNumber }
        guard !later.isEmpty else { return false }
        return !later.contains { week in (week.workouts ?? []).contains(where: \.isCompleted) }
    }

    /// Runs the current week's stage again next week, for a runner who isn't ready for
    /// the step up.
    ///
    /// Inserts a fresh copy of this week's sessions as next week, on the runner's current
    /// run days, moves every later week and its sessions back seven days, and moves the
    /// plan's end back with them. This week is left as it is, finished sessions and all.
    /// The progression is otherwise untouched: the stage after the repeat is the one that
    /// would have come next.
    ///
    /// - Returns: The inserted week, attached to `plan`; nil, changing nothing, when
    ///   ``canRepeatWeek(in:now:)`` is false. The caller saves and re-syncs.
    @discardableResult
    func repeatWeek(in plan: TrainingPlan, profile: UserProfile, now: Date = Date()) -> TrainingWeek? {
        guard Self.canRepeatWeek(in: plan, now: now),
              let current = Self.currentWeek(in: plan, now: now),
              let stage = Self.stage(of: current) else { return nil }

        for week in (plan.weeks ?? []) where week.weekNumber > current.weekNumber {
            week.weekNumber += 1
            week.startDate = week.startDate.adding(days: 7)
            week.endDate = week.endDate.adding(days: 7)
            for workout in week.workouts ?? [] {
                workout.scheduledDate = workout.scheduledDate.adding(days: 7)
            }
        }

        let runOffsets = Self.runOffsets(
            preferred: profile.preferredRunDayIndices,
            weeklyRunDays: profile.weeklyRunDays
        )
        let repeated = makeWeek(
            number: current.weekNumber + 1,
            stage: stage,
            weekStart: current.startDate.startOfDay.adding(days: 7),
            notBefore: .distantPast,
            schedule: WeekSchedule(profile: profile, runOffsets: runOffsets),
            isFinalWeek: false
        )
        plan.weeks = (plan.weeks ?? []) + [repeated]
        plan.endDate = plan.endDate.adding(days: 7)
        return repeated
    }

    // MARK: - Building a week

    /// What every week of one plan shares: the run days, the jog pace behind the distance
    /// estimate, and the optional strength session.
    private struct WeekSchedule {
        let runOffsets: [Int]
        let jogPaceSecondsPerKm: Double
        let strengthPlan: StrengthWorkoutPlan?
        let strengthOffset: Int?

        init(profile: UserProfile, runOffsets: [Int]) {
            self.runOffsets = runOffsets
            self.jogPaceSecondsPerKm = StartRunningPlanService.jogPaceSecondsPerKm(for: profile)
            self.strengthPlan = profile.selectedEquipment.isEmpty
                ? nil
                : StrengthLibrary.plan(for: profile.selectedEquipment, focus: profile.strengthFocus, phase: .base)
            self.strengthOffset = StartRunningPlanService.strengthOffset(runOffsets: runOffsets)
        }
    }

    /// One week of the plan: the stage's session on each run day, and the strength session
    /// when there is one. Days before `notBefore` are left out.
    private func makeWeek(
        number: Int,
        stage: StartRunningProgram.Stage,
        weekStart: Date,
        notBefore startDay: Date,
        schedule: WeekSchedule,
        isFinalWeek: Bool
    ) -> TrainingWeek {
        var workouts: [ScheduledWorkout] = []

        for offset in schedule.runOffsets {
            let date = weekStart.adding(days: offset)
            guard date >= startDay else { continue }
            workouts.append(runWorkout(
                date: date,
                stage: stage,
                jogPaceSecondsPerKm: schedule.jogPaceSecondsPerKm,
                isFinalRun: isFinalWeek && offset == schedule.runOffsets.last
            ))
        }

        if let strengthPlan = schedule.strengthPlan, !strengthPlan.exercises.isEmpty,
           let strengthOffset = schedule.strengthOffset {
            let date = weekStart.adding(days: strengthOffset)
            if date >= startDay {
                workouts.append(strengthWorkout(date: date, plan: strengthPlan))
            }
        }

        let estimatedKm = workouts.reduce(0.0) { $0 + ($1.targetDistanceMeters ?? 0) } / 1_000
        let week = TrainingWeek(
            weekNumber: number,
            startDate: weekStart,
            phase: .base,
            targetDistanceKm: estimatedKm
        )
        week.workouts = workouts.sorted { $0.scheduledDate < $1.scheduledDate }
        return week
    }

    // MARK: - Reading a plan back

    /// The stage a week prescribes, read from its first run session.
    static func stage(of week: TrainingWeek) -> StartRunningProgram.Stage? {
        (week.workouts ?? [])
            .filter { $0.workoutType.isRunType }
            .sorted { $0.scheduledDate < $1.scheduledDate }
            .lazy
            .compactMap { StartRunningProgram.stage(matching: $0.workoutStructure) }
            .first
    }

    /// The stage to pick a plan back up from after a break: the latest stage the runner
    /// completed at least one session of, run again rather than skipped past, or the
    /// plan's first stage when nothing has been run yet.
    static func resumeStage(for plan: TrainingPlan) -> Int {
        let weeks = (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
        let ranLast = weeks.last { week in
            (week.workouts ?? []).contains { $0.isCompleted && $0.workoutType.isRunType }
        }
        if let ranLast, let ranStage = Self.stage(of: ranLast) { return ranStage.number }
        return weeks.lazy.compactMap { Self.stage(of: $0) }.first?.number ?? 1
    }

    /// What the Plan tab says about the week the runner is in. Derived from the plan every
    /// time, never stored.
    struct WeekGuidance: Hashable, Sendable {
        var stage: StartRunningProgram.Stage
        /// What changes next week, or what comes after the program on its last week.
        var next: String
        /// True once the program is done: the last run of its last week is completed, or
        /// that week is over with at least one of its runs done. The Plan tab then offers
        /// the 5K plan that picks up from here.
        var isFinished: Bool = false
    }

    /// The week the runner is in, or nil before the plan starts and after it ends.
    static func currentWeek(in plan: TrainingPlan, now: Date = Date()) -> TrainingWeek? {
        let today = now.startOfDay
        return (plan.weeks ?? []).first {
            $0.startDate.startOfDay <= today && $0.endDate.startOfDay >= today
        }
    }

    static func guidance(for plan: TrainingPlan, now: Date = Date()) -> WeekGuidance? {
        guard plan.isStartRunningPlan else { return nil }
        let weeks = (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
        let today = now.startOfDay
        // The week the runner is in; before the plan starts, its first week; after it
        // ends, its last.
        let shown: TrainingWeek?
        if let current = Self.currentWeek(in: plan, now: now) {
            shown = current
        } else if let firstWeek = weeks.first, today < firstWeek.startDate.startOfDay {
            shown = firstWeek
        } else {
            shown = weeks.last
        }
        guard let week = shown, let stage = Self.stage(of: week) else { return nil }

        // Next week as the plan now has it, which after a repeat is this stage again.
        let following = weeks.first { $0.weekNumber == week.weekNumber + 1 }.flatMap { Self.stage(of: $0) }

        let next: String
        if stage.isGraduation, following == nil {
            next = String(
                localized: "After this week, a 5K plan picks up where this one ends.",
                comment: "Start Running guidance on the last week of the program"
            )
        } else if let following, following.number == stage.number {
            next = String(
                localized: "Next week: the same again, then the next step.",
                comment: "Start Running guidance when next week repeats this week's sessions"
            )
        } else {
            let nextStage = following ?? StartRunningProgram.stage(stage.number + 1)
            next = String(
                localized: "Next week: \(nextStage.summary).",
                comment: "Start Running guidance: what next week's sessions are"
            )
        }

        guard stage.isGraduation, following == nil, let lastWeek = weeks.last, week === lastWeek else {
            return WeekGuidance(stage: stage, next: next)
        }
        let lastWeekRuns = (lastWeek.workouts ?? []).filter { $0.workoutType.isRunType }
        let ranLastRun = lastWeekRuns.max { $0.scheduledDate < $1.scheduledDate }?.isCompleted == true
        let isOver = today > lastWeek.endDate.startOfDay
        // Over without a single run in its last week isn't finishing it: no congratulations
        // for 30 minutes the runner hasn't run.
        guard ranLastRun || (isOver && lastWeekRuns.contains(where: \.isCompleted)) else {
            guard isOver else { return WeekGuidance(stage: stage, next: next) }
            return WeekGuidance(
                stage: stage,
                next: String(
                    localized: "When you can run 30 minutes without stopping, start a 5K plan from New Plan.",
                    comment: "Start Running guidance after the plan ended without its last week run"
                )
            )
        }
        return WeekGuidance(
            stage: stage,
            next: String(
                localized: """
                You've finished Start Running. A 5K plan picks up from here: three or four runs \
                a week, building to 5K.
                """,
                comment: "Start Running guidance once the last run of the program is done"
            ),
            isFinished: true
        )
    }

    // MARK: - Days

    /// The weekday offsets (0 = Monday … 6 = Sunday) the runner runs on.
    ///
    /// Up to `StartRunningProgram.runsPerWeek` of the days they chose, picked so the
    /// shortest gap between two runs, counted round the week, is as long as it can be.
    /// With no days chosen, the runner's weekly count is spread evenly from Monday.
    static func runOffsets(preferred: [Int], weeklyRunDays: Int) -> [Int] {
        let days = Array(Set(preferred.filter { (0...6).contains($0) })).sorted()
        let wanted = StartRunningProgram.runsPerWeek
        guard !days.isEmpty else {
            let count = max(1, min(wanted, weeklyRunDays))
            let step = 7.0 / Double(count)
            return (0..<count).map { Int(Double($0) * step) }
        }
        guard days.count > wanted else { return days }

        var best = Array(days.prefix(wanted))
        var bestGap = -1
        for combination in combinations(of: days, choosing: wanted) {
            let gap = shortestGap(combination)
            if gap > bestGap {
                best = combination
                bestGap = gap
            }
        }
        return best
    }

    /// The day for the week's one strength session: a day off running, and preferably not
    /// the day before a run, so sore legs have a day to settle.
    static func strengthOffset(runOffsets: [Int]) -> Int? {
        let runs = Set(runOffsets)
        let free = (0...6).filter { !runs.contains($0) }
        let restful = free.filter { !runs.contains(($0 + 1) % 7) }
        let candidates = restful.isEmpty ? free : restful
        guard !candidates.isEmpty else { return nil }
        return candidates[candidates.count / 2]
    }

    private static func combinations(of items: [Int], choosing count: Int) -> [[Int]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        var result: [[Int]] = []
        for (index, item) in items.enumerated() {
            let rest = Array(items[(index + 1)...])
            for tail in combinations(of: rest, choosing: count - 1) {
                result.append([item] + tail)
            }
        }
        return result
    }

    /// The shortest gap, in days, between consecutive sorted offsets, wrapping from the
    /// last day of one week to the first of the next.
    private static func shortestGap(_ sorted: [Int]) -> Int {
        guard let first = sorted.first, let last = sorted.last, sorted.count > 1 else { return 7 }
        var gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        gaps.append(first + 7 - last)
        return gaps.min() ?? 7
    }

    // MARK: - Workout factory

    static func jogPaceSecondsPerKm(for profile: UserProfile) -> Double {
        guard let vdot = profile.baselineVDOT else { return fallbackJogPaceSecondsPerKm }
        let easy = PaceCalculatorService.trainingPaces(forVDOT: vdot).easyRange
        return (easy.lowerBound + easy.upperBound) / 2
    }

    /// One run/walk session.
    ///
    /// The pace bounds stay nil: the session is prescribed by the clock and by effort.
    /// Distance is filled in only as an estimate from the minutes, because the rest of the
    /// app renders distances.
    private func runWorkout(
        date: Date,
        stage: StartRunningProgram.Stage,
        jogPaceSecondsPerKm: Double,
        isFinalRun: Bool
    ) -> ScheduledWorkout {
        let warmup = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(StartRunningProgram.warmupSeconds),
            targetPaceSecondsPerKm: nil,
            label: String(localized: "Brisk walk", comment: "Start Running warm-up segment")
        )
        let cooldown = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(StartRunningProgram.cooldownSeconds),
            targetPaceSecondsPerKm: nil,
            label: String(localized: "Walk to finish", comment: "Start Running cool-down segment")
        )
        let run = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(stage.runSeconds),
            targetPaceSecondsPerKm: nil,
            label: String(localized: "Run", comment: "Run portion of a Start Running session")
        )
        // A continuous run has no walk: an empty segment, which the guided run and
        // WorkoutKit both read as "no recovery step".
        let walk = stage.walkSeconds > 0
            ? WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: Double(stage.walkSeconds),
                targetPaceSecondsPerKm: nil,
                label: String(localized: "Walk", comment: "Walk portion of a Start Running session")
            )
            : WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: "")

        let runningSeconds = Double(stage.runningSeconds)
        let walkingSeconds = Double(
            StartRunningProgram.warmupSeconds + StartRunningProgram.cooldownSeconds + stage.walkBreakSeconds
        )
        let estimatedMeters = runningSeconds / jogPaceSecondsPerKm * 1_000
            + walkingSeconds / Self.walkPaceSecondsPerKm * 1_000

        let workout = ScheduledWorkout(
            scheduledDate: date.startOfDay,
            workoutType: .easy,
            targetDistanceMeters: estimatedMeters,
            targetPaceLowerBound: nil,
            targetPaceUpperBound: nil,
            notes: Self.note(for: stage, isFinalRun: isFinalRun)
        )
        workout.workoutStructure = WorkoutStructure(
            warmup: warmup,
            mainSets: [WorkoutSet(
                repetitions: stage.repetitions,
                workSegment: run,
                recoverySegment: walk,
                label: stage.summary
            )],
            cooldown: cooldown,
            totalEstimatedDistanceMeters: estimatedMeters,
            totalEstimatedDurationSeconds: Double(stage.sessionSeconds)
        )
        return workout
    }

    /// One strength session, on a day off running. Only built when the runner chose some
    /// equipment, the same rule race plans follow.
    private func strengthWorkout(date: Date, plan: StrengthWorkoutPlan) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: date.startOfDay,
            workoutType: .strength,
            notes: String(
                localized: "\(plan.estimatedDurationMinutes) min. Optional: skip it if your legs are still sore from running.",
                comment: "Note on the one strength session a week in a Start Running plan"
            )
        )
        workout.strengthPlan = plan
        return workout
    }

    static func note(for stage: StartRunningProgram.Stage, isFinalRun: Bool) -> String {
        let walkMinutes = StartRunningProgram.warmupSeconds / 60
        var parts: [String] = [
            String(
                localized: "Stage \(stage.number) of \(StartRunningProgram.stageCount). \(stage.summary), with a \(walkMinutes) minute walk before and after.",
                comment: "Opening of a Start Running session note: the stage and the session"
            ),
            String(
                localized: "Run slowly enough to talk in short sentences. If you can't, slow down or walk sooner.",
                comment: "Start Running effort guidance on every session"
            )
        ]
        if stage.isContinuous {
            parts.append(String(
                localized: "If you have to walk, walk, then pick the running back up. Finishing the time matters more than running all of it.",
                comment: "Start Running guidance on a continuous run"
            ))
        } else {
            parts.append(String(
                localized: "The walks are part of the plan, not a break from it.",
                comment: "Start Running guidance on a run/walk session"
            ))
        }
        if isFinalRun {
            parts.append(String(
                localized: "This is the last run of the plan: 30 minutes without stopping. A 5K plan picks up from here.",
                comment: "Start Running note on the graduation run"
            ))
        }
        parts.append(String(
            localized: "Stop and get checked if you have chest pain, feel faint, or have pain that gets worse as you run.",
            comment: "Safety line on every Start Running session"
        ))
        return parts.joined(separator: " ")
    }
}
