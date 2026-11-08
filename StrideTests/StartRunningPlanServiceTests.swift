import Testing
import Foundation
@testable import Stride

/// Behaviour tests for the Start Running plan.
///
/// Like the pregnancy tests, several of these assert an *absence*: no pace bands, no race,
/// nothing else allowed to rewrite the sessions. Every other plan in the app has those, and
/// the machinery that adds them is one call away. The rest pin the program's shape, which
/// is the feature: one stage a week, the same session each run day, never a step up from
/// what the runner said they can already do. See `docs/START_RUNNING_PROGRAM.md`.
struct StartRunningPlanServiceTests {

    private let service = StartRunningPlanService()

    // MARK: Fixtures

    /// Next Monday. Deliberately in the future: `refreshPaces`, `AdaptableWorkoutSelector`
    /// and the heat advisory only consider sessions dated today or later, so a past date
    /// would make the "nothing else may rewrite this plan" tests pass vacuously.
    private var start: Date { Date().startOfWeek.adding(weeks: 1) }

    private func makeProfile(
        runDays: [Int] = [0, 2, 4],
        equipment: [StrengthEquipment] = [],
        estimated5K: Double? = nil
    ) -> UserProfile {
        let profile = UserProfile(
            name: "New Runner",
            goalRace: .maintainFitness,
            goalFinishTime: 0,
            weeklyRunDays: max(1, runDays.count),
            fitnessLevel: .beginner,
            currentEstimated5KTimeSeconds: estimated5K,
            preferredRunDayIndices: runDays
        )
        profile.selectedEquipment = equipment
        return profile
    }

