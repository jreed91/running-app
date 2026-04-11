import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query private var profiles: [UserProfile]

    @State private var showResetConfirmation = false
    #if DEBUG
    @State private var seedWeeks = 8
    #endif

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    profileSection(profile: profile)
                }
                unitsSection
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
        Section {
            Stepper("\(seedWeeks) weeks of history", value: $seedWeeks, in: 2...24)

            Button("Seed Run History") {
                DebugRunGenerator.seed(weeks: seedWeeks, context: context)
            }

            Button("Clear Seeded Runs", role: .destructive) {
                DebugRunGenerator.clear(context: context)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Inserts fake RunWorkout entries. Only visible in DEBUG builds.")
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
