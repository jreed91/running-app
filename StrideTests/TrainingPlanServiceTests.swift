import Testing
import Foundation
@testable import Stride

struct TrainingPlanServiceTests {

    private let service = TrainingPlanService()

    private func weeks(in plan: TrainingPlan) -> [TrainingWeek] {
        (plan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
    }

    private func workouts(in week: TrainingWeek) -> [ScheduledWorkout] {
        (week.workouts ?? []).sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func workouts(in plan: TrainingPlan) -> [ScheduledWorkout] {
        weeks(in: plan).flatMap { workouts(in: $0) }
    }

    private func makeProfile(
        race: RaceType = .fiveK,
        fitnessLevel: FitnessLevel = .intermediate,
        runDays: Int = 4,
        time5KSeconds: Double? = 25 * 60
    ) -> UserProfile {
        UserProfile(
            name: "Test Runner",
            goalRace: race,
            goalFinishTime: 22 * 60,
            weeklyRunDays: runDays,
            fitnessLevel: fitnessLevel,
            currentEstimated5KTimeSeconds: time5KSeconds
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    // MARK: Plan structure

    @Test("Generated plan has the requested number of weeks")
    func planWeekCount() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        #expect(weeks(in: plan).count == 10)
    }

    @Test("Each week has at least one workout")
    func weeksHaveWorkouts() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in weeks(in: plan) {
            #expect(!workouts(in: week).isEmpty, "Week \(week.weekNumber) has no workouts")
        }
    }

    @Test("Plan ends with a taper phase")
    func planEndsTaper() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        #expect(weeks(in: plan).last?.phase == .taper)
    }

    @Test("Each week contains a long run")
    func weeksContainLongRun() {
        let profile = makeProfile(runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in weeks(in: plan) {
            let hasLongRun = workouts(in: week).contains { $0.workoutType == .longRun }
            #expect(hasLongRun, "Week \(week.weekNumber) missing long run")
        }
    }

    // MARK: Run-day spread

    @Test("Workouts are spread across the correct number of days")
    func workoutCount() {
        let profile = makeProfile(runDays: 3)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in weeks(in: plan) {
            let weekWorkouts = workouts(in: week)
            #expect(weekWorkouts.count == 3, "Week \(week.weekNumber): expected 3 workouts, got \(weekWorkouts.count)")
        }
    }

    // MARK: Race-specific intervals

    @Test("5K plan contains interval sessions")
    func fiveKPlanHasIntervals() {
        let profile = makeProfile(race: .fiveK, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        let hasIntervals = workouts(in: plan).contains { $0.workoutType == .interval }
        #expect(hasIntervals)
    }

    @Test("Half marathon plan contains tempo sessions")
    func halfMarathonPlanHasTempo() {
        let profile = makeProfile(race: .halfMarathon, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 14)
        let hasTempo = workouts(in: plan).contains { $0.workoutType == .tempo }
        #expect(hasTempo)
    }

    @Test("Maintain fitness plan supports non-race training blocks")
    func maintainFitnessPlanHasBalancedWork() {
        let profile = makeProfile(race: .maintainFitness, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        let planWorkouts = workouts(in: plan)
        #expect(planWorkouts.contains { $0.workoutType == .tempo })
        #expect(planWorkouts.contains { $0.workoutType == .longRun })
        #expect(plan.raceName == nil)
        #expect(plan.raceDate == nil)
    }

    @Test("Race plan ends on the selected race date")
    func racePlanEndDateMatchesRaceDate() {
        let profile = makeProfile(race: .halfMarathon, runDays: 4)
        let raceDate = date(2026, 4, 19)
        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 1, 5),
            raceDate: raceDate,
            raceName: "Austin Half",
            runDayIndices: [0, 2, 4, 5]
        )

        #expect(Calendar.current.isDate(plan.endDate, inSameDayAs: raceDate))
        #expect(Calendar.current.isDate(plan.raceDate ?? .distantPast, inSameDayAs: raceDate))
        #expect(plan.raceName == "Austin Half")
    }

    @Test("Race plan schedules final race workout on exact race day")
    func racePlanFinalWorkoutIsRaceDay() {
        let profile = makeProfile(race: .marathon, runDays: 4)
        let raceDate = date(2026, 10, 11)
        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 6, 15),
            raceDate: raceDate,
            raceName: "Chicago Marathon",
            runDayIndices: [0, 2, 4, 5]
        )
        let finalWorkout = workouts(in: plan).last

        #expect(finalWorkout?.workoutType == .race)
        #expect(finalWorkout.map { Calendar.current.isDate($0.scheduledDate, inSameDayAs: raceDate) } == true)
    }

