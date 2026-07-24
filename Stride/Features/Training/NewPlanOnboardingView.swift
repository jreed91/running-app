import SwiftUI
import SwiftData

struct NewPlanOnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var appSettings

    @Query private var profiles: [UserProfile]

    // Navigation
    @State private var step = 0
    @State private var goingForward = true

    // Step 1 – Race
    @State private var goalRace: RaceType = .halfMarathon
    @State private var raceName = ""
    @State private var raceDate = Date().startOfWeek.adding(weeks: 12)
    /// Canonical custom goal distance in kilometres (used when `goalRace == .custom`).
    @State private var customDistanceKm: Double = 10.0

    // Step 2 – Fitness
    @State private var fitnessLevel: FitnessLevel = .intermediate

    // Step 3 – 5K time
    @State private var fiveKMinutes = 25
    @State private var fiveKSeconds = 0

    // Step 4 – Duration
    private enum ScheduleMode: String, CaseIterable {
        case weeks = "Weeks"
        case endDate = "End Date"
    }
    @State private var scheduleMode: ScheduleMode = .weeks
    @State private var selectedWeeks = 12
    @State private var startDate = Date().startOfWeek.adding(days: 7)
    @State private var targetEndDate = Date().startOfWeek.adding(days: 7).adding(weeks: 12)

    // Step 5 – Schedule days
    @State private var selectedDays: Set<Int> = [0, 2, 4, 5]

    // Step 6 – Strength
    @State private var selectedEquipment: Set<StrengthEquipment> = []
    @State private var strengthFocus: StrengthFocus = .runningSpecific

    @State private var isCreatingPlan = false
    @State private var planErrorMessage: String?

    private let totalSteps = 6

    private var profile: UserProfile? { profiles.first }

    // MARK: - Computed

    private var fiveKTimeSeconds: Double { Double(fiveKMinutes * 60 + fiveKSeconds) }

    private var vdotValue: Double {
        PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fiveKTimeSeconds)
    }

    private var paces: TrainingPaces {
        PaceCalculatorService.trainingPaces(forVDOT: vdotValue)
    }

    private var weekRange: ClosedRange<Int> { goalRace.typicalWeeks }

    /// Goal distance in meters, resolving a custom distance when applicable.
    private var effectiveRaceDistanceMeters: Double {
        goalRace.usesCustomDistance ? customDistanceKm * 1_000 : goalRace.distanceMeters
    }

    /// The standard race archetype the current goal maps to for volume/pace estimates.
    private var trainingStyle: RaceType {
        goalRace.trainingStyle(forDistanceMeters: effectiveRaceDistanceMeters)
    }

    private var computedEndDate: Date { startDate.adding(weeks: selectedWeeks) }

    private var computedWeeks: Int {
        let days = Calendar.current.dateComponents(
            [.day], from: startDate, to: targetEndDate
        ).day ?? 0
        return max(weekRange.lowerBound, min(weekRange.upperBound, days / 7))
    }

    private var effectiveWeeks: Int {
        if goalRace.isGoalRace {
            return weeksThroughRaceDate(startDate: effectiveStartDate, raceDate: raceDate)
        }
        return scheduleMode == .weeks ? selectedWeeks : computedWeeks
    }

    private var estimatedWorkouts: Int { effectiveWeeks * max(selectedDays.count, 3) }

    /// Peak weekly volume in km, mirroring `TrainingPlanService.weeklyKm` for the peak phase.
    private var peakKm: Double {
        let base = fitnessLevel.startingWeeklyKm(for: trainingStyle)
        return trainingStyle == .maintainFitness ? base * 1.2 : base * 1.5
    }

    private var goalFinishTimeSeconds: Double {
        PaceCalculatorService.predictedTime(vdot: vdotValue, distanceMeters: effectiveRaceDistanceMeters)
    }

    private var minEndDate: Date { startDate.adding(weeks: weekRange.lowerBound) }
    private var maxEndDate: Date { startDate.adding(weeks: weekRange.upperBound) }
    private var minimumRaceDate: Date { Date().startOfDay.adding(days: 1) }
    private var effectiveStartDate: Date {
        goalRace.isGoalRace && raceDate.startOfDay < startDate.startOfDay ? Date().startOfDay : startDate.startOfDay
    }
    private var raceGoalReady: Bool {
        !goalRace.isGoalRace || !raceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            currentStep
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
                ))
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .ignoresSafeArea()
        .onAppear { loadFromProfile() }
        .alert(
            "Couldn't build your plan",
            isPresented: Binding(
                get: { planErrorMessage != nil },
                set: { if !$0 { planErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { planErrorMessage = nil }
        } message: {
            Text(planErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case 0:
            OBShell(
                stepIndex: 0, total: totalSteps,
                kicker: "Step 1 · Goal",
                title: "Pick your goal.",
                subtitle: "Choose a race or maintain fitness. You can change this anytime.",
                ctaLabel: "Continue",
                ctaEnabled: raceGoalReady,
                onBack: { dismiss() },
                onCTA: advance
            ) { raceContent }

        case 1:
            OBShell(
                stepIndex: 1, total: totalSteps,
                kicker: "Step 2 · Fitness",
                title: "Where are you now?",
                subtitle: "Be honest — plans scale up from here. No ego lifts allowed.",
                ctaLabel: "Continue",
                onBack: retreat,
                onCTA: advance
            ) { levelContent }

        case 2:
            OBShell(
                stepIndex: 2, total: totalSteps,
                kicker: "Step 3 · Pace",
                title: "Your recent 5K time?",
                subtitle: "Your VDOT — and every training pace — comes from this number.",
                ctaLabel: "Continue",
                onBack: retreat,
                onCTA: advance
            ) { timeContent }

        case 3:
            OBShell(
                stepIndex: 3, total: totalSteps,
                kicker: goalRace.isGoalRace ? "Step 4 · Race Day" : "Step 4 · Duration",
                title: goalRace.isGoalRace ? "When is race day?" : "How long to train?",
                subtitle: goalRace.isGoalRace ? "Your plan will finish on the goal race date." : "Choose a plan length that suits your schedule.",
                ctaLabel: "Continue",
                onBack: retreat,
                onCTA: advance
            ) { durationContent }

        case 4:
            OBShell(
                stepIndex: 4, total: totalSteps,
                kicker: "Step 5 · Schedule",
                title: "When can you run?",
                subtitle: "Pick the days you'll train. We'll build your plan around them.",
                ctaLabel: "Continue",
                onBack: retreat,
                onCTA: { guard !selectedDays.isEmpty else { return }; advance() }
            ) { scheduleContent }

        case 5:
            OBShell(
                stepIndex: 5, total: totalSteps,
                kicker: "Step 6 · Strength",
                title: "What equipment do you have?",
                subtitle: "We'll add strength sessions on your off days, tailored to your gear.",
                ctaLabel: "Build My Plan",
                secondaryLabel: "Skip strength training",
                onSecondary: { selectedEquipment.removeAll(); advance() },
                onBack: retreat,
                onCTA: advance
            ) { strengthContent }

        default:
            OBReady(
                goalRace: goalRace,
                planWeeks: effectiveWeeks,
                progressTotal: totalSteps + 1,
                goalTimeSeconds: goalFinishTimeSeconds,
                estimatedWorkouts: estimatedWorkouts,
                peakKm: peakKm,
                isCreatingPlan: isCreatingPlan,
                onViewPlan: {
                    guard !isCreatingPlan else { return }
                    isCreatingPlan = true
                    generatePlan()
                }
            )
        }
    }

    // MARK: - Navigation

    private func advance() { goingForward = true; withAnimation { step += 1 } }
    private func retreat() { goingForward = false; withAnimation { step -= 1 } }

    // MARK: - Step content

    private var raceContent: some View {
        VStack(spacing: 10) {
            ForEach(RaceType.allCases, id: \.self) { race in
                OBRaceCard(race: race, isSelected: goalRace == race) {
                    goalRace = race
                    clampWeeks()
                    recalibrateRaceName()
                }
            }
            if goalRace.usesCustomDistance {
                OBCustomDistanceCard(distanceKm: $customDistanceKm)
                    .onChange(of: customDistanceKm) { _, _ in recalibrateRaceName() }
            }
            if goalRace.isGoalRace {
                OBRaceDetailsCard(
                    raceName: $raceName,
                    raceDate: $raceDate,
                    race: goalRace,
                    minimumDate: minimumRaceDate
                )
            }
        }
    }

    private var levelContent: some View {
        VStack(spacing: 10) {
            ForEach(FitnessLevel.allCases, id: \.self) { level in
                OBLevelRow(level: level, race: goalRace, isSelected: fitnessLevel == level) {
                    fitnessLevel = level
                }
            }
        }
    }

    private var timeContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Text("5K FINISH TIME")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    Picker("Minutes", selection: $fiveKMinutes) {
                        ForEach(14...99, id: \.self) {
                            Text(String(format: "%02d", $0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)

                    Text(":")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)

                    Picker("Seconds", selection: $fiveKSeconds) {
                        ForEach(stride(from: 0, through: 55, by: 5).map { $0 }, id: \.self) {
                            Text(String(format: "%02d", $0)).tag($0)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 80)
                }

                HStack(spacing: 6) {
                    Text(String(format: "VDOT %.0f", vdotValue))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                    Text("·").foregroundStyle(.secondary)
                    Text(vdotLabel)
                        .font(.captionStrong)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.brand.opacity(0.1), in: Capsule())
            }
            .padding(20)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR TRAINING PACES (\(appSettings.unitPreference.paceLabel.uppercased()))")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    OBPaceCell(zone: "Easy", color: .zoneEasy, pace: easyLabel)
                    OBPaceCell(zone: "Marathon", color: .zoneMarathon, pace: marathonLabel)
                    OBPaceCell(zone: "Tempo", color: .zoneTempo, pace: tempoLabel)
                    OBPaceCell(zone: "Interval", color: .zoneInterval, pace: intervalLabel)
                }
            }

            HStack(spacing: 10) {
                StrideIcon(name: .timer, size: 16, color: .secondary)
                Text("Don't know your 5K time? Estimate from a recent run or use your current fitness level as a guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var durationContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                if goalRace.isGoalRace {
                    DatePicker(
                        "Race date",
                        selection: $raceDate,
                        in: minimumRaceDate...,
                        displayedComponents: .date
                    )
                    .onChange(of: raceDate) { _, _ in recalibrateDates() }

                    LabeledContent("Duration") {
                        Text("\(effectiveWeeks) weeks")
                            .foregroundStyle(.secondary)
                    }

                    if raceDate.startOfDay < startDate.startOfDay {
                        LabeledContent("Start date") {
                            Text(Date().startOfDay, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                            .onChange(of: startDate) { _, _ in recalibrateDates() }
                    }
                } else {
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

                    Divider()

                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _, _ in recalibrateDates() }
                }
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 10) {
                StrideIcon(name: .calendar, size: 16, color: .secondary)
                Text(goalRace.isGoalRace
                     ? "Race plans can target any future date."
                     : "\(goalRace.typicalWeeks.lowerBound)–\(goalRace.typicalWeeks.upperBound) weeks recommended for \(goalRace.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var scheduleContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    let weekStart = Date().startOfWeek
                    ForEach(0..<7, id: \.self) { i in
                        let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
                        // Real day-of-month numbers for the current (Monday-first)
                        // week instead of hardcoded literals that read "20…26" forever.
                        let dayNumber = Calendar.current.component(.day, from: weekStart.adding(days: i))
                        let isOn = selectedDays.contains(i)
                        Button {
                            if isOn { selectedDays.remove(i) } else { selectedDays.insert(i) }
                        } label: {
                            VStack(spacing: 2) {
                                Text(dayLabels[i])
                                    .font(.system(size: 11, weight: .bold))
                                    .kerning(0.6)
                                    .opacity(isOn ? 0.85 : 0.6)
                                Text("\(dayNumber)")
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                            }
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    isOn ? Color.brand : Color.surfaceTertiary,
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .foregroundStyle(isOn ? Color.white : Color.secondary)
                                .shadow(color: isOn ? Color.brand.opacity(0.4) : .clear, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    Text("\(selectedDays.count)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Days per week").font(.captionStrong)
                        Text(recommendedDaysLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            if selectedDays.isEmpty {
                HStack(spacing: 10) {
                    StrideIcon(name: .flag, size: 16, color: .destructive)
                    Text("Select at least one run day to continue.")
                        .font(.caption)
                        .foregroundStyle(.destructive)
                }
                .padding(14)
                .background(Color.destructive.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var strengthContent: some View {
        VStack(spacing: 16) {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)
            OBStrengthFocusPicker(focus: $strengthFocus)
                .opacity(selectedEquipment.isEmpty ? 0.4 : 1)
                .disabled(selectedEquipment.isEmpty)
        }
    }

    // MARK: - Helpers

    private var vdotLabel: String {
        switch vdotValue {
        case ..<30: return "beginner"
        case 30..<40: return "base fitness"
        case 40..<50: return "good intermediate"
        case 50..<60: return "advanced"
        default: return "elite"
        }
    }

    private var recommendedDaysLabel: String {
        switch goalRace {
        case .maintainFitness: return "Recommended for Maintain Fitness"
        case .fiveK: return "Recommended for 5K"
        case .halfMarathon: return "Recommended for Half Marathon"
        case .marathon: return "Recommended for Marathon"
        case .custom: return "Recommended for your distance"
        }
    }

    /// Auto-generated race name for a custom distance, so the field is never blank.
    private var defaultRaceName: String {
        appSettings.unitPreference == .imperial
            ? String(format: "%.1f mi Race", customDistanceKm * 0.621371)
            : String(format: "%.1f km Race", customDistanceKm)
    }

    /// Keeps the race name in sync with the chosen custom distance while it still
    /// looks auto-generated; a name the user typed is left untouched.
    private func recalibrateRaceName() {
        guard goalRace.usesCustomDistance else { return }
        let trimmed = raceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksAutoGenerated = trimmed.isEmpty
            || (trimmed.hasSuffix(" Race") && (trimmed.first?.isNumber ?? false))
        if looksAutoGenerated {
            raceName = defaultRaceName
        }
    }

    private func shortPace(_ secsPerKm: Double) -> String {
        guard secsPerKm > 0, secsPerKm.isFinite else { return "--:--" }
        let s = appSettings.unitPreference == .imperial ? secsPerKm * 1.60934 : secsPerKm
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private var easyLabel: String {
        "\(shortPace(paces.easyRange.lowerBound))–\(shortPace(paces.easyRange.upperBound))"
    }
    private var marathonLabel: String { shortPace(paces.marathon) }
    private var tempoLabel: String { shortPace(paces.threshold) }
    private var intervalLabel: String { shortPace(paces.interval) }

    private func loadFromProfile() {
        guard let profile else { return }
        goalRace = profile.goalRace
        raceName = profile.raceName ?? ""
        raceDate = profile.raceDate ?? raceDate
        if let custom = profile.customDistanceMeters, custom > 0 {
            customDistanceKm = custom / 1_000
        }
        fitnessLevel = profile.fitnessLevel
        if !profile.preferredRunDayIndices.isEmpty {
            selectedDays = Set(profile.preferredRunDayIndices)
        }
        if let t = profile.currentEstimated5KTimeSeconds, t > 0 {
            fiveKMinutes = max(14, min(99, Int(t) / 60))
            let rem = Int(t) % 60
            fiveKSeconds = (rem / 5) * 5
        }
        selectedEquipment = Set(profile.selectedEquipment)
        strengthFocus = profile.strengthFocus
        clampWeeks()
    }

    private func clampWeeks() {
        selectedWeeks = max(weekRange.lowerBound, min(weekRange.upperBound, selectedWeeks))
        recalibrateDates()
    }

    private func recalibrateDates() {
        if goalRace.isGoalRace {
            if raceDate < minimumRaceDate { raceDate = minimumRaceDate }
        } else if scheduleMode == .weeks {
            targetEndDate = computedEndDate
        } else {
            if targetEndDate < minEndDate { targetEndDate = minEndDate }
            if targetEndDate > maxEndDate { targetEndDate = maxEndDate }
        }
    }

    private func weeksThroughRaceDate(startDate: Date, raceDate: Date) -> Int {
        let days = Calendar.current.dateComponents(
            [.day],
            from: startDate.startOfDay,
            to: raceDate.startOfDay
        ).day ?? 0
        return max(1, Int(ceil(Double(max(days, 0) + 1) / 7.0)))
    }

    // MARK: - Plan generation

    private func generatePlan() {
        // Without a profile there is nothing to build a plan from. Clear the spinner
        // and tell the user instead of leaving "Build My Plan" wedged forever.
        guard let profile else {
            isCreatingPlan = false
            planErrorMessage = "We couldn't find your runner profile. Close this screen and try again."
            return
        }

        let sortedDays = selectedDays.sorted()

        profile.goalRace = goalRace
        profile.customDistanceMeters = goalRace.usesCustomDistance ? effectiveRaceDistanceMeters : nil
        profile.raceName = goalRace.isGoalRace ? raceName.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        profile.raceDate = goalRace.isGoalRace ? raceDate.startOfDay : nil
        profile.fitnessLevel = fitnessLevel
        profile.goalFinishTime = goalFinishTimeSeconds
        profile.weeklyRunDays = sortedDays.count
        profile.preferredRunDayIndices = sortedDays
        profile.currentEstimated5KTimeSeconds = fiveKTimeSeconds
        profile.selectedEquipment = Array(selectedEquipment)
        profile.strengthFocus = strengthFocus
        profile.updatedAt = Date()

        // Retire existing plans so there is only ever one active plan per user. Every
        // prior plan is preserved as history (deactivated) rather than deleted, so the
        // Plan History screen keeps a record of it — including plans the user started
        // but never logged a workout in. Deletion stays a deliberate, user-initiated
        // action via swipe-to-delete in the Plan History list (H3).
        let existing = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []

        let plan: TrainingPlan
        if goalRace.isGoalRace {
            plan = container.trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: effectiveStartDate,
                raceDate: raceDate,
                raceName: raceName.trimmingCharacters(in: .whitespacesAndNewlines),
                runDayIndices: sortedDays,
                unitPreference: appSettings.unitPreference
            )
        } else {
            plan = container.trainingPlanService.generatePlan(
                profile: profile,
                startDate: startDate,
                numberOfWeeks: effectiveWeeks,
                runDayIndices: sortedDays,
                unitPreference: appSettings.unitPreference
            )
        }
        context.insert(plan)
        do {
            try context.save()
        } catch {
            context.delete(plan)
            isCreatingPlan = false
            planErrorMessage = "Your plan couldn't be saved. Please try again.\n\n\(error.localizedDescription)"
            AppLogger.log("Failed to save generated plan: \(error)", label: "onboarding", level: .error)
            return
        }

        Task {
            if appSettings.morningReminderEnabled {
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
            for previous in existing {
                try? await container.healthKitRepository.removeWorkoutPlans(for: previous)
                previous.isActive = false
            }
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
            try? context.save()
            isCreatingPlan = false
            dismiss()
        }
    }
}
