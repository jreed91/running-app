import SwiftUI
import SwiftData
import AuthenticationServices
import CloudKit
import CoreData

@MainActor
private final class CloudKitImportWaitState {
    var didResume = false
    var observer: NSObjectProtocol?
    var timeoutTimer: Timer?
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ didImport: Bool) {
        guard !didResume else { return }
        didResume = true
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation?.resume(returning: didImport)
        continuation = nil
    }
}

// MARK: - OBWelcome

struct OBWelcome: View {
    let onStart: () -> Void
    let onSignIn: (String) -> Void

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // The night map, as on the icon. Its glow is an `EllipticalGradient`, whose
            // radii are fractions of the frame, so it needs no `GeometryReader` (U7).
            NightMapBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 90)

                StrideAppMark(size: 120)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .opacity(appeared ? 1 : 0)
                    .adaptiveAnimation(AppAnimation.entrance, value: appeared)

                Spacer(minLength: 40)

                Text("WELCOME TO STRIDE.")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.8)
                    .foregroundStyle(.brand)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.08), value: appeared)

                Spacer().frame(height: 10)

                Text("Training plans that\nadapt to your pace.")
                    .font(.dsLargeTitle.weight(.heavy))
                    .kerning(-0.95)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .lineSpacing(-4)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.14), value: appeared)

                Spacer().frame(height: 14)

                Text("VDOT-based pace zones. Adaptive weekly plans. Built for iPhone and Apple Watch.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.md)
                    .lineSpacing(2)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.20), value: appeared)

                Spacer(minLength: 30)

                Button(action: onStart) {
                    HStack(spacing: 10) {
                        Text("Get started").font(.dsHeadline.weight(.bold))
                        StrideIcon(name: .chevronRight, size: 15, color: .onFill, strokeWeight: 2.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.lg)
                    .background(.route, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                    .appGlow(.strong, color: .brand)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.lg)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .foregroundStyle(.onFill)
                .buttonStyle(BouncyButtonStyle())
                .accessibilityIdentifier("onboarding.getStarted")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)
                .adaptiveAnimation(AppAnimation.entrance.delay(0.28), value: appeared)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { result in
                    if case .success(let auth) = result,
                       let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                        Task { @MainActor in onSignIn(credential.user) }
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .padding(.top, AppSpacing.md)
                .opacity(appeared ? 1 : 0)
                .adaptiveAnimation(AppAnimation.entrance.delay(0.34), value: appeared)

                Spacer().frame(height: 34)
            }
            .padding(.horizontal, AppSpacing.xxl)
        }
        .onAppear { appeared = true }
        // The welcome screens sit on the night map in both appearances, like the icon.
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - OBWelcomeBack

struct OBWelcomeBack: View {
    @Environment(AuthService.self) private var authService
    @Environment(AppSettings.self) private var appSettings
    @Query private var profiles: [UserProfile]

    let onStartFresh: () -> Void
    private let restoreCoordinator = WelcomeBackRestoreCoordinator()

    @State private var iCloudIssue: String?
    // Set once the initial-sync wait concludes. `syncOutcome` records *how* it
    // concluded: a definitive finish (`imported`/`noRemoteData`) lets an empty
    // store fall through to fresh onboarding, whereas a `timedOut` result keeps
    // the user on the restore screen so late-arriving iCloud data isn't lost.
    @State private var initialSyncFinished = false
    @State private var syncOutcome: WelcomeBackRestoreCoordinator.InitialSyncOutcome?

    init(onStartFresh: @escaping () -> Void) {
        self.onStartFresh = onStartFresh
        _profiles = Query()
    }

    private var hasData: Bool { !profiles.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The same night map as `OBWelcome`.
            NightMapBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 90)
                StrideAppMark(size: 120)
                Spacer(minLength: 40)

