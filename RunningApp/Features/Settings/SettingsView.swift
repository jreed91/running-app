import SwiftUI
import SwiftData
import AuthenticationServices

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.appContainer) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthService.self) private var authService
    @Query private var profiles: [UserProfile]
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    @State private var showResetConfirmation = false
    @State private var showSyncRestartNote = false
    #if DEBUG
    @State private var seedWeeks = 8
    @State private var completionCutoff = Date()
    #endif

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let profile { profileHeaderCard(profile) }
                    accountCard
                    unitsCard
                    if let profile { trainingCard(profile) }
                    appCard
                    dataCard
                    routeGeniusCard
                    aboutCard
                    dangerCard
                    #if DEBUG
                    developerCard
                    #endif
                }
                .padding()
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Settings")
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { resetAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, all workouts, training plans, and saved routes.")
            }
        }
    }

    // MARK: - Profile header

    private func profileHeaderCard(_ profile: UserProfile) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.brand, Color(red: 0.878, green: 0.263, blue: 0.102)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 60, height: 60)
                if profile.name.isEmpty {
                    StrideIcon(name: .run, size: 28, color: .white, strokeWeight: 2.2)
                } else {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? "Runner" : profile.name)
                    .font(.system(size: 20, weight: .bold))
                HStack(spacing: 4) {
                    Text(profile.goalRace.displayName)
                    Text("·")
                    Text(profile.fitnessLevel.displayName)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.brand.opacity(0.1), Color.brand.opacity(0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Account card

    private var accountCard: some View {
        settingsSection("Account") {
            if authService.isSignedIn {
                settingsRow(icon: .check, iconColor: .success, title: "Signed in with Apple") {
                    Button("Sign out") { authService.signOut() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    settingsRow(icon: .lock, iconColor: .secondary, title: "Apple Account") {
                        EmptyView()
                    }
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = []
                    } onCompletion: { result in
                        if case .success(let auth) = result,
                           let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                            Task { @MainActor in
                                authService.handleSignIn(userID: credential.user)
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - Units card

    private var unitsCard: some View {
        settingsSection("Units") {
            HStack(spacing: 4) {
                ForEach(UnitPreference.allCases, id: \.self) { unit in
                    Button { appSettings.unitPreference = unit } label: {
                        VStack(spacing: 3) {
                            Text(unit.displayName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(unit == .metric ? "km · min/km" : "mi · min/mi")
                                .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            appSettings.unitPreference == unit ? Color.brand : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .foregroundStyle(appSettings.unitPreference == unit ? .white : .secondary)
                        .animation(.easeInOut(duration: 0.15), value: appSettings.unitPreference)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: 14))
            .padding(16)
        }
    }

    // MARK: - Training card

    private func trainingCard(_ profile: UserProfile) -> some View {
        settingsSection("Runner Profile") {
            settingsRow(icon: .run, iconColor: .brand, title: "Name") {
                TextField("Your name", text: Bindable(profile).name)
                    .multilineTextAlignment(.trailing)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            }
            rowDivider
            settingsRow(icon: .heart, iconColor: .destructive, title: "Gender") {
                Picker("", selection: Bindable(profile).gender) {
                    ForEach(Gender.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - App card

    private var appCard: some View {
        settingsSection("App") {
            settingsRow(icon: .gear, iconColor: .secondary, title: "iCloud Sync") {
                Toggle("", isOn: Bindable(appSettings).iCloudSyncEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .onChange(of: appSettings.iCloudSyncEnabled) { _, _ in
                        showSyncRestartNote = true
                    }
            }
            if showSyncRestartNote {
                Text("Restart the app for this change to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 62)
                    .padding(.bottom, 10)
            }
            rowDivider
            settingsRow(icon: .bell, iconColor: .zoneTempo, title: "Morning Reminder") {
                Toggle("", isOn: Bindable(appSettings).morningReminderEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .onChange(of: appSettings.morningReminderEnabled) { _, enabled in
                        guard let plan = activePlans.first else { return }
                        Task {
                            if enabled {
                                await container.notificationService.scheduleMorningReminders(for: plan)
                            } else {
                                await container.notificationService.cancelAllMorningReminders()
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Data card

    private var dataCard: some View {
        settingsSection("Data") {
            NavigationLink {
                HealthKitImportView()
            } label: {
                settingsRow(icon: .heart, iconColor: .destructive, title: "Import from Apple Health") {
                    StrideIcon(name: .chevronRight, size: 12,
                               color: Color.secondary.opacity(0.5), strokeWeight: 2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    // MARK: - Route Genius card

    private var routeGeniusCard: some View {
        settingsSection("Route Genius") {
            settingsRow(icon: .location, iconColor: .brand, title: "ORS API Key") {
                EmptyView()
            }
            SecureField("Paste your token here", text: Bindable(appSettings).orsAPIKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            Text("Free key at openrouteservice.org · 2,000 routes/day · stored on-device only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }

    // MARK: - About card

    private var aboutCard: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return settingsSection("About") {
            settingsRow(icon: .gear, iconColor: Color.secondary, title: "Version") {
                Text(version)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Danger card

    private var dangerCard: some View {
        Button(role: .destructive) {
            showResetConfirmation = true
        } label: {
            HStack(spacing: 10) {
                StrideIcon(name: .close, size: 16, color: .destructive, strokeWeight: 2.2)
                Text("Reset All Data")
                    .font(.bodyStrong)
                    .foregroundStyle(.destructive)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.destructive.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Developer card (DEBUG)

    #if DEBUG
    private var developerCard: some View {
        let plan = activePlans.first
        return VStack(spacing: 16) {
            settingsSection("Developer · Run History") {
                settingsRow(icon: .history, iconColor: .secondary, title: "\(seedWeeks) weeks of history") {
                    Stepper("", value: $seedWeeks, in: 2...24)
                        .labelsHidden()
                }
                rowDivider
                Button {
                    DebugRunGenerator.seed(weeks: seedWeeks, context: context)
                } label: {
                    settingsRow(icon: .play, iconColor: .success, title: "Seed Run History") {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                rowDivider
                Button {
                    DebugRunGenerator.clear(context: context)
                } label: {
                    settingsRow(icon: .close, iconColor: .destructive, title: "Clear Seeded Runs") {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.destructive)
            }

            if let plan {
                settingsSection("Developer · Plan Progress") {
                    HStack {
                        StrideIcon(name: .calendar, size: 16, color: .brand, strokeWeight: 2)
                            .padding(.leading, 16)
                        DatePicker(
                            "Complete through",
                            selection: $completionCutoff,
                            in: plan.startDate...plan.endDate,
                            displayedComponents: .date
                        )
                        .padding(.trailing, 16)
                    }
                    .padding(.vertical, 12)
                    rowDivider
                    Button {
                        DebugRunGenerator.completePlan(upTo: completionCutoff, plan: plan, context: context)
                    } label: {
                        settingsRow(icon: .check, iconColor: .success, title: "Mark Workouts Complete") {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    rowDivider
                    Button {
                        DebugRunGenerator.resetPlanProgress(plan: plan, context: context)
                    } label: {
                        settingsRow(icon: .close, iconColor: .destructive, title: "Reset Debug Completions") {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.destructive)
                }
            }
        }
    }
    #endif

    // MARK: - Layout helpers

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func settingsRow<Trailing: View>(
        icon: StrideIconName,
        iconColor: Color,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                StrideIcon(name: icon, size: 16, color: iconColor, strokeWeight: 2.0)
            }
            Text(title).font(.bodyRegular)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 62)
    }

    // MARK: - Actions

    private func resetAll() {
        try? context.delete(model: RunWorkout.self)
        try? context.delete(model: TrainingPlan.self)
        try? context.delete(model: UserProfile.self)
        try? context.delete(model: SavedRoute.self)
        try? context.save()
    }
}

// MARK: - DebugRunGenerator

#if DEBUG
enum DebugRunGenerator {

    static let tag = "debug_seeded"

    static func seed(weeks: Int, context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())

        for weekOffset in 0..<weeks {
            guard let anchor = Calendar.current.date(
                byAdding: .weekOfYear, value: -(weekOffset + 1), to: today
            ) else { continue }
            let weekStart = anchor.startOfWeek

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

    static func clear(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<RunWorkout>()) else { return }
        all.filter { $0.notes == tag }.forEach { context.delete($0) }
        try? context.save()
    }

    static func completePlan(upTo cutoff: Date, plan: TrainingPlan, context: ModelContext) {
        let cal = Calendar.current
        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] {
                guard
                    !workout.isCompleted,
                    workout.workoutType != .rest,
                    cal.compare(workout.scheduledDate, to: cutoff, toGranularity: .day) != .orderedDescending
                else { continue }

                let run = makeCompletionRun(for: workout)
                context.insert(run)
                workout.completedWorkout = run
                workout.isCompleted = true
            }
        }
        try? context.save()
    }

    static func resetPlanProgress(plan: TrainingPlan, context: ModelContext) {
        for week in plan.weeks ?? [] {
            for workout in week.workouts ?? [] where workout.isCompleted {
                guard let run = workout.completedWorkout, run.notes == tag else { continue }
                context.delete(run)
                workout.completedWorkout = nil
                workout.isCompleted = false
            }
        }
        try? context.save()
    }

    private static func makeWorkout(date: Date, type: WorkoutType, progressFactor: Double) -> RunWorkout {
        let (distance, basePace, baseHR) = stats(for: type, progressFactor: progressFactor)
        let duration = (distance / 1_000) * basePace
        let runDate = date.addingTimeInterval(Double.random(in: 6 * 3_600 ... 8 * 3_600))
        let workout = RunWorkout(date: runDate, distanceMeters: distance, durationSeconds: duration, workoutType: type)
        workout.averageHeartRate = baseHR + Double.random(in: -4 ... 4)
        workout.elevationGainMeters = Double.random(in: 10 ... 55)
        workout.notes = tag
        workout.splits = makeSplits(distanceMeters: distance, basePace: basePace)
        return workout
    }

    private static func stats(for type: WorkoutType, progressFactor: Double) -> (distance: Double, pace: Double, hr: Double) {
        let improvement = progressFactor * 20
        switch type {
        case .easy:    return (Double.random(in: 6_000...9_000),  375 - improvement + Double.random(in: -10...10), 138)
        case .tempo:   return (Double.random(in: 6_000...8_000),  305 - improvement + Double.random(in: -8...8),   163)
        case .longRun: return (Double.random(in: 13_000...20_000), 385 - improvement + Double.random(in: -10...10), 148)
        default:       return (Double.random(in: 6_000...8_000),  365 - improvement + Double.random(in: -10...10), 140)
        }
    }

    private static func makeCompletionRun(for scheduled: ScheduledWorkout) -> RunWorkout {
        let distance = scheduled.targetDistanceMeters ?? fallbackDistance(for: scheduled.workoutType)
        let pace: Double
        if let range = scheduled.targetPaceRange {
            pace = Double.random(in: range.lowerBound...range.upperBound)
        } else {
            pace = fallbackPace(for: scheduled.workoutType) + Double.random(in: -10...10)
        }
        let duration = (distance / 1_000) * pace
        let runDate = Calendar.current.startOfDay(for: scheduled.scheduledDate)
            .addingTimeInterval(Double.random(in: 6.5 * 3_600 ... 8 * 3_600))
        let run = RunWorkout(
            date: runDate,
            distanceMeters: distance + Double.random(in: -150...150),
            durationSeconds: duration,
            workoutType: scheduled.workoutType
        )
        run.averageHeartRate = fallbackHR(for: scheduled.workoutType) + Double.random(in: -4...4)
        run.elevationGainMeters = Double.random(in: 8...45)
        run.notes = tag
        run.splits = makeSplits(distanceMeters: distance, basePace: pace)
        return run
    }

    private static func fallbackDistance(for type: WorkoutType) -> Double {
        switch type {
        case .easy: return 7_000; case .tempo: return 7_000
        case .interval: return 8_500; case .longRun: return 15_000
        case .race: return 5_000; default: return 6_000
        }
    }

    private static func fallbackPace(for type: WorkoutType) -> Double {
        switch type {
        case .easy: return 370; case .tempo: return 305
        case .interval: return 330; case .longRun: return 380
        case .race: return 290; default: return 360
        }
    }

    private static func fallbackHR(for type: WorkoutType) -> Double {
        switch type {
        case .easy: return 138; case .tempo: return 162
        case .interval: return 170; case .longRun: return 148
        case .race: return 178; default: return 140
        }
    }

    private static func makeSplits(distanceMeters: Double, basePace: Double) -> [Split] {
        let kmCount = max(1, Int(distanceMeters / 1_000))
        return (1...kmCount).map { km in
            Split(
                kilometer: km,
                paceSecondsPerKm: basePace + Double.random(in: -12...12),
                heartRate: nil,
                elevationGainMeters: Double.random(in: 0...6),
                cumulativeDistanceMeters: Double(km) * 1_000
            )
        }
    }
}
#endif
