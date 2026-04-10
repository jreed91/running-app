import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query private var profiles: [UserProfile]

    @State private var showResetConfirmation = false

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
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Reset All Data", role: .destructive) {
                showResetConfirmation = true
            }
        }
    }

    // MARK: Actions

    private func resetAll() {
        try? context.delete(model: RunWorkout.self)
        try? context.delete(model: TrainingPlan.self)
        try? context.delete(model: UserProfile.self)
        try? context.save()
    }
}
