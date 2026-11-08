import SwiftUI
import SwiftData

// MARK: - StartRunningPlanSetupView

/// Sets up a Start Running plan from the Plan tab's New Plan menu.
///
/// The same four inputs onboarding collects for one (starting point, run days, equipment,
/// start date), so the two entry points build the same plan. A screen of its own rather than
/// a goal on `NewPlanOnboardingView`, which asks for a 5K time and a race date this plan has
/// no use for. Program details: `docs/START_RUNNING_PROGRAM.md`.
struct StartRunningPlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    @Query private var profiles: [UserProfile]

    @State private var startingPoint: StartRunningProgram.StartingPoint = .notYet
    @State private var startDate = Date().startOfWeek.adding(days: 7)
    @State private var selectedDays: Set<Int> = [0, 2, 4]
    @State private var selectedEquipment: Set<StrengthEquipment> = []
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var profile: UserProfile? { profiles.first }

    private var canGenerate: Bool {
        profile != nil && !selectedDays.isEmpty && !isGenerating
    }

    private var runsPerWeek: Int {
        StartRunningPlanService.runOffsets(
            preferred: selectedDays.sorted(),
            weeklyRunDays: selectedDays.count
        ).count
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                startingPointSection
                runDaysSection
                strengthSection
                startDateSection
                safetySection
            }
            .strideList()
            .navigationTitle("Start Running")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Generate") { generatePlan() }
                            .disabled(!canGenerate)
                    }
                }
            }
            .alert(
                "Couldn't build the plan",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { loadFromProfile() }
        }
    }

    // MARK: - Sections

    private var startingPointSection: some View {
        Section {
            Picker("How long can you run without stopping?", selection: $startingPoint) {
                ForEach(StartRunningProgram.StartingPoint.allCases) { point in
                    Text(point.localizedName).tag(point)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            LabeledContent("Week 1") {
                Text(StartRunningProgram.stage(startingPoint.firstStage).summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("How long can you run without stopping?")
        } footer: {
            Text("\(startingPoint.weeks) weeks to 30 minutes without stopping. Can already run about 20 minutes? A 5K training plan will suit you better.")
        }
        .strideListRow()
    }

    private var runDaysSection: some View {
        Section {
            DayOfWeekPicker(selectedDays: $selectedDays)
                .padding(.vertical, AppSpacing.xs)
        } header: {
            HStack {
                Text("Run days")
                Spacer()
                Text("\(runsPerWeek) runs / week")
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        } footer: {
            if selectedDays.isEmpty {
                Text("Select at least one run day.")
                    .foregroundStyle(.destructive)
            } else {
                Text("Three runs a week, with a day between them. Pick more and the plan uses the three most spread out.")
            }
        }
        .strideListRow()
    }

    private var strengthSection: some View {
        Section {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
        } header: {
            Text("Strength (optional)")
        } footer: {
            Text("Pick your equipment for one short strength session a week, on a day off running. Leave it empty to skip strength.")
        }
    }

    private var startDateSection: some View {
        Section("Start date") {
            DatePicker("First day", selection: $startDate, in: Date().startOfDay..., displayedComponents: .date)
        }
        .strideListRow()
    }

    private var safetySection: some View {
        Section {
            Text("Stop and get checked if you have chest pain, feel faint, or have pain that gets worse as you run. If you're worried about your health, talk to a doctor before you start.")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
        .strideListRow()
    }

    // MARK: - Helpers

    private func loadFromProfile() {
        guard let profile else { return }
        if !profile.preferredRunDayIndices.isEmpty {
            selectedDays = Set(profile.preferredRunDayIndices)
        }
        selectedEquipment = Set(profile.selectedEquipment)
    }

    // MARK: - Plan generation

    private func generatePlan() {
        guard let profile, !selectedDays.isEmpty else { return }
        isGenerating = true

        profile.weeklyRunDays = selectedDays.count
        profile.preferredRunDayIndices = selectedDays.sorted()
        profile.selectedEquipment = Array(selectedEquipment)
        profile.updatedAt = Date()

        let plan = StartRunningPlanService().generatePlan(
            profile: profile,
            startDate: startDate,
            firstStage: startingPoint.firstStage
        )

        // Retires the previous plan, saves, and syncs the Watch and the reminders behind
        // the dismissal, the way the other two setup screens do.
        do {
            try container.planLifecycle.activateNewPlan(
                plan,
                context: context,
                morningRemindersEnabled: appSettings.morningReminderEnabled,
                unitPreference: appSettings.unitPreference
            )
        } catch {
            errorMessage = String(
                localized: "Your plan couldn't be saved. Please try again.",
                comment: "Start Running plan save failure"
            )
            AppLogger.log("Failed to save the Start Running plan: \(error)", label: "startRunning", level: .error)
            isGenerating = false
            return
        }

        isGenerating = false
        dismiss()
    }
}
