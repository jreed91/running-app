import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import Stride

@MainActor
struct PersistenceGraphTests {

    @Test("Repositories save and fetch persisted models from an in-memory SwiftData graph")
    func repositoriesPersistModels() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let profile = UserProfile(
            name: "Taylor",
            goalRace: .halfMarathon,
            goalFinishTime: 6_000,
            raceName: "Austin Half",
            raceDate: Date(timeIntervalSince1970: 1_785_024_000),
            weeklyRunDays: 4,
            fitnessLevel: .intermediate,
            gender: .female,
            currentEstimated5KTimeSeconds: 1_500,
            preferredRunDayIndices: [0, 2, 5]
        )
        context.insert(profile)

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: .now.startOfWeek,
            numberOfWeeks: 6,
            runDayIndices: [0, 2, 5]
        )
        plan.raceName = "Austin Half"
        plan.raceDate = profile.raceDate
        try container.planRepository.save(plan)

        let route = SavedRoute(
            name: "Lake Loop",
            routeType: .loop,
            requestedDistanceMeters: 5_000,
            actualDistanceMeters: 5_120,
            estimatedDurationSeconds: 1_650,
            startLatitude: 30.2672,
            startLongitude: -97.7431,
            coordinates: [
                Coordinate(CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)),
                Coordinate(CLLocationCoordinate2D(latitude: 30.2680, longitude: -97.7412))
            ],
            steps: [
                RouteStep(instruction: "Head north", name: "Congress Ave", distanceMeters: 500, durationSeconds: 180)
            ]
        )
        try container.routeRepository.save(route)

        let scheduled = ScheduledWorkout(
            scheduledDate: .now,
            workoutType: .tempo,
            targetDistanceMeters: 8_000,
            targetPaceLowerBound: 300,
            targetPaceUpperBound: 320,
            notes: "Steady effort"
        )
        let run = RunWorkout(
            date: .now,
            distanceMeters: 8_000,
            durationSeconds: 2_520,
            workoutType: .tempo,
            workoutLocation: .outdoor
        )
        run.splits = [
            Split(kilometer: 1, paceSecondsPerKm: 310, heartRate: 152, elevationGainMeters: 8, cumulativeDistanceMeters: 1_000),
            Split(kilometer: 2, paceSecondsPerKm: 315, heartRate: 154, elevationGainMeters: 10, cumulativeDistanceMeters: 2_000)
        ]
        run.routeCoordinates = [
            Coordinate(CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)),
            Coordinate(CLLocationCoordinate2D(latitude: 30.2680, longitude: -97.7412))
        ]
        run.scheduledWorkout = scheduled
        scheduled.completedWorkout = run
        context.insert(scheduled)
        try container.workoutRepository.save(run)

        let fetchedPlan = try #require(try container.planRepository.fetchActivePlan())
        let weeks = (fetchedPlan.weeks ?? []).sorted { $0.weekNumber < $1.weekNumber }
        let totalScheduledWorkouts = weeks.reduce(into: 0) { count, week in
            count += week.workouts?.count ?? 0
        }
        #expect(fetchedPlan.targetRace == .halfMarathon)
        #expect(fetchedPlan.raceName == "Austin Half")
        #expect(fetchedPlan.raceDate == Date(timeIntervalSince1970: 1_785_024_000))
        #expect(weeks.count == 6)
        #expect(totalScheduledWorkouts > 0)
        #expect(weeks.contains { !($0.workouts ?? []).isEmpty })

        let fetchedRoutes = try container.routeRepository.fetchAll()
        #expect(fetchedRoutes.count == 1)
        #expect(fetchedRoutes[0].routeType == .loop)
        #expect(fetchedRoutes[0].coordinates.count == 2)
        #expect(fetchedRoutes[0].steps.first?.instruction == "Head north")

        let workouts = try container.workoutRepository.fetchAll()
        let fetchedRun = try #require(workouts.first)
        #expect(fetchedRun.scheduledWorkout?.notes == "Steady effort")
        #expect(fetchedRun.splits.count == 2)
        #expect(fetchedRun.routeCoordinates.count == 2)

        let profiles = try context.fetch(FetchDescriptor<UserProfile>())
        let fetchedProfile = try #require(profiles.first)
        #expect(fetchedProfile.name == "Taylor")
        #expect(fetchedProfile.goalRace == .halfMarathon)
        #expect(fetchedProfile.raceName == "Austin Half")
        #expect(fetchedProfile.raceDate == Date(timeIntervalSince1970: 1_785_024_000))
        #expect(fetchedProfile.gender == .female)
        #expect(fetchedProfile.preferredRunDayIndices == [0, 2, 5])
    }

    @Test("Repository delete APIs remove saved plans, workouts, and routes")
    func repositoriesDeleteModels() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext

        let profile = UserProfile(
            name: "Delete Me",
            goalRace: .fiveK,
            goalFinishTime: 1_500,
            weeklyRunDays: 3,
            fitnessLevel: .beginner
        )
        context.insert(profile)

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: .now.startOfWeek,
            numberOfWeeks: 4
        )
        try container.planRepository.save(plan)

        let workout = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_600)
        try container.workoutRepository.save(workout)

        let route = SavedRoute(
            name: "Short Loop",
            routeType: .loop,
            requestedDistanceMeters: 3_000,
            actualDistanceMeters: 3_100,
            estimatedDurationSeconds: 1_100,
            startLatitude: 35,
            startLongitude: -97,
            coordinates: [Coordinate(CLLocationCoordinate2D(latitude: 35, longitude: -97))],
            steps: []
        )
        try container.routeRepository.save(route)

        try container.planRepository.delete(plan)
        try container.workoutRepository.delete(workout)
        try container.routeRepository.delete(route)

        #expect((try container.planRepository.fetchAll()).isEmpty)
        #expect((try container.workoutRepository.fetchAll()).isEmpty)
        #expect((try container.routeRepository.fetchAll()).isEmpty)
    }
}
