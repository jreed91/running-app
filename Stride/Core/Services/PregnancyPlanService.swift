import Foundation

// MARK: - PregnancyPlanService

/// Builds a running plan for a pregnancy.
///
/// It is a sibling of `TrainingPlanService`, not a mode of it, because almost nothing they
/// do is the same shape. A race plan periodises *upward* toward a fixed date and prescribes
/// by VDOT-derived pace; a pregnancy plan tapers *downward* toward an estimated due date,
/// prescribes by effort, and has no goal race, no intervals, and no race week at all. The
/// two share only the SwiftData models — deliberately, so the Plan tab, the widgets, the
/// history, and HealthKit sync all work on a pregnancy plan without knowing it is one.
///
/// Every number this service uses lives in `PregnancyRunningPolicy` with its source
/// attached; the long form is `docs/PREGNANCY_RUNNING_EVIDENCE.md`.
///
/// **Stride is not a clinician.** `generatePlan` refuses to build anything until the runner
/// has confirmed the contraindication screen and that they have discussed running with their
/// own maternity provider, and every session it produces carries the red-flag pointer.
struct PregnancyPlanService {

    // MARK: Failures

    enum Failure: LocalizedError, Equatable {
        /// No estimated due date, so there is no gestational clock to index the plan by.
        case missingDueDate
        /// The runner has not completed the contraindication screen.
        case notCleared
        /// The due date is already in the past. There is no pregnancy plan left to build,
        /// and postpartum return-to-running is deliberately not generated (see
        /// `PregnancyRunningPolicy.postpartumHandoff`).
        case dueDatePassed

        var errorDescription: String? {
            switch self {
            case .missingDueDate:
                return String(localized: "Add your estimated due date first.", comment: "Pregnancy plan generation failure")
            case .notCleared:
                return String(localized: "Confirm the health checklist before building a plan.", comment: "Pregnancy plan generation failure")
            case .dueDatePassed:
                return String(localized: "That due date has passed. Stride does not build postpartum return-to-running plans.", comment: "Pregnancy plan generation failure")
            }
        }
    }

    /// Longest plan we will build, in weeks. Forty-two weeks covers a pregnancy started at
    /// week zero and run two weeks past the estimated due date.
    private static let maximumWeeks = 42

    /// Walking pace used only to turn prescribed *minutes* into the distance estimate the
    /// rest of the app renders. Nothing is prescribed in distance.
    private static let walkPaceSecondsPerKm: Double = 12 * 60

    /// The VDOT assumed when the runner has never entered a 5K time — a mid-recreational
    /// 32-minute 5K. Used only for the same distance estimate.
    private static let fallbackVDOT: Double = PaceCalculatorService.vdot(
        distanceMeters: 5_000,
        timeSeconds: 32 * 60
    )

    // MARK: - Public API

    /// Builds a pregnancy plan running from `startDate` through the week of the estimated
    /// due date.
    ///
    /// - Throws: ``Failure`` when the profile is missing a due date, has not completed the
    ///   contraindication screen, or the due date has already passed.
    func generatePlan(
        profile: UserProfile,
        startDate: Date
    ) throws -> TrainingPlan {
        guard let dueDate = profile.dueDate?.startOfDay else { throw Failure.missingDueDate }
        guard profile.pregnancyClearedAt != nil else { throw Failure.notCleared }

        let start = startDate.startOfWeek
        let daysToDue = Calendar.current.dateComponents([.day], from: start, to: dueDate).day ?? -1
        guard daysToDue >= 0 else { throw Failure.dueDatePassed }
        let numberOfWeeks = max(1, min(Self.maximumWeeks, daysToDue / 7 + 1))

        let plan = TrainingPlan(
            targetRace: .maintainFitness,
            goalTimeSeconds: 0,
            startDate: start,
            endDate: start.adding(weeks: numberOfWeeks)
        )
        plan.planKind = .pregnancy
        plan.dueDate = dueDate

        let runOffsets = resolvedRunOffsets(for: profile)
        let baseMinutes = profile.prePregnancyWeeklyRunMinutes
            ?? PregnancyRunningPolicy.defaultWeeklyRunMinutes(for: profile.fitnessLevel)
        let habituallyVigorous = profile.pregnancyHabituallyVigorous
            ?? (profile.fitnessLevel == .advanced || profile.fitnessLevel == .competitive)
        let paces = PaceCalculatorService.trainingPaces(forVDOT: profile.baselineVDOT ?? Self.fallbackVDOT)
        let easyPace = (paces.easyRange.lowerBound + paces.easyRange.upperBound) / 2

        // A pregnancy plan is resistance training as well as aerobic training (SOGC/CSEP
        // 2019), and the pelvic floor prescription rides on the strength session — so a
        // runner who selected no equipment still gets bodyweight sessions rather than none.
        let equipment = profile.selectedEquipment.isEmpty
            ? [StrengthEquipment.bodyweight]
            : profile.selectedEquipment

        for index in 0..<numberOfWeeks {
            let week = buildWeek(
                weekNumber: index + 1,
                weekStart: start.adding(weeks: index),
                dueDate: dueDate,
                runOffsets: runOffsets,
                baseWeeklyRunMinutes: max(0, baseMinutes),
                habituallyVigorous: habituallyVigorous,
                easyPaceSecondsPerKm: easyPace,
                equipment: equipment,
                strengthFocus: profile.strengthFocus
            )
            plan.weeks = (plan.weeks ?? []) + [week]
        }
        return plan
    }