                Text("WELCOME BACK.")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.8)
                    .foregroundStyle(.brand)
                Spacer().frame(height: 10)
                Text(hasData ? "Your training plan\nis ready." : "Checking\niCloud…")
                    .font(.dsLargeTitle.weight(.heavy))
                    .kerning(-0.95)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .animation(.easeInOut(duration: 0.3), value: hasData)
                Spacer().frame(height: 14)
                if !hasData {
                    Text("Looking for your training data in iCloud.\nThis can take a few minutes on a new device.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.md)
                        .lineSpacing(2)
                    if let iCloudIssue {
                        Spacer().frame(height: 12)
                        Text(iCloudIssue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AppSpacing.md)
                    }
                    Spacer().frame(height: 28)
                    ProgressView().tint(.brand).scaleEffect(1.2)
                }

                Spacer(minLength: 30)
            }
            .padding(.horizontal, AppSpacing.xxl)

            VStack(spacing: 14) {
                if hasData {
                    Button {
                        authService.welcomeBackPending = false
                    } label: {
                        HStack(spacing: 10) {
                            Text("Continue to Dashboard").font(.dsHeadline.weight(.bold))
                            StrideIcon(name: .chevronRight, size: 15, color: .onFill, strokeWeight: 2.6)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.lg)
                        .background(.route, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .appGlow(.strong, color: .brand)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.lg)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                    .foregroundStyle(.onFill)
                    .buttonStyle(.plain)
                }

                Button(action: onStartFresh) {
                    Text("Start fresh instead")
                        .font(.dsSubhead.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, 44)
        }
        .environment(\.colorScheme, .dark)
        .task { await checkICloudStatus() }
        .task { await waitForInitialSync() }
        .onChange(of: initialSyncFinished) { _, finished in
            guard finished else { return }
            // CloudKit imports arrive in batches; the first completed-import event
            // fires `initialSyncFinished` but the UserProfile record may still be
            // in a later batch. Wait an additional 3 seconds so any remaining
            // batches can land in the store and surface through @Query before we
            // decide there is nothing to restore.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // A timed-out wait is inconclusive: keep the returning user on the
                // restore screen (with its manual "Start fresh" button) instead of
                // dropping them into new-user onboarding while data may still sync.
                let outcome = syncOutcome ?? .timedOut
                if restoreCoordinator.shouldStartFresh(outcome: outcome, hasData: hasData) {
                    onStartFresh()
                }
            }
        }
    }

    private func checkICloudStatus() async {
        let container = CKContainer(identifier: StrideSchema.cloudKitContainerID)
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<CKAccountStatus, Never>) in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
        let presentation = restoreCoordinator.presentation(for: status)
        iCloudIssue = presentation.issueMessage
        if presentation.shouldAutoTransition {
            scheduleUnavailableICloudTransition()
        }
    }

    /// CloudKit can't deliver records when the account isn't usable. Give the
    /// user a few seconds to read the diagnostic, then advance so they aren't
    /// stuck staring at "Checking iCloud…" indefinitely.
    private func scheduleUnavailableICloudTransition() {
        Task { @MainActor in
            await restoreCoordinator.waitBeforeAutoTransition()
            // The account is unusable, so no CloudKit records will arrive — a
            // definitive "no remote data" conclusion, not a timeout.
            syncOutcome = .noRemoteData
            initialSyncFinished = true
        }
    }

    /// Waits for a definitive "initial sync done" signal so we can tell new
    /// users apart from returning users whose data is still arriving.
    ///
    /// Three possible signals, whichever comes first wins:
    /// 1. iCloud sync is disabled — nothing will ever sync, so transition right away.
    /// 2. `NSPersistentCloudKitContainer` posts an import event with `endDate` set —
    ///    SwiftData uses NSPersistentCloudKitContainer under the hood, so this
    ///    fires once CloudKit has finished pulling the current set of changes.
    /// 3. A 60s fallback timeout — defensive for devices where the notification
    ///    never arrives (e.g. CloudKit container failed to initialise).
    @MainActor
    private func waitForInitialSync() async {
        let outcome = await restoreCoordinator.waitForInitialSync(
            iCloudSyncEnabled: appSettings.iCloudSyncEnabled,
            waitForImport: waitForCloudKitImportEvent(timeoutNanoseconds:)
        )
        // Preserve a definitive conclusion reached earlier (e.g. the unusable-iCloud
        // auto-transition) rather than letting a later timeout overwrite it.
        if syncOutcome == nil || outcome != .timedOut {
            syncOutcome = outcome
        }
        initialSyncFinished = true
    }

    @MainActor
    private func waitForCloudKitImportEvent(timeoutNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let state = CloudKitImportWaitState()
            state.continuation = continuation

            state.observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil,
                queue: .main
            ) { note in
                guard
                    let event = note.userInfo?[
                        NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                    ] as? NSPersistentCloudKitContainer.Event,
                    event.type == .import,
                    event.endDate != nil
                else { return }
                Task { @MainActor in
                    state.finish(true)
                }
            }

            state.timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeoutNanoseconds) / 1_000_000_000, repeats: false) { _ in
                Task { @MainActor in
                    state.finish(false)
                }
            }
        }
    }
}