    private func weeks(in plan: TrainingPlan) -> [TrainingWeek] {
        (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
    }

    private func runs(in week: TrainingWeek) -> [ScheduledWorkout] {
        (week.workouts ?? []).filter { $0.workoutType.isRunType }.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func runs(in plan: TrainingPlan) -> [ScheduledWorkout] {
        weeks(in: plan).flatMap { runs(in: $0) }
    }

    private func weekday(of date: Date, from weekStart: Date) -> Int {
        Calendar.current.dateComponents([.day], from: weekStart.startOfDay, to: date.startOfDay).day ?? -1
    }

    // MARK: - The program

    @Test("Ten stages, from one minute of running at a time to thirty without stopping")
    func programShape() {
        let stages = StartRunningProgram.stages
        #expect(stages.count == 10)
        #expect(stages.map(\.number) == Array(1...10))

        let first = StartRunningProgram.stage(1)
        #expect(first.repetitions == 8 && first.runSeconds == 60 && first.walkSeconds == 90)
        #expect(!first.isContinuous)

        let last = StartRunningProgram.stage(10)
        #expect(last.isContinuous)
        #expect(last.runSeconds == 30 * 60)
        #expect(last.isGraduation)
    }

    @Test("The longest stretch of running grows every stage, never by more than 1.7×")
    func progressionIsGradual() {
        let longest = StartRunningProgram.stages.map(\.runSeconds)
        for (previous, next) in zip(longest, longest.dropFirst()) {
            #expect(next > previous)
            #expect(Double(next) / Double(previous) <= 1.7, "\(previous) s to \(next) s is too steep a step")
        }
    }

    @Test("Stage numbers outside the table clamp into it")
    func stageClamps() {
        #expect(StartRunningProgram.stage(0).number == 1)
        #expect(StartRunningProgram.stage(-3).number == 1)
        #expect(StartRunningProgram.stage(99).number == 10)
    }

    @Test("Each starting point begins no harder than what the runner can already run")
    func startingPoints() {
        let canRunSeconds: [StartRunningProgram.StartingPoint: Int] = [
            .notYet: 60, .fewMinutes: 2 * 60, .fiveMinutes: 5 * 60, .tenMinutes: 10 * 60
        ]
        for point in StartRunningProgram.StartingPoint.allCases {
            let stage = StartRunningProgram.stage(point.firstStage)
            #expect(stage.runSeconds <= canRunSeconds[point] ?? 0, "\(point) starts above what the runner said")
            #expect(point.weeks == 10 - point.firstStage + 1)
        }
        #expect(StartRunningProgram.StartingPoint.notYet.weeks == 10)
        #expect(StartRunningProgram.StartingPoint.tenMinutes.weeks == 5)
    }

    // MARK: - The plan

    @Test("A plan is one week per stage and ends on the graduation stage")
    func oneWeekPerStage() {
        for firstStage in [1, 3, 5, 6] {
            let plan = service.generatePlan(profile: makeProfile(), startDate: start, firstStage: firstStage)
            let planWeeks = weeks(in: plan)
            #expect(planWeeks.count == 10 - firstStage + 1)
            for (index, week) in planWeeks.enumerated() {
                #expect(StartRunningPlanService.stage(of: week)?.number == firstStage + index)
            }
            #expect(planWeeks.last.flatMap { StartRunningPlanService.stage(of: $0) }?.isGraduation == true)
            #expect(plan.endDate == plan.startDate.adding(weeks: planWeeks.count))
        }
    }

    @Test("A Start Running plan has no race, no goal time and no pace targets")
    func noRaceNoPace() {
        let plan = service.generatePlan(profile: makeProfile(estimated5K: 26 * 60), startDate: start)
        #expect(plan.planKind == .startRunning)
        #expect(plan.isStartRunningPlan)
        #expect(plan.prescribesByTime)
        #expect(!plan.planKind.hasGoalRace)
        #expect(plan.targetRace == .maintainFitness)
        #expect(plan.raceDate == nil)
        #expect(plan.goalTimeSeconds == 0)
        for workout in weeks(in: plan).flatMap({ $0.workouts ?? [] }) {
            #expect(workout.targetPaceLowerBound == nil)
            #expect(workout.targetPaceUpperBound == nil)
            #expect(workout.workoutType != .interval && workout.workoutType != .tempo && workout.workoutType != .race)
            for segment in [workout.workoutStructure?.warmup, workout.workoutStructure?.cooldown].compactMap({ $0 }) {
                #expect(segment.targetPaceSecondsPerKm == nil)
            }
            for set in workout.workoutStructure?.mainSets ?? [] {
                #expect(set.workSegment.targetPaceSecondsPerKm == nil)
                #expect(set.recoverySegment.targetPaceSecondsPerKm == nil)
            }
        }
    }

    @Test("Every run day of a week is the same session")
    func sameSessionAllWeek() {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        for week in weeks(in: plan) {
            let stages = runs(in: week).map { StartRunningProgram.stage(matching: $0.workoutStructure)?.number }
            #expect(stages.count == 3)
            #expect(Set(stages).count == 1)
            #expect(stages.allSatisfy { $0 != nil })
        }
    }

    @Test("A session is a brisk walk, the stage's run/walk set, and a walk to finish")
    func sessionStructure() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start, firstStage: 3)
        let session = try #require(runs(in: plan).first)
        let structure = try #require(session.workoutStructure)
        let set = try #require(structure.mainSets.first)

        #expect(session.workoutType == .easy)
        #expect(structure.warmup.durationSeconds == 300)
        #expect(structure.cooldown.durationSeconds == 300)
        #expect(structure.mainSets.count == 1)
        #expect(set.repetitions == 6)
        #expect(set.workSegment.durationSeconds == 120)
        #expect(set.recoverySegment.durationSeconds == 90)
        // Warm-up + 6 runs + 5 walks between them + cool-down. No walk after the last run:
        // the cool-down follows it.
        #expect(structure.totalEstimatedDurationSeconds == Double(300 + 6 * 120 + 5 * 90 + 300))
        #expect((session.targetDistanceMeters ?? 0) > 0)
        #expect(session.targetDistanceMeters == structure.totalEstimatedDistanceMeters)
    }

