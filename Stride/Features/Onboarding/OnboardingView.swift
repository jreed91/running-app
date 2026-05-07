import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import HealthKit

// MARK: - OnboardingView

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthService.self) private var authService

    // Navigation
    @State private var step = 0
    @State private var goingForward = true

    // Step data
    @State private var goalRace: RaceType = .fiveK
    @State private var raceName = RaceType.fiveK.displayName
    @State private var raceDate = Date().startOfWeek.adding(weeks: 8)
    @State private var planStart: Date = Date().startOfWeek.adding(weeks: 1).startOfDay
    @State private var fitnessLevel: FitnessLevel = .intermediate
    @State private var fitnessSelection: OBFitnessSelection = .recreational
    @State private var fiveKHours = 0
    @State private var fiveKMinutes = 26
    @State private var fiveKSeconds = 24
    @State private var selectedDays: Set<Int> = [0, 2, 4, 5]
    @State private var longRunOnSaturday = true

    // Strength step state
    @State private var selectedEquipment: Set<StrengthEquipment> = []
    @State private var strengthFocus: StrengthFocus = .runningSpecific

    // Permissions display state
    @State private var locationEnabled = false
    @State private var notificationsEnabled = false
    @State private var healthEnabled = false

    // Sequential permission flow
    @State private var permRowsVisible: [Bool] = [false, false, false]
    @State private var isRequestingPermissions = false
    @State private var activePermission: Int? = nil

    @State private var isCreatingPlan = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let locationManager = CLLocationManager()
    private let totalSteps = 9

    // MARK: - Computed

    private var fiveKTimeSeconds: Double {
        Double(fiveKHours * 3600 + fiveKMinutes * 60 + fiveKSeconds)
    }

    private var vdotValue: Double {
        PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fiveKTimeSeconds)
    }

    private var paces: TrainingPaces {
        PaceCalculatorService.trainingPaces(forVDOT: vdotValue)
    }

    private var planWeeks: Int {
        guard goalRace.isGoalRace else { return goalRace.typicalWeeks.lowerBound }
        return weeksThroughRaceDate(startDate: planStartDate, raceDate: raceDate)
    }

    private var planStartDate: Date {
        planStart.startOfDay
    }

    private var minimumRaceDate: Date {
        planStart.startOfDay.adding(days: 7)
    }

    private var minimumStartDate: Date {
        Date().startOfDay
    }

    private var maximumStartDate: Date? {
        goalRace.isGoalRace ? raceDate.startOfDay.adding(days: -7) : nil
    }

    private var startDateValid: Bool {
        guard planStart.startOfDay >= minimumStartDate else { return false }
        if let max = maximumStartDate {
            return planStart.startOfDay <= max
        }
        return true
    }

    private var raceGoalReady: Bool {
        !goalRace.isGoalRace || !raceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var estimatedWorkouts: Int { planWeeks * max(selectedDays.count, 3) }

    /// Peak weekly volume in km, mirroring `TrainingPlanService.weeklyKm` for the peak phase.
    private var peakKm: Double {
        let base = fitnessLevel.startingWeeklyKm(for: goalRace)
        return goalRace == .maintainFitness ? base * 1.2 : base * 1.5
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
        .adaptiveAnimation(AppAnimation.bouncy, value: step)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case 0:
            if authService.welcomeBackPending {
                OBWelcomeBack(onStartFresh: handleStartFresh)
            } else {
                OBWelcome(onStart: advance, onSignIn: handleSignIn)
            }
        case 1:
            OBShell(stepIndex: 1, total: totalSteps, kicker: "Your goal",
                    title: "What are you training for?", subtitle: "We'll build a plan around your race — or keep you running strong without one.",
                    ctaLabel: "Continue",
                    onBack: retreat,
                    onCTA: advance) {
                goalContent
            }
        case 2:
            OBShell(stepIndex: 2, total: totalSteps, kicker: "Timing",
                    title: goalRace.isGoalRace ? "When's the big day?" : "When do you want to start?",
                    subtitle: goalRace.isGoalRace
                        ? "Pick your race date and when training begins."
                        : "Choose a start date — typically next Monday.",
                    ctaLabel: "Continue",
                    ctaEnabled: raceGoalReady && startDateValid,
                    onBack: retreat,
                    onCTA: advance) {
                timingContent
            }
        case 3:
            OBShell(stepIndex: 3, total: totalSteps, kicker: "Units",
                    title: "Kilometres or miles?", subtitle: "Choose how distances and paces are shown throughout the app.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                unitsContent
            }
        case 4:
            OBShell(stepIndex: 4, total: totalSteps, kicker: "About you",
                    title: "How would you describe your running?", subtitle: "We'll calibrate volume and pace from here.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                levelContent
            }
        case 5:
            OBShell(stepIndex: 5, total: totalSteps, kicker: "Calibrate",
                    title: "Your recent 5K time?", subtitle: "Used to compute your VDOT and pace zones. You can skip or update this later.",
                    ctaLabel: "Continue",
                    secondaryLabel: "I don't know my 5K time",
                    onSecondary: advance,
                    onBack: retreat, onCTA: advance) {
                timeContent
            }
        case 6:
            OBShell(stepIndex: 6, total: totalSteps, kicker: "Schedule",
                    title: "Which days can you run?", subtitle: "Pick your typical week. We'll place harder workouts on your energy days.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                scheduleContent
            }
        case 7:
            OBShell(stepIndex: 7, total: totalSteps, kicker: "Strength Training",
                    title: "What equipment do you have?",
                    subtitle: "We'll add 1–2 strength sessions per week tailored to your gear.",
                    ctaLabel: "Continue",
                    secondaryLabel: "Skip strength training",
                    onSecondary: { selectedEquipment.removeAll(); advance() },
                    onBack: retreat,
                    onCTA: advance) {
                strengthContent
            }
        case 8:
            OBShell(stepIndex: 8, total: totalSteps, kicker: "Permissions",
                    title: "A few things to set up.", subtitle: "Each is optional — you can always change these in Settings.",
                    ctaLabel: isRequestingPermissions ? "Requesting…" : "Build my plan",
                    secondaryLabel: "Skip — I'll do this later",
                    onSecondary: advance,
                    ctaEnabled: !isRequestingPermissions,
                    onBack: retreat,
                    onCTA: {
                        guard !isRequestingPermissions else { return }
                        isRequestingPermissions = true
                        Task { await requestPermissionsSequentially() }
                    }) {
                permissionsContent
            }
        default:
            OBReady(goalRace: goalRace, planWeeks: planWeeks,
                    progressTotal: totalSteps,
                    goalTimeSeconds: goalFinishTimeSeconds,
                    estimatedWorkouts: estimatedWorkouts, peakKm: peakKm,
                    isCreatingPlan: isCreatingPlan, onViewPlan: { isCreatingPlan = true; createProfileAndPlan() })
        }
    }

    // MARK: - Navigation

    private func advance() {
        goingForward = true
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : AppAnimation.bouncy) { step += 1 }
    }
    private func retreat() {
        goingForward = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : AppAnimation.bouncy) { step -= 1 }
    }

    // MARK: - Goal content

    private var goalContent: some View {
        VStack(spacing: 10) {
            ForEach(RaceType.allCases, id: \.self) { race in
                OBRaceCard(race: race, isSelected: goalRace == race) {
                    goalRace = race
                    recalibrateRaceDate()
                }
            }

        }
    }

    // MARK: - Timing content

    private var timingContent: some View {
        VStack(spacing: 16) {
            if goalRace.isGoalRace {
                OBRaceDetailsCard(
                    raceName: $raceName,
                    raceDate: $raceDate,
                    race: goalRace,
                    minimumDate: minimumRaceDate
                )
            }

            OBStartDateCard(
                startDate: $planStart,
                planWeeks: planWeeks,
                isRacePlan: goalRace.isGoalRace,
                minimumDate: minimumStartDate,
                maximumDate: maximumStartDate
            )
        }
        .onChange(of: planStart) { _, _ in
            if goalRace.isGoalRace, raceDate < minimumRaceDate {
                raceDate = minimumRaceDate
            }
        }
    }

    private func unitCard(_ unit: UnitPreference, isSelected: Bool) -> some View {
        let iconColor: Color = isSelected ? .brand : .secondary
        let circleFill = Color.brand.opacity(isSelected ? 0.15 : 0.06)
        let bgColor: Color = isSelected ? Color.brand.opacity(0.06) : Color.surfaceSecondary
        let borderColor: Color = isSelected ? Color.brand.opacity(0.4) : Color.clear
        let subtitle = unit == .metric ? "Distances in km · Pace in min/km" : "Distances in miles · Pace in min/mi"

        return Button { appSettings.unitPreference = unit } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(circleFill).frame(width: 48, height: 48)
                    StrideIcon(name: .ruler, size: 22, color: iconColor, strokeWeight: 2.0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.displayName).font(.bodyStrong).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(16)
            .background(bgColor, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var unitsContent: some View {
        VStack(spacing: 10) {
            ForEach(UnitPreference.allCases, id: \.self) { unit in
                unitCard(unit, isSelected: appSettings.unitPreference == unit)
            }
        }
    }

    // MARK: - Level content

    private var levelContent: some View {
        VStack(spacing: 10) {
            ForEach(OBFitnessSelection.allCases, id: \.self) { selection in
                OBFitnessRow(selection: selection, goalRace: goalRace, isSelected: fitnessSelection == selection) {
                    fitnessSelection = selection
                    fitnessLevel = selection.fitnessLevel
                }
            }
        }
    }

    // MARK: - Time content

    private var timeContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    OBTimeWheelColumn(label: "HR", value: $fiveKHours, range: Array(0...4), isMuted: true)
                    Picker("Minutes", selection: $fiveKMinutes) {
                        ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .modifier(OBWheelColumnStyle(label: "MIN"))
                    Picker("Seconds", selection: $fiveKSeconds) { ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
                        .modifier(OBWheelColumnStyle(label: "SEC"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.brand.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Text(String(format: "%.0f", vdotValue))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VDOT \(String(format: "%.0f", vdotValue)) · \(vdotLabel)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Easy \(shortPace(paces.easyRange.lowerBound)) · Tempo \(tempoLabel) · Interval \(intervalLabel)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: [Color.brand.opacity(0.14), Color.brand.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.brand.opacity(0.28), lineWidth: 0.5))
        }
    }

    // MARK: - Schedule content

    private var scheduleContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                // Day grid
                HStack(spacing: 8) {
                    ForEach(0..<7) { i in
                        let labels = ["M","T","W","T","F","S","S"]
                        let dayNumbers = [20, 21, 22, 23, 24, 25, 26]
                        let isOn = selectedDays.contains(i)
                        Button {
                            withAnimation(AppAnimation.snappy) {
                                if isOn { selectedDays.remove(i) } else { selectedDays.insert(i) }
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text(labels[i])
                                    .font(.system(size: 11, weight: .bold))
                                    .kerning(0.6)
                                    .opacity(isOn ? 0.85 : 0.6)
                                Text("\(dayNumbers[i])")
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(isOn ? Color.brand : Color.surfaceTertiary,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .shadow(color: isOn ? Color.brand.opacity(0.35) : .clear, radius: 10, y: 4)
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
            }
            .padding(14)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 10) {
                Text("Long run day")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([("Sat", true), ("Sun", false), ("Flexible", false)], id: \.0) { name, isSat in
                        Button { longRunOnSaturday = isSat } label: {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(longRunOnSaturday == isSat && name != "Flexible" ? Color.surfaceSecondary : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(color: longRunOnSaturday == isSat && name != "Flexible" ? Color.black.opacity(0.1) : .clear, radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Text("Runs per week")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(selectedDays.count)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Strength content

    private var strengthContent: some View {
        VStack(spacing: 20) {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)
            OBStrengthFocusPicker(focus: $strengthFocus)
                .opacity(selectedEquipment.isEmpty ? 0.4 : 1)
                .disabled(selectedEquipment.isEmpty)
        }
    }

    // MARK: - Permissions content

    private var permissionsContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                OBPermissionRow(icon: .location, label: "Location",
                                desc: "Record GPS routes during runs.",
                                tint: .zoneEasy, isOn: locationEnabled,
                                isActive: activePermission == 0)
                    .opacity(permRowsVisible[0] ? 1 : 0)
                    .offset(y: permRowsVisible[0] ? 0 : 14)

                OBPermissionRow(icon: .heart, label: "HealthKit",
                                desc: "Heart rate, VO2 max, workouts.",
                                tint: .destructive, isOn: healthEnabled,
                                isActive: activePermission == 1)
                    .opacity(permRowsVisible[1] ? 1 : 0)
                    .offset(y: permRowsVisible[1] ? 0 : 14)

                OBPermissionRow(icon: .bell, label: "Notifications",
                                desc: "Plan reminders, daily workout ping.",
                                tint: .zoneTempo, isOn: notificationsEnabled,
                                isActive: activePermission == 2)
                    .opacity(permRowsVisible[2] ? 1 : 0)
                    .offset(y: permRowsVisible[2] ? 0 : 14)

                OBPermissionRow(icon: .timer, label: "Apple Watch",
                                desc: "Launch Stride on your wrist.",
                                tint: .secondary, isOn: false,
                                isActive: false)
                    .opacity(permRowsVisible[2] ? 1 : 0)
                    .offset(y: permRowsVisible[2] ? 0 : 14)
            }
            .adaptiveAnimation(AppAnimation.bouncy, value: permRowsVisible[0])
            .adaptiveAnimation(AppAnimation.bouncy, value: permRowsVisible[1])
            .adaptiveAnimation(AppAnimation.bouncy, value: permRowsVisible[2])
        }
        .task {
            await checkExistingPermissions()

            // All permissions already granted — skip this step automatically
            if healthEnabled && locationEnabled && notificationsEnabled {
                advance()
                return
            }

            // Stagger in only the rows that still need action (already-granted
            // rows appear immediately as "on"; pending rows animate in)
            permRowsVisible = [false, false, false]
            try? await Task.sleep(nanoseconds: 200_000_000)
            permRowsVisible[0] = true
            try? await Task.sleep(nanoseconds: 260_000_000)
            permRowsVisible[1] = true
            try? await Task.sleep(nanoseconds: 260_000_000)
            permRowsVisible[2] = true
        }
    }

    // MARK: - Pace label helpers

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

    private var vdotLabel: String {
        switch vdotValue {
        case ..<30: return "beginner"
        case 30..<40: return "base fitness"
        case 40..<50: return "Intermediate"
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

    private func recalibrateRaceDate() {
        guard goalRace.isGoalRace else { return }
        if raceDate < minimumRaceDate {
            raceDate = minimumRaceDate
        }
        let trimmedRaceName = raceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedRaceNames = Set(RaceType.allCases.map(\.displayName))
        if trimmedRaceName.isEmpty || generatedRaceNames.contains(trimmedRaceName) {
            raceName = goalRace.displayName
        }
    }

    private var goalFinishTimeSeconds: Double {
        PaceCalculatorService.predictedTime(vdot: vdotValue, distanceMeters: goalRace.distanceMeters)
    }

    // MARK: - Permissions

    /// Pre-populate enabled flags from actual system authorization status.
    private func checkExistingPermissions() async {
        // Location
        let locStatus = locationManager.authorizationStatus
        if locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways {
            locationEnabled = true
        }
        // Notifications
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        if notifSettings.authorizationStatus == .authorized ||
           notifSettings.authorizationStatus == .provisional {
            notificationsEnabled = true
        }
        // HealthKit authorization status for reading is opaque; treat as granted
        // if the store has already been authorized for any write type.
        if HKHealthStore.isHealthDataAvailable() {
            let store = HKHealthStore()
            if let distType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
               store.authorizationStatus(for: distType) == .sharingAuthorized {
                healthEnabled = true
            }
        }
    }

    private func requestPermissionsSequentially() async {
        // 1. Location (skip if already granted)
        if !locationEnabled {
            activePermission = 0
            locationManager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 1_800_000_000)   // time for system dialog
            withAnimation { locationEnabled = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 2. HealthKit (skip if already granted)
        if !healthEnabled {
            activePermission = 1
            if HKHealthStore.isHealthDataAvailable() {
                try? await container.healthKitRepository.requestAuthorization()
                await container.workoutSyncService.startObserving()
            }
            withAnimation { healthEnabled = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 3. Notifications (skip if already granted)
        if !notificationsEnabled {
            activePermission = 2
            try? await NotificationService.shared.requestAuthorization()
            withAnimation { notificationsEnabled = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        activePermission = nil
        isRequestingPermissions = false
        advance()
    }

    // MARK: - Sign in with Apple

    private func handleSignIn(_ userID: String) {
        authService.handleSignIn(userID: userID)
        authService.welcomeBackPending = true
    }

    private func handleStartFresh() {
        authService.welcomeBackPending = false
        // Skip past OBWelcome — the user has already authenticated, and
        // returning them to the sign-in screen would just risk a loop back
        // into OBWelcomeBack if they tap Sign in with Apple again.
        if step == 0 { advance() }
    }

    // MARK: - Create profile and plan

    private func createProfileAndPlan() {
        // CloudKit may have delivered the user's existing profile while they were
        // going through onboarding. If so, skip creation entirely — ContentView's
        // @Query will detect the non-empty profile list and switch to MainTabView.
        let check = FetchDescriptor<UserProfile>()
        if let existing = try? context.fetch(check), !existing.isEmpty {
            isCreatingPlan = false
            return
        }

        let v = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fiveKTimeSeconds)
        let goalFinishTime = PaceCalculatorService.predictedTime(vdot: v, distanceMeters: goalRace.distanceMeters)
        let profile = UserProfile(
            name: "",
            goalRace: goalRace,
            goalFinishTime: goalFinishTime,
            raceName: goalRace.isGoalRace ? raceName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            raceDate: goalRace.isGoalRace ? raceDate.startOfDay : nil,
            weeklyRunDays: max(selectedDays.count, 1),
            fitnessLevel: fitnessLevel,
            gender: .preferNotToShare,
            currentEstimated5KTimeSeconds: fiveKTimeSeconds,
            preferredRunDayIndices: selectedDays.sorted()
        )
        profile.selectedEquipment = Array(selectedEquipment)
        profile.strengthFocus = strengthFocus
        context.insert(profile)
        let plan: TrainingPlan
        if goalRace.isGoalRace {
            plan = container.trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: planStartDate,
                raceDate: raceDate,
                raceName: raceName.trimmingCharacters(in: .whitespacesAndNewlines),
                runDayIndices: selectedDays.sorted(),
                unitPreference: appSettings.unitPreference
            )
        } else {
            plan = container.trainingPlanService.generatePlan(
                profile: profile,
                startDate: planStartDate,
                numberOfWeeks: planWeeks,
                runDayIndices: selectedDays.sorted(),
                unitPreference: appSettings.unitPreference
            )
        }
        context.insert(plan)
        try? context.save()

        Task {
            await container.notificationService.scheduleReminders(for: plan)
            if appSettings.morningReminderEnabled {
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
            try? context.save()
            isCreatingPlan = false
        }
    }
}