// MARK: - OBShell

struct OBShell<Content: View>: View {
    let stepIndex: Int
    let total: Int
    let kicker: String
    let title: String
    let subtitle: String
    let ctaLabel: String
    var secondaryLabel: String?
    var onSecondary: (() -> Void)?
    var ctaEnabled: Bool = true
    let onBack: () -> Void
    let onCTA: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress chrome
                VStack(spacing: 0) {
                    Spacer().frame(height: 54)
                    HStack(spacing: 14) {
                        Button(action: onBack) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 32, height: 32)
                                StrideIcon(name: .chevronLeft, size: 14, color: .primary, strokeWeight: 2.4)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("onboarding.back.\(stepIndex)")

                        // The platform's own determinate bar, which is what this was drawing
                        // by hand: a 4pt track filled to a fraction. It needs no
                        // `GeometryReader` to measure itself (U7), and it is hidden from
                        // VoiceOver because the "3/8" counter beside it already says this —
                        // the same call `ProgressRingView` makes next to its stat (U10).
                        ProgressView(value: Double(stepIndex), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(.brand)
                            .adaptiveAnimation(AppAnimation.bouncy, value: stepIndex)
                            .accessibilityHidden(true)

                        // Steps count 1…total (the welcome screen is step 0, uncounted;
                        // the final "ready" screen is the last step) — so show
                        // `stepIndex` directly rather than `stepIndex + 1`, which used to
                        // start at "2/total" and print the last number twice.
                        Text("\(stepIndex)/\(total)")
                            .font(.dsCaption2.weight(.bold).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, 18)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kicker.uppercased())
                                .font(.dsCaption.weight(.bold))
                                .kerning(1.6)
                                .foregroundStyle(.brand)
                            Text(title)
                                .font(.dsTitle1.weight(.heavy))
                                .kerning(-0.8)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.bodyRegular)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                        }

                        content()
                    }
                    .padding(.horizontal, AppSpacing.xxl)
                    .padding(.bottom, 120)
                }
            }

            // CTA pinned at bottom
            VStack(spacing: 10) {
                Button(action: onCTA) {
                    HStack(spacing: 10) {
                        Text(ctaLabel).font(.dsHeadline.weight(.bold))
                        StrideIcon(name: .chevronRight, size: 14, color: .onFill, strokeWeight: 2.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.lg)
                    .background(LinearGradient.route.opacity(ctaEnabled ? 1 : 0.5),
                                in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .appGlow(.strong, color: .brand, isActive: ctaEnabled)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .foregroundStyle(.onFill)
                .buttonStyle(.plain)
                .disabled(!ctaEnabled)
                .accessibilityIdentifier("onboarding.primaryCTA.\(stepIndex)")

                if let secondaryLabel, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryLabel)
                            .font(.dsSubhead.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.secondaryCTA.\(stepIndex)")
                }
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, 44)
        }
    }
}

// MARK: - OBRaceCard

struct OBRaceCard: View {
    let race: RaceType
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private var color: Color {
        switch race {
        case .maintainFitness: return .brand
        case .fiveK: return .zoneInterval
        case .halfMarathon: return .zoneTempo
        case .marathon: return .zoneEasy
        case .custom: return .zoneMarathon
        }
    }
    private var icon: StrideIconName {
        switch race {
        case .maintainFitness: return .heart
        case .fiveK: return .bolt
        case .halfMarathon: return .tempo
        case .marathon: return .run
        case .custom: return .ruler
        }
    }
    private var distanceLabel: String {
        let isImperial = appSettings.unitPreference == .imperial
        switch race {
        case .maintainFitness: return "No race target"
        case .fiveK:         return isImperial ? "3.1 mi"  : "5.0 km"
        case .halfMarathon:  return isImperial ? "13.1 mi" : "21.1 km"
        case .marathon:      return isImperial ? "26.2 mi" : "42.2 km"
        case .custom:        return "Set your own"
        }
    }

