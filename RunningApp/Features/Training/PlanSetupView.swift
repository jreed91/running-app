import SwiftUI
import SwiftData

struct PlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    @Query private var profiles: [UserProfile]

    // MARK: - Schedule mode

    private enum ScheduleMode: String, CaseIterable {
        case weeks = "Weeks"
        case endDate = "End Date"
    }

    @State private var scheduleMode: ScheduleMode = .weeks
    @State private var selectedWeeks = 10
    @State private var startDate = Date().startOfWeek.adding(days: 7)
    @State private var targetEndDate = Date().startOfWeek.adding(days: 7).adding(weeks: 10)
    @State private var isGenerating = false

    private var profile: UserProfile? { profiles.first }

    private var weekRange: ClosedRange<Int> {
        profile?.goalRace.typicalWeeks ?? (8...12)
    }

    /// End date computed from weeks stepper + start date.
    private var computedEndDate: Date {
        startDate.adding(weeks: selectedWeeks)
    }

    /// Week count derived from target end date, clamped to the allowed range.
    private var computedWeeks: Int {
        let days = Calendar.current.dateComponents(
            [.day], from: startDate, to: targetEndDate
        ).day ?? 0
        return max(weekRange.lowerBound, min(weekRange.upperBound, days / 7))
    }

    /// The week count that will actually be used when generating the plan.
    private var effectiveWeeks: Int {
        scheduleMode == .weeks ? selectedWeeks : computedWeeks
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan Length") {
                    Picker("Set by", selection: $scheduleMode) {
                        ForEach(ScheduleMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: scheduleMode) { _, _ in recalibrateDates() }

                    if scheduleMode == .weeks {
                        Stepper("\(selectedWeeks) weeks", value: $selectedWeeks, in: weekRange)
                            .onChange(of: selectedWeeks) { _, _ in
                                targetEndDate = computedEndDate
                            }
                        LabeledContent("End date") {
                            Text(computedEndDate, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        DatePicker(
                            "End date",
                            selection: $targetEndDate,
                            in: minEndDate...maxEndDate,
                            displayedComponents: .date
                        )
                        LabeledContent("Duration") {
                            Text("\(computedWeeks) weeks")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Start Date") {
                    DatePicker("First day", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _, _ in recalibrateDates() }
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

    // MARK: - Helpers

    private var minEndDate: Date { startDate.adding(weeks: weekRange.lowerBound) }
    private var maxEndDate: Date { startDate.adding(weeks: weekRange.upperBound) }

    /// Keep end date / week count consistent whenever the anchoring value changes.
    private func recalibrateDates() {
        if scheduleMode == .weeks {
            targetEndDate = computedEndDate
        } else {
            // Clamp end date to remain within valid range for the new start date
            if targetEndDate < minEndDate { targetEndDate = minEndDate }
            if targetEndDate > maxEndDate { targetEndDate = maxEndDate }
        }
    }

    // MARK: - Plan generation

    private func generatePlan() {
        guard let profile else { return }
        isGenerating = true

        // Deactivate existing plans
        let existing = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        existing.forEach { $0.isActive = false }

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: effectiveWeeks
        )
        context.insert(plan)
        try? context.save()

        Task {
            await container.notificationService.scheduleReminders(for: plan)
            await container.calendarSyncService.syncPlan(plan)
            // Persist EventKit identifiers written back onto workout models
            try? context.save()
            dismiss()
        }
    }
}
