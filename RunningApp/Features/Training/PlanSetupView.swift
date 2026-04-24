import SwiftUI
import SwiftData

struct PlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

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

    // Editable goal fields — initialised from profile in onAppear
    @State private var goalRace: RaceType = .fiveK
    @State private var fitnessLevel: FitnessLevel = .beginner
    @State private var selectedDays: Set<Int> = [0, 2, 4, 5] // Mon Wed Fri Sat

    private var profile: UserProfile? { profiles.first }

    private var weekRange: ClosedRange<Int> { goalRace.typicalWeeks }

    private var computedEndDate: Date { startDate.adding(weeks: selectedWeeks) }

    private var computedWeeks: Int {
        let days = Calendar.current.dateComponents(
            [.day], from: startDate, to: targetEndDate
        ).day ?? 0
        return max(weekRange.lowerBound, min(weekRange.upperBound, days / 7))
    }

    private var effectiveWeeks: Int {
        scheduleMode == .weeks ? selectedWeeks : computedWeeks
    }

    private var sortedSelectedDays: [Int] { selectedDays.sorted() }

    private var canGenerate: Bool {
        profile != nil && !isGenerating && !selectedDays.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                goalSection
                runDaysSection
                planLengthSection
                startDateSection
            }
            .navigationTitle("New Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
            .onAppear { loadFromProfile() }
        }
    }

    // MARK: - Sections

    private var goalSection: some View {
        Section("Goal") {
            Picker("Goal", selection: $goalRace) {
                ForEach(RaceType.allCases, id: \.self) { race in
                    Text(race.displayName).tag(race)
                }
            }
            .onChange(of: goalRace) { _, _ in clampWeeks() }

            Picker("Fitness level", selection: $fitnessLevel) {
                ForEach(FitnessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
        }
    }

    private var runDaysSection: some View {
        Section {
            DayOfWeekPicker(selectedDays: $selectedDays)
                .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Run Days")
                Spacer()
                Text("\(selectedDays.count) day\(selectedDays.count == 1 ? "" : "s") / week")
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        } footer: {
            if selectedDays.isEmpty {
                Text("Select at least one run day.")
                    .foregroundStyle(.red)
            }
        }
    }

    private var planLengthSection: some View {
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
                    .onChange(of: selectedWeeks) { _, _ in targetEndDate = computedEndDate }
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
    }

    private var startDateSection: some View {
        Section("Start Date") {
            DatePicker("First day", selection: $startDate, displayedComponents: .date)
                .onChange(of: startDate) { _, _ in recalibrateDates() }
        }
    }

    // MARK: - Helpers

    private var minEndDate: Date { startDate.adding(weeks: weekRange.lowerBound) }
    private var maxEndDate: Date { startDate.adding(weeks: weekRange.upperBound) }

    private func loadFromProfile() {
        guard let profile else { return }
        goalRace = profile.goalRace
        fitnessLevel = profile.fitnessLevel
        if !profile.preferredRunDayIndices.isEmpty {
            selectedDays = Set(profile.preferredRunDayIndices)
        } else {
            selectedDays = defaultDays(for: profile.weeklyRunDays)
        }
        clampWeeks()
    }

    private func defaultDays(for count: Int) -> Set<Int> {
        let clamped = max(1, min(7, count))
        let step = 7.0 / Double(clamped)
        return Set((0..<clamped).map { Int(Double($0) * step) })
    }

    private func clampWeeks() {
        selectedWeeks = max(weekRange.lowerBound, min(weekRange.upperBound, selectedWeeks))
        recalibrateDates()
    }

    private func recalibrateDates() {
        if scheduleMode == .weeks {
            targetEndDate = computedEndDate
        } else {
            if targetEndDate < minEndDate { targetEndDate = minEndDate }
            if targetEndDate > maxEndDate { targetEndDate = maxEndDate }
        }
    }

    // MARK: - Plan generation

    private func generatePlan() {
        guard let profile, !selectedDays.isEmpty else { return }
        isGenerating = true

        // Persist goal changes back to the profile
        profile.goalRace = goalRace
        profile.fitnessLevel = fitnessLevel
        profile.weeklyRunDays = selectedDays.count
        profile.preferredRunDayIndices = sortedSelectedDays
        profile.updatedAt = Date()

        // Deactivate existing plans
        let existing = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        existing.forEach { $0.isActive = false }

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: effectiveWeeks,
            runDayIndices: sortedSelectedDays,
            unitPreference: appSettings.unitPreference
        )
        context.insert(plan)
        try? context.save()

        Task {
            await container.notificationService.scheduleReminders(for: plan)
            if appSettings.morningReminderEnabled {
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan)
            try? context.save()
            isGenerating = false
            dismiss()
        }
    }
}