    /// Whether `distanceLabel` is a measurement or a phrase.
    ///
    /// The monospaced face is the app's *data* face — it exists so digits line up. Two of
    /// the five badges are prose ("No race target", "Set your own"), and monospacing those
    /// made them wide enough to wrap inside the baseline-aligned `HStack`, which then broke
    /// "Custom Distance" onto a second line as well (S3).
    private var distanceLabelIsMeasurement: Bool {
        switch race {
        case .maintainFitness, .custom: return false
        case .fiveK, .halfMarathon, .marathon: return true
        }
    }
    private var desc: String {
        switch race {
        case .maintainFitness: return "Balanced fitness, no race block"
        case .fiveK: return "Fast, speed-focused plans"
        case .halfMarathon: return "Endurance with tempo work"
        case .marathon: return "Long-run focused, biggest build"
        case .custom: return "Any distance — 10K, 50K, or anything"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 48, height: 48)
                    StrideIcon(name: icon, size: 22, color: color, strokeWeight: 2.2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(race.localizedName).font(.bodyStrong)
                        Text(distanceLabel)
                            .font(distanceLabelIsMeasurement
                                  ? .dsCaption.weight(.semibold).monospaced()
                                  : .dsCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Text("\(desc) · \(race.typicalWeeks.lowerBound)–\(race.typicalWeeks.upperBound) wks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Selection is `Color.brand`, and the per-race tint stays on the icon.
                //
                // `color` comes from the pace-zone palette, which is a *data* scale — it
                // encodes effort on charts and in the run HUD. Used as decoration here it put
                // `zoneInterval`, i.e. red, on the default-selected 5K card, so the app's
                // first interactive screen presented its pre-selected answer in the same
                // colour it uses for errors — and step 3's selection is orange, so selection
                // colour was not even internally consistent (S17).
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(AppSpacing.lg)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle()).foregroundStyle(.primary)
    }
}

// MARK: - OBCustomDistanceCard

/// Lets the runner dial in an arbitrary goal distance when `RaceType.custom` is selected.
/// The canonical value is stored in kilometres; the display adapts to the unit preference.
struct OBCustomDistanceCard: View {
    @Binding var distanceKm: Double

    @Environment(AppSettings.self) private var appSettings

    private var isImperial: Bool { appSettings.unitPreference == .imperial }

    /// Common goal distances offered as one-tap chips (stored in kilometres).
    private let quickPicks: [(label: String, km: Double)] = [
        ("10K", 10), ("15K", 15), ("20K", 20), ("30K", 30), ("50K", 50)
    ]

    private var displayValue: String {
        isImperial
            ? String(format: "%.1f mi", distanceKm * 0.621371)
            : String(format: "%.1f km", distanceKm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .ruler, size: 18, color: .brand)
                Text("RACE DISTANCE")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayValue)
                    .font(.dsHeadline.weight(.bold).monospaced())
                    .foregroundStyle(.brand)
            }

            Slider(value: $distanceKm, in: 1...80, step: 0.1)
                .tint(.brand)
                .accessibilityIdentifier("onboarding.customDistanceSlider")

            HStack(spacing: 8) {
                ForEach(quickPicks, id: \.label) { pick in
                    let isOn = abs(distanceKm - pick.km) < 0.05
                    Button { distanceKm = pick.km } label: {
                        Text(pick.label)
                            .font(.dsFootnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm)
                            .background(
                                isOn ? Color.brand : Color.surfaceTertiary,
                                in: RoundedRectangle(cornerRadius: AppRadius.sm)
                            )
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - OBRaceDetailsCard

struct OBRaceDetailsCard: View {
    @Binding var raceName: String
    @Binding var raceDate: Date

    let race: RaceType
    let minimumDate: Date

    private var trimmedRaceName: String {
        raceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .flag, size: 18, color: .brand)
                Text("GOAL RACE")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Race name")
                    .font(.captionStrong)
                    .foregroundStyle(.secondary)
                TextField("Austin \(race.displayName)", text: $raceName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .font(.bodyRegular)
                    .padding(.horizontal, 14)
                    .padding(.vertical, AppSpacing.md)
                    .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .strokeBorder(trimmedRaceName.isEmpty ? Color.destructive.opacity(0.35) : Color.clear)
                    )
            }

            DatePicker(
                "Race date",
                selection: $raceDate,
                in: minimumDate...,
                displayedComponents: .date
            )
            .font(.bodyStrong)
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - OBStartDateCard

struct OBStartDateCard: View {
    @Binding var startDate: Date
    let planWeeks: Int
    let isRacePlan: Bool
    let minimumDate: Date
    let maximumDate: Date?

    private var dateRange: ClosedRange<Date> {
        let upper = maximumDate ?? minimumDate.adding(days: 365)
        let lower = min(minimumDate, upper)
        return lower...upper
    }

    private var weeksLabel: String {
        guard isRacePlan else { return "Plan starts on this date" }
        return "\(planWeeks)-week plan ends on race day"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StrideIcon(name: .calendar, size: 18, color: .brand)
                Text("START DATE")
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
            }

            DatePicker(
                "Start date",
                selection: $startDate,
                in: dateRange,
                displayedComponents: .date
            )
            .font(.bodyStrong)

            Text(weeksLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - OBLevelRow

enum OBFitnessSelection: CaseIterable, Sendable {
    case newToRunning
    case recreational
    case experienced
    case competitive

    /// Read from `FitnessLevel` rather than restated here, so the word on this card and the
    /// word Settings shows for the same answer cannot drift apart again (S9).
    var title: String { fitnessLevel.localizedName }

    var subtitle: String {
        switch self {
        case .newToRunning: return "Run/walk intervals. Just getting started."
        case .recreational: return "Run weekly. Casual but consistent."
        case .experienced:  return "Consistent training week to week."
        case .competitive:  return "Racing regularly with structured training."
        }
    }

    /// One level per option. `.experienced` and `.competitive` both mapped to `.advanced`
    /// until `FitnessLevel.competitive` existed, which made two of the four cards produce an
    /// identical plan — and say so, both reading "Plan starts ~25 mi/week" (S10).
    var fitnessLevel: FitnessLevel {
        switch self {
        case .newToRunning: return .beginner
        case .recreational: return .intermediate
        case .experienced:  return .advanced
        case .competitive:  return .competitive
        }
    }

    var barCount: Int {
        switch self {
        case .newToRunning: return 1
        case .recreational: return 2
        case .experienced: return 3
        case .competitive: return 4
        }
    }
}

struct OBFitnessRow: View {
    let selection: OBFitnessSelection
    let goalRace: RaceType
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private let barHeights: [CGFloat] = [8, 12, 16, 22]

    private var planStartLabel: String {
        let km = selection.fitnessLevel.startingWeeklyKm(for: goalRace)
        switch appSettings.unitPreference {
        case .metric:
            return String(format: "Plan starts ~%.0f km/week", km)
        case .imperial:
            return String(format: "Plan starts ~%.0f mi/week", km * 0.621371)
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: AppRadius.micro)
                                .fill(index < selection.barCount ? Color.brand : Color.secondary.opacity(0.12))
                                .frame(width: 5, height: barHeights[index])
                        }
                    }
                    .frame(width: 28, height: 22)

                    Text(selection.title)
                        .font(.dsHeadline.weight(.bold))
                        .kerning(-0.3)
                        .foregroundStyle(.primary)

                    Spacer()
                    OBRadio(isSelected: isSelected, color: .brand)
                }

                Text(selection.subtitle)
                    .font(.dsFootnote)
                    .kerning(-0.1)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)

                Text(planStartLabel)
                    .font(.dsCaption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(.leading, 38)
            }
            .padding(14)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct OBLevelRow: View {
    let level: FitnessLevel
    let race: RaceType
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppSettings.self) private var appSettings

    private var desc: String {
        switch level {
        case .beginner: return "New to running or returning"
        case .intermediate: return "Comfortable running 3× per week"
        case .advanced: return "Consistent weekly mileage"
        case .competitive: return "Racing regularly with structured training"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.localizedName).font(.bodyStrong)
                    Text(desc)
                        .font(.caption).foregroundStyle(.secondary)
                    Text({
                        let km = level.startingWeeklyKm(for: race)
                        if appSettings.unitPreference == .imperial {
                            return String(format: "%.0f mi/wk base", km * 0.621371)
                        }
                        return String(format: "%.0f km/wk base", km)
                    }())
                        .font(.dsCaption.weight(.semibold).monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(.horizontal, 18).padding(.vertical, AppSpacing.lg)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(isSelected ? Color.brand : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle()).foregroundStyle(.primary)
    }
}

// MARK: - OBTimeWheelColumn

struct OBTimeWheelColumn: View {
    let label: String
    @Binding var value: Int
    let range: [Int]
    var isMuted = false

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.dsCaption2.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            Picker(label, selection: $value) {
                ForEach(range, id: \.self) { option in
                    Text(String(format: "%02d", option))
                        .font(.dsTitle1.monospaced())
                        .foregroundStyle(isMuted ? .secondary : .primary)
                        .tag(option)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 116)
            .clipped()
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xs)
                    .strokeBorder(Color.brand.opacity(0.32), lineWidth: 1.5)
                    .padding(.horizontal, AppSpacing.sm)
                    .frame(height: 42),
                alignment: .center
            )
        }
        .frame(maxWidth: .infinity)
    }
}

struct OBWheelColumnStyle: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.dsCaption2.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            content
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: 116)
                .clipped()
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: AppRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.xs)
                        .strokeBorder(Color.brand.opacity(0.32), lineWidth: 1.5)
                        .padding(.horizontal, AppSpacing.sm)
                        .frame(height: 42),
                    alignment: .center
                )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - OBPaceCell

