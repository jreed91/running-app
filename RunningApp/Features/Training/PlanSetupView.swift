import SwiftUI
import SwiftData

struct PlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [UserProfile]

    @State private var selectedWeeks = 10
    @State private var startDate = Date().startOfWeek.adding(days: 7)
    @State private var isGenerating = false

    private var profile: UserProfile? { profiles.first }

    private var weekRange: ClosedRange<Int> {
        (profile?.goalRace.typicalWeeks) ?? (8...12)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan length") {
                    Stepper("\(selectedWeeks) weeks", value: $selectedWeeks, in: weekRange)
                }
                Section("Start date") {
                    DatePicker("First day", selection: $startDate, displayedComponents: .date)
                }
                if let profile {
                    Section("Goal") {
                        LabeledContent("Race", value: profile.goalRace.displayName)
                        LabeledContent("Fitness level", value: profile.fitnessLevel.displayName)
                        LabeledContent("Run days/week", value: "\(profile.weeklyRunDays)")
                    }
                }
            }
            .navigationTitle("New Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generatePlan() }
                        .disabled(profile == nil || isGenerating)
                }
            }
        }
    }

    private func generatePlan() {
        guard let profile else { return }
        isGenerating = true

        // Deactivate existing plans
        let existing = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        existing.forEach { $0.isActive = false }

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: selectedWeeks
        )
        context.insert(plan)
        try? context.save()

        // Schedule reminders
        Task {
            await container.notificationService.scheduleReminders(for: plan)
            await MainActor.run { dismiss() }
        }
    }
}
