import SwiftUI
import SwiftData

struct PlanSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
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
    @State private var errorMessage: String?

    // Editable goal fields — initialised from profile in onAppear
    @State private var goalRace: RaceType = .fiveK
    @State private var fitnessLevel: FitnessLevel = .beginner
    @State private var selectedDays: Set<Int> = [0, 2, 4, 5] // Mon Wed Fri Sat
    @State private var selectedEquipment: Set<StrengthEquipment> = []
    @State private var strengthFocus: StrengthFocus = .runningSpecific
    /// Canonical custom goal distance in kilometres (used when `goalRace == .custom`).
    @State private var customDistanceKm: Double = 10.0

    private var profile: UserProfile? { profiles.first }

    private var weekRange: ClosedRange<Int> { goalRace.typicalWeeks }

    /// Goal distance in meters, resolving a custom distance when applicable.
    private var effectiveRaceDistanceMeters: Double {
        goalRace.usesCustomDistance ? customDistanceKm * 1_000 : goalRace.distanceMeters
    }

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
                strengthSection
            }
            .strideList()
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

    private var goalSection: some View {
        Section("Goal") {
            Picker("Goal", selection: $goalRace) {
                ForEach(RaceType.allCases, id: \.self) { race in
                    Text(race.localizedName).tag(race)
                }
            }
            .onChange(of: goalRace) { _, _ in clampWeeks() }

            if goalRace.usesCustomDistance {
                Stepper(
                    value: $customDistanceKm,
                    // The value is stored in km; for imperial users step by half a mile
                    // (0.5 mi ≈ 0.805 km) so the mile display advances in clean 0.5 mi
                    // increments rather than the ~0.31 mi jumps a 0.5 km step produced.
                    in: 1...80,
                    step: appSettings.unitPreference == .imperial ? 0.5 * 1.609344 : 1
                ) {
                    LabeledContent("Distance") {
                        Text(
                            appSettings.unitPreference == .imperial
                                ? String(format: "%.1f mi", customDistanceKm * 0.621371)
                                : String(format: "%.1f km", customDistanceKm)
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Fitness level", selection: $fitnessLevel) {
                ForEach(FitnessLevel.allCases, id: \.self) { level in
                    Text(level.localizedName).tag(level)
                }
            }
        }
        .strideListRow()
    }

    private var runDaysSection: some View {
        Section {
            DayOfWeekPicker(selectedDays: $selectedDays)
                .padding(.vertical, AppSpacing.xs)
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
                    .foregroundStyle(.destructive)
            }
        }
        .strideListRow()
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
        .strideListRow()
    }

    private var startDateSection: some View {
        Section("Start Date") {
            DatePicker("First day", selection: $startDate, displayedComponents: .date)
                .onChange(of: startDate) { _, _ in recalibrateDates() }
        }
        .strideListRow()
    }

    private var strengthSection: some View {
        Section {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
            if !selectedEquipment.isEmpty {
                OBStrengthFocusPicker(focus: $strengthFocus)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        } header: {
            Text("Strength Training")
        } footer: {
            if selectedEquipment.isEmpty {
                Text("Select equipment to add strength sessions on your off days.")
            }
        }
    }

    // MARK: - Helpers

    private var minEndDate: Date { startDate.adding(weeks: weekRange.lowerBound) }
    private var maxEndDate: Date { startDate.adding(weeks: weekRange.upperBound) }

    private func loadFromProfile() {
        guard let profile else { return }
        goalRace = profile.goalRace
        if let custom = profile.customDistanceMeters, custom > 0 {
            customDistanceKm = custom / 1_000
        }
        fitnessLevel = profile.fitnessLevel
        if !profile.preferredRunDayIndices.isEmpty {
            selectedDays = Set(profile.preferredRunDayIndices)
        } else {
            selectedDays = defaultDays(for: profile.weeklyRunDays)
        }
        selectedEquipment = Set(profile.selectedEquipment)
        strengthFocus = profile.strengthFocus
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
        profile.customDistanceMeters = goalRace.usesCustomDistance ? effectiveRaceDistanceMeters : nil
        if let t = profile.currentEstimated5KTimeSeconds, t > 0 {
            let v = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: t)
            profile.goalFinishTime = PaceCalculatorService.predictedTime(
                vdot: v, distanceMeters: effectiveRaceDistanceMeters
            )
        }
        profile.fitnessLevel = fitnessLevel
        profile.weeklyRunDays = selectedDays.count
        profile.preferredRunDayIndices = sortedSelectedDays
        profile.selectedEquipment = Array(selectedEquipment)
        profile.strengthFocus = strengthFocus
        profile.updatedAt = Date()

        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: startDate,
            numberOfWeeks: effectiveWeeks,
            runDayIndices: sortedSelectedDays,
            unitPreference: appSettings.unitPreference
        )

        // Retires every existing plan so there is only ever one active plan per user, and
        // keeps each of them as history (deactivated) rather than deleting it — the Plan
        // History screen keeps a record even of plans the runner never logged a workout in.
        // Deletion stays a deliberate, user-initiated swipe in that list (H3). The Watch
        // entries and the reminders follow behind the dismissal so a slow scheduler cannot
        // hold this screen on its spinner.
        do {
            try container.planLifecycle.activateNewPlan(
                plan,
                context: context,
                morningRemindersEnabled: appSettings.morningReminderEnabled,
                unitPreference: appSettings.unitPreference
            )
        } catch {
            AppLogger.log("Failed to save the plan created in setup: \(error)", label: "plan", level: .error)
            errorMessage = String(
                localized: "Your plan couldn't be saved. Please try again.",
                comment: "Plan save failure"
            )
            isGenerating = false
            return
        }

        isGenerating = false
        dismiss()
    }
}