struct OBPaceCell: View {
    let zone: String
    let color: Color
    let pace: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.uppercased())
                    .font(.dsCaption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(color)
                Text(pace)
                    .font(.dsSubhead.weight(.semibold).monospaced())
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.md).padding(.vertical, 10)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

// MARK: - OBPermissionRow

struct OBPermissionRow: View {
    let icon: StrideIconName
    let label: String
    let desc: String
    let tint: Color
    let isOn: Bool
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(tint.opacity(isActive ? 0.25 : 0.15))
                    .frame(width: 40, height: 40)
                StrideIcon(name: icon, size: 20, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.bodyStrong)
                Text(isActive ? "Requesting access…" : desc)
                    .font(.caption).foregroundStyle(isActive ? tint : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: isActive)
            }
            Spacer()
            // Status, not a control. This row has no tap target — the CTA at the bottom
            // requests all three in sequence — but an empty stroked circle is the standard
            // unchecked-checkbox shape, so on a row with an icon, a title and a subtitle it
            // read as "tap me to grant this" (S14). "Not yet" says the same thing without
            // promising an interaction that isn't there.
            Group {
                if isActive {
                    ProgressView().tint(tint)
                        .frame(height: 28)
                } else if isOn {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Color.success)
                                .frame(width: 22, height: 22)
                            StrideIcon(name: .check, size: 11, color: .white, strokeWeight: 3)
                        }
                        Text("Allowed")
                            .font(.dsCaption.weight(.semibold))
                            .foregroundStyle(Color.success)
                    }
                    .frame(height: 28)
                } else {
                    Text("Not yet")
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 28)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
        }
        .padding(.vertical, AppSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Requesting" : isOn ? "Allowed" : "Not yet granted")
    }
}

