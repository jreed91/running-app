import Testing
import Foundation
@testable import Stride

/// Behaviour tests for the pregnancy plan.
///
/// Several of these assert an *absence* — no pace bands, no intervals, no race — because
/// those are the regressions this feature is most likely to suffer: every other plan in the
/// app has them, and the machinery that adds them is one call away. See
/// `docs/PREGNANCY_RUNNING_EVIDENCE.md` for why each absence is deliberate.
struct PregnancyPlanServiceTests {

    private let service = PregnancyPlanService()

    // MARK: Fixtures

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    /// Next Monday. Deliberately in the future: `TrainingPlanService.refreshPaces` and
    /// `AdaptableWorkoutSelector` both only consider workouts dated today or later, so a
    /// fixed past date would make the "nothing else may rewrite this plan" tests pass
    /// vacuously.
    private var start: Date { Date().startOfWeek.adding(weeks: 1) }

    private func makeProfile(
        fitnessLevel: FitnessLevel = .intermediate,
        runDays: [Int] = [0, 2, 4, 6],
        weeklyRunMinutes: Int? = 200,
        habituallyVigorous: Bool? = false,
        dueDateWeeksFromStart: Int? = 30,
        cleared: Bool = true,
        equipment: [StrengthEquipment] = [.bodyweight, .dumbbells]
    ) -> UserProfile {
        let profile = UserProfile(
            name: "Test Runner",
            goalRace: .maintainFitness,
            goalFinishTime: 0,
            weeklyRunDays: runDays.count,
            fitnessLevel: fitnessLevel,
            gender: .female,
            currentEstimated5KTimeSeconds: 27 * 60,
            preferredRunDayIndices: runDays
        )
        if let weeks = dueDateWeeksFromStart {
            profile.dueDate = start.adding(weeks: weeks)
        }
        profile.pregnancyClearedAt = cleared ? Date() : nil
        profile.prePregnancyWeeklyRunMinutes = weeklyRunMinutes
        profile.pregnancyHabituallyVigorous = habituallyVigorous
        profile.selectedEquipment = equipment
        return profile
    }

    private func weeks(in plan: TrainingPlan) -> [TrainingWeek] {
        (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
    }

    private func workouts(in plan: TrainingPlan) -> [ScheduledWorkout] {
        weeks(in: plan).flatMap { ($0.workouts ?? []).sorted { $0.scheduledDate < $1.scheduledDate } }
    }

    private func minutes(_ workout: ScheduledWorkout) -> Int {
        Int(((workout.workoutStructure?.totalEstimatedDurationSeconds ?? 0) / 60).rounded())
    }

    private func runMinutes(in week: TrainingWeek) -> Int {
        (week.workouts ?? []).filter { $0.workoutType.isRunType }.reduce(0) { $0 + minutes($1) }
    }

    private func activeMinutes(in week: TrainingWeek) -> Int {
        (week.workouts ?? [])
            .filter { $0.workoutType.isRunType || $0.workoutType == .crossTraining }
            .reduce(0) { $0 + minutes($1) }
    }

    private func gestationalWeek(of week: TrainingWeek, in plan: TrainingPlan) -> Int {
        guard let dueDate = plan.dueDate else { return 0 }
        return GestationalAge.on(week.startDate, dueDate: dueDate).weeks
    }

    // MARK: - The gate

    @Test("A plan cannot be built without an estimated due date")
    func requiresDueDate() {
        let profile = makeProfile(dueDateWeeksFromStart: nil)
        #expect(throws: PregnancyPlanService.Failure.missingDueDate) {
            _ = try service.generatePlan(profile: profile, startDate: start)
        }
    }

