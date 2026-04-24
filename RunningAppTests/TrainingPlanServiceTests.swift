import Testing
import Foundation
@testable import RunningApp

struct TrainingPlanServiceTests {

    private let service = TrainingPlanService()

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

    // MARK: Plan structure

    @Test("Generated plan has the requested number of weeks")
    func planWeekCount() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        #expect(plan.weeks.count == 10)
    }

    @Test("Each week has at least one workout")
    func weeksHaveWorkouts() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in plan.weeks {
            #expect(!week.workouts.isEmpty, "Week \(week.weekNumber) has no workouts")
        }
    }

    @Test("Plan ends with a taper phase")
    func planEndsTaper() {
        let profile = makeProfile()
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        #expect(plan.weeks.last?.phase == .taper)
    }

    @Test("Each week contains a long run")
    func weeksContainLongRun() {
        let profile = makeProfile(runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in plan.weeks {
            let hasLongRun = week.workouts.contains { $0.workoutType == .longRun }
            #expect(hasLongRun, "Week \(week.weekNumber) missing long run")
        }
    }

    // MARK: Run-day spread

    @Test("Workouts are spread across the correct number of days")
    func workoutCount() {
        let profile = makeProfile(runDays: 3)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
        for week in plan.weeks {
            #expect(week.workouts.count == 3, "Week \(week.weekNumber): expected 3 workouts, got \(week.workouts.count)")
        }
    }

    // MARK: Race-specific intervals

    @Test("5K plan contains interval sessions")
    func fiveKPlanHasIntervals() {
        let profile = makeProfile(race: .fiveK, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        let hasIntervals = plan.weeks.flatMap(\.workouts).contains { $0.workoutType == .interval }
        #expect(hasIntervals)
    }

    @Test("Half marathon plan contains tempo sessions")
    func halfMarathonPlanHasTempo() {
        let profile = makeProfile(race: .halfMarathon, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 14)
        let hasTempo = plan.weeks.flatMap(\.workouts).contains { $0.workoutType == .tempo }
        #expect(hasTempo)
    }

    @Test("Maintain fitness plan supports non-race training blocks")
    func maintainFitnessPlanHasBalancedWork() {
        let profile = makeProfile(race: .maintainFitness, runDays: 4)
        let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 10)
        let workouts = plan.weeks.flatMap(\.workouts)
        #expect(workouts.contains { $0.workoutType == .tempo })
        #expect(workouts.contains { $0.workoutType == .longRun })
    }

    // MARK: Easy run distribution

    @Test("Easy run count per week matches expected value for any run-day configuration")
    func easyRunCountByDayCount() {
        // (runDays, numberOfWeeks, phaseFilter, expectedEasyRunsPerWeek)
        // base phase has 1 quality type; build phase has 2 quality types
        let cases: [(runDays: Int, weeks: Int, phase: TrainingPhase, expectedEasy: Int)] = [
            (3, 4, .base,  1),  // quality + easy + long
            (3, 8, .build, 0),  // quality + quality + long (no easy slot)
            (4, 4, .base,  2),  // quality + easy + easy + long
            (4, 8, .build, 1),  // quality + quality + easy + long
            (5, 4, .base,  3),  // quality + easy × 3 + long
            (5, 8, .build, 2),  // quality × 2 + easy × 2 + long
        ]
        for c in cases {
            let profile = makeProfile(race: .fiveK, runDays: c.runDays)
            let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: c.weeks)
            let targetWeeks = plan.weeks.filter { $0.phase == c.phase }
            guard !targetWeeks.isEmpty else { continue }
            for week in targetWeeks {
                let easyCount = week.workouts.filter { $0.workoutType == .easy }.count
                #expect(
                    easyCount == c.expectedEasy,
                    "\(c.runDays)-day \(c.phase) week: expected \(c.expectedEasy) easy run(s), got \(easyCount)"
                )
            }
        }
    }

    @Test("Easy runs in the same week have equal target distances for 3–6 run days")
    func easyRunDistancesAreBalanced() {
        for runDays in 3...6 {
            let profile = makeProfile(race: .halfMarathon, runDays: runDays)
            let plan = service.generatePlan(profile: profile, startDate: .now, numberOfWeeks: 8)
            for week in plan.weeks {
                let dists = week.workouts
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

        let originalTempo = plan.weeks
            .flatMap { $0.workouts }
            .first(where: { $0.workoutType == .tempo })?
            .targetPaceLowerBound

        // Refresh with a faster-runner profile (20-min 5K → higher VDOT → faster paces)
        let fastProfile = makeProfile(race: .fiveK, runDays: 4, time5KSeconds: 20 * 60)
        service.refreshPaces(plan: plan, history: [], profile: fastProfile)

        let updatedTempo = plan.weeks
            .flatMap { $0.workouts }
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
        let peakWeeks = plan.weeks.filter { $0.phase == .peak }
        let taperWeeks = plan.weeks.filter { $0.phase == .taper }
        guard let peakKm = peakWeeks.first?.targetDistanceKm,
              let taperKm = taperWeeks.first?.targetDistanceKm else {
            Issue.record("Missing peak or taper week")
            return
        }
        #expect(taperKm < peakKm, "Taper (\(taperKm) km) should be less than peak (\(peakKm) km)")
    }
}