// MARK: - OBRadio

struct OBRadio: View {
    let isSelected: Bool
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? color : Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 22, height: 22)
            if isSelected {
                Circle().fill(color).frame(width: 22, height: 22)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                StrideIcon(name: .check, size: 12, color: .onFill, strokeWeight: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
    }
}

// MARK: - OBReady

struct OBReady: View {
    let goalRace: RaceType
    let planWeeks: Int
    var progressTotal = 8
    let goalTimeSeconds: Double
    let estimatedWorkouts: Int
    let peakKm: Double
    let isCreatingPlan: Bool
    /// This screen used to draw the progress bar without the chevron every other step has,
    /// which made the one screen most likely to prompt a change of mind — the first sight of
    /// peak mileage, week count and the phase breakdown — the only one you could not go back
    /// from (S16).
    let onBack: () -> Void
    let onViewPlan: () -> Void

    @Environment(AppSettings.self) private var appSettings

    /// Peak weekly volume for the chart's y-axis, expressed in the user's preferred unit.
    private var peakMiles: Int {
        appSettings.unitPreference == .imperial
            ? max(1, Int((peakKm * 0.621371).rounded()))
            : max(1, Int(peakKm.rounded()))
    }

    /// Shares `durationString` with the Plan tab rather than reimplementing it.
    ///
    /// This used to round where `durationString` truncates, so the same plan's finish time
    /// read 26:24 here and 26:23 one screen later (S11).
    private var goalTimeLabel: String { goalTimeSeconds.durationString }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Chrome: progress bar at 100% with 7/7 counter
                Spacer().frame(height: 54)
                HStack(spacing: 14) {
                    Button(action: onBack) {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.1))
                                .frame(width: 32, height: 32)
                            StrideIcon(name: .chevronLeft, size: 14, color: .primary, strokeWeight: 2.4)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreatingPlan)
                    .opacity(isCreatingPlan ? 0.4 : 1)
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("onboarding.back.\(progressTotal)")

                    // The same bar as the step chrome, full (U7). The `GeometryReader` this
                    // replaces was measuring a width only to fill all of it.
                    ProgressView(value: 1)
                        .progressViewStyle(.linear)
                        .tint(.brand)
                        .accessibilityHidden(true)
                    Text("\(progressTotal)/\(progressTotal)")
                        .font(.dsCaption2.weight(.bold).monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR PLAN")
                                .font(.dsCaption2.weight(.bold))
                                .kerning(1.6)
                                .foregroundStyle(.brand)
                            Text("\(planWeeks)-week \(goalRace.localizedName) plan\nbuilt for you.")
                                .font(.dsTitle1.weight(.heavy))
                                .kerning(-0.7)
                                .foregroundStyle(.primary)
                                .lineSpacing(-2)
                        }
                        .padding(.horizontal, AppSpacing.xl)

                        // Summary card
                        HStack(spacing: 0) {
                            // "PROJECTED", not "GOAL": `goalTimeSeconds` is
                            // `predictedTime(vdot:)` for the runner's *current* VDOT, so
                            // labelling it a goal told them their goal was to run exactly as
                            // fast as they already do (S12).
                            OBSummaryStat(label: "PROJECTED", value: goalTimeLabel)
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBSummaryStat(label: "WEEKS", value: "\(planWeeks)")
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBSummaryStat(
                                label: appSettings.unitPreference == .imperial ? "PEAK MI" : "PEAK KM",
                                value: "\(peakMiles)"
                            )
                        }
                        .padding(AppSpacing.lg)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                        .padding(.horizontal, AppSpacing.lg)

                        // Weekly mileage chart
                        WeeklyMileageChart(planWeeks: planWeeks, goalRace: goalRace, peakMiles: peakMiles, unit: appSettings.unitPreference)
                            .padding(.horizontal, AppSpacing.lg)

                        Spacer().frame(height: 120)
                    }
                    .padding(.top, AppSpacing.sm)
                }
            }

            // CTA
            Button(action: onViewPlan) {
                Group {
                    if isCreatingPlan {
                        ProgressView().tint(.onFill)
                    } else {
                        HStack(spacing: 10) {
                            Text("Start training").font(.dsHeadline.weight(.bold))
                            StrideIcon(name: .chevronRight, size: 15, color: .onFill, strokeWeight: 2.6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(.route, in: RoundedRectangle(cornerRadius: AppRadius.lg))
                .appGlow(.strong, color: .brand)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.lg)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .foregroundStyle(.onFill)
            .buttonStyle(.plain)
            .disabled(isCreatingPlan)
            .accessibilityIdentifier("onboarding.startTraining")
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, 44)
        }
    }
}

