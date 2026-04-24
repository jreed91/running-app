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

    // Navigation
    @State private var step = 0
    @State private var goingForward = true

    // Step data
    @State private var goalRace: RaceType = .halfMarathon
    @State private var fitnessLevel: FitnessLevel = .intermediate
    @State private var fiveKMinutes = 25
    @State private var fiveKSeconds = 0
    @State private var selectedDays: Set<Int> = [0, 1, 3, 4, 5]
    @State private var longRunOnSaturday = true

    // Permissions display state
    @State private var locationEnabled = false
    @State private var notificationsEnabled = false
    @State private var healthEnabled = false

    // Sequential permission flow
    @State private var permRowsVisible: [Bool] = [false, false, false]
    @State private var isRequestingPermissions = false
    @State private var activePermission: Int? = nil

    @State private var isCreatingPlan = false

    private let locationManager = CLLocationManager()
    private let totalSteps = 6

    // MARK: - Computed

    private var fiveKTimeSeconds: Double {
        Double(fiveKMinutes * 60 + fiveKSeconds)
    }

    private var vdotValue: Double {
        PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fiveKTimeSeconds)
    }

    private var paces: TrainingPaces {
        PaceCalculatorService.trainingPaces(forVDOT: vdotValue)
    }

    private var planWeeks: Int { goalRace.typicalWeeks.lowerBound }

    private var estimatedWorkouts: Int { planWeeks * max(selectedDays.count, 3) }

    private var estimatedKm: Int {
        let base = fitnessLevel.startingWeeklyKm(for: goalRace)
        return Int((base + base * 1.8) / 2 * Double(planWeeks))
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
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case 0:
            OBWelcome(onStart: advance)
        case 1:
            OBShell(stepIndex: 0, total: totalSteps, kicker: "Step 1 · Goal",
                    title: "Pick a race.", subtitle: "What are you training for? You can change this anytime.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                goalContent
            }
        case 2:
            OBShell(stepIndex: 1, total: totalSteps, kicker: "Step 2 · Units",
                    title: "Kilometres or miles?", subtitle: "Choose how distances and paces are shown throughout the app.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                unitsContent
            }
        case 3:
            OBShell(stepIndex: 2, total: totalSteps, kicker: "Step 3 · Level",
                    title: "Where are you now?", subtitle: "Be honest — plans scale up from here. No ego lifts allowed.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                levelContent
            }
        case 4:
            OBShell(stepIndex: 3, total: totalSteps, kicker: "Step 4 · Pace",
                    title: "Your recent 5K time?", subtitle: "Your VDOT — and every training pace — comes from this number.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                timeContent
            }
        case 5:
            OBShell(stepIndex: 4, total: totalSteps, kicker: "Step 5 · Schedule",
                    title: "When can you run?", subtitle: "Pick the days you'll train. We'll build your plan around them.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                scheduleContent
            }
        case 6:
            OBShell(stepIndex: 5, total: totalSteps, kicker: "Step 6 · Access",
                    title: "A few permissions.", subtitle: "Grant these so Stride can track your runs and keep your plan in sync.",
                    ctaLabel: isRequestingPermissions ? "Requesting…" : "Enable & Continue",
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
                    estimatedWorkouts: estimatedWorkouts, estimatedKm: estimatedKm,
                    isCreatingPlan: isCreatingPlan, onViewPlan: { isCreatingPlan = true; createProfileAndPlan() })
        }
    }

    // MARK: - Navigation

    private func advance() { goingForward = true; withAnimation { step += 1 } }
    private func retreat() { goingForward = false; withAnimation { step -= 1 } }

    // MARK: - Goal content

    private var goalContent: some View {
        VStack(spacing: 10) {
            ForEach(RaceType.allCases, id: \.self) { race in
                OBRaceCard(race: race, isSelected: goalRace == race) { goalRace = race }
            }
        }
    }

    // MARK: - Units content

    private var unitsContent: some View {
        VStack(spacing: 10) {
            ForEach(UnitPreference.allCases, id: \.self) { unit in
                unitCard(unit, isSelected: appSettings.unitPreference == unit)
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

    // MARK: - Level content

    private var levelContent: some View {
        VStack(spacing: 10) {
            ForEach(FitnessLevel.allCases, id: \.self) { level in
                OBLevelRow(level: level, race: goalRace, isSelected: fitnessLevel == level) { fitnessLevel = level }
            }
        }
    }

    // MARK: - Time content

    private var timeContent: some View {
        VStack(spacing: 18) {
            // Large time picker card
            VStack(spacing: 12) {
                Text("5K FINISH TIME")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Picker("Minutes", selection: $fiveKMinutes) {
                        ForEach(14...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
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
                // VDOT badge
                HStack(spacing: 6) {
                    Text(String(format: "VDOT %.0f", vdotValue))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(vdotLabel)
                        .font(.captionStrong)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.brand.opacity(0.1), in: Capsule())
            }
            .padding(20)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            // Training paces
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

            // Tip
            HStack(spacing: 10) {
                StrideIcon(name: .timer, size: 16, color: .secondary)
                Text("Don't know your 5K time? Run a time trial and come back, or estimate from a recent run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Schedule content

    private var scheduleContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                // Day grid
                HStack(spacing: 6) {
                    ForEach(0..<7) { i in
                        let labels = ["M","T","W","T","F","S","S"]
                        let isOn = selectedDays.contains(i)
                        Button {
                            if isOn { selectedDays.remove(i) } else { selectedDays.insert(i) }
                        } label: {
                            Text(labels[i])
                                .font(.system(size: 17, weight: .bold))
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(isOn ? Color.brand : Color.surfaceTertiary,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(isOn ? Color.white : Color.secondary)
                                .shadow(color: isOn ? Color.brand.opacity(0.4) : .clear, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Days per week pill
                HStack(spacing: 10) {
                    Text("\(selectedDays.count)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Days per week")
                            .font(.captionStrong)
                        Text(recommendedDaysLabel)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))

            // Long run day
            VStack(alignment: .leading, spacing: 10) {
                Text("LONG RUN DAY")
                    .font(.sectionHeader).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([("Saturday", true), ("Sunday", false)], id: \.0) { name, isSat in
                        Button { longRunOnSaturday = isSat } label: {
                            VStack(spacing: 4) {
                                Text(name).font(.bodyStrong)
                                Text(longRunOnSaturday == isSat ? "Selected" : "Alternate")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(longRunOnSaturday == isSat ? Color.brand : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: - Permissions content

    private var permissionsContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                OBPermissionRow(icon: .heart, label: "Apple Health",
                                desc: "Read runs, heart rate, workouts",
                                tint: .destructive, isOn: healthEnabled,
                                isActive: activePermission == 0)
                    .opacity(permRowsVisible[0] ? 1 : 0)
                    .offset(y: permRowsVisible[0] ? 0 : 14)

                Divider().padding(.leading, 68)
                    .opacity(permRowsVisible[1] ? 1 : 0)

                OBPermissionRow(icon: .location, label: "Location",
                                desc: "GPS tracking during runs",
                                tint: .zoneEasy, isOn: locationEnabled,
                                isActive: activePermission == 1)
                    .opacity(permRowsVisible[1] ? 1 : 0)
                    .offset(y: permRowsVisible[1] ? 0 : 14)

                Divider().padding(.leading, 68)
                    .opacity(permRowsVisible[2] ? 1 : 0)

                OBPermissionRow(icon: .bell, label: "Notifications",
                                desc: "Workout reminders, plan updates",
                                tint: .zoneTempo, isOn: notificationsEnabled,
                                isActive: activePermission == 2)
                    .opacity(permRowsVisible[2] ? 1 : 0)
                    .offset(y: permRowsVisible[2] ? 0 : 14)
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: permRowsVisible[0])
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: permRowsVisible[1])
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: permRowsVisible[2])

            HStack(spacing: 10) {
                StrideIcon(name: .lock, size: 16, color: .secondary)
                Text("Data stays on-device. Stride never uploads your runs without permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .opacity(permRowsVisible[2] ? 1 : 0)
            .animation(.easeOut(duration: 0.3).delay(0.1), value: permRowsVisible[2])
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
        case 40..<50: return "good intermediate"
        case 50..<60: return "advanced"
        default: return "elite"
        }
    }

    private var recommendedDaysLabel: String {
        switch goalRace {
        case .fiveK: return "Recommended for 5K"
        case .halfMarathon: return "Recommended for Half Marathon"
        case .marathon: return "Recommended for Marathon"
        }
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
        // 1. HealthKit (skip if already granted)
        if !healthEnabled {
            activePermission = 0
            if HKHealthStore.isHealthDataAvailable() {
                try? await container.healthKitRepository.requestAuthorization()
                await container.workoutSyncService.startObserving()
            }
            withAnimation { healthEnabled = true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 2. Location (skip if already granted)
        if !locationEnabled {
            activePermission = 1
            locationManager.requestWhenInUseAuthorization()
            try? await Task.sleep(nanoseconds: 1_800_000_000)   // time for system dialog
            withAnimation { locationEnabled = true }
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

    // MARK: - Create profile and plan

    private func createProfileAndPlan() {
        let v = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: fiveKTimeSeconds)
        let goalFinishTime = PaceCalculatorService.predictedTime(vdot: v, distanceMeters: goalRace.distanceMeters)
        let profile = UserProfile(
            name: "",
            goalRace: goalRace,
            goalFinishTime: goalFinishTime,
            weeklyRunDays: max(selectedDays.count, 1),
            fitnessLevel: fitnessLevel,
            gender: .preferNotToShare,
            currentEstimated5KTimeSeconds: fiveKTimeSeconds,
            preferredRunDayIndices: selectedDays.sorted()
        )
        context.insert(profile)
        let plan = container.trainingPlanService.generatePlan(
            profile: profile,
            startDate: Date().startOfWeek.adding(weeks: 1),
            numberOfWeeks: planWeeks,
            runDayIndices: selectedDays.sorted(),
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
            isCreatingPlan = false
        }
    }
}