    @Test("A plan cannot be built until the health checklist is confirmed")
    func requiresScreening() {
        let profile = makeProfile(cleared: false)
        #expect(throws: PregnancyPlanService.Failure.notCleared) {
            _ = try service.generatePlan(profile: profile, startDate: start)
        }
    }

    @Test("A due date in the past is refused rather than turned into a postpartum plan")
    func refusesPastDueDate() {
        let profile = makeProfile()
        profile.dueDate = start.adding(weeks: -2)
        #expect(throws: PregnancyPlanService.Failure.dueDatePassed) {
            _ = try service.generatePlan(profile: profile, startDate: start)
        }
    }

    // MARK: - Shape

    @Test("The plan runs from the start week through the week of the due date")
    func planSpansToDueDate() throws {
        let profile = makeProfile(dueDateWeeksFromStart: 30)
        let plan = try service.generatePlan(profile: profile, startDate: start)
        #expect(plan.planKind == .pregnancy)
        #expect(plan.isPregnancyPlan)
        #expect(plan.dueDate == profile.dueDate?.startOfDay)
        #expect(weeks(in: plan).count == 31)
        #expect(plan.targetRace == .maintainFitness)
    }

    @Test("Every week holds at least one session")
    func everyWeekHasWork() throws {
        let plan = try service.generatePlan(profile: makeProfile(), startDate: start)
        for week in weeks(in: plan) {
            #expect(!(week.workouts ?? []).isEmpty, "Week \(week.weekNumber) is empty")
        }
    }

    @Test("A pregnancy plan never schedules a race or an interval session")
    func noRacingAndNoIntervals() throws {
        let plan = try service.generatePlan(
            profile: makeProfile(fitnessLevel: .competitive, habituallyVigorous: true),
            startDate: start
        )
        for workout in workouts(in: plan) {
            #expect(workout.workoutType != .race, "A pregnancy plan scheduled a race")
            #expect(workout.workoutType != .interval, "A pregnancy plan scheduled intervals")
            #expect(workout.intervals.isEmpty, "A pregnancy workout carries interval reps")
        }
    }

    @Test("No pregnancy workout carries a pace target")
    func pregnancyWorkoutsCarryNoPaceTargets() throws {
        let plan = try service.generatePlan(
            profile: makeProfile(fitnessLevel: .advanced, habituallyVigorous: true),
            startDate: start
        )
        for workout in workouts(in: plan) {
            #expect(workout.targetPaceLowerBound == nil, "Pace lower bound leaked onto a pregnancy workout")
            #expect(workout.targetPaceUpperBound == nil, "Pace upper bound leaked onto a pregnancy workout")
            #expect(workout.targetPaceRange == nil)
        }
    }

    @Test("Every run is prescribed as a duration")
    func runsArePrescribedInMinutes() throws {
        let plan = try service.generatePlan(profile: makeProfile(), startDate: start)
        for workout in workouts(in: plan) where workout.workoutType.isRunType {
            #expect(minutes(workout) > 0, "A pregnancy run has no prescribed duration")
        }
    }

    // MARK: - The volume curve

    @Test("Volume falls from the first trimester to the third")
    func volumeTapersAcrossTrimesters() throws {
        let profile = makeProfile(dueDateWeeksFromStart: 32)
        profile.dueDate = start.adding(weeks: 32)
        let plan = try service.generatePlan(profile: profile, startDate: start)

        let byTrimester = Dictionary(grouping: weeks(in: plan)) {
            PregnancyTrimester(gestationalWeek: gestationalWeek(of: $0, in: plan))
        }
        let first = byTrimester[.first]?.map { runMinutes(in: $0) } ?? []
        let third = byTrimester[.third]?.map { runMinutes(in: $0) } ?? []

        try #require(!first.isEmpty)
        try #require(!third.isEmpty)
        let firstAverage = Double(first.reduce(0, +)) / Double(first.count)
        let thirdAverage = Double(third.reduce(0, +)) / Double(third.count)
        #expect(thirdAverage < firstAverage, "Third-trimester running should be lower than first-trimester running")
    }

    @Test("The volume share never rises as the pregnancy progresses")
    func volumeShareIsMonotonic() {
        var previous = Double.infinity
        for week in 0...42 {
            let share = PregnancyRunningPolicy.runningVolumeShare(atGestationalWeek: week)
            #expect(share <= previous, "Share rose at gestational week \(week)")
            previous = share
        }
    }

    @Test("Third-trimester volume lands inside the documented 30–60% reduction")
    func thirdTrimesterReductionMatchesLiterature() {
        for week in 28...40 {
            let share = PregnancyRunningPolicy.runningVolumeShare(atGestationalWeek: week)
            #expect(share <= 0.70, "Week \(week) is barely reduced at all")
            #expect(share >= 0.30, "Week \(week) cuts more than the literature supports")
        }
    }

    @Test("Every week reaches the 150-minute guideline floor")
    func weeksReachTheGuidelineFloor() throws {
        // A runner doing very little running before pregnancy is the case that exercises the
        // top-up: the running alone never gets near 150 minutes.
        let profile = makeProfile(fitnessLevel: .beginner, runDays: [1, 3, 5], weeklyRunMinutes: 60)
        let plan = try service.generatePlan(profile: profile, startDate: start)
        for week in weeks(in: plan) {
            #expect(
                activeMinutes(in: week) >= PregnancyRunningPolicy.minimumWeeklyActiveMinutes,
                "Week \(week.weekNumber) prescribes only \(activeMinutes(in: week)) active minutes"
            )
        }
    }

    @Test("No single session exceeds the trimester duration cap")
    func sessionsRespectTheDurationCap() throws {
        let profile = makeProfile(fitnessLevel: .competitive, runDays: [0, 2, 4, 6], weeklyRunMinutes: 400)
        let plan = try service.generatePlan(profile: profile, startDate: start)
        for week in weeks(in: plan) {
            let cap = PregnancyRunningPolicy.sessionMinutesCap(
                for: PregnancyTrimester(gestationalWeek: gestationalWeek(of: week, in: plan))
            )
            for workout in (week.workouts ?? []) where workout.workoutType.isRunType {
                #expect(minutes(workout) <= cap, "Week \(week.weekNumber) prescribes \(minutes(workout)) min against a \(cap) min cap")
            }
        }
    }

    @Test("Run frequency is held while duration is cut")
    func frequencyIsHeld() throws {
        let runDays = [0, 2, 4, 6]
        let profile = makeProfile(runDays: runDays, weeklyRunMinutes: 240)
        let plan = try service.generatePlan(profile: profile, startDate: start)
        for week in weeks(in: plan) {
            let offsets = Set((week.workouts ?? [])
                .filter { $0.workoutType.isRunType || $0.workoutType == .crossTraining }
                .map { Calendar.current.dateComponents([.day], from: week.startDate, to: $0.scheduledDate).day ?? -1 })
            for day in runDays {
                #expect(offsets.contains(day), "Week \(week.weekNumber) left the runner's \(day) slot empty")
            }
        }
    }

    // MARK: - Intensity

    @Test("A runner who was not doing hard sessions is never given one")
    func noModerateSessionWithoutVigorousHistory() throws {
        let profile = makeProfile(fitnessLevel: .intermediate, habituallyVigorous: false)
        let plan = try service.generatePlan(profile: profile, startDate: start)
        #expect(!workouts(in: plan).contains { $0.workoutType == .tempo })
    }

    @Test("A habitually vigorous runner keeps one steadier session, and loses it at 28 weeks")
    func moderateSessionEndsAtTwentyEightWeeks() throws {
        let profile = makeProfile(fitnessLevel: .advanced, habituallyVigorous: true, dueDateWeeksFromStart: 34)
        profile.dueDate = start.adding(weeks: 34)
        let plan = try service.generatePlan(profile: profile, startDate: start)

        var sawEarlyModerate = false
        for week in weeks(in: plan) {
            let ga = gestationalWeek(of: week, in: plan)
            let hasModerate = (week.workouts ?? []).contains { $0.workoutType == .tempo }
            if ga < 28 {
                sawEarlyModerate = sawEarlyModerate || hasModerate
            } else {
                #expect(!hasModerate, "A moderate session survived into gestational week \(ga)")
            }
        }
        #expect(sawEarlyModerate, "A habitually vigorous runner got no steadier session at all")
    }

    @Test("From 28 weeks runs are structured as run/walk")
    func lateRunsUseRunWalk() throws {
        let profile = makeProfile(dueDateWeeksFromStart: 36)
        profile.dueDate = start.adding(weeks: 36)
        let plan = try service.generatePlan(profile: profile, startDate: start)

        for week in weeks(in: plan) where gestationalWeek(of: week, in: plan) >= 28 {
            for workout in (week.workouts ?? []) where workout.workoutType.isRunType {
                let reps = workout.workoutStructure?.mainSets.first?.repetitions ?? 0
                #expect(reps >= 1)
                #expect(
                    workout.workoutStructure?.mainSets.first?.recoverySegment.durationSeconds != nil,
                    "A late-pregnancy run has no walk breaks"
                )
            }
        }
    }

    // MARK: - Strength and pelvic floor

    @Test("Every strength session opens with pelvic floor training")
    func pelvicFloorLeadsEveryStrengthSession() throws {
        let plan = try service.generatePlan(profile: makeProfile(), startDate: start)
        let strength = workouts(in: plan).filter { $0.workoutType == .strength }
        try #require(!strength.isEmpty)
        for workout in strength {
            let first = workout.strengthPlan?.exercises.first
            #expect(first?.name == PregnancyRunningPolicy.pelvicFloorExercise.name)
        }
    }

    @Test("Every week schedules strength work")
    func everyWeekHasStrength() throws {
        let plan = try service.generatePlan(profile: makeProfile(), startDate: start)
        for week in weeks(in: plan) {
            #expect(
                (week.workouts ?? []).contains { $0.workoutType == .strength },
                "Week \(week.weekNumber) has no strength session, so the pelvic floor block has no home"
            )
        }
    }

    @Test("A runner who selected no equipment still gets bodyweight strength")
    func strengthSurvivesEmptyEquipment() throws {
        let profile = makeProfile(equipment: [])
        let plan = try service.generatePlan(profile: profile, startDate: start)
        #expect(workouts(in: plan).contains { $0.workoutType == .strength })
    }

    @Test("Supine exercises disappear from 16 weeks")
    func noSupineWorkAfterSixteenWeeks() throws {
        let profile = makeProfile(equipment: [.bodyweight, .barbell, .resistanceBands], dueDateWeeksFromStart: 34)
        profile.dueDate = start.adding(weeks: 34)
        let plan = try service.generatePlan(profile: profile, startDate: start)

        for week in weeks(in: plan) where gestationalWeek(of: week, in: plan) >= PregnancyRunningPolicy.supineCutoffGestationalWeek {
            for workout in (week.workouts ?? []) where workout.workoutType == .strength {
                for exercise in workout.strengthPlan?.exercises ?? [] {
                    #expect(
                        !PregnancyStrengthAdapter.supineExerciseNames.contains(exercise.name),
                        "\(exercise.name) is a supine exercise scheduled at \(gestationalWeek(of: week, in: plan)) weeks"
                    )
                }
            }
        }
    }

    // MARK: - Nothing else may rewrite the plan

    @Test("The AI coach is offered no workouts from a pregnancy plan")
    func coachCannotAdaptAPregnancyPlan() throws {
        let plan = try service.generatePlan(profile: makeProfile(), startDate: start)
        #expect(AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: start).isEmpty)
        #expect(AdaptableWorkoutSelector.nextAdaptableWorkout(in: plan, now: start) == nil)
    }

    @Test("refreshPaces leaves a pregnancy plan alone")
    func refreshPacesSkipsPregnancyPlans() throws {
        let profile = makeProfile()
        let plan = try service.generatePlan(profile: profile, startDate: start)
        let before = workouts(in: plan).map { ($0.targetPaceLowerBound, $0.notes) }

        TrainingPlanService().refreshPaces(plan: plan, history: [], profile: profile)

        let after = workouts(in: plan).map { ($0.targetPaceLowerBound, $0.notes) }
        #expect(before.count == after.count)
        for (lhs, rhs) in zip(before, after) {
            #expect(lhs.0 == nil && rhs.0 == nil, "refreshPaces wrote a pace band onto a pregnancy workout")
            #expect(lhs.1 == rhs.1, "refreshPaces rewrote a pregnancy workout's note")
        }
    }

    // MARK: - Gestational age

    @Test("Gestational age counts back from the due date at 40 weeks")
    func gestationalAgeMath() {
        let due = date(2026, 6, 1)
        #expect(GestationalAge.on(due, dueDate: due) == GestationalAge(weeks: 40, days: 0))
        #expect(GestationalAge.on(due.adding(days: -7), dueDate: due) == GestationalAge(weeks: 39, days: 0))
        #expect(GestationalAge.on(due.adding(days: -115), dueDate: due).noteForm == "23+4")
        #expect(GestationalAge.on(due.adding(days: -280), dueDate: due) == GestationalAge(weeks: 0, days: 0))
    }

    @Test("A date before conception clamps to zero rather than going negative")
    func gestationalAgeClampsAtZero() {
        let due = date(2026, 6, 1)
        let age = GestationalAge.on(due.adding(days: -400), dueDate: due)
        #expect(age.weeks == 0)
        #expect(age.days == 0)
    }

    @Test("Trimester boundaries follow the obstetric convention")
    func trimesterBoundaries() {
        #expect(PregnancyTrimester(gestationalWeek: 0) == .first)
        #expect(PregnancyTrimester(gestationalWeek: 13) == .first)
        #expect(PregnancyTrimester(gestationalWeek: 14) == .second)
        #expect(PregnancyTrimester(gestationalWeek: 27) == .second)
        #expect(PregnancyTrimester(gestationalWeek: 28) == .third)
        #expect(PregnancyTrimester(gestationalWeek: 41) == .third)
    }

    // MARK: - Guidance

    @Test("The final week hands off to the postpartum guidance and no earlier week does")
    func postpartumHandoffOnlyAtTheEnd() {
        let due = start.adding(weeks: 20)
        let mid = PregnancyPlanService.guidance(forWeekStarting: start, dueDate: due, isFinalWeek: false)
        let last = PregnancyPlanService.guidance(forWeekStarting: due, dueDate: due, isFinalWeek: true)
        #expect(mid.postpartum == nil)
        #expect(last.postpartum != nil)
    }

    @Test("An unrecognised plan kind decodes as a standard plan")
    func unknownPlanKindDegrades() {
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.adding(weeks: 10)
        )
        plan.planKindRaw = "something_from_a_newer_client"
        #expect(plan.planKind == .standard)
        #expect(!plan.isPregnancyPlan)
        #expect(plan.gestationalAge() == nil)
    }
}