// MARK: - OBSummaryStat

private struct OBSummaryStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.dsCaption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.dsTitle2.monospaced())
                .kerning(-0.5)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - WeeklyMileageChart

private struct WeeklyMileageChart: View {
    let planWeeks: Int
    let goalRace: RaceType
    let peakMiles: Int
    let unit: UnitPreference

    @State private var barsVisible = false

    /// Bars: (week number, mileage, phase).
    private var bars: [(n: Int, mi: Int, phase: TrainingPhase)] {
        guard planWeeks > 0 else { return [] }
        let phases = phaseSchedule(for: planWeeks)
        let peak = Double(peakMiles)
        return (0..<planWeeks).map { i in
            let phase = phases[i]
            let fraction: Double = {
                let progress = Double(i) / Double(max(planWeeks - 1, 1))
                switch phase {
                case .base:  return 0.5 + progress * 0.25
                case .build: return 0.75 + progress * 0.20
                case .peak:  return 1.00
                case .taper: return 0.45
                }
            }()
            // Cutback every 4th week in base/build.
            let cutback = ((i + 1) % 4 == 0 && (phase == .base || phase == .build)) ? 0.75 : 1.0
            return (i + 1, max(1, Int((peak * fraction * cutback).rounded())), phase)
        }
    }

    private func phaseSchedule(for weeks: Int) -> [TrainingPhase] {
        let base = max(weeks * 3 / 8, 1)
        let build = max(weeks * 2 / 8, 1)
        let peak = max(weeks * 2 / 8, 1)
        let taperStart = weeks - 1
        return (0..<weeks).map { i in
            if i >= taperStart { return .taper }
            if i < base { return .base }
            if i < base + build { return .build }
            if i < base + build + peak { return .peak }
            return .taper
        }
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WEEKLY \(unit == .imperial ? "MILEAGE" : "KILOMETRES")")
                .font(.dsCaption2.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(bars.enumerated()), id: \.element.n) { index, bar in
                    VStack(spacing: 4) {
                        Text("\(bar.mi)")
                            .font(.dsCaption2.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                            .opacity(barsVisible ? 1 : 0)
                        RoundedRectangle(cornerRadius: AppRadius.micro)
                            .fill(bar.phase.tint)
                            .frame(height: barsVisible ? max(6, CGFloat(bar.mi) / CGFloat(peakMiles) * 72) : 2)
                            .animation(AppAnimation.bouncy.delay(Double(index) * 0.04), value: barsVisible)
                        Text("W\(bar.n)")
                            .font(.dsCaption2.weight(.semibold).monospaced())
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 104)
            .task { barsVisible = true }

            // Legend. Driven off the same `tint` the bars use, rather than a second list of
            // colours that has to be kept in step with the first by hand.
            HStack(spacing: 12) {
                ForEach([TrainingPhase.base, .build, .peak, .taper], id: \.self) { phase in
                    let name = phase.localizedName
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: AppRadius.micro)
                            .fill(phase.tint)
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.dsCaption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, AppSpacing.xs)
        }
        .padding(AppSpacing.lg)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.lg))
    }
}

