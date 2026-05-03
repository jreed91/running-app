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
            GeometryReader { geo in
                ZStack {
                    Color.surfacePrimary
                    RadialGradient(
                        colors: [Color.brand.opacity(0.22), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: max(geo.size.width, geo.size.height) * 0.85
                    )
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 90)

                StrideAppMark(size: 120)
                    .scaleEffect(appeared ? 1 : 0.55)
                    .opacity(appeared ? 1 : 0)
                    .adaptiveAnimation(AppAnimation.entrance, value: appeared)

                Spacer(minLength: 40)

                Text("WELCOME TO STRIDE.")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.8)
                    .foregroundStyle(.brand)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.08), value: appeared)

                Spacer().frame(height: 10)

                Text("Training plans that\nadapt to your pace.")
                    .font(.system(size: 34, weight: .heavy))
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
                    .padding(.horizontal, 12)
                    .lineSpacing(2)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                    .adaptiveAnimation(AppAnimation.entrance.delay(0.20), value: appeared)

                Spacer(minLength: 30)

                Button(action: onStart) {
                    HStack(spacing: 10) {
                        Text("Get started").font(.system(size: 17, weight: .bold))
                        StrideIcon(name: .chevronRight, size: 15, color: .white, strokeWeight: 2.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: Color.brand.opacity(0.5), radius: 14, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .foregroundStyle(.white)
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
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.top, 12)
                .opacity(appeared ? 1 : 0)
                .adaptiveAnimation(AppAnimation.entrance.delay(0.34), value: appeared)

                Spacer().frame(height: 34)
            }
            .padding(.horizontal, 24)
        }
        .onAppear { appeared = true }
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
    // Set true once we have a definitive signal that CloudKit's initial
    // import has run. Combined with `hasData` below, an empty store after
    // this point means the user is new (or has no iCloud data) and should
    // proceed with regular onboarding rather than waiting forever.
    @State private var initialSyncFinished = false

    init(onStartFresh: @escaping () -> Void) {
        self.onStartFresh = onStartFresh
        _profiles = Query()
    }

    private var hasData: Bool { !profiles.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    Color.surfacePrimary
                    RadialGradient(
                        colors: [Color.brand.opacity(0.22), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: max(geo.size.width, geo.size.height) * 0.85
                    )
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 90)
                StrideAppMark(size: 120)
                Spacer(minLength: 40)

                Text("WELCOME BACK.")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.8)
                    .foregroundStyle(.brand)
                Spacer().frame(height: 10)
                Text(hasData ? "Your training plan\nis ready." : "Checking\niCloud…")
                    .font(.system(size: 34, weight: .heavy))
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
                        .padding(.horizontal, 12)
                        .lineSpacing(2)
                    if let iCloudIssue {
                        Spacer().frame(height: 12)
                        Text(iCloudIssue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    Spacer().frame(height: 28)
                    ProgressView().tint(.brand).scaleEffect(1.2)
                }

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 14) {
                if hasData {
                    Button {
                        authService.welcomeBackPending = false
                    } label: {
                        HStack(spacing: 10) {
                            Text("Continue to Dashboard").font(.system(size: 17, weight: .bold))
                            StrideIcon(name: .chevronRight, size: 15, color: .white, strokeWeight: 2.6)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(color: Color.brand.opacity(0.5), radius: 14, y: 8)
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    }
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                }

                Button(action: onStartFresh) {
                    Text("Start fresh instead")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
        }
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
                if restoreCoordinator.shouldStartFresh(initialSyncFinished: true, hasData: hasData) {
                    onStartFresh()
                }
            }
        }
    }

    private func checkICloudStatus() async {
        let container = CKContainer(identifier: "iCloud.com.running.stride")
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
        await restoreCoordinator.waitForInitialSync(
            iCloudSyncEnabled: appSettings.iCloudSyncEnabled,
            waitForImport: waitForCloudKitImportEvent(timeoutNanoseconds:)
        )
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
                        .accessibilityIdentifier("onboarding.back.\(stepIndex)")

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 4)
                                Capsule().fill(Color.brand)
                                    .frame(width: geo.size.width * CGFloat(stepIndex + 1) / CGFloat(total),
                                           height: 4)
                                    .adaptiveAnimation(AppAnimation.bouncy, value: stepIndex)
                            }
                        }
                        .frame(height: 4)

                        Text("\(stepIndex + 1)/\(total)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kicker.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .kerning(1.6)
                                .foregroundStyle(.brand)
                            Text(title)
                                .font(.system(size: 32, weight: .heavy))
                                .kerning(-0.8)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.bodyRegular)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                        }

                        content()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }
            }

            // CTA pinned at bottom
            VStack(spacing: 10) {
                Button(action: onCTA) {
                    HStack(spacing: 10) {
                        Text(ctaLabel).font(.system(size: 17, weight: .bold))
                        StrideIcon(name: .chevronRight, size: 14, color: .white, strokeWeight: 2.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.brand.opacity(ctaEnabled ? 1 : 0.5),
                                in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.brand.opacity(ctaEnabled ? 0.4 : 0), radius: 12, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .disabled(!ctaEnabled)
                .accessibilityIdentifier("onboarding.primaryCTA.\(stepIndex)")

                if let secondaryLabel, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.secondaryCTA.\(stepIndex)")
                }
            }
            .padding(.horizontal, 20)
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
        }
    }
    private var icon: StrideIconName {
        switch race {
        case .maintainFitness: return .heart
        case .fiveK: return .bolt
        case .halfMarathon: return .tempo
        case .marathon: return .run
        }
    }
    private var distanceLabel: String {
        let isImperial = appSettings.unitPreference == .imperial
        switch race {
        case .maintainFitness: return isImperial ? "No race target" : "No race target"
        case .fiveK:         return isImperial ? "3.1 mi"  : "5.0 km"
        case .halfMarathon:  return isImperial ? "13.1 mi" : "21.1 km"
        case .marathon:      return isImperial ? "26.2 mi" : "42.2 km"
        }
    }
    private var desc: String {
        switch race {
        case .maintainFitness: return "Balanced fitness, no race block"
        case .fiveK: return "Fast, speed-focused plans"
        case .halfMarathon: return "Endurance with tempo work"
        case .marathon: return "Long-run focused, biggest build"
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
                        Text(race.displayName).font(.bodyStrong)
                        Text(distanceLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(desc) · \(race.typicalWeeks.lowerBound)–\(race.typicalWeeks.upperBound) wks")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: color)
            }
            .padding(16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? color : Color.clear, lineWidth: 2))
        }
        .buttonStyle(BouncyButtonStyle()).foregroundStyle(.primary)
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
                    .padding(.vertical, 12)
                    .background(.surfaceTertiary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
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
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
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
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - OBLevelRow

enum OBFitnessSelection: CaseIterable, Sendable {
    case newToRunning
    case recreational
    case experienced
    case competitive

    var title: String {
        switch self {
        case .newToRunning: return "New to running"
        case .recreational: return "Recreational"
        case .experienced: return "Experienced"
        case .competitive: return "Competitive"
        }
    }

    var subtitle: String {
        switch self {
        case .newToRunning: return "Run/walk intervals. 0-8 mi per week."
        case .recreational: return "Run weekly. 8-20 mi per week."
        case .experienced: return "Consistent. 20-40 mi per week."
        case .competitive: return "40+ mi per week. Racing regularly."
        }
    }

    var fitnessLevel: FitnessLevel {
        switch self {
        case .newToRunning: return .beginner
        case .recreational: return .intermediate
        case .experienced, .competitive: return .advanced
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
    let isSelected: Bool
    let onSelect: () -> Void

    private let barHeights: [CGFloat] = [8, 12, 16, 22]

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(index < selection.barCount ? Color.brand : Color.secondary.opacity(0.12))
                                .frame(width: 5, height: barHeights[index])
                        }
                    }
                    .frame(width: 28, height: 22)

                    Text(selection.title)
                        .font(.system(size: 17, weight: .bold))
                        .kerning(-0.3)
                        .foregroundStyle(.primary)

                    Spacer()
                    OBRadio(isSelected: isSelected, color: .brand)
                }

                Text(selection.subtitle)
                    .font(.system(size: 13))
                    .kerning(-0.1)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
            }
            .padding(14)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
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
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.displayName).font(.bodyStrong)
                    Text(desc)
                        .font(.caption).foregroundStyle(.secondary)
                    Text({
                        let km = level.startingWeeklyKm(for: race)
                        if appSettings.unitPreference == .imperial {
                            return String(format: "%.0f mi/wk base", km * 0.621371)
                        }
                        return String(format: "%.0f km/wk base", km)
                    }())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                OBRadio(isSelected: isSelected, color: .brand)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
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
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            Picker(label, selection: $value) {
                ForEach(range, id: \.self) { option in
                    Text(String(format: "%02d", option))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(isMuted ? .secondary : .primary)
                        .tag(option)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 116)
            .clipped()
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.brand.opacity(0.32), lineWidth: 1.5)
                    .padding(.horizontal, 8)
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
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            content
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: 116)
                .clipped()
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.brand.opacity(0.32), lineWidth: 1.5)
                        .padding(.horizontal, 8)
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
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(color)
                Text(pace)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
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
                RoundedRectangle(cornerRadius: 12)
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
            Group {
                if isActive {
                    ProgressView().tint(tint)
                        .frame(width: 28, height: 28)
                } else if isOn {
                    ZStack {
                        Circle().fill(Color.success)
                            .frame(width: 28, height: 28)
                        StrideIcon(name: .check, size: 13, color: .white, strokeWeight: 3)
                    }
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
        }
        .padding(.vertical, 12)
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
                StrideIcon(name: .check, size: 12, color: .white, strokeWeight: 3)
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
    let estimatedKm: Int
    let isCreatingPlan: Bool
    let onViewPlan: () -> Void

    @Environment(AppSettings.self) private var appSettings

    /// Estimated peak weekly mileage for the chart's y-axis.
    private var peakMiles: Int {
        let peakKm = Double(estimatedKm) / Double(max(planWeeks, 1)) * 1.40
        return appSettings.unitPreference == .imperial
            ? max(1, Int((peakKm * 0.621371).rounded()))
            : max(1, Int(peakKm.rounded()))
    }

    private var goalTimeLabel: String {
        let total = max(0, Int(goalTimeSeconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Chrome: progress bar at 100% with 7/7 counter
                Spacer().frame(height: 54)
                HStack(spacing: 14) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 4)
                            Capsule().fill(Color.brand).frame(height: 4)
                                .frame(width: geo.size.width)
                        }
                    }
                    .frame(height: 4)
                    Text("\(progressTotal)/\(progressTotal)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR PLAN")
                                .font(.system(size: 11, weight: .bold))
                                .kerning(1.6)
                                .foregroundStyle(.brand)
                            Text("\(planWeeks)-week \(goalRace.displayName) plan\nbuilt for you.")
                                .font(.system(size: 28, weight: .heavy))
                                .kerning(-0.7)
                                .foregroundStyle(.primary)
                                .lineSpacing(-2)
                        }
                        .padding(.horizontal, 20)

                        // Summary card
                        HStack(spacing: 0) {
                            OBSummaryStat(label: "GOAL", value: goalTimeLabel)
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBSummaryStat(label: "WEEKS", value: "\(planWeeks)")
                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 36)
                            OBSummaryStat(
                                label: appSettings.unitPreference == .imperial ? "PEAK MI" : "PEAK KM",
                                value: "\(peakMiles)"
                            )
                        }
                        .padding(16)
                        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 16)

                        // Weekly mileage chart
                        WeeklyMileageChart(planWeeks: planWeeks, goalRace: goalRace, peakMiles: peakMiles, unit: appSettings.unitPreference)
                            .padding(.horizontal, 16)

                        Spacer().frame(height: 120)
                    }
                    .padding(.top, 8)
                }
            }

            // CTA
            Button(action: onViewPlan) {
                Group {
                    if isCreatingPlan {
                        ProgressView().tint(.white)
                    } else {
                        HStack(spacing: 10) {
                            Text("Start training").font(.system(size: 17, weight: .bold))
                            StrideIcon(name: .chevronRight, size: 15, color: .white, strokeWeight: 2.6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: Color.brand.opacity(0.5), radius: 14, y: 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                )
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .disabled(isCreatingPlan)
            .accessibilityIdentifier("onboarding.startTraining")
            .padding(.horizontal, 20)
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
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
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

    private func phaseColor(_ phase: TrainingPhase) -> Color {
        switch phase {
        case .base:  return .zoneEasy
        case .build: return .zoneTempo
        case .peak:  return .zoneInterval
        case .taper: return .zoneMarathon
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WEEKLY \(unit == .imperial ? "MILEAGE" : "KILOMETRES")")
                .font(.system(size: 11, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(bars.enumerated()), id: \.element.n) { index, bar in
                    VStack(spacing: 4) {
                        Text("\(bar.mi)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .opacity(barsVisible ? 1 : 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(phaseColor(bar.phase))
                            .frame(height: barsVisible ? max(6, CGFloat(bar.mi) / CGFloat(peakMiles) * 72) : 2)
                            .animation(AppAnimation.bouncy.delay(Double(index) * 0.04), value: barsVisible)
                        Text("W\(bar.n)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 104)
            .task { barsVisible = true }

            // Legend
            HStack(spacing: 12) {
                ForEach([
                    ("Base",  Color.zoneEasy),
                    ("Build", Color.zoneTempo),
                    ("Peak",  Color.zoneInterval),
                    ("Taper", Color.zoneMarathon),
                ], id: \.0) { name, color in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
    }
}
