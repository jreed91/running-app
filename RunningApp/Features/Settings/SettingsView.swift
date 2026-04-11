import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query private var profiles: [UserProfile]

    @State private var showResetConfirmation = false
    #if DEBUG
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]
    @State private var seedWeeks = 8
    @State private var completionCutoff = Date()
    #endif

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    profileSection(profile: profile)
                }
                unitsSection
                appleHealthSection
                notificationsSection
                aboutSection
                dangerSection
                #if DEBUG
                developerSection
                #endif
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { resetAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, all workouts, and training plans.")
            }
        }
    }

    // MARK: Sections

    private func profileSection(profile: UserProfile) -> some View {
        Section("Runner Profile") {
            LabeledContent("Name", value: profile.name)
            LabeledContent("Goal Race", value: profile.goalRace.displayName)
            LabeledContent("Fitness Level", value: profile.fitnessLevel.displayName)
            LabeledContent("Run Days / Week", value: "\(profile.weeklyRunDays)")
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Distance", selection: Bindable(appSettings).unitPreference) {
                ForEach(UnitPreference.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var appleHealthSection: some View {
        Section("Apple Health") {
            NavigationLink("Import Older Workouts") {
                HealthKitImportView()
            }
        } footer: {
            Text("Recent runs from the Workout and Fitness apps sync automatically when you open History.")
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            NavigationLink("Workout Reminders") {
                Text("Notification preferences coming soon.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return Section("About") {
            LabeledContent("Version", value: version)
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Reset All Data", role: .destructive) {
                showResetConfirmation = true
            }
        }
    }

    // MARK: Developer section (DEBUG only)

    #if DEBUG
    private var developerSection: some View {
        let plan = activePlans.first
        return Group {
            Section {
                Stepper("\(seedWeeks) weeks of history", value: $seedWeeks, in: 2...24)
                Button("Seed Run History") {
                    DebugRunGenerator.seed(weeks: seedWeeks, context: context)
                }
                Button("Clear Seeded Runs", role: .destructive) {
                    DebugRunGenerator.clear(context: context)
                }
            } header: {
                Text("Developer – Run History")
            } footer: {
                Text("Inserts fake RunWorkout entries tagged for easy removal.")
            }

            Section {
                if let plan {
                    DatePicker(
                        "Complete through",
                        selection: $completionCutoff,
                        in: plan.startDate...plan.endDate,
                        displayedComponents: .date
                    )
                    Button("Mark Workouts Complete") {
                        DebugRunGenerator.completePlan(
                            upTo: completionCutoff, plan: plan, context: context
                        )
                    }
                    Button("Reset Debug Completions", role: .destructive) {
                        DebugRunGenerator.resetPlanProgress(plan: plan, context: context)
                    }
                } else {
                    Text("No active training plan.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Developer – Plan Progress")
            } footer: {
                Text("Creates matching RunWorkouts for each scheduled workout up to the chosen date. Only debug-tagged completions are removed on reset.")
            }
        }
    }
    #endif

    // MARK: Actions

    private func resetAll() {
        try? context.delete(model: RunWorkout.self)
        try? context.delete(model: TrainingPlan.self)
        try? context.delete(model: UserProfile.self)
        try? context.save()
    }
}

// MARK: - DebugRunGenerator

#if DEBUG
/// Generates realistic fake ``RunWorkout`` entries for use during development.
///
/// All seeded workouts are tagged `notes == DebugRunGenerator.tag` so they can
/// be identified and removed without touching real data.
enum DebugRunGenerator {

    static let tag = "debug_seeded"

    // MARK: Public API

    /// Inserts `weeks` worth of fake runs into `context`.
    ///
    /// Three runs per week (easy / tempo / long-run), with paces and volumes
    /// that improve slightly over time and a cutback every fourth week.
    static func seed(weeks: Int, context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())

        for weekOffset in 0..<weeks {
            // weekOffset 0 = most recent past week; higher = older
            guard let anchor = Calendar.current.date(
                byAdding: .weekOfYear, value: -(weekOffset + 1), to: today
            ) else { continue }
            let weekStart = anchor.startOfWeek

            // Oldest runs = lower volume/fitness; most recent = higher
            let progressFactor = Double(weeks - weekOffset) / Double(weeks)
            let isCutback = (weeks - weekOffset) % 4 == 0

            let slots: [(dayOffset: Int, type: WorkoutType)] = isCutback
                ? [(1, .easy), (4, .easy),  (6, .longRun)]
                : [(1, .easy), (3, .tempo), (6, .longRun)]

            for slot in slots {
                let date = weekStart.adding(days: slot.dayOffset)
                guard date < today else { continue }
                context.insert(makeWorkout(date: date, type: slot.type, progressFactor: progressFactor))
            }
        }
        try? context.save()
    }

    /// Deletes all workouts previously inserted by ``seed(weeks:context:)``.
    static func clear(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<RunWorkout>()) else { return }
        all.filter { $0.notes == tag }.forEach { context.delete($0) }
        try? context.save()
    }

    // MARK: Plan completion

    /// Marks every non-rest ``ScheduledWorkout`` in `plan` whose date falls on
    /// or before `cutoff` as complete, backing each one with a fake ``RunWorkout``.
    static func completePlan(upTo cutoff: Date, plan: TrainingPlan, context: ModelContext) {
        let cal = Calendar.current
        for week in plan.weeks {
            for workout in week.workouts {
                guard
                    !workout.isCompleted,
                    workout.workoutType != .rest,
                    cal.compare(workout.scheduledDate, to: cutoff, toGranularity: .day) != .orderedDescending
                else { continue }

                let run = makeCompletionRun(for: workout)
                context.insert(run)
                workout.completedWorkout = run
                workout.isCompleted = true
            }
        }
        try? context.save()
    }

    /// Removes debug-tagged completions from `plan`, restoring those workouts
    /// to their incomplete state. Real (non-tagged) completions are left alone.
    static func resetPlanProgress(plan: TrainingPlan, context: ModelContext) {
        for week in plan.weeks {
            for workout in week.workouts where workout.isCompleted {
                guard let run = workout.completedWorkout, run.notes == tag else { continue }
                context.delete(run)
                workout.completedWorkout = nil
                workout.isCompleted = false
            }
        }
        try? context.save()
    }

    // MARK: Private helpers

    private static func makeWorkout(
        date: Date,
        type: WorkoutType,
        progressFactor: Double   // 0 = beginner, 1 = peak fitness
    ) -> RunWorkout {
        let (distance, basePace, baseHR) = stats(for: type, progressFactor: progressFactor)
        let duration = (distance / 1_000) * basePace

        // Place the run in the morning (6 – 8 am)
        let runDate = date.addingTimeInterval(Double.random(in: 6 * 3_600 ... 8 * 3_600))

        let workout = RunWorkout(
            date: runDate,
            distanceMeters: distance,
            durationSeconds: duration,
            workoutType: type
        )
        workout.averageHeartRate = baseHR + Double.random(in: -4 ... 4)
        workout.elevationGainMeters = Double.random(in: 10 ... 55)
        workout.notes = tag
        workout.splits = makeSplits(distanceMeters: distance, basePace: basePace)
        return workout
    }

    /// Returns (distanceMeters, paceSecondsPerKm, avgHeartRate) for a workout type.
    ///
    /// `progressFactor` of 1.0 gives the fastest / longest version; 0.0 gives
    /// the slowest / shortest — modelling a runner building fitness over the plan.
    private static func stats(
        for type: WorkoutType,
        progressFactor: Double
    ) -> (distance: Double, pace: Double, hr: Double) {
        // Paces improve by up to 20 s/km from start to end of history
        let improvement = progressFactor * 20

        switch type {
        case .easy:
            return (
                distance: Double.random(in: 6_000 ... 9_000),
                pace:     375 - improvement + Double.random(in: -10 ... 10),
                hr:       138
            )
        case .tempo:
            return (
                distance: Double.random(in: 6_000 ... 8_000),
                pace:     305 - improvement + Double.random(in: -8 ... 8),
                hr:       163
            )
        case .longRun:
            return (
                distance: Double.random(in: 13_000 ... 20_000),
                pace:     385 - improvement + Double.random(in: -10 ... 10),
                hr:       148
            )
        default:
            return (
                distance: Double.random(in: 6_000 ... 8_000),
                pace:     365 - improvement + Double.random(in: -10 ... 10),
                hr:       140
            )
        }
    }

    /// Builds a ``RunWorkout`` that plausibly satisfies a ``ScheduledWorkout``'s targets.
    private static func makeCompletionRun(for scheduled: ScheduledWorkout) -> RunWorkout {
        let distance = scheduled.targetDistanceMeters ?? fallbackDistance(for: scheduled.workoutType)

        // Pick a pace inside the target range if available, otherwise use a default
        let pace: Double
        if let range = scheduled.targetPaceRange {
            pace = Double.random(in: range.lowerBound...range.upperBound)
        } else {
            pace = fallbackPace(for: scheduled.workoutType) + Double.random(in: -10...10)
        }

        let duration = (distance / 1_000) * pace
        let runDate = Calendar.current.startOfDay(for: scheduled.scheduledDate)
            .addingTimeInterval(Double.random(in: 6.5 * 3_600 ... 8 * 3_600))

        let run = RunWorkout(
            date: runDate,
            distanceMeters: distance + Double.random(in: -150...150),
            durationSeconds: duration,
            workoutType: scheduled.workoutType
        )
        run.averageHeartRate = fallbackHR(for: scheduled.workoutType) + Double.random(in: -4...4)
        run.elevationGainMeters = Double.random(in: 8...45)
        run.notes = tag
        run.splits = makeSplits(distanceMeters: distance, basePace: pace)
        return run
    }

    private static func fallbackDistance(for type: WorkoutType) -> Double {
        switch type {
        case .easy:         return 7_000
        case .tempo:        return 7_000
        case .interval:     return 8_500   // warmup + reps + cooldown
        case .longRun:      return 15_000
        case .race:         return 5_000
        default:            return 6_000
        }
    }

    private static func fallbackPace(for type: WorkoutType) -> Double {
        switch type {
        case .easy:         return 370
        case .tempo:        return 305
        case .interval:     return 330
        case .longRun:      return 380
        case .race:         return 290
        default:            return 360
        }
    }

    private static func fallbackHR(for type: WorkoutType) -> Double {
        switch type {
        case .easy:         return 138
        case .tempo:        return 162
        case .interval:     return 170
        case .longRun:      return 148
        case .race:         return 178
        default:            return 140
        }
    }

    private static func makeSplits(distanceMeters: Double, basePace: Double) -> [Split] {
        let kmCount = max(1, Int(distanceMeters / 1_000))
        return (1 ... kmCount).map { km in
            Split(
                kilometer: km,
                paceSecondsPerKm: basePace + Double.random(in: -12 ... 12),
                heartRate: nil,
                elevationGainMeters: Double.random(in: 0 ... 6),
                cumulativeDistanceMeters: Double(km) * 1_000
            )
        }
    }
}
#endif