    // MARK: - Weekly guidance (read by the UI; no model field needed)

    /// What to tell the runner about a given week. Derived, not stored: `TrainingWeek` has
    /// no notes field, and a pregnancy week's guidance is a pure function of where the
    /// pregnancy is.
    struct WeekGuidance: Hashable, Sendable {
        var gestationalAge: GestationalAge
        var trimester: PregnancyTrimester
        var headline: String
        var terrain: String
        var heat: String
        var pelvicFloor: String
        /// Non-nil on the last week of the plan.
        var postpartum: String?
    }

    static func guidance(
        forWeekStarting weekStart: Date,
        dueDate: Date,
        isFinalWeek: Bool = false
    ) -> WeekGuidance {
        let ga = GestationalAge.on(weekStart, dueDate: dueDate)
        let trimester = ga.trimester
        return WeekGuidance(
            gestationalAge: ga,
            trimester: trimester,
            headline: headline(for: trimester, gestationalAge: ga),
            terrain: PregnancyRunningPolicy.terrainGuidance(for: trimester),
            heat: PregnancyRunningPolicy.heatAndHydrationNote,
            pelvicFloor: PregnancyRunningPolicy.pelvicFloorExercise.notes ?? "",
            postpartum: isFinalWeek ? PregnancyRunningPolicy.postpartumHandoff : nil
        )
    }

    private static func headline(for trimester: PregnancyTrimester, gestationalAge ga: GestationalAge) -> String {
        switch trimester {
        case .first:
            return String(
                localized: "Week \(ga.noteForm). Keep the frequency, drop whatever the fatigue and nausea take. A short run you actually do beats a long one you dread.",
                comment: "Pregnancy plan weekly headline, first trimester"
            )
        case .second:
            return String(
                localized: "Week \(ga.noteForm). Most runners feel best about now. Runs shorten a little; effort stays conversational.",
                comment: "Pregnancy plan weekly headline, second trimester"
            )
        case .third:
            return String(
                localized: "Week \(ga.noteForm). Shorter, easier, closer to home — and run/walk by default. Stopping early is a finished session, not a failed one.",
                comment: "Pregnancy plan weekly headline, third trimester"
            )
        }
    }

    // MARK: - Week builder

