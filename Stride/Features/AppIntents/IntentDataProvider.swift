import Foundation
import SwiftData

// Sendable value types extracted from SwiftData models so they can cross
// actor boundaries safely inside intent perform() methods.

struct TodaysRunData: Sendable {
    let workoutType: WorkoutType
    let distanceMeters: Double?
    let notes: String?
}

struct WeeklySummaryData: Sendable {
    let totalMeters: Double
}

// MARK: - Container factory

enum IntentDataProvider {
    /// Opens the same on-disk store that AppContainer uses, without CloudKit
    /// sync overhead. Safe for read-only intent access alongside the main container.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            UserProfile.self,
            RunWorkout.self,
            TrainingPlan.self,
            TrainingWeek.self,
            ScheduledWorkout.self,
            SavedRoute.self,
        ])
        let storeURL = URL.applicationSupportDirectory.appending(path: "Stride.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }
}

// MARK: - ModelActor for background reads

@ModelActor
actor IntentModelActor {

    func todaysRun() throws -> TodaysRunData? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { return nil }
        let predicate = #Predicate<ScheduledWorkout> {
            $0.scheduledDate >= today && $0.scheduledDate < tomorrow && !$0.isCompleted
        }
        var descriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.scheduledDate)]
        )
        descriptor.fetchLimit = 10
        let workouts = try modelContext.fetch(descriptor)
        guard let w = workouts.first(where: { $0.workoutType != .rest }) else { return nil }
        return TodaysRunData(
            workoutType: w.workoutType,
            distanceMeters: w.targetDistanceMeters,
            notes: w.notes
        )
    }

    func weeklySummary() throws -> WeeklySummaryData {
        let cal = Calendar.current
        let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let startOfWeek = cal.date(from: components) ?? Date()
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: startOfWeek) ?? Date()
        let predicate = #Predicate<RunWorkout> {
            $0.date >= startOfWeek && $0.date < endOfWeek
        }
        let workouts = try modelContext.fetch(FetchDescriptor<RunWorkout>(predicate: predicate))
        return WeeklySummaryData(totalMeters: workouts.reduce(0.0) { $0 + $1.distanceMeters })
    }
}
