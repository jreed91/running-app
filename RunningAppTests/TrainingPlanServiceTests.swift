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