    @Test("Very short race horizons never crash and still end in a taper", arguments: [1, 2, 3, 4, 5])
    func shortRacePlanDoesNotCrash(weeksOut: Int) {
        for race in [RaceType.fiveK, .halfMarathon, .marathon] {
            let profile = makeProfile(race: race, runDays: 4)
            let start = date(2026, 7, 6)
            let plan = service.generateRacePlan(
                profile: profile,
                startDate: start,
                raceDate: start.adding(weeks: weeksOut - 1).adding(days: 6),
                raceName: "Short Notice Race",
                runDayIndices: [0, 2, 4, 5]
            )
            #expect(weeks(in: plan).count == weeksOut, "\(race) at \(weeksOut) weeks")
            #expect(weeks(in: plan).last?.phase == .taper, "\(race) at \(weeksOut) weeks should end in taper")
        }
    }

    @Test("A race date in the past falls back to a single-week plan instead of crashing")
    func pastRaceDateDoesNotCrash() {
        let profile = makeProfile(race: .marathon, runDays: 4)
        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 7, 6),
            raceDate: date(2026, 6, 1),
            raceName: "Already Ran It",
            runDayIndices: [0, 2, 4, 5]
        )
        #expect(weeks(in: plan).count == 1)
    }

    @Test("Race plan schedules race day even when weekday is not selected")
    func racePlanAllowsRaceDayOutsideTrainingDays() {
        let profile = makeProfile(race: .fiveK, runDays: 2)
        let raceDate = date(2026, 2, 18) // Wednesday
        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 1, 5),
            raceDate: raceDate,
            raceName: "Midweek 5K",
            runDayIndices: [0, 4]
        )

        let raceWorkout = workouts(in: plan).first {
            $0.workoutType == .race && Calendar.current.isDate($0.scheduledDate, inSameDayAs: raceDate)
        }
        #expect(raceWorkout != nil)
    }

    @Test("Race workout target distance matches selected race")
    func raceWorkoutDistanceMatchesRaceType() {
        let profile = makeProfile(race: .halfMarathon, runDays: 4)
        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 1, 5),
            raceDate: date(2026, 4, 19),
            raceName: "Austin Half",
            runDayIndices: [0, 2, 4, 5]
        )
        let raceWorkout = workouts(in: plan).first { $0.workoutType == .race }

        #expect(raceWorkout?.targetDistanceMeters == RaceType.halfMarathon.distanceMeters)
    }

    // MARK: Custom distance

    @Test("Custom distance maps to the nearest training archetype")
    func customDistanceTrainingStyle() {
        #expect(RaceType.custom.trainingStyle(forDistanceMeters: 5_000) == .fiveK)
        #expect(RaceType.custom.trainingStyle(forDistanceMeters: 10_000) == .halfMarathon)
        #expect(RaceType.custom.trainingStyle(forDistanceMeters: 21_097.5) == .halfMarathon)
        #expect(RaceType.custom.trainingStyle(forDistanceMeters: 42_195) == .marathon)
        // Standard race types always resolve to themselves.
        #expect(RaceType.fiveK.trainingStyle(forDistanceMeters: 99_999) == .fiveK)
    }

    @Test("Custom race plan targets the user-defined distance on race day")
    func customRacePlanUsesCustomDistance() {
        let customMeters = 10_000.0
        let profile = makeProfile(race: .custom, runDays: 4)
        profile.customDistanceMeters = customMeters

        let plan = service.generateRacePlan(
            profile: profile,
            startDate: date(2026, 1, 5),
            raceDate: date(2026, 3, 22),
            raceName: "City 10K",
            runDayIndices: [0, 2, 4, 5]
        )

        #expect(plan.targetRace == .custom)
        #expect(plan.customDistanceMeters == customMeters)
        #expect(plan.effectiveRaceDistanceMeters == customMeters)

        let raceWorkout = workouts(in: plan).first { $0.workoutType == .race }
        #expect(raceWorkout?.targetDistanceMeters == customMeters)
        #expect(raceWorkout?.notes?.contains("City 10K") == true)
    }

    @Test("Custom plan still produces a periodised plan with quality work")
    func customPlanHasQualitySessions() {
        let profile = makeProfile(race: .custom, runDays: 5)
        profile.customDistanceMeters = 12_000

        let plan = service.generatePlan(
            profile: profile,
            startDate: .now,
            numberOfWeeks: 12,
            runDayIndices: [0, 1, 2, 4, 5]
        )

        #expect(weeks(in: plan).count == 12)
        let hasQuality = workouts(in: plan).contains { $0.workoutType.isQualitySession }
        #expect(hasQuality, "Custom-distance plan should include quality sessions")
        #expect(weeks(in: plan).last?.phase == .taper)
    }

    // MARK: Easy run distribution

    @Test("Easy run count per week matches expected value for any run-day configuration")
    func easyRunCountByDayCount() {
        // (runDays, numberOfWeeks, phaseFilter, expectedEasyRunsPerWeek)
        // base phase has 1 quality type; build phase has 2 quality types
        // swiftlint:disable:next large_tuple
        let cases: [(runDays: Int, weeks: Int, phase: TrainingPhase, expectedEasy: Int)] = [
            (3, 4, .base,  1),  // quality + easy + long
            (3, 8, .build, 1),  // quality + easy + long (quality capped for sustainability)
            (4, 4, .base,  2),  // quality + easy + easy + long
            (4, 8, .build, 1),  // quality + quality + easy + long
            (5, 4, .base,  3),  // quality + easy × 3 + long
            (5, 8, .build, 2),  // quality × 2 + easy × 2 + long
        ]
        for c in cases {
            let profile = makeProfile(race: .fiveK, runDays: c.runDays)
            let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: c.weeks)
            let targetWeeks = weeks(in: plan).filter { $0.phase == c.phase }
            guard !targetWeeks.isEmpty else { continue }
            for week in targetWeeks {
                let easyCount = workouts(in: week).filter { $0.workoutType == .easy }.count
                #expect(
                    easyCount == c.expectedEasy,
                    "\(c.runDays)-day \(c.phase) week: expected \(c.expectedEasy) easy run(s), got \(easyCount)"
                )
            }
        }
    }

    @Test("3-day weeks never schedule more than one quality session")
    func threeDayWeeksCapQualitySessions() {
        let profile = makeProfile(race: .fiveK, runDays: 3)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        for week in weeks(in: plan) {
            let qualityCount = workouts(in: week).filter(\.workoutType.isQualitySession).count
            #expect(qualityCount <= 1, "Week \(week.weekNumber) has \(qualityCount) quality sessions")
        }
    }

    @Test("When 5K estimate is missing, goal time still influences derived paces")
    func goalTimeInfluencesPaceFallback() {
        let conservative = UserProfile(
            name: "Conservative Goal",
            goalRace: .halfMarathon,
            goalFinishTime: 140 * 60,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: nil
        )
        let aggressive = UserProfile(
            name: "Aggressive Goal",
            goalRace: .halfMarathon,
            goalFinishTime: 110 * 60,
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            currentEstimated5KTimeSeconds: nil
        )

        let slowPlan = service.generatePlan(profile: conservative, startDate: .now, numberOfWeeks: 12)
        let fastPlan = service.generatePlan(profile: aggressive, startDate: .now, numberOfWeeks: 12)

        let slowTempo = workouts(in: slowPlan)
            .first(where: { $0.workoutType == .tempo })?
            .targetPaceLowerBound
        let fastTempo = workouts(in: fastPlan)
            .first(where: { $0.workoutType == .tempo })?
            .targetPaceLowerBound

        guard let slowTempo, let fastTempo else {
            Issue.record("Could not find comparable tempo workouts")
            return
        }
        #expect(fastTempo < slowTempo, "Faster goal should produce faster tempo target pace")
    }

    @Test("Easy runs in the same week have equal target distances for 3–6 run days")
    func easyRunDistancesAreBalanced() {
        for runDays in 3...6 {
            let profile = makeProfile(race: .halfMarathon, runDays: runDays)
            let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
            for week in weeks(in: plan) {
                let dists = workouts(in: week)
                    .filter { $0.workoutType == .easy }
                    .compactMap { $0.targetDistanceMeters }
                guard dists.count >= 2 else { continue }
                let first = dists[0]
                for dist in dists.dropFirst() {
                    #expect(
                        abs(dist - first) < 1,
                        "\(runDays)-day week: easy run distances unequal — \(dists)"
                    )
                }
            }
        }
    }

    @Test("refreshPaces tightens pace targets when runner's profile improves")
    func refreshPacesUpdatesPaceTargets() {
        let slowProfile = makeProfile(race: .fiveK, runDays: 4, time5KSeconds: 25 * 60)
        let plan = service.generatePlan(profile: slowProfile, startDate: .now, numberOfWeeks: 8)

        let originalTempo = workouts(in: plan)
            .first(where: { $0.workoutType == .tempo })?
            .targetPaceLowerBound

        // Refresh with a faster-runner profile (20-min 5K → higher VDOT → faster paces)
        let fastProfile = makeProfile(race: .fiveK, runDays: 4, time5KSeconds: 20 * 60)
        service.refreshPaces(plan: plan, history: [], profile: fastProfile)

        let updatedTempo = workouts(in: plan)
            .first(where: { $0.workoutType == .tempo && !$0.isCompleted })?
            .targetPaceLowerBound

        guard let old = originalTempo, let new = updatedTempo else {
            Issue.record("Could not find a tempo workout in the plan"); return
        }
        #expect(new < old, "Faster profile should yield a lower (faster) tempo pace lower bound")
    }

    // MARK: Target distance

    @Test("Target distance decreases in taper week vs peak week")
    func taperReducesVolume() {
        let profile = makeProfile(runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        let peakWeeks = weeks(in: plan).filter { $0.phase == .peak }
        let taperWeeks = weeks(in: plan).filter { $0.phase == .taper }
        guard let peakKm = peakWeeks.first?.targetDistanceKm,
              let taperKm = taperWeeks.first?.targetDistanceKm else {
            Issue.record("Missing peak or taper week")
            return
        }
        #expect(taperKm < peakKm, "Taper (\(taperKm) km) should be less than peak (\(peakKm) km)")
    }

    // MARK: Progressive overload & cutbacks (M28)

    @Test("Cutback weeks reduce volume below the surrounding progression")
    func cutbackWeeksReduceVolume() {
        let profile = makeProfile(race: .fiveK, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 12)
        let ws = weeks(in: plan)
        func km(_ weekNumber: Int) -> Double { ws[weekNumber - 1].targetDistanceKm }

        // Progressive overload: volume rises across the first three weeks.
        #expect(km(1) < km(2), "Week 1 (\(km(1))) should be below week 2 (\(km(2)))")
        #expect(km(2) < km(3), "Week 2 (\(km(2))) should be below week 3 (\(km(3)))")
        // Week 4 is a cutback: meaningfully below week 3, not equal to it (the old bug
        // made the cutback multiplier identical to the preceding week).
        #expect(km(4) < km(3) * 0.95, "Week 4 cutback (\(km(4))) not below week 3 (\(km(3)))")
        // Volume rebounds after the cutback.
        #expect(km(5) > km(4), "Week 5 (\(km(5))) should rebound above week 4 cutback (\(km(4)))")
        // The second cutback (week 8) also dips below its neighbour.
        #expect(km(8) < km(7) * 0.95, "Week 8 cutback (\(km(8))) not below week 7 (\(km(7)))")
    }

    @Test("Base/build volume progresses instead of flatlining")
    func volumeProgressesNotFlat() {
        let profile = makeProfile(race: .fiveK, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 12)
        let ws = weeks(in: plan)

        // The old clamp made every week from index 4 onward exactly 1.45×base — a flat
        // line. Peak volume must exceed the opening base week.
        let peakKm = ws.first { $0.phase == .peak }?.targetDistanceKm ?? 0
        #expect(peakKm > ws[0].targetDistanceKm, "Peak (\(peakKm)) not above opening week (\(ws[0].targetDistanceKm))")

        // Non-cutback base/build weeks should take on more than one distinct value.
        let baseBuildKm = ws
            .filter { $0.phase == .base || $0.phase == .build }
            .map { Int($0.targetDistanceKm.rounded()) }
        #expect(Set(baseBuildKm).count > 1, "Base/build volume is flat: \(baseBuildKm)")
    }

    // MARK: Current-week boundary (H6)

    @Test("currentWeek includes the final calendar day of the week")
    func currentWeekIncludesFinalDay() {
        // A week whose last calendar day is today: startDate = today − 6 days, so the
        // stored endDate is today at 00:00. The pre-fix `endDate >= Date()` comparison
        // excluded the entire final day (most visibly Sunday, the long-run day).
        let start = Date().startOfDay.adding(days: -6)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.adding(days: 6)
        )
        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 20)
        plan.weeks = [week]

        #expect(plan.currentWeek === week, "currentWeek should resolve on the final day of the week")
    }

    @Test("currentWeek is nil once the week has fully elapsed")
    func currentWeekNilAfterWeekEnds() {
        // A week that ended yesterday: startDate = today − 7 days.
        let start = Date().startOfDay.adding(days: -7)
        let plan = TrainingPlan(
            targetRace: .fiveK,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.adding(days: 6)
        )
        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 20)
        plan.weeks = [week]

        #expect(plan.currentWeek == nil)
    }

    // MARK: Volume conservation & run-day changes (M29–M32)

    @Test("Weekly running volume is conserved for 1 and 2 run-day weeks (M32)", arguments: [1, 2])
    func volumeConservedForFewRunDays(runDays: Int) {
        let profile = makeProfile(race: .maintainFitness, runDays: runDays)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in weeks(in: plan) {
            let scheduledKm = workouts(in: week)
                .filter { $0.workoutType.isRunType }
                .reduce(0.0) { $0 + ($1.targetDistanceMeters ?? 0) / 1_000 }
            let tolerance = max(0.5, week.targetDistanceKm * 0.02)
            #expect(
                abs(scheduledKm - week.targetDistanceKm) < tolerance,
                "Week \(week.weekNumber) (\(runDays)d): scheduled \(scheduledKm) km vs target \(week.targetDistanceKm) km"
            )
        }
    }

    @Test("Reducing run days preserves the long run and drops easy runs first (M29)")
    func reducingRunDaysKeepsLongRun() {
        // Future start so every workout is in the future and eligible to be re-slotted.
        let start = Date().startOfDay.adding(days: 14)
        let profile = makeProfile(race: .maintainFitness, runDays: 5)
        let plan = service.generatePlan(
            profile: profile,
            startDate: start,
            numberOfWeeks: 6,
            runDayIndices: [0, 1, 2, 3, 5]
        )

        let toDelete = service.applyNewRunDays(to: plan, newDayIndices: [0, 2, 4], profile: profile)

        #expect(!toDelete.isEmpty, "Reducing 5 run days to 3 should surface excess workouts")
        #expect(
            !toDelete.contains { $0.workoutType == .longRun },
            "The long run must never be deleted when reducing run days"
        )
        #expect(
            toDelete.allSatisfy { $0.workoutType == .easy },
            "Only easy runs should be dropped; dropped types: \(toDelete.map(\.workoutType))"
        )
        // Every affected future week must still carry exactly one (kept) long run.
        for week in weeks(in: plan) {
            let deletedIDs = Set(toDelete.map(\.id))
            let survivingLongRuns = workouts(in: week)
                .filter { $0.workoutType == .longRun && !deletedIDs.contains($0.id) }
            #expect(survivingLongRuns.count == 1, "Week \(week.weekNumber) should keep its long run")
        }
    }

    @Test("Adding run days sizes stub runs against outstanding volume, not the whole week (M30)")
    func addingRunDaysAccountsForCompletedVolume() {
        let start = Date().startOfDay.adding(days: 14)
        let plan = TrainingPlan(
            targetRace: .maintainFitness,
            goalTimeSeconds: 1_500,
            startDate: start,
            endDate: start.adding(days: 42)
        )
        let week = TrainingWeek(weekNumber: 1, startDate: start, phase: .base, targetDistanceKm: 40)
        // 25 km already run this week, 5 km still on the schedule for a future day.
        let done = ScheduledWorkout(scheduledDate: start, workoutType: .easy, targetDistanceMeters: 25_000)
        done.isCompleted = true
        let remaining = ScheduledWorkout(scheduledDate: start.adding(days: 1), workoutType: .easy, targetDistanceMeters: 5_000)
        week.workouts = [done, remaining]
        plan.weeks = [week]

        // Grow to three run days; two stub runs are created for the extra slots.
        _ = service.applyNewRunDays(to: plan, newDayIndices: [1, 2, 3], profile: nil)

        let totalKm = (week.workouts ?? [])
            .filter { $0.workoutType.isRunType }
            .reduce(0.0) { $0 + ($1.targetDistanceMeters ?? 0) / 1_000 }
        // Outstanding volume was only 10 km, so the week should still total ~40 km,
        // not balloon past it as it did when completed volume was ignored.
        #expect(abs(totalKm - 40) < 0.5, "Week totalled \(totalKm) km; expected ~40 km")
    }

    @Test("Race-week strength is never scheduled on or after race day (M31)")
    func noStrengthAfterRaceDay() {
        let profile = makeProfile(race: .halfMarathon, runDays: 4)
        profile.selectedEquipment = [.bodyweight]
        profile.strengthFocus = .runningSpecific
        let start = Date().startOfWeek.adding(weeks: 1)       // a future Monday
        let raceDate = start.adding(weeks: 5).adding(days: 2) // Wednesday of the final week

        let plan = service.generateRacePlan(
            profile: profile,
            startDate: start,
            raceDate: raceDate,
            raceName: "Test Half"
        )

        let all = workouts(in: plan)
        guard let race = all.first(where: { $0.workoutType == .race }) else {
            Issue.record("Race plan has no race workout")
            return
        }
        #expect(all.contains { $0.workoutType == .strength }, "Equipment set but no strength scheduled")
        let raceDay = Calendar.current.startOfDay(for: race.scheduledDate)
        let offending = all.filter {
            $0.workoutType == .strength
                && Calendar.current.startOfDay(for: $0.scheduledDate) >= raceDay
        }
        #expect(offending.isEmpty, "Strength scheduled on/after race day: \(offending.map(\.scheduledDate))")
    }

    @Test("Every non-rest, non-race workout has a warm-up defined")
    func allWorkoutsHaveWarmup() {
        let profile = makeProfile(race: .halfMarathon, runDays: 5)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 12)
        for workout in workouts(in: plan) {
            guard workout.workoutType != .rest,
                  workout.workoutType != .race,
                  workout.workoutType != .crossTraining else { continue }
            guard let structure = workout.workoutStructure else {
                Issue.record("\(workout.workoutType) on \(workout.scheduledDate) has no WorkoutStructure")
                continue
            }
            let warmup = structure.warmup
            let hasLength = (warmup.distanceMeters ?? 0) > 0 || (warmup.durationSeconds ?? 0) > 0
            #expect(hasLength, "\(workout.workoutType) warm-up has neither distance nor duration defined")
        }
    }
}
