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
    ///
    /// `.none` is what makes the first sentence true. Omitting `cloudKitDatabase:`
    /// defaults it to `.automatic`, so each of the four intents that calls this was
    /// standing up a *second* CloudKit-mirroring container over the very store file the
    /// app already has open for mirroring — the arrangement Apple's own schema-init
    /// sample unloads its store to avoid (F1).
    static func makeContainer() throws -> ModelContainer {
        let schema = StrideSchema.make()
        let config = ModelConfiguration(
            schema: schema,
            url: StrideSchema.storeURL,
            cloudKitDatabase: .none
        )
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
        // Runs, not walks (N38). Siri and Spotlight offer these as "your runs", and the
        // limit has to count runs or a week of walking empties the list.
        return try modelContext
            .fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: limit))
            .map { $0.runWorkoutEntity(unit: unit) }
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
        return try modelContext
            .fetch(RunWorkout.runsOnlyDescriptor(fetchLimit: 50))
            .compactMap { run in
                let entity = run.runWorkoutEntity(unit: unit)
                guard needle.isEmpty || entity.title.lowercased().contains(needle) else { return nil }
                return entity
            }
    }

    /// The coach's single highest-priority card, right now.
    ///
    /// Runs `SmartCoachCards` **directly**, unlike the widget extension, which has to be
    /// handed a finished string through `WidgetSnapshot`. Intents open the same on-disk
    /// store the app does (`IntentDataProvider.makeContainer`), so the scheduled workouts,
    /// logged runs and profile the selection needs are all right here. Siri therefore
    /// answers from the same thresholds the dashboard draws, without a second opinion
    /// compiled anywhere.
    ///
    /// `SmartCoachCard` is `Sendable`, so the card crosses the actor boundary as-is and
    /// nothing has to be flattened into a transfer struct the way `TodaysRunData` is.
    func coachTip(unit: UnitPreference, now: Date = Date()) throws -> SmartCoachCard? {
        // Only the active plan can answer "what should I do next" — retired plans keep
        // their future days, the same trap `todaysRun()` guards against.
        var planDescriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        planDescriptor.fetchLimit = 1
        let plan = try modelContext.fetch(planDescriptor).first

        // Bounded like the dashboard's own query: the widest window any rule looks
        // through is 90 days of cadence, so the newest 120 runs is more than enough and
        // an unbounded fetch inside an intent is a cost paid on every invocation.
        let runs = try modelContext.fetch(RunWorkout.runsOnlyDescriptor(
            sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)],
            fetchLimit: 120
        ))

        var profileDescriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\UserProfile.updatedAt, order: .reverse)]
        )
        profileDescriptor.fetchLimit = 1
        let profile = try modelContext.fetch(profileDescriptor).first

        let context = SmartCoachCards.Context(
            nextSession: ScheduledDayResolver.upcomingSession(onOrAfter: now, in: plan),
            recentRuns: runs,
            profile: profile,
            dayState: ScheduledDayResolver.dayState(on: now, in: plan),
            unit: unit,
            now: now
        )
        return SmartCoachCards.cards(context, limit: 1).first
    }

    func weeklySummary() throws -> WeeklySummaryData {
        // Use the app-wide Monday-based week (`Date.startOfWeek`) so Siri's
        // weekly total matches the dashboard. `Calendar.current`'s default
        // `firstWeekday` (Sunday in the US) would otherwise disagree by a whole
        // run whenever the current day is a Sunday or Monday.
        let startOfWeek = Date().startOfWeek
        let endOfWeek = startOfWeek.adding(days: 7)
        // "How far have I run this week" — so walks (N38) and rides (B8) are excluded,
        // matching the same total on the dashboard and in the weekly widget.
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        let predicate = #Predicate<RunWorkout> {
            $0.date >= startOfWeek && $0.date < endOfWeek
                && $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
        }
        let workouts = try modelContext.fetch(FetchDescriptor<RunWorkout>(predicate: predicate))
        return WeeklySummaryData(totalMeters: workouts.reduce(0.0) { $0 + $1.distanceMeters })
    }
}