// MARK: - OBEquipmentGrid

struct OBEquipmentGrid: View {
    @Binding var selectedEquipment: Set<StrengthEquipment>

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(StrengthEquipment.allCases, id: \.self) { item in
                OBEquipmentCard(
                    equipment: item,
                    isSelected: selectedEquipment.contains(item)
                ) {
                    if selectedEquipment.contains(item) {
                        selectedEquipment.remove(item)
                    } else {
                        selectedEquipment.insert(item)
                    }
                }
            }
        }
    }
}

// MARK: - OBEquipmentCard

struct OBEquipmentCard: View {
    let equipment: StrengthEquipment
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                iconView
                labelView
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.dsCallout)
                        .foregroundStyle(Color.brand)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.md)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(borderColor, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconView: some View {
        Image(systemName: equipment.systemImage)
            .font(.dsBody.weight(.medium))
            .frame(width: 28)
            .foregroundStyle(isSelected ? Color.brand : Color.secondary)
    }

    /// Two lines, not one: "Resistance Bands" is the longest of the six names and does not
    /// fit a half-width grid cell at default Dynamic Type even at the 0.8 scale floor, so a
    /// single line truncated it to "Resistance…" while its grid neighbour fit (S2).
    private var labelView: some View {
        Text(equipment.localizedName)
            .font(.dsSubhead.weight(.semibold))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: Color {
        isSelected ? Color.brand.opacity(0.12) : Color.surfaceSecondary
    }

    private var borderColor: Color {
        isSelected ? Color.brand.opacity(0.5) : Color.clear
    }
}

// MARK: - OBStrengthFocusPicker

struct OBStrengthFocusPicker: View {
    @Binding var focus: StrengthFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRAINING FOCUS")
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            VStack(spacing: 8) {
                ForEach(StrengthFocus.allCases, id: \.self) { option in
                    OBStrengthFocusRow(
                        option: option,
                        isSelected: focus == option,
                        onTap: { focus = option }
                    )
                }
            }
        }
    }
}

private struct OBStrengthFocusRow: View {
    let option: StrengthFocus
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                OBRadio(isSelected: isSelected, color: .brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.localizedName)
                        .font(.dsSubhead.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(option.subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.md)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(borderColor, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: Color {
        isSelected ? Color.brand.opacity(0.10) : Color.surfaceSecondary
    }

    private var borderColor: Color {
        isSelected ? Color.brand.opacity(0.4) : Color.clear
    }
}