    @Test("A continuous stage has no walk step, so the guided run gives none")
    func continuousStageHasNoRecovery() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start, firstStage: 8)
        let structure = try #require(runs(in: plan).first?.workoutStructure)
        let set = try #require(structure.mainSets.first)
        #expect(set.repetitions == 1)
        #expect(set.workSegment.durationSeconds == 18 * 60)
        #expect(set.recoverySegment.durationSeconds == nil)

        let steps = GuidedWorkoutState.flatten(structure)
        #expect(steps.count == 3, "warm-up, the run, cool-down")
    }

    @Test("Every stage reads back from the session it builds, and a rewritten one reads as none")
    func stageReadsBack() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        for (index, week) in weeks(in: plan).enumerated() {
            let session = try #require(runs(in: week).first)
            #expect(StartRunningProgram.stage(matching: session.workoutStructure)?.number == index + 1)
        }

        var edited = try #require(runs(in: plan).first?.workoutStructure)
        edited.mainSets[0].repetitions += 1
        #expect(StartRunningProgram.stage(matching: edited) == nil)
        #expect(StartRunningProgram.stage(matching: nil) == nil)
    }

    @Test("The distance estimate uses the runner's easy pace when there is one")
    func distanceEstimate() throws {
        let slow = service.generatePlan(profile: makeProfile(), startDate: start, firstStage: 10)
        let fast = service.generatePlan(profile: makeProfile(estimated5K: 22 * 60), startDate: start, firstStage: 10)
        let slowMeters = try #require(runs(in: slow).first?.targetDistanceMeters)
        let fastMeters = try #require(runs(in: fast).first?.targetDistanceMeters)
        // 30 min at 8:00/km plus 10 min of walking at 12:00/km.
        #expect(abs(slowMeters - (30.0 / 8 + 10.0 / 12) * 1_000) < 1)
        #expect(fastMeters > slowMeters)
    }

    // MARK: - Days

    @Test("At most three run days, spaced as far apart as the chosen days allow")
    func runDaySelection() {
        #expect(StartRunningPlanService.runOffsets(preferred: [0, 1, 2, 3, 4, 5, 6], weeklyRunDays: 7) == [0, 2, 4])
        #expect(StartRunningPlanService.runOffsets(preferred: [0, 1, 2, 3, 4], weeklyRunDays: 5) == [0, 2, 4])
        #expect(StartRunningPlanService.runOffsets(preferred: [1, 2, 3, 5], weeklyRunDays: 4) == [1, 3, 5])
        // Fewer than three chosen: those days, as they are.
        #expect(StartRunningPlanService.runOffsets(preferred: [5, 6], weeklyRunDays: 2) == [5, 6])
        #expect(StartRunningPlanService.runOffsets(preferred: [3, 3, 9, -1], weeklyRunDays: 1) == [3])
        // None chosen: the weekly count, capped at three, spread from Monday.
        #expect(StartRunningPlanService.runOffsets(preferred: [], weeklyRunDays: 5) == [0, 2, 4])
        #expect(StartRunningPlanService.runOffsets(preferred: [], weeklyRunDays: 2) == [0, 3])
        #expect(StartRunningPlanService.runOffsets(preferred: [], weeklyRunDays: 0) == [0])
    }

    @Test("Sessions land on the runner's weekdays")
    func sessionsOnChosenDays() {
        let plan = service.generatePlan(profile: makeProfile(runDays: [1, 3, 5]), startDate: start)
        for week in weeks(in: plan) {
            let days = runs(in: week).map { weekday(of: $0.scheduledDate, from: week.startDate) }
            #expect(days == [1, 3, 5])
        }
    }

    @Test("Starting mid-week leaves out the run days already gone")
    func midWeekStart() {
        let thursday = start.adding(days: 3)
        let plan = service.generatePlan(profile: makeProfile(runDays: [0, 2, 4]), startDate: thursday)
        #expect(plan.startDate == start, "weeks stay Monday to Sunday")
        let firstWeek = weeks(in: plan).first
        let firstWeekRuns = firstWeek.map { runs(in: $0) } ?? []
        #expect(firstWeekRuns.count == 1)
        #expect(firstWeekRuns.allSatisfy { $0.scheduledDate >= thursday })
    }

    @Test("Starting after the week's last run day begins the next Monday")
    func lateWeekStart() {
        let sunday = start.adding(days: 6)
        let plan = service.generatePlan(profile: makeProfile(runDays: [0, 2, 4]), startDate: sunday)
        #expect(plan.startDate == start.adding(weeks: 1))
        #expect(weeks(in: plan).first.map { runs(in: $0).count } == 3)
    }

    @Test("One strength session a week, on a day off running, only when equipment is chosen")
    func strength() {
        let withKit = service.generatePlan(profile: makeProfile(equipment: [.bodyweight]), startDate: start)
        for week in weeks(in: withKit) {
            let strength = (week.workouts ?? []).filter { $0.workoutType == .strength }
            #expect(strength.count == 1)
            let runDays = Set(runs(in: week).map { $0.scheduledDate.startOfDay })
            #expect(strength.allSatisfy { !runDays.contains($0.scheduledDate.startOfDay) })
            #expect(strength.allSatisfy { $0.strengthPlan != nil })
        }

        let without = service.generatePlan(profile: makeProfile(equipment: []), startDate: start)
        #expect(weeks(in: without).allSatisfy { ($0.workouts ?? []).allSatisfy { $0.workoutType != .strength } })
    }

    @Test("Strength avoids the day before a run when the week allows")
    func strengthDay() {
        // Mon/Wed/Fri runs: Saturday is the only day off that isn't the eve of a run.
        #expect(StartRunningPlanService.strengthOffset(runOffsets: [0, 2, 4]) == 5)
        #expect(StartRunningPlanService.strengthOffset(runOffsets: [1, 3, 5]) == 6)
    }

    // MARK: - Reading the plan back

    @Test("Guidance reads this week's stage, and the first stage before the plan starts")
    func guidance() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start, firstStage: 4)
        let before = try #require(StartRunningPlanService.guidance(for: plan, now: start.adding(days: -2)))
        #expect(before.stage.number == 4)

        let thirdWeek = try #require(StartRunningPlanService.guidance(for: plan, now: start.adding(weeks: 2).adding(days: 1)))
        #expect(thirdWeek.stage.number == 6)

        let afterEnd = try #require(StartRunningPlanService.guidance(for: plan, now: plan.endDate.adding(weeks: 3)))
        #expect(afterEnd.stage.isGraduation)
    }

    @Test("A rebuild picks up at the last stage the runner ran, not past it")
    func resumeStage() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        #expect(StartRunningPlanService.resumeStage(for: plan) == 1, "nothing run yet: the plan's first stage")

        let fourthWeek = try #require(weeks(in: plan).first { $0.weekNumber == 4 })
        let ran = try #require(runs(in: fourthWeek).first)
        ran.isCompleted = true
        #expect(StartRunningPlanService.resumeStage(for: plan) == 4)

        let rebuilt = service.generatePlan(
            profile: makeProfile(),
            startDate: start,
            firstStage: StartRunningPlanService.resumeStage(for: plan)
        )
        #expect(weeks(in: rebuilt).count == 7)
    }

    // MARK: - Nothing else may rewrite it

    @Test("The AI coach is offered no workouts from a Start Running plan")
    func coachCannotAdapt() {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        #expect(AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: start).isEmpty)
        #expect(AdaptableWorkoutSelector.nextAdaptableWorkout(in: plan, now: start) == nil)

        // The same sessions on a standard plan are candidates, so the guard is what
        // empties the list, not the sessions themselves.
        plan.planKind = .standard
        #expect(!AdaptableWorkoutSelector.adaptableWorkouts(in: plan, now: start).isEmpty)
    }

    @Test("refreshPaces leaves a Start Running plan alone")
    func refreshPacesSkips() {
        let profile = makeProfile(estimated5K: 30 * 60)
        let plan = service.generatePlan(profile: profile, startDate: start)
        let before = weeks(in: plan).flatMap { $0.workouts ?? [] }.map { ($0.targetPaceLowerBound, $0.notes, $0.workoutStructure) }

        TrainingPlanService().refreshPaces(plan: plan, history: [], profile: profile)

        let after = weeks(in: plan).flatMap { $0.workouts ?? [] }.map { ($0.targetPaceLowerBound, $0.notes, $0.workoutStructure) }
        #expect(before.count == after.count)
        for (lhs, rhs) in zip(before, after) {
            #expect(lhs.0 == nil && rhs.0 == nil, "refreshPaces wrote a pace band onto a Start Running session")
            #expect(lhs.1 == rhs.1, "refreshPaces rewrote a Start Running session's note")
            #expect(lhs.2 == rhs.2, "refreshPaces rewrote a Start Running session's run/walk set")
        }
    }

    @MainActor
    @Test("The heat sheet never offers to trim a Start Running session")
    func noHeatAdvisory() throws {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        plan.isActive = true
        // Wednesday's session, so the evening before is a Tuesday: the advisory's
        // "tomorrow" is midnight plus 24 hours, which a clock change on a Sunday would move.
        let session = try #require(runs(in: plan).dropFirst().first)
        let eve = session.scheduledDate.adding(days: -1).addingTimeInterval(12 * 3_600)
        #expect(HeatAdvisoryService.sessionNeedingAdvisory(in: plan, now: eve) == nil)

        plan.planKind = .standard
        #expect(HeatAdvisoryService.sessionNeedingAdvisory(in: plan, now: eve) != nil)
    }

    // MARK: - Plan kind

    @Test("Time-based kinds are kept off pace machinery and races")
    func planKindRules() {
        #expect(!PlanKind.standard.prescribesByTime)
        #expect(PlanKind.pregnancy.prescribesByTime)
        #expect(PlanKind.startRunning.prescribesByTime)
        #expect(PlanKind.standard.hasGoalRace)
        #expect(!PlanKind.pregnancy.hasGoalRace)
        #expect(!PlanKind.startRunning.hasGoalRace)
    }

    @Test("A plan is named by its kind unless it has a race name")
    func displayTitle() {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        #expect(plan.displayTitle == PlanKind.startRunning.localizedName)

        let race = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            raceName: "Parkrun",
            startDate: start,
            endDate: start.adding(weeks: 8)
        )
        #expect(race.displayTitle == "Parkrun")
        race.raceName = "  "
        #expect(race.displayTitle == RaceType.fiveK.localizedName)
    }

    @Test("A plan kind this build doesn't know reads back as a standard plan")
    func unknownKindDegrades() {
        let plan = service.generatePlan(profile: makeProfile(), startDate: start)
        plan.planKindRaw = "somethingNewer"
        #expect(plan.planKind == .standard)
        plan.planKindRaw = "startRunning"
        #expect(plan.planKind == .startRunning)
    }
}
