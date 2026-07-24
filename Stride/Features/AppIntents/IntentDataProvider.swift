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
    /// Uses `StrideSchema` so the schema can never drift from the app's.
    static func makeContainer() throws -> ModelContainer {
        let schema = StrideSchema.make()
        let config = ModelConfiguration(schema: schema, url: StrideSchema.storeURL)
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
        // Only the active plan can answer "what am I running today". Retired plans keep
        // their future days (they are preserved as history, not deleted), so without
        // this filter Siri could read out a workout from a plan the runner replaced.
        // A workout with no plan at all is legacy data and stays eligible.
        let live = workouts.filter { workout in
            guard let plan = workout.week?.plan else { return true }
            return plan.isActive
        }
        // Prefer an actual run; fall back to any other session (strength, cross-training)
        // so a gym day still answers rather than reporting nothing scheduled.
        guard let w = live.first(where: { $0.workoutType.isRunType })
            ?? live.first(where: { $0.workoutType != .rest }) else { return nil }
        return TodaysRunData(
            workoutType: w.workoutType,
            distanceMeters: w.targetDistanceMeters,
            notes: w.notes
        )
    }

    // MARK: - RunWorkoutEntity fetches (Siri / Spotlight / Apple Intelligence)

    func recentRunEntities(limit: Int, unit: UnitPreference) throws -> [RunWorkoutEntity] {
        var descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { $0.runWorkoutEntity(unit: unit) }
    }

    func runEntities(ids: [UUID], unit: UnitPreference) throws -> [RunWorkoutEntity] {
        guard !ids.isEmpty else { return [] }
        let identifiers = ids
        let predicate = #Predicate<RunWorkout> { identifiers.contains($0.id) }
        let descriptor = FetchDescriptor<RunWorkout>(predicate: predicate)
        return try modelContext.fetch(descriptor).map { $0.runWorkoutEntity(unit: unit) }
    }

    func runEntities(matching query: String, unit: UnitPreference) throws -> [RunWorkoutEntity] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return try modelContext.fetch(descriptor).compactMap { run in
            let entity = run.runWorkoutEntity(unit: unit)
            guard needle.isEmpty || entity.title.lowercased().contains(needle) else { return nil }
            return entity
        }
    }

    func weeklySummary() throws -> WeeklySummaryData {
        // Use the app-wide Monday-based week (`Date.startOfWeek`) so Siri's
        // weekly total matches the dashboard. `Calendar.current`'s default
        // `firstWeekday` (Sunday in the US) would otherwise disagree by a whole
        // run whenever the current day is a Sunday or Monday.
        let startOfWeek = Date().startOfWeek
        let endOfWeek = startOfWeek.adding(days: 7)
        let predicate = #Predicate<RunWorkout> {
            $0.date >= startOfWeek && $0.date < endOfWeek
        }
        let workouts = try modelContext.fetch(FetchDescriptor<RunWorkout>(predicate: predicate))
        return WeeklySummaryData(totalMeters: workouts.reduce(0.0) { $0 + $1.distanceMeters })
    }
}