    // swiftlint:disable:next function_parameter_count
    private func buildWeek(
        weekNumber: Int,
        weekStart: Date,
        dueDate: Date,
        runOffsets: [Int],
        baseWeeklyRunMinutes: Int,
        habituallyVigorous: Bool,
        easyPaceSecondsPerKm: Double,
        equipment: [StrengthEquipment],
        strengthFocus: StrengthFocus
    ) -> TrainingWeek {
        let ga = GestationalAge.on(weekStart, dueDate: dueDate)
        let trimester = ga.trimester

        // A pregnancy plan has no build and no peak. Weeks map onto the two phases that
        // describe what is actually happening: hold, then ease off.
        let phase: TrainingPhase = trimester == .third ? .taper : .base

        let sessions = runSessions(
            runOffsets: runOffsets,
            baseWeeklyRunMinutes: baseWeeklyRunMinutes,
            habituallyVigorous: habituallyVigorous,
            gestationalAge: ga
        )

        var runWorkouts: [ScheduledWorkout] = []
        var crossMinutes: [Int: Int] = [:]
        var occupied = Set<Int>()
        var estimatedKm = 0.0
        var runSeconds = 0.0

        for session in sessions {
            occupied.insert(session.offset)
            switch session.kind {
            case .run:
                let workout = runWorkout(
                    date: weekStart.adding(days: session.offset),
                    minutes: session.minutes,
                    effort: session.effort,
                    isLong: session.isLong,
                    gestationalAge: ga,
                    easyPaceSecondsPerKm: easyPaceSecondsPerKm
                )
                estimatedKm += (workout.targetDistanceMeters ?? 0) / 1_000
                // Counted from the structure rather than from `session.minutes`: run/walk
                // rounds to whole cycles, so the built session is what the week actually
                // prescribes and the floor below has to be measured against that.
                runSeconds += workout.workoutStructure?.totalEstimatedDurationSeconds ?? 0
                runWorkouts.append(workout)
            case .crossTraining:
                crossMinutes[session.offset] = session.minutes
            }
        }

        // Top the week up to the guideline floor of 150 minutes (§1). Running short is
        // expected and fine as pregnancy progresses; being *inactive* is the thing the
        // guidelines are actually trying to prevent.
        var deficit = PregnancyRunningPolicy.minimumWeeklyActiveMinutes
            - Int((runSeconds / 60).rounded())
            - crossMinutes.values.reduce(0, +)
        if deficit > 0 {
            let openDays = (0...6).filter { !occupied.contains($0) }
            let wanted = min(openDays.count, max(1, Int(ceil(Double(deficit) / 45.0))))
            let picks = Self.evenlyPicked(openDays, count: wanted)
            if !picks.isEmpty {
                let per = min(60, max(20, Int((Double(deficit) / Double(picks.count)).rounded(.up))))
                for offset in picks {
                    crossMinutes[offset] = per
                    occupied.insert(offset)
                    deficit -= per
                }
            }
            // Still short because every day is already spoken for: lengthen the low-impact
            // sessions rather than leave the week under the floor. 90 minutes is where a
            // single walk or swim stops being a sensible thing to prescribe.
            if deficit > 0, !crossMinutes.isEmpty {
                let offsets = crossMinutes.keys.sorted()
                let extra = Int((Double(deficit) / Double(offsets.count)).rounded(.up))
                for offset in offsets {
                    crossMinutes[offset] = min(90, (crossMinutes[offset] ?? 0) + extra)
                }
            }
        }

        var workouts = runWorkouts
        for offset in crossMinutes.keys.sorted() {
            workouts.append(crossTrainingWorkout(
                date: weekStart.adding(days: offset),
                minutes: crossMinutes[offset] ?? PregnancyRunningPolicy.minimumSessionMinutes
            ))
        }
        let free = (0...6).filter { !occupied.contains($0) }

        // Strength, with the pelvic floor block on the front of it (§6).
        let strengthCount = PregnancyRunningPolicy.strengthSessionsPerWeek(for: trimester)
        let basePlan = StrengthLibrary.plan(for: equipment, focus: strengthFocus, phase: phase)
        let adaptedPlan = PregnancyStrengthAdapter.adapt(basePlan, atGestationalWeek: ga.weeks)
        if !adaptedPlan.exercises.isEmpty {
            for offset in Self.evenlyPicked(
                strengthOffsets(free: free, runOffsets: runOffsets),
                count: strengthCount
            ) {
                let workout = ScheduledWorkout(
                    scheduledDate: weekStart.adding(days: offset),
                    workoutType: .strength,
                    notes: String(
                        localized: "\(adaptedPlan.estimatedDurationMinutes) min. Pelvic floor work first — that part is every day, not just today.",
                        comment: "Note on a pregnancy strength session"
                    )
                )
                workout.strengthPlan = adaptedPlan
                workouts.append(workout)
            }
        }

        let week = TrainingWeek(
            weekNumber: weekNumber,
            startDate: weekStart,
            phase: phase,
            targetDistanceKm: estimatedKm
        )
        week.workouts = workouts.sorted { $0.scheduledDate < $1.scheduledDate }
        return week
    }

