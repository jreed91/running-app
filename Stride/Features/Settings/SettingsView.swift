import SwiftUI
import SwiftData
import AuthenticationServices
#if canImport(PulseUI)
import PulseUI
#endif

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthService.self) private var authService
    @Query private var profiles: [UserProfile]
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    /// The profile avatar and the initial inside it scale together, so the letter
    /// can't outgrow its circle at large content sizes (U2).
    @ScaledMetric(relativeTo: .title) private var avatarSize: CGFloat = 60

    @State private var showResetConfirmation = false
    @State private var showPulseConsole = false
    @State private var notificationTestStatus: String?
    #if DEBUG
    @State private var seedWeeks = 8
    @State private var completionCutoff = Date()
    @State private var workoutKitResendStatus: String?
    #endif

    private var profile: UserProfile? { profiles.first }

    /// True only while the live iCloud-sync preference differs from the one the
    /// running store was opened with — toggling back makes the note disappear.
    private var syncRestartPending: Bool {
        appSettings.iCloudSyncEnabled != container.syncPreferenceAtLaunch
    }
    private var persistenceStatusText: String {
        switch container.persistenceMode {
        case .cloudKit:
            "CloudKit"
        case .inMemory:
            "In-Memory"
        case .localOnly:
            "Local Only"
        case .localFallback:
            "Local Fallback"
        case .recreatedLocalFallback:
            "Recreated Local Store"
        case .emergencyInMemory:
            "Emergency In-Memory"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let profile { profileHeaderCard(profile) }
                    accountCard
                    unitsCard
                    if let profile { trainingCard(profile) }
                    if let profile { heartRateCard(profile) }
                    appCard
                    dataCard
                    routeGeniusCard
                    aiCoachCard
                    if BuildEnvironment.showsTestFlightDiagnostics {
                        notificationTestingCard
                    }
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
                    .frame(width: avatarSize, height: avatarSize)
                if profile.name.isEmpty {
                    StrideIcon(name: .run, size: avatarSize * 0.47, color: .onFill, strokeWeight: 2.2)
                } else {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: avatarSize * 0.47, weight: .bold))
                        .foregroundStyle(.onFill)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? "Runner" : profile.name)
                    .font(.dsTitle3.weight(.bold))
                HStack(spacing: 4) {
                    Text(profile.goalRace.localizedName)
                    Text("·")
                    Text(profile.fitnessLevel.localizedName)
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
            in: RoundedRectangle(cornerRadius: AppRadius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(Color.brand.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Account card

    private var accountCard: some View {
        settingsSection("Account") {
            if authService.isSignedIn {
                settingsRow(icon: .check, iconColor: .success, title: "Signed in with Apple") {
                    Button("Sign out") { authService.signOut() }
                        .font(.dsFootnote.weight(.medium))
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
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.md)
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
                            Text(unit.localizedName)
                                .font(.dsSubhead.weight(.semibold))
                            Text(unit == .metric ? "km · min/km" : "mi · min/mi")
                                .font(.dsCaption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(
                            appSettings.unitPreference == unit ? Color.brand : Color.clear,
                            in: RoundedRectangle(cornerRadius: AppRadius.sm)
                        )
                        .foregroundStyle(appSettings.unitPreference == unit ? .white : .secondary)
                        .animation(.easeInOut(duration: 0.15), value: appSettings.unitPreference)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppSpacing.xs)
            .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .padding(AppSpacing.lg)
        }
    }

    // MARK: - Training card

    private func trainingCard(_ profile: UserProfile) -> some View {
        settingsSection("Runner Profile") {
            settingsRow(icon: .run, iconColor: .brand, title: "Name") {
                TextField("Your name", text: profileNameBinding(for: profile))
                    .multilineTextAlignment(.trailing)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            }
            rowDivider
            settingsRow(icon: .heart, iconColor: .destructive, title: "Gender") {
                Picker("", selection: profileGenderBinding(for: profile)) {
                    ForEach(Gender.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - Heart Rate card

    private func heartRateCard(_ profile: UserProfile) -> some View {
        settingsSection("Heart Rate Zones") {
            settingsRow(icon: .heart, iconColor: .zoneTempo, title: "Age") {
                HStack(spacing: 10) {
                    Text("\(ageBinding(for: profile).wrappedValue)")
                        .font(.bodyRegular).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: ageBinding(for: profile), in: 10...100)
                        .labelsHidden()
                }
            }
            rowDivider
            settingsRow(icon: .bolt, iconColor: .zoneInterval, title: "Max HR") {
                HStack(spacing: 10) {
                    Text("\(maxHRBinding(for: profile).wrappedValue) bpm")
                        .font(.bodyRegular).foregroundStyle(.secondary)
                        .monospacedDigit()
                    Stepper("", value: maxHRBinding(for: profile), in: 120...220)
                        .labelsHidden()
                }
            }
            if profile.maxHeartRateBPM != nil {
                rowDivider
                Button {
                    profile.maxHeartRateBPM = nil
                    persistProfileEdit(profile)
                } label: {
                    HStack {
                        Text("Reset to age estimate (\(UserProfile.estimatedMaxHeartRate(forAge: profile.age ?? 30)) bpm)")
                            .font(.caption).foregroundStyle(.brand)
                        Spacer()
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.md)
                }
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
            }
            if syncRestartPending {
                Text("Restart the app for this change to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 62)
                    .padding(.bottom, 10)
            }
            rowDivider
            settingsRow(icon: .check, iconColor: .brand, title: "Active Store") {
                Text(persistenceStatusText)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            }
            if appSettings.iCloudSyncEnabled {
                Text("Verify CloudKit on-device in Pulse Console: look for `CloudKit` `setup`, `export`, and `import` events.")
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
                        // Only *scheduling* needs a plan (N16). Guarding the whole block on
                        // one meant turning the toggle off while a plan was being replaced
                        // left the already-scheduled reminders firing, and turning it on
                        // never asked for permission — a toggle that disagreed with reality
                        // until the next launch reconciled it.
                        let plan = activePlans.first
                        Task {
                            guard enabled else {
                                await container.notificationService.cancelAllMorningReminders()
                                return
                            }
                            if !(await container.notificationService.isAuthorized) {
                                try? await container.notificationService.requestAuthorization()
                            }
                            guard let plan else { return }
                            await container.notificationService.scheduleMorningReminders(for: plan)
                        }
                    }
            }
            rowDivider
            // The one setting that makes the app talk over the runner's music, so it
            // says what it will say and stays off until asked (U4).
            settingsRow(icon: .ruler, iconColor: .zoneEasy, title: "Spoken Splits") {
                Toggle("", isOn: Bindable(appSettings).spokenSplitsEnabled)
                    .labelsHidden()
                    .tint(.brand)
            }
            Text("Announces each \(appSettings.unitPreference.distanceLabel) and its pace out loud during a run. Music ducks for the announcement.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 62)
                .padding(.bottom, 10)
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

            if BuildEnvironment.showsTestFlightDiagnostics {
                rowDivider
                NavigationLink {
                    CloudKitDebugView()
                } label: {
                    settingsRow(icon: .history, iconColor: .brand, title: "CloudKit Debug Data") {
                        StrideIcon(name: .chevronRight, size: 12,
                                   color: Color.secondary.opacity(0.5), strokeWeight: 2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
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
                .font(.dsFootnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, 6)
            Text("Free key at openrouteservice.org · 2,000 routes/day · stored on-device only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, 14)
        }
    }


    // MARK: - AI Coach card

    private var aiCoachCard: some View {
        settingsSection("AI Coach") {
            settingsRow(icon: .bolt, iconColor: .zoneTempo, title: "AI Insights") {
                Toggle("", isOn: Bindable(appSettings).aiInsightsEnabled)
                    .labelsHidden()
                    .tint(.brand)
            }
            rowDivider
            settingsRow(icon: .gear, iconColor: .brand, title: "Model") {
                Picker("", selection: Bindable(appSettings).aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.localizedName).tag(provider)
                    }
                }
                .labelsHidden()
            }
            Text(aiProviderFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, 14)
        }
    }

    private var aiProviderFootnote: String {
        switch appSettings.aiProvider {
        case .appleOnDevice:
            return "Runs on your device with Apple Intelligence. No API key, no cost, and your training data never leaves your iPhone. Requires a supported device with Apple Intelligence enabled."
        case .applePrivateCloud:
            return "Uses Apple Private Cloud Compute for deeper analysis on longer requests. No API key required; data is processed with Apple's Private Cloud Compute privacy guarantees."
        }
    }

    // MARK: - About card

    private var notificationTestingCard: some View {
        settingsSection("TestFlight · Notifications") {
            Button {
                Task {
                    do {
                        if !(await container.notificationService.isAuthorized) {
                            try await container.notificationService.requestAuthorization()
                        }
                        try await container.notificationService.triggerAllTestNotifications(in: context)
                        notificationTestStatus = "Sent workout, morning, and synced-run test notifications."
                    } catch {
                        notificationTestStatus = "Failed to send test notifications: \(error.localizedDescription)"
                    }
                }
            } label: {
                settingsRow(icon: .bell, iconColor: .brand, title: "Trigger All Notifications") {
                    StrideIcon(name: .play, size: 12,
                               color: Color.secondary.opacity(0.7), strokeWeight: 2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            rowDivider
            Button {
                Task {
                    do {
                        if !(await container.notificationService.isAuthorized) {
                            try await container.notificationService.requestAuthorization()
                        }
                        guard let lastRun = try container.workoutRepository.fetchRecent(limit: 1).first else {
                            notificationTestStatus = "No runs found to notify. Record or sync a run first."
                            return
                        }
                        try await container.notificationService.notifyNewRunSynced(
                            lastRun,
                            unit: appSettings.unitPreference
                        )
                        notificationTestStatus = "Sent synced-run notification. Tap it to review your latest run."
                    } catch {
                        notificationTestStatus = "Failed to send latest-run notification: \(error.localizedDescription)"
                    }
                }
            } label: {
                settingsRow(icon: .history, iconColor: .brand, title: "Notify Latest Run") {
                    StrideIcon(name: .play, size: 12,
                               color: Color.secondary.opacity(0.7), strokeWeight: 2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if let notificationTestStatus {
                rowDivider
                Text(notificationTestStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, 14)
            } else {
                rowDivider
                Text("Sends each local notification type immediately so QA can verify copy, sounds, and tap behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, 14)
            }
        }
    }

    private var aboutCard: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return settingsSection("About") {
            settingsRow(icon: .gear, iconColor: Color.secondary, title: "Version") {
                Text(version)
                    .font(.dsSubhead.weight(.medium).monospaced())
                    .foregroundStyle(.secondary)
            }
            #if canImport(PulseUI)
            if BuildEnvironment.showsTestFlightDiagnostics {
                rowDivider
                Button {
                    showPulseConsole = true
                } label: {
                    settingsRow(icon: .history, iconColor: .brand, title: "Pulse Console") {
                        StrideIcon(name: .chevronRight, size: 12,
                                   color: Color.secondary.opacity(0.5), strokeWeight: 2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            #endif
        }
        #if canImport(PulseUI)
        .sheet(isPresented: $showPulseConsole) { NavigationStack { ConsoleView() } }
        #endif
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
            .padding(.vertical, AppSpacing.lg)
            .background(Color.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
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
                            .padding(.leading, AppSpacing.lg)
                        DatePicker(
                            "Complete through",
                            selection: $completionCutoff,
                            in: plan.startDate...plan.endDate,
                            displayedComponents: .date
                        )
                        .padding(.trailing, AppSpacing.lg)
                    }
                    .padding(.vertical, AppSpacing.md)
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

                settingsSection("Developer · WorkoutKit") {
                    Button {
                        resendWorkoutsToWorkoutKit(plan: plan)
                    } label: {
                        settingsRow(icon: .calendar, iconColor: .brand, title: "Resend Plan to WorkoutKit") {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    if let workoutKitResendStatus {
                        Text(workoutKitResendStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 62)
                            .padding(.trailing, AppSpacing.lg)
                            .padding(.bottom, AppSpacing.md)
                    }
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
                .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                content()
            }
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
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
                RoundedRectangle(cornerRadius: AppRadius.xs)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                StrideIcon(name: icon, size: 16, color: iconColor, strokeWeight: 2.0)
            }
            Text(title).font(.bodyRegular).layoutPriority(1)
            Spacer(minLength: AppSpacing.md)
            // A trailing control is a value, not prose: hold it to one line so it cannot
            // grow the row from the inside. `AIProvider.appleOnDevice` ("On-device (Apple
            // Intelligence)") wrapped to three lines in a `Picker` and drew straight over
            // this row's own title and the footnote beneath the card. Truncation matches
            // what Settings.app does with a long picker value — the full text is still
            // there in the menu, and the footnote below spells the choice out.
            trailing()
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 62)
    }

    // MARK: - Actions

    private func profileNameBinding(for profile: UserProfile) -> Binding<String> {
        Binding(
            get: { profile.name },
            set: { newValue in
                guard profile.name != newValue else { return }
                profile.name = newValue
                persistProfileEdit(profile)
            }
        )
    }

    private func profileGenderBinding(for profile: UserProfile) -> Binding<Gender> {
        Binding(
            get: { profile.gender },
            set: { newValue in
                guard profile.gender != newValue else { return }
                profile.gender = newValue
                persistProfileEdit(profile)
            }
        )
    }

    /// Age drives the Tanaka max-HR estimate. Defaults to 30 until the user sets it; once the
    /// user has an explicit Max HR, changing age no longer moves it (the estimate is decoupled).
    private func ageBinding(for profile: UserProfile) -> Binding<Int> {
        Binding(
            get: { profile.age ?? 30 },
            set: { newValue in
                guard profile.age != newValue else { return }
                profile.age = newValue
                persistProfileEdit(profile)
            }
        )
    }

    /// Max HR shows the effective value (explicit → age estimate → 190 default). Editing it
    /// stores an explicit `maxHeartRateBPM`, overriding the age estimate.
    private func maxHRBinding(for profile: UserProfile) -> Binding<Int> {
        Binding(
            get: { profile.effectiveMaxHeartRate ?? 190 },
            set: { newValue in
                guard profile.maxHeartRateBPM != newValue else { return }
                profile.maxHeartRateBPM = newValue
                persistProfileEdit(profile)
            }
        )
    }

    private func persistProfileEdit(_ profile: UserProfile) {
        profile.updatedAt = Date()
        context.saveOrLog("a profile edit")
    }

    private func resetAll() {
        // The whole routine — reminders, Watch entries, pending-review defaults, then
        // the models — lives in `PlanLifecycleService.resetAllData` (N11). Clearing only the
        // store left reminders firing and a deleted run able to resurrect itself.
        Task { await container.resetAllData(context: context) }
    }

    #if DEBUG
    private func resendWorkoutsToWorkoutKit(plan: TrainingPlan) {
        workoutKitResendStatus = "Resending workouts to WorkoutKit…"
        Task {
            do {
                try await container.healthKitRepository.syncWorkoutPlans(
                    for: plan,
                    unitPreference: appSettings.unitPreference
                )
                await MainActor.run {
                    workoutKitResendStatus = "WorkoutKit sync completed."
                }
            } catch {
                await MainActor.run {
                    workoutKitResendStatus = "WorkoutKit sync failed: \(error.localizedDescription)"
                }
            }
        }
    }
    #endif
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
        context.saveOrLog("sample run history")
    }

    /// Removes every seeded run, repairing the plan days they were linked to.
    ///
    /// "Mark Workouts Complete" links its generated runs to scheduled days and sets
    /// `isCompleted`, and it sits directly above this button. Deleting the runs on their
    /// own left those days still marked complete with no run behind them — the exact
    /// invariant `WorkoutRepository.delete` exists to repair, skipped because this path
    /// deletes through the context directly (D3). The relationship's `.nullify` rule
    /// clears `completedWorkout` and nothing else. The scalar backup is cleared too, for
    /// the seeded runs that carry one.
    ///
    /// No tombstone is written: seeded runs are local inventions with no
    /// `healthKitWorkoutID`, so there is no import to suppress.
    static func clear(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<RunWorkout>()) else { return }
        for run in all where run.notes == tag {
            if let scheduled = run.scheduledWorkout {
                scheduled.completedWorkout = nil
                scheduled.linkedRunWorkoutID = nil
                scheduled.isCompleted = false
            }
            context.delete(run)
        }
        context.saveOrLog("the removal of sample data")
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
        context.saveOrLog("sample plan progress")
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
        context.saveOrLog("the reset of sample plan progress")
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
