import SwiftUI
import SwiftData
import AuthenticationServices
import UserNotifications
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
    @State private var showSignOutConfirmation = false
    @State private var showPulseConsole = false
    /// The full-history archive (B6), non-nil only while its share sheet is up.
    @State private var dataExportFile: ExportedFile?
    @State private var isExportingData = false
    /// Shown when the archive could not be written, rather than the tap doing nothing.
    @State private var dataExportErrorMessage: String?
    @State private var notificationTestStatus: String?
    /// Whether iOS has notifications switched off for Stride. Re-read on every return to
    /// the foreground, since the place the runner fixes it is the Settings app.
    @State private var notificationsDeniedBySystem = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    /// Settings opens as a sheet from Home's profile button (it was a tab).
    @Environment(\.dismiss) private var dismiss
    /// Private Cloud Compute availability + daily quota, refreshed whenever the model
    /// picker changes. `nil` until read, and on devices with no server model at all.
    ///
    /// Outside the `#if DEBUG` block below on purpose: the AI Coach card ships in
    /// Release, so a debug-only declaration compiles in Debug and then fails the archive
    /// with "Cannot find 'pccStatus' in scope".
    @State private var pccStatus: ServerModelStatus?
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
        container.persistenceMode.displayName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xl) {
                    if let profile { profileHeaderCard(profile) }
                    if let profile { profileCard(profile) }
                    unitsCard
                    notificationsCard
                    duringRunCard
                    musicRoutesGearCard
                    aiCoachCard
                    dataSyncCard
                    aboutCard
                    dangerCard
                    if BuildEnvironment.showsTestFlightDiagnostics {
                        testFlightCard
                    }
                    #if DEBUG
                    developerCard
                    #endif
                }
                .padding()
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
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
            .confirmationDialog(
                "Sign out of your Apple Account?",
                isPresented: $showSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { authService.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your runs, plan and settings stay on this iPhone.")
            }
            .sheet(item: $dataExportFile) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Couldn't export your data", isPresented: Binding(
                get: { dataExportErrorMessage != nil },
                set: { if !$0 { dataExportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dataExportErrorMessage ?? "")
            }
        }
    }

    // MARK: - Profile header

    private func profileHeaderCard(_ profile: UserProfile) -> some View {
        HStack(spacing: AppSpacing.lg) {
            // A brand tint, not the route: the route means progress or go, and an
            // avatar is neither.
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.12))
                    .frame(width: avatarSize, height: avatarSize)
                if profile.name.isEmpty {
                    StrideIcon(name: .run, size: avatarSize * 0.47, color: .brandText, strokeWeight: 2.2)
                } else {
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: avatarSize * 0.47, weight: .bold))
                        .foregroundStyle(.brandText)
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
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AppSpacing.lg)
        .heroCard()
    }

    // MARK: - Profile card

    private func profileCard(_ profile: UserProfile) -> some View {
        settingsSection("Profile") {
            settingsRow(icon: .person, iconColor: .brand, title: "Name") {
                TextField("Your name", text: profileNameBinding(for: profile))
                    .multilineTextAlignment(.trailing)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            }
            rowDivider
            // Feeds the coach's fuelling amounts, which are all per kilogram (see
            // `CoachNutrition`). Apple Health is the primary source and replaces this on
            // the next launch when it has a sample, so the footnote below says so rather
            // than letting an overwritten value look like a bug.
            settingsRow(icon: .ruler, iconColor: .brand, title: "Weight") {
                NumericStepperField(
                    title: "Weight",
                    value: bodyMassBinding(for: profile),
                    range: bodyMassRange,
                    suffix: bodyMassUnitSuffix,
                    showsLabel: false
                )
            }
            footnote(Text(bodyMassFootnote))
            rowDivider
            settingsRow(icon: .person, iconColor: .brand, title: "Gender") {
                menuPicker(
                    "Gender",
                    selection: profileGenderBinding(for: profile),
                    options: Gender.allCases,
                    label: \.localizedName
                )
            }
            rowDivider
            // Typable as well as steppable, and the same control onboarding uses (S25).
            settingsRow(icon: .calendar, iconColor: .brand, title: "Age") {
                NumericStepperField(
                    title: "Age",
                    value: ageBinding(for: profile),
                    range: 10...100,
                    showsLabel: false
                )
            }
            rowDivider
            settingsRow(icon: .heart, iconColor: .brand, title: "Max HR") {
                NumericStepperField(
                    title: "Max HR",
                    value: maxHRBinding(for: profile),
                    range: 120...220,
                    suffix: "bpm",
                    showsLabel: false
                )
            }
            if profile.maxHeartRateBPM != nil {
                Button {
                    profile.maxHeartRateBPM = nil
                    persistProfileEdit(profile)
                } label: {
                    footnote(
                        Text("Reset to age estimate (\(UserProfile.estimatedMaxHeartRate(forAge: profile.age ?? UserProfile.assumedAge)) bpm)"),
                        color: .brandText
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Units card

    private var unitsCard: some View {
        settingsSection("Units") {
            UnitPreferencePicker(selection: Bindable(appSettings).unitPreference)
                .padding(AppSpacing.lg)
        }
    }

    // MARK: - Notifications card

    private var notificationsCard: some View {
        settingsSection("Notifications") {
            if notificationsDeniedBySystem {
                notificationsDeniedRow
                rowDivider
            }
            settingsRow(icon: .bell, iconColor: .brand, title: "Morning reminder") {
                Toggle("Morning reminder", isOn: Bindable(appSettings).morningReminderEnabled)
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
            if appSettings.morningReminderEnabled {
                rowDivider
                morningReminderTimeRow
            }
            rowDivider
            settingsRow(icon: .trophy, iconColor: .brand, title: "Training nudges") {
                Toggle("Training nudges", isOn: Bindable(appSettings).trainingNudgesEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .accessibilityIdentifier("settings.trainingNudges")
                    .onChange(of: appSettings.trainingNudgesEnabled) { _, enabled in
                        // Same shape as the two toggles around it (N16): off has to take
                        // down what is already queued rather than waiting for the next
                        // launch to reconcile, and on has to ask for permission before
                        // this evening's slot arrives. The next foreground re-arms.
                        Task {
                            guard enabled else {
                                await container.notificationService
                                    .cancelTrainingNudges(includingLog: true)
                                return
                            }
                            if !(await container.notificationService.isAuthorized) {
                                try? await container.notificationService.requestAuthorization()
                            }
                        }
                    }
            }
            footnote(Text("An evening nudge when a streak or your plan is slipping, and a Sunday recap. At most one a day."))
            rowDivider
            settingsRow(icon: .flame, iconColor: .warning, title: "Heat adaptation") {
                Toggle("Heat adaptation", isOn: Bindable(appSettings).heatAdaptationEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .accessibilityIdentifier("settings.heatAdaptation")
                    .onChange(of: appSettings.heatAdaptationEnabled) { _, enabled in
                        // Same shape as the morning reminder above (N16): turning it off
                        // has to take down the advisory and its pending banner now, not at
                        // the next launch, and turning it on has to ask for permission
                        // before the first evening slot arrives.
                        Task {
                            guard enabled else {
                                await container.heatAdvisoryService.clear()
                                return
                            }
                            if !(await container.notificationService.isAuthorized) {
                                try? await container.notificationService.requestAuthorization()
                            }
                        }
                    }
            }
            footnote(Text("When tomorrow looks hot or humid enough to matter, asks the evening before whether to ease the session."))
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsDeniedBySystem = status == .denied
        }
    }

    /// Shown only when iOS has notifications off for Stride. Every toggle below reads "on"
    /// in that state and none of them can deliver, so the card says so and links to the
    /// one switch that matters, rather than leaving the runner wondering why nothing comes.
    private var notificationsDeniedRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Notifications are off for Stride in iOS Settings, so none of these reminders can reach you.")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            Button("Open notification settings") {
                guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                openURL(url)
            }
            .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
            .accessibilityIdentifier("settings.openNotificationSettings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
    }

    private var morningReminderTimeRow: some View {
        settingsRow(icon: .timer, iconColor: .brand, title: "Reminder time") {
            DatePicker(
                "Reminder time",
                selection: morningReminderTimeBinding,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .accessibilityIdentifier("settings.morningReminderTime")
        }
    }

    /// The reminder time as a `Date` for `DatePicker`, stored as minutes after midnight.
    /// Setting it reschedules the reminders straight away, the same as the toggle does.
    private var morningReminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minutes = appSettings.morningReminderMinuteOfDay
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                // Split up: `(a ?? x) * 60 + (b ?? y)` alone timed out the Release type-checker.
                let hour: Int = parts.hour ?? 8
                let minute: Int = parts.minute ?? 0
                let minutes: Int = hour * 60 + minute
                guard minutes != appSettings.morningReminderMinuteOfDay else { return }
                appSettings.morningReminderMinuteOfDay = minutes
                guard let plan = activePlans.first else { return }
                Task { await container.notificationService.scheduleMorningReminders(for: plan) }
            }
        )
    }

    // MARK: - During a Run card

    private var duringRunCard: some View {
        settingsSection("During a run") {
            // The one setting that makes the app talk over the runner's music, so it
            // says what it will say and stays off until asked (U4).
            settingsRow(icon: .flag, iconColor: .brand, title: "Spoken splits") {
                Toggle("Spoken splits", isOn: Bindable(appSettings).spokenSplitsEnabled)
                    .labelsHidden()
                    .tint(.brand)
            }
            footnote(Text("Reads out each \(appSettings.unitPreference.distanceLabel) and its pace. Music ducks while it speaks."))
            rowDivider
            // Off until asked, like Spoken Splits above: it talks over the runner's music.
            settingsRow(icon: .tempo, iconColor: .brand, title: "Spoken workout steps") {
                Toggle("Spoken workout steps", isOn: Bindable(appSettings).spokenWorkoutStepsEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .accessibilityIdentifier("settings.spokenWorkoutSteps")
            }
            footnote(Text("Calls out each rep, recovery and cool-down in interval and tempo sessions, with a heads-up before each ends."))
        }
    }

    // MARK: - Music, Routes & Gear card

    private var musicRoutesGearCard: some View {
        settingsSection("Music, Routes & Gear") {
            NavigationLink {
                StrengthSettingsView()
            } label: {
                settingsRow(icon: .dumbbell, iconColor: .brand, title: "Strength training") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("settings.strengthTraining")
            footnote(Text("The equipment you have and what your strength sessions focus on."))

            rowDivider
            NavigationLink {
                RunPlaylistSettingsView()
            } label: {
                settingsRow(icon: .music, iconColor: .brand, title: "Run playlists") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            footnote(Text("Apple Music playlists shaped like the session: calmer for the warm-up and cool-down, harder through the work."))

            rowDivider
            NavigationLink {
                ShoesView()
            } label: {
                settingsRow(icon: .run, iconColor: .brand, title: "My shoes") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            footnote(Text("Tracks how far each pair has gone and warns you when one is nearly worn out."))

            rowDivider
            settingsRow(icon: .location, iconColor: .brand, title: "Routing key") {
                Text("Optional")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            // A well inside the card, lined up with the row's title like the footnotes.
            SecureField("Leave empty to use Apple Maps", text: Bindable(appSettings).orsAPIKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.dsSubhead)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(.surfacePrimary, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .strokeBorder(.cardStroke, lineWidth: 1)
                )
                .padding(.leading, Self.footnoteIndent)
                .padding(.trailing, AppSpacing.lg)
                .padding(.bottom, AppSpacing.sm)
                .accessibilityIdentifier("settings.routingKey")
            footnote(Text("Route Genius uses Apple Maps. Paste a free openrouteservice.org key to plan loops with it instead. Stored on this iPhone only."))
        }
    }

    // MARK: - AI Coach card

    private var aiCoachCard: some View {
        settingsSection("AI Coach") {
            // Named "AI Coach", the same words the coach chat uses when it sends the
            // runner here to switch it on.
            settingsRow(icon: .bolt, iconColor: .brand, title: "AI Coach") {
                Toggle("AI Coach", isOn: Bindable(appSettings).aiInsightsEnabled)
                    .labelsHidden()
                    .tint(.brand)
            }
            // The model only matters while the coach is on. A segmented control rather
            // than a menu `Picker`: the menu drew in system blue and its long value
            // ("Apple Private Cloud Compute") wrapped over the row's own title.
            if appSettings.aiInsightsEnabled {
                rowDivider
                StrideSegmentedControl(
                    selection: Bindable(appSettings).aiProvider,
                    options: AIProvider.allCases,
                    title: { Text($0 == .appleOnDevice ? "On iPhone" : "Private Cloud") },
                    subtitle: { Text($0 == .appleOnDevice ? "Apple Intelligence" : "Apple's servers") }
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Where coaching runs")
                .padding(AppSpacing.lg)
                if appSettings.aiProvider == .applePrivateCloud,
                   let status = pccStatus,
                   status.quotaMessage != nil || status.canRequestLimitIncrease {
                    rowDivider
                    privateCloudComputeStatusRow(status)
                }
                footnote(Text(Self.aiProviderFootnote(for: appSettings.aiProvider, status: pccStatus)))
            }
        }
        .task(id: appSettings.aiProvider) {
            pccStatus = await container.aiCoachService.serverModelStatus()
        }
    }

    /// Apple asks apps not to spring the daily Private Cloud Compute limit on people in a
    /// dismissible alert, but to keep the current standing visible and offer the upgrade
    /// flow — so the quota lives here, next to the model picker that opted into it. Drawn
    /// only when there is something to say: a plain "Ready" row repeated the footnote.
    @ViewBuilder
    private func privateCloudComputeStatusRow(_ status: ServerModelStatus) -> some View {
        settingsRow(
            icon: .timer,
            iconColor: status.isLimitReached ? .destructive : (status.isApproachingLimit ? .warning : .brand),
            title: "Daily allowance"
        ) {
            if status.canRequestLimitIncrease {
                Button("Options") {
                    container.aiCoachService.presentServerLimitIncrease()
                }
                .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
            }
        }
        if let message = status.quotaMessage {
            footnote(
                Text(message),
                color: status.isLimitReached ? Color.destructive : Color.warning
            )
        }
    }

    /// Static and status-in-hand rather than a computed property reading `pccStatus`:
    /// the footnote is a pure function of the provider and the snapshot, so it reads the
    /// same way the row above it does and has nothing to fall out of step with.
    private static func aiProviderFootnote(
        for provider: AIProvider,
        status: ServerModelStatus?
    ) -> String {
        switch provider {
        case .appleOnDevice:
            return String(
                localized: "Runs on your iPhone with Apple Intelligence. Your training data never leaves it.",
                comment: "Settings footnote for the on-device AI model"
            )
        case .applePrivateCloud:
            // The unavailable case is worth spelling out: the runner picked the server
            // model and is quietly getting the on-device one, which is the fallback
            // working as designed rather than a failure.
            if let status, !status.isAvailable {
                switch status.availability {
                case .deviceNotEligible:
                    return String(
                        localized: "Private Cloud Compute needs a newer iPhone, so coaching runs on your iPhone instead.",
                        comment: "Settings footnote when Private Cloud Compute is unsupported"
                    )
                case .systemNotReady, .unknownReason, .available:
                    return String(
                        localized: "Private Cloud Compute isn't ready, so coaching runs on your iPhone for now. It needs Apple Intelligence on and a connection.",
                        comment: "Settings footnote when Private Cloud Compute is not ready"
                    )
                }
            }
            return String(
                localized: "Deeper reads from Apple's servers. Apple doesn't keep your data, and Stride falls back to your iPhone when you're offline or past the daily limit.",
                comment: "Settings footnote for the Private Cloud Compute AI model"
            )
        }
    }

    // MARK: - Data & Sync card

    private var dataSyncCard: some View {
        settingsSection("Data & sync") {
            if authService.isSignedIn {
                settingsRow(icon: .check, iconColor: .success, title: "Signed in with Apple") {
                    Button("Sign out") { showSignOutConfirmation = true }
                        .buttonStyle(.strideButton(.quiet, compact: true, fullWidth: false))
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
                    // Black on daylight paper, white on the night map, as onboarding pairs them;
                    // a black button disappeared into the dark card.
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.md)
                }
            }
            rowDivider
            settingsRow(icon: .cloud, iconColor: .brand, title: "iCloud sync") {
                Toggle("iCloud sync", isOn: Bindable(appSettings).iCloudSyncEnabled)
                    .labelsHidden()
                    .tint(.brand)
            }
            if syncRestartPending {
                footnote(Text("Restart the app for this change to take effect."))
            }
            rowDivider
            NavigationLink {
                HealthKitImportView()
            } label: {
                settingsRow(icon: .heart, iconColor: .brand, title: "Import from Apple Health") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            rowDivider
            settingsRow(icon: .walk, iconColor: .brand, title: "Import walks") {
                Toggle("Import walks", isOn: Bindable(appSettings).walkImportEnabled)
                    .labelsHidden()
                    .tint(.brand)
                    .accessibilityIdentifier("settings.importWalks")
            }
            footnote(Text("Adds walks from Apple Health to your history. They stay out of your mileage, pace, records and streaks."))

            rowDivider
            Button {
                exportAllData()
            } label: {
                settingsRow(icon: .export, iconColor: .brand, title: "Export all data") {
                    if isExportingData {
                        ProgressView()
                    } else {
                        rowChevron
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(isExportingData)
            .accessibilityIdentifier("settings.exportAllData")
            footnote(Text("One ZIP with every workout, strength session and shoe as spreadsheets, and each route as a GPX file."))
        }
    }

    // MARK: - TestFlight card

    /// Everything that is for testers rather than runners, in one card at the bottom:
    /// the store and sync checks, the logs, and the notification test harness. Gated on
    /// `BuildEnvironment.showsTestFlightDiagnostics`, so an App Store build never draws it.
    private var testFlightCard: some View {
        settingsSection("TestFlight") {
            settingsRow(icon: .cloud, iconColor: .secondary, title: "Active store") {
                Text(persistenceStatusText)
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            }
            if appSettings.iCloudSyncEnabled {
                footnote(Text("Check sync in Pulse Console: look for CloudKit setup, export and import events."))
            }
            rowDivider
            NavigationLink {
                CloudKitDebugView()
            } label: {
                settingsRow(icon: .gear, iconColor: .secondary, title: "CloudKit debug data") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            #if canImport(PulseUI)
            rowDivider
            Button {
                showPulseConsole = true
            } label: {
                settingsRow(icon: .history, iconColor: .secondary, title: "Pulse Console") {
                    rowChevron
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            #endif
            rowDivider
            Button {
                Task {
                    do {
                        if !(await container.notificationService.isAuthorized) {
                            try await container.notificationService.requestAuthorization()
                        }
                        try await container.notificationService.triggerAllTestNotifications(in: context)
                        notificationTestStatus = "Sent morning, synced-run and training-nudge test notifications."
                    } catch {
                        notificationTestStatus = "Failed to send test notifications: \(error.localizedDescription)"
                    }
                }
            } label: {
                settingsRow(icon: .bell, iconColor: .secondary, title: "Trigger all notifications") {
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
                settingsRow(icon: .run, iconColor: .secondary, title: "Notify latest run") {
                    StrideIcon(name: .play, size: 12,
                               color: Color.secondary.opacity(0.7), strokeWeight: 2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if let notificationTestStatus {
                footnote(Text(notificationTestStatus))
            } else {
                footnote(Text("Sends each local notification now, to check copy, sound and what a tap opens."))
            }
        }
        #if canImport(PulseUI)
        .sheet(isPresented: $showPulseConsole) { NavigationStack { ConsoleView() } }
        #endif
    }

    // MARK: - About card

    private var aboutCard: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return settingsSection("About") {
            settingsRow(icon: .gear, iconColor: Color.secondary, title: "Version") {
                Text(build.map { "\(version) (\($0))" } ?? version)
                    .font(.dsSubhead.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Danger card

    private var dangerCard: some View {
        Button(role: .destructive) {
            showResetConfirmation = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                StrideIcon(name: .close, size: 16, color: .destructive, strokeWeight: 2.2)
                Text("Reset all data")
            }
        }
        .buttonStyle(.strideButton(.destructive))
    }

    // MARK: - Developer card (DEBUG)

    #if DEBUG
    private var developerCard: some View {
        let plan = activePlans.first
        return VStack(spacing: 16) {
            settingsSection("Developer · Run history") {
                settingsRow(icon: .history, iconColor: .secondary, title: "\(seedWeeks) weeks of history") {
                    Stepper("\(seedWeeks) weeks of history", value: $seedWeeks, in: 2...24)
                        .labelsHidden()
                }
                rowDivider
                Button {
                    DebugRunGenerator.seed(weeks: seedWeeks, context: context)
                } label: {
                    settingsRow(icon: .play, iconColor: .success, title: "Seed run history") {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                rowDivider
                Button {
                    DebugRunGenerator.clear(context: context)
                } label: {
                    settingsRow(icon: .close, iconColor: .destructive, title: "Clear seeded runs") {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.destructive)
            }

            if let plan {
                settingsSection("Developer · Plan progress") {
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
                        settingsRow(icon: .check, iconColor: .success, title: "Mark workouts complete") {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    rowDivider
                    Button {
                        DebugRunGenerator.resetPlanProgress(plan: plan, context: context)
                    } label: {
                        settingsRow(icon: .close, iconColor: .destructive, title: "Reset debug completions") {
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
                        settingsRow(icon: .calendar, iconColor: .brand, title: "Resend plan to WorkoutKit") {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)

                    if let workoutKitResendStatus {
                        Text(workoutKitResendStatus)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Self.footnoteIndent)
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
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            // Leading, not the default centre: a footnote narrower than the card was
            // centred, so each one started at a different x.
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .strideCard()
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

    /// Where a row's title starts (16 padding + 32 icon tile + 14 gap): footnotes and
    /// dividers line up with it.
    private static let footnoteIndent: CGFloat = 62

    private var rowDivider: some View {
        Divider().padding(.leading, Self.footnoteIndent)
    }

    /// The line of explanation under a row. One helper so every footnote starts under the
    /// row's title and keeps the same gap above the next divider; hand-padded copies had
    /// drifted (one had no bottom gap at all and sat on the divider).
    private func footnote(_ text: Text, color: Color = .secondary) -> some View {
        text
            .font(.dsCaption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.footnoteIndent)
            .padding(.trailing, AppSpacing.lg)
            .padding(.bottom, AppSpacing.md)
    }

    private var rowChevron: some View {
        StrideIcon(name: .chevronRight, size: 12,
                   color: Color.secondary.opacity(0.5), strokeWeight: 2)
    }

    /// A choice from a short list as a row value: the current value in secondary text with
    /// the up-down chevron, opening the system menu. A bare menu `Picker` drew in system
    /// blue, the one blue thing on the screen (the same shape as `RunShoeRow`).
    private func menuPicker<Value: Hashable>(
        _ title: LocalizedStringKey,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Text(label(selection.wrappedValue))
                    .font(.bodyRegular)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.dsCaption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(label(selection.wrappedValue))
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

    // MARK: Body mass

    /// Kilograms per pound, for the imperial round-trip below.
    private static let poundsPerKilogram = 2.20462

    /// The weight shown, in the runner's own unit.
    ///
    /// Stored as kilograms always — every rate in `CoachNutrition` is per kilogram, and a
    /// stored number whose meaning moved with a display toggle would be a data bug
    /// waiting to happen. Converting here means the toggle changes what is drawn and
    /// nothing else.
    ///
    /// `NumericStepperField` is integer-valued, which is the right resolution: fuelling
    /// amounts are rounded to whole grams and 50 ml, so a tenth of a kilo cannot move
    /// them. The round-trip through pounds is lossy for that reason and deliberately so —
    /// re-reading 158 lb as 71.667 kg and drawing it back as 158 lb is stable.
    private func bodyMassBinding(for profile: UserProfile) -> Binding<Int> {
        Binding(
            get: {
                guard let kilograms = profile.bodyMassKilograms else { return bodyMassPlaceholder }
                return Int((displayMass(fromKilograms: kilograms)).rounded())
            },
            set: { newValue in
                let kilograms = kilograms(fromDisplay: Double(newValue))
                guard profile.bodyMassKilograms != kilograms else { return }
                profile.bodyMassKilograms = kilograms
                persistProfileEdit(profile)
            }
        )
    }

    private func displayMass(fromKilograms kilograms: Double) -> Double {
        appSettings.unitPreference == .metric
            ? kilograms
            : kilograms * Self.poundsPerKilogram
    }

    private func kilograms(fromDisplay value: Double) -> Double {
        appSettings.unitPreference == .metric
            ? value
            : value / Self.poundsPerKilogram
    }

    /// What the stepper shows before a weight is known.
    ///
    /// A middle-of-the-range value rather than the range's floor: the field has to show
    /// *something*, and starting at 30 kg means a runner who taps the stepper once has
    /// told the coach they weigh 31 kg. Nothing is written until they actually edit it,
    /// so this is a starting point for the control, not a stored default.
    private var bodyMassPlaceholder: Int {
        appSettings.unitPreference == .metric ? 70 : 154
    }

    private var bodyMassRange: ClosedRange<Int> {
        // Mirrors `CoachNutrition.validMass`, converted: anything outside it is a
        // mis-entry or the wrong unit, and the coach ignores it anyway.
        appSettings.unitPreference == .metric ? 25...250 : 55...550
    }

    private var bodyMassUnitSuffix: String {
        appSettings.unitPreference == .metric
            ? String(localized: "kg", comment: "Body mass unit")
            : String(localized: "lb", comment: "Body mass unit")
    }

    /// Says where the number comes from, because Health overwrites it.
    ///
    /// Without this, a runner who types a weight and finds it changed after the next
    /// launch has watched the app silently discard their input. Naming Health as the
    /// source makes that behaviour a stated rule rather than a bug.
    private var bodyMassFootnote: String {
        String(
            localized: """
            Used to work out your fuelling amounts. Read from Apple Health when it has \
            your weight — what you type here applies now and until Health next supplies one.
            """,
            comment: "Settings footnote under the weight field"
        )
    }

    /// Age drives the Tanaka max-HR estimate. Defaults to `UserProfile.assumedAge` until the
    /// user sets it; once the user has an explicit Max HR, changing age no longer moves it
    /// (the estimate is decoupled).
    private func ageBinding(for profile: UserProfile) -> Binding<Int> {
        Binding(
            get: { profile.age ?? UserProfile.assumedAge },
            set: { newValue in
                guard profile.age != newValue else { return }
                profile.age = newValue
                persistProfileEdit(profile)
            }
        )
    }

    /// Max HR shows the effective value (explicit → age estimate → estimate for the assumed
    /// age). Editing it stores an explicit `maxHeartRateBPM`, overriding the age estimate.
    ///
    /// The last fallback used to be a flat `190`, which is `220 − 30` — a different formula
    /// from the Tanaka estimate the Age row above it implies and onboarding shows. A runner
    /// who left both defaults alone saw "187 bpm" during setup and then "Age 30 / Max HR 190"
    /// here, with the two rows contradicting each other on screen (S7).
    private func maxHRBinding(for profile: UserProfile) -> Binding<Int> {
        Binding(
            get: {
                profile.effectiveMaxHeartRate
                    ?? UserProfile.estimatedMaxHeartRate(forAge: profile.age ?? UserProfile.assumedAge)
            },
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

    /// Builds the full-history archive (B6) and presents the share sheet.
    ///
    /// The files' text is built here, on the main actor, because it reads SwiftData models
    /// that belong to this view's context; only the plain strings cross to the background
    /// task that writes and zips them, which is the part that can take a moment on a long
    /// history.
    private func exportAllData() {
        guard !isExportingData else { return }
        let exportedAt = Date()
        let entries: [DataExport.Entry]
        do {
            entries = DataExport.entries(
                runs: try context.fetch(FetchDescriptor<RunWorkout>()),
                strengthSessions: try context.fetch(FetchDescriptor<StrengthWorkout>()),
                shoes: try context.fetch(FetchDescriptor<Shoe>()),
                exportedAt: exportedAt
            )
        } catch {
            AppLogger.log("Data export fetch failed: \(error.localizedDescription)", label: "Export", level: .error)
            dataExportErrorMessage = error.localizedDescription
            return
        }
        let name = DataExport.archiveName(exportedAt: exportedAt)
        isExportingData = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DataExportWriter.writeArchive(entries: entries, name: name) }
            }.value
            isExportingData = false
            switch result {
            case .success(let url):
                dataExportFile = ExportedFile(url: url)
            case .failure(let error):
                dataExportErrorMessage = error.localizedDescription
            }
        }
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
    /// "Mark workouts complete" links its generated runs to scheduled days and sets
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