    /// Which days a strength session may land on.
    ///
    /// One day is held back so a week always has somewhere to be genuinely empty — the
    /// guidelines encourage activity on most days, not on all seven under instruction. When
    /// the week is full enough that nothing is left, strength doubles up with a
    /// cross-training day rather than being dropped: the pelvic floor prescription rides on
    /// this session and it is the one thing that should never fall off a week (§6).
    private func strengthOffsets(free: [Int], runOffsets: [Int]) -> [Int] {
        let restDay = free.last
        let withoutRestDay = free.filter { $0 != restDay }
        if !withoutRestDay.isEmpty { return withoutRestDay }

        let nonRunDays = (0...6).filter { !runOffsets.contains($0) && $0 != restDay }
        if !nonRunDays.isEmpty { return nonRunDays }

        let anyNonRunDay = (0...6).filter { !runOffsets.contains($0) }
        return anyNonRunDay.isEmpty ? Array(0...6) : anyNonRunDay
    }

    // MARK: - Session allocation

    private struct Session {
        enum Kind { case run, crossTraining }
        var offset: Int
        var kind: Kind
        var minutes: Int
        var effort: PregnancyEffort
        var isLong: Bool
    }

    /// Splits the week's running minutes across the runner's chosen days.
    ///
    /// Frequency is held and duration is cut — the pattern Tenforde et al. observed rather
    /// than one this app invented. Weights (long 1.6, moderate 1.1, easy 1.0) rather than
    /// fixed fractions, so the long run stays the longest session at every day count.
    private func runSessions(
        runOffsets: [Int],
        baseWeeklyRunMinutes: Int,
        habituallyVigorous: Bool,
        gestationalAge ga: GestationalAge
    ) -> [Session] {
        guard !runOffsets.isEmpty else { return [] }

        let share = PregnancyRunningPolicy.runningVolumeShare(atGestationalWeek: ga.weeks)
        let weeklyMinutes = Double(baseWeeklyRunMinutes) * share
        let cap = PregnancyRunningPolicy.sessionMinutesCap(for: ga.trimester)

        let longOffset = runOffsets[runOffsets.count - 1]
        let wantsModerate = PregnancyRunningPolicy.allowsModerateSession(
            atGestationalWeek: ga.weeks,
            habituallyVigorous: habituallyVigorous
        )
        // Only worth carving a steadier session out of a week that has three run days or
        // more; below that it would come out of the easy running the plan is built on.
        let moderateOffset: Int? = (wantsModerate && runOffsets.count >= 3) ? runOffsets[0] : nil

        func weight(_ offset: Int) -> Double {
            if offset == longOffset { return 1.6 }
            if offset == moderateOffset { return 1.1 }
            return 1.0
        }
        let totalWeight = runOffsets.reduce(0.0) { $0 + weight($1) }

        return runOffsets.map { offset in
            let raw = Int((weeklyMinutes * weight(offset) / totalWeight).rounded())
            let minutes = min(raw, cap)
            let effort: PregnancyEffort = offset == moderateOffset ? .moderate : .easy
            guard minutes >= PregnancyRunningPolicy.minimumSessionMinutes else {
                // Too short to be worth running: the day still counts toward the weekly
                // floor, as the low-impact activity the guidelines are just as happy with.
                return Session(
                    offset: offset,
                    kind: .crossTraining,
                    minutes: PregnancyRunningPolicy.minimumSessionMinutes,
                    effort: .easy,
                    isLong: false
                )
            }
            return Session(
                offset: offset,
                kind: .run,
                minutes: minutes,
                effort: effort,
                isLong: offset == longOffset
            )
        }
    }

    /// The weekday offsets (0 = Monday … 6 = Sunday) this runner runs on.
    ///
    /// Frequency is the one thing a pregnancy plan does *not* reduce, so this is resolved
    /// once per plan and reused unchanged for every week of it.
    private func resolvedRunOffsets(for profile: UserProfile) -> [Int] {
        let preferred = profile.preferredRunDayIndices.filter { (0...6).contains($0) }
        if !preferred.isEmpty { return Array(Set(preferred)).sorted() }
        let count = max(1, min(7, profile.weeklyRunDays))
        let step = 7.0 / Double(count)
        return (0..<count).map { Int(Double($0) * step) }
    }

    /// Picks `count` offsets spread as evenly as possible across `candidates`.
    private static func evenlyPicked(_ candidates: [Int], count: Int) -> [Int] {
        guard count > 0, !candidates.isEmpty else { return [] }
        let pickCount = min(count, candidates.count)
        if pickCount == 1 { return [candidates[candidates.count / 2]] }
        let step = Double(candidates.count - 1) / Double(pickCount - 1)
        var picked: [Int] = []
        for index in 0..<pickCount {
            let value = candidates[Int((Double(index) * step).rounded())]
            if !picked.contains(value) { picked.append(value) }
        }
        return picked
    }

    // MARK: - Workout factories

    /// One prescribed run.
    ///
    /// Note what is *not* set: `targetPaceLowerBound` and `targetPaceUpperBound` stay nil.
    /// Pregnancy moves the pace–effort relationship week by week, so a pace band would be
    /// wrong by construction (§3). Distance is filled in only as an estimate derived from
    /// the prescribed minutes, because the rest of the app renders distances.
    private func runWorkout(
        date: Date,
        minutes: Int,
        effort: PregnancyEffort,
        isLong: Bool,
        gestationalAge ga: GestationalAge,
        easyPaceSecondsPerKm: Double
    ) -> ScheduledWorkout {
        let bookend = minutes >= 30 ? 5 : 3
        let mainMinutes = max(5, minutes - 2 * bookend)
        let usesRunWalk = PregnancyRunningPolicy.usesRunWalk(atGestationalWeek: ga.weeks)

        let warmup = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(bookend * 60),
            targetPaceSecondsPerKm: nil,
            label: String(localized: "Walk to start", comment: "Pregnancy run warm-up segment")
        )
        let cooldown = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(bookend * 60),
            targetPaceSecondsPerKm: nil,
            label: String(localized: "Walk to finish", comment: "Pregnancy run cool-down segment")
        )

        var mainSets: [WorkoutSet] = []
        var runSeconds = 0.0
        var walkSeconds = Double(2 * bookend * 60)

        if usesRunWalk {
            let cycle = PregnancyRunningPolicy.runWalkRunMinutes + PregnancyRunningPolicy.runWalkWalkMinutes
            let reps = max(1, mainMinutes / cycle)
            mainSets = [WorkoutSet(
                repetitions: reps,
                workSegment: WorkoutSegment(
                    distanceMeters: nil,
                    durationSeconds: Double(PregnancyRunningPolicy.runWalkRunMinutes * 60),
                    targetPaceSecondsPerKm: nil,
                    label: String(localized: "Run", comment: "Run portion of a pregnancy run/walk set")
                ),
                recoverySegment: WorkoutSegment(
                    distanceMeters: nil,
                    durationSeconds: Double(PregnancyRunningPolicy.runWalkWalkMinutes * 60),
                    targetPaceSecondsPerKm: nil,
                    label: String(localized: "Walk", comment: "Walk portion of a pregnancy run/walk set")
                ),
                label: String(
                    localized: "\(reps) × \(PregnancyRunningPolicy.runWalkRunMinutes) min run / \(PregnancyRunningPolicy.runWalkWalkMinutes) min walk",
                    comment: "Label for a pregnancy run/walk set"
                )
            )]
            runSeconds = Double(reps * PregnancyRunningPolicy.runWalkRunMinutes * 60)
            walkSeconds += Double(max(0, reps - 1) * PregnancyRunningPolicy.runWalkWalkMinutes * 60)
        } else if effort == .moderate {
            // The moderate block is capped and the rest of the session is easy, so a
            // "steady" day never becomes a long sustained hard effort (§3, §4).
            let moderateMinutes = min(mainMinutes, PregnancyRunningPolicy.moderateBlockMinutesCap)
            mainSets.append(WorkoutSet(
                repetitions: 1,
                workSegment: WorkoutSegment(
                    distanceMeters: nil,
                    durationSeconds: Double(moderateMinutes * 60),
                    targetPaceSecondsPerKm: nil,
                    label: PregnancyEffort.moderate.localizedName
                ),
                recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
                label: String(localized: "Moderate block", comment: "Label for the steady block of a pregnancy run")
            ))
            let remainder = mainMinutes - moderateMinutes
            if remainder > 0 {
                mainSets.append(easySet(minutes: remainder))
            }
            runSeconds = Double(mainMinutes * 60)
        } else {
            mainSets = [easySet(minutes: mainMinutes)]
            runSeconds = Double(mainMinutes * 60)
        }

        let estimatedMeters = runSeconds / easyPaceSecondsPerKm * 1_000
            + walkSeconds / Self.walkPaceSecondsPerKm * 1_000
        let totalSeconds = runSeconds + walkSeconds

        let type: WorkoutType
        if effort == .moderate {
            type = .tempo
        } else {
            type = isLong ? .longRun : .easy
        }

        let workout = ScheduledWorkout(
            scheduledDate: date.startOfDay,
            workoutType: type,
            targetDistanceMeters: estimatedMeters,
            targetPaceLowerBound: nil,
            targetPaceUpperBound: nil,
            notes: runNote(minutes: minutes, effort: effort, usesRunWalk: usesRunWalk)
        )
        workout.workoutStructure = WorkoutStructure(
            warmup: warmup,
            mainSets: mainSets,
            cooldown: cooldown,
            totalEstimatedDistanceMeters: estimatedMeters,
            totalEstimatedDurationSeconds: totalSeconds
        )
        return workout
    }

    private func easySet(minutes: Int) -> WorkoutSet {
        WorkoutSet(
            repetitions: 1,
            workSegment: WorkoutSegment(
                distanceMeters: nil,
                durationSeconds: Double(minutes * 60),
                targetPaceSecondsPerKm: nil,
                label: PregnancyEffort.easy.localizedName
            ),
            recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
            label: String(localized: "Easy running", comment: "Label for the easy block of a pregnancy run")
        )
    }

    private func runNote(minutes: Int, effort: PregnancyEffort, usesRunWalk: Bool) -> String {
        var parts: [String] = [
            String(
                localized: "\(minutes) min by the clock, not by distance. \(effort.prescription)",
                comment: "Opening of a pregnancy run note: duration and effort prescription"
            )
        ]
        if usesRunWalk {
            parts.append(String(
                localized: "Run/walk by default — run it straight through if that feels better.",
                comment: "Run/walk guidance on a late-pregnancy run"
            ))
        }
        parts.append(PregnancyRunningPolicy.heatAndHydrationNote)
        parts.append(String(
            localized: "Stop and call your maternity provider for bleeding, fluid loss, contractions, chest pain, or dizziness that does not settle.",
            comment: "Red-flag pointer on every pregnancy run"
        ))
        return parts.joined(separator: " ")
    }

    private func crossTrainingWorkout(date: Date, minutes: Int) -> ScheduledWorkout {
        let workout = ScheduledWorkout(
            scheduledDate: date.startOfDay,
            workoutType: .crossTraining,
            targetDistanceMeters: nil,
            targetPaceLowerBound: nil,
            targetPaceUpperBound: nil,
            notes: String(
                localized: "\(minutes) min moderate. \(PregnancyRunningPolicy.crossTrainingNote)",
                comment: "Note on a pregnancy cross-training session"
            )
        )
        // A cross-training session is prescribed purely in minutes, and `ScheduledWorkout`
        // has nowhere else to put a duration — the structure is where the week's active
        // minutes are actually counted from, here and in the tests.
        let block = WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: Double(minutes * 60),
            targetPaceSecondsPerKm: nil,
            label: PregnancyEffort.moderate.localizedName
        )
        workout.workoutStructure = WorkoutStructure(
            warmup: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
            mainSets: [WorkoutSet(
                repetitions: 1,
                workSegment: block,
                recoverySegment: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
                label: String(localized: "Low-impact cross-training", comment: "Label for a pregnancy cross-training block")
            )],
            cooldown: WorkoutSegment(distanceMeters: nil, durationSeconds: nil, targetPaceSecondsPerKm: nil, label: ""),
            totalEstimatedDistanceMeters: 0,
            totalEstimatedDurationSeconds: Double(minutes * 60)
        )
        return workout
    }
}
