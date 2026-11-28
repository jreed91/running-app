import SwiftUI
import SwiftData
import CoreLocation
import UserNotifications
import HealthKit

// MARK: - OnboardingView

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(AuthService.self) private var authService

    // Navigation
    /// Which screen is showing. See `OnboardingStep` for the order.
    @State private var step: OnboardingStep = .welcome
    @State private var goingForward = true

    // Step data
    /// Which generator onboarding is heading for. `.pregnancy` re-points three of the eight
    /// steps (timing, calibration, and the summary) at questions a pregnancy plan actually
    /// needs, because a due date is not a race date and a 5K time buys a pregnancy plan
    /// nothing — it prescribes no paces. See `docs/PREGNANCY_RUNNING_EVIDENCE.md`.
    @State private var planKind: PlanKind = .standard
    @State private var dueDate = Date().adding(weeks: 20)
    @State private var pregnancyScreeningConfirmed = false
    @State private var prePregnancyWeeklyMinutes = PregnancyRunningPolicy.defaultWeeklyRunMinutes(for: .intermediate)
    @State private var pregnancyHabituallyVigorous = false
    /// Whether the runner has touched the weekly-minutes field. Until they do, choosing a
    /// fitness level on the step before re-seeds it; once they have, it is theirs and the
    /// level no longer overwrites it.
    @State private var didEditPrePregnancyMinutes = false
    /// How long a Start Running runner can run without stopping today, which decides the
    /// stage their plan starts at. Asked in the 5K-time step's place.
    @State private var startingPoint: StartRunningProgram.StartingPoint = .notYet

    @State private var goalRace: RaceType = .fiveK
    @State private var raceName = RaceType.fiveK.displayName
    @State private var raceDate = Date().startOfWeek.adding(weeks: 8)
    /// Canonical custom goal distance in kilometres (used when `goalRace == .custom`).
    @State private var customDistanceKm: Double = 15.0
    @State private var planStart: Date = Date().startOfWeek.adding(weeks: 1).startOfDay
    @State private var fitnessLevel: FitnessLevel = .intermediate
    @State private var fitnessSelection: OBFitnessSelection = .recreational
    @State private var fiveKHours = 0
    @State private var fiveKMinutes = 26
    @State private var fiveKSeconds = 24
    /// True once the user confirms the 5K step (Continue). If they skip it, the
    /// default 26:24 must not be recorded as their real estimate — a nil estimate
    /// lets the plan derive VDOT from fitness level/gender instead.
    @State private var didEnter5KTime = false
    @State private var selectedDays: Set<Int> = [0, 2, 4, 5]
    /// A preference shown on the schedule step. Not stored on the profile yet: the plan
    /// generators place the long run themselves, so "Flexible" is a real third answer
    /// here rather than another way of saying Sunday.
    @State private var longRunDay: LongRunDay = .saturday

    // HR-zone calibration (shown on the Calibrate step). Age drives the Tanaka max-HR
    // estimate; an explicit override decouples it. Both are optional — untouched values
    // are not forced onto the profile.
    @State private var age = UserProfile.assumedAge
    @State private var maxHROverride: Int? = nil
    @State private var didEnterHR = false

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
    private let totalSteps = OnboardingStep.countedSteps

    private enum LongRunDay: String, CaseIterable {
        case saturday = "Sat"
        case sunday = "Sun"
        case flexible = "Flexible"

        var accessibilityName: String {
            switch self {
            case .saturday: return String(localized: "Saturday")
            case .sunday: return String(localized: "Sunday")
            case .flexible: return String(localized: "Flexible")
            }
        }
    }

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
        if isStartRunningPlan { return startingPoint.weeks }
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
        // A pregnancy plan runs *to* the due date, so the due date is the start date's
        // ceiling — the same role race day plays for a race plan. `startDateValid` then
        // covers both without a second validity rule.
        if isPregnancyPlan { return dueDate.startOfDay }
        return goalRace.isGoalRace ? raceDate.startOfDay.adding(days: -7) : nil
    }

    // MARK: Pregnancy

    private var isPregnancyPlan: Bool { planKind == .pregnancy }

    private var isStartRunningPlan: Bool { planKind == .startRunning }

    /// Run days the Start Running plan will actually use: up to three of the chosen days.
    private var startRunningDaysPerWeek: Int {
        StartRunningPlanService.runOffsets(
            preferred: selectedDays.sorted(),
            weeklyRunDays: selectedDays.count
        ).count
    }

    private var gestationalAgeAtStart: GestationalAge {
        GestationalAge.on(planStartDate, dueDate: dueDate)
    }

    /// Mirrors `PregnancyPlanService`'s own span so the summary screen promises the number of
    /// weeks the generator will actually produce: from the Monday of the start week through
    /// the week the runner is due.
    private var pregnancyPlanWeeks: Int {
        let days = Calendar.current.dateComponents(
            [.day],
            from: planStartDate.startOfWeek,
            to: dueDate.startOfDay
        ).day ?? 0
        return max(1, min(42, days / 7 + 1))
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

    /// Goal distance in meters, resolving a custom distance when applicable.
    private var effectiveRaceDistanceMeters: Double {
        goalRace.usesCustomDistance ? customDistanceKm * 1_000 : goalRace.distanceMeters
    }

    private var estimatedWorkouts: Int { planWeeks * max(selectedDays.count, 3) }

    /// The runner's recent running in Health, read on each step so it is there once Health
    /// access is granted. Sizes the previews below; the plan itself reads it again at build.
    @State private var recentVolume: RecentRunningVolume?

    /// The weeks the plan would build for `level` with today's choices.
    private func previewWeeks(for level: FitnessLevel) -> [TrainingPlanService.WeekVolume] {
        container.trainingPlanService.previewWeeks(
            fitnessLevel: level,
            goalRace: goalRace,
            raceDistanceMeters: effectiveRaceDistanceMeters,
            numberOfWeeks: planWeeks,
            runDays: max(selectedDays.count, 1),
            recentVolume: recentVolume
        )
    }

    private var planPreview: [TrainingPlanService.WeekVolume] { previewWeeks(for: fitnessLevel) }

    /// Whether the runner's recent running lowered week one below what the level alone gives.
    private var startsFromRecentRunning: Bool {
        guard recentVolume != nil, let first = planPreview.first else { return false }
        let usual = container.trainingPlanService.previewWeeks(
            fitnessLevel: fitnessLevel,
            goalRace: goalRace,
            raceDistanceMeters: effectiveRaceDistanceMeters,
            numberOfWeeks: planWeeks,
            runDays: max(selectedDays.count, 1),
            recentVolume: nil
        ).first
        return first.scheduledKm < (usual?.scheduledKm ?? 0) - 0.5
    }

    /// Steps slide the way the runner is going; under Reduce Motion they cross-fade.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            currentStep
                .id(step)
                .transition(stepTransition)
        }
        .adaptiveAnimation(AppAnimation.bouncy, value: step)
        .ignoresSafeArea()
        .task(id: step) {
            // Re-checked per step so a grant on the permissions step is picked up, but
            // only until the recent running has been read once.
            guard recentVolume == nil else { return }
            // `isAuthorized` is a synchronous call into healthd, which on CI can take
            // minutes. It must block neither the main actor nor the cooperative pool.
            let repository = container.healthKitRepository
            guard await repository.isAuthorizedOffCooperativePool() else { return }
            recentVolume = await repository.recentRunningVolume()
        }
        // A friend's race invite opened before onboarding is done: the goal step starts
        // on their race. Past the goal step it waits, and the new-plan flow offers it
        // once the tabs are up, rather than changing a goal already chosen.
        .onAppear { takeRaceInvite() }
        .onChange(of: container.appNavigation.pendingRaceInvite) { _, _ in takeRaceInvite() }
    }

    private func takeRaceInvite() {
        guard let invite = container.appNavigation.pendingRaceInvite,
              step.rawValue <= OnboardingStep.goal.rawValue
        else { return }
        container.appNavigation.pendingRaceInvite = nil
        planKind = .standard
        goalRace = invite.raceType
        raceName = invite.name
        if let date = invite.raceDate() { raceDate = date }
        if let meters = invite.customDistanceMeters { customDistanceKm = meters / 1_000 }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .welcome:
            if authService.welcomeBackPending {
                OBWelcomeBack(onStartFresh: handleStartFresh)
            } else {
                OBWelcome(onStart: advance, onSignIn: handleSignIn)
            }
        case .goal:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Your goal",
                    title: "What are you training for?",
                    subtitle: "Pick a race distance, keep running strong without one, or start from run/walk.",
                    ctaLabel: "Continue",
                    onBack: retreat,
                    onCTA: advance) {
                goalContent
            }
        case .timing where isPregnancyPlan:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Timing",
                    title: "When are you due?",
                    subtitle: "Your plan runs from the start date through the week you're due, easing off as it goes.",
                    ctaLabel: "Continue",
                    ctaEnabled: startDateValid,
                    onBack: retreat,
                    onCTA: advance) {
                pregnancyTimingContent
            }
        case .timing:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Timing",
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
        // Units used to be a step of its own, answering a question the device already
        // knows (`UnitPreference.localeDefault`) — so nine steps stood between a new
        // runner and a usable app, one of them a fork with a right answer (U10). It is a
        // control on this step now, pre-set and there to be corrected rather than asked.
        case .level:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "About you",
                    title: "How would you describe your running?",
                    subtitle: levelSubtitle,
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                levelContent
            }
        // A 5K time buys a pregnancy plan nothing — it prescribes no paces — so the
        // calibration slot asks the two things that plan is actually built from, and carries
        // the screening gate that decides whether it gets built at all.
        case .calibrate where isPregnancyPlan:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Health check",
                    title: "A couple of checks first.",
                    subtitle: "Stride won't build a pregnancy plan until you've read this and confirmed it.",
                    ctaLabel: "Continue",
                    ctaEnabled: pregnancyScreeningConfirmed,
                    onBack: retreat,
                    onCTA: advance) {
                pregnancyHealthContent
            }
        // A runner who can't yet run five minutes has no 5K time to give. What places a
        // Start Running plan is how long they can run today.
        case .calibrate where isStartRunningPlan:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Starting point",
                    title: "How long can you run without stopping?",
                    subtitle: "Your plan starts from here. Starting a little easy costs you nothing.",
                    ctaLabel: "Continue",
                    onBack: retreat,
                    onCTA: { didEnter5KTime = false; advance() }) {
                OBStartingPointPicker(selection: $startingPoint)
            }
        case .calibrate:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Calibrate",
                    title: "Your recent 5K time?", subtitle: "Used to compute your VDOT and pace zones. You can skip or update this later.",
                    ctaLabel: "Continue",
                    secondaryLabel: "I don't know my 5K time",
                    onSecondary: { didEnter5KTime = false; advance() },
                    onBack: retreat,
                    onCTA: { didEnter5KTime = true; advance() }) {
                timeContent
            }
        case .schedule:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Schedule",
                    title: "Which days can you run?",
                    subtitle: isStartRunningPlan
                        ? "Three runs a week, with a day between. Pick more and we'll use the three most spread out."
                        : "Pick your typical week. We'll place harder workouts on your energy days.",
                    ctaLabel: "Continue", onBack: retreat, onCTA: advance) {
                scheduleContent
            }
        case .strength:
            // A pregnancy plan cannot skip strength outright: the daily pelvic floor
            // prescription rides on that session, so clearing the equipment falls back to
            // bodyweight rather than to nothing. The secondary label says which it is.
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Strength training",
                    title: "What equipment do you have?",
                    subtitle: isPregnancyPlan
                        ? "We'll add 1–2 sessions per week, each opening with pelvic floor work."
                        : isStartRunningPlan
                            ? "Optional: one short session a week, on a day off running."
                            : "We'll add 1–2 strength sessions per week tailored to your gear.",
                    ctaLabel: "Continue",
                    secondaryLabel: isPregnancyPlan ? "Bodyweight only" : "Skip strength training",
                    onSecondary: { selectedEquipment.removeAll(); advance() },
                    onBack: retreat,
                    onCTA: advance) {
                strengthContent
            }
        case .permissions:
            OBShell(stepIndex: step.rawValue, total: totalSteps, kicker: "Permissions",
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
        case .ready:
            if isStartRunningPlan {
                OBStartRunningReady(
                    startingPoint: startingPoint,
                    runDaysPerWeek: startRunningDaysPerWeek,
                    progressTotal: totalSteps,
                    isCreatingPlan: isCreatingPlan,
                    onBack: retreat,
                    onViewPlan: { isCreatingPlan = true; createProfileAndPlan() }
                )
            } else if isPregnancyPlan {
                OBPregnancyReady(
                    planWeeks: pregnancyPlanWeeks,
                    gestationalAgeAtStart: gestationalAgeAtStart,
                    runDaysPerWeek: max(selectedDays.count, 1),
                    progressTotal: totalSteps,
                    isCreatingPlan: isCreatingPlan,
                    onBack: retreat,
                    onViewPlan: { isCreatingPlan = true; createProfileAndPlan() }
                )
            } else {
                OBReady(goalRace: goalRace, planWeeks: planWeeks,
                        progressTotal: totalSteps,
                        goalTimeSeconds: goalFinishTimeSeconds,
                        estimatedWorkouts: estimatedWorkouts, weeks: planPreview,
                        startsFromRecentRunning: startsFromRecentRunning,
                        isCreatingPlan: isCreatingPlan, onBack: retreat,
                        onViewPlan: { isCreatingPlan = true; createProfileAndPlan() })
            }
        }
    }

    // MARK: - Navigation

    private func advance() {
        goingForward = true
        withAnimation(reduceMotion ? AppAnimation.reduced : AppAnimation.bouncy) { step = step.next }
    }
    private func retreat() {
        goingForward = false
        withAnimation(reduceMotion ? AppAnimation.reduced : AppAnimation.bouncy) { step = step.previous }
    }

    // MARK: - Goal content

    private var goalContent: some View {
        VStack(spacing: 10) {
            ForEach(RaceType.allCases, id: \.self) { race in
                OBRaceCard(race: race, isSelected: planKind == .standard && goalRace == race) {
                    planKind = .standard
                    goalRace = race
                    recalibrateRaceDate()
                }
            }

            if planKind == .standard, goalRace.usesCustomDistance {
                OBCustomDistanceCard(distanceKm: $customDistanceKm)
                    .onChange(of: customDistanceKm) { _, _ in recalibrateRaceDate() }
            }

            // Below a heading of its own rather than as a sixth race card: the five above are
            // all answers to "how far", and this one selects a different generator and
            // re-points the rest of onboarding.
            HStack {
                Text("SPECIALIZED")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, AppSpacing.sm)

            OBStartRunningPlanCard(isSelected: isStartRunningPlan) {
                chooseStartRunning()
            }

            OBSpecializedPlanCard(isSelected: isPregnancyPlan) {
                planKind = .pregnancy
                // A pregnancy plan genuinely has no goal race, which is what
                // `.maintainFitness` means. `PlanKind` carries the rest.
                goalRace = .maintainFitness
                recalibrateDueDate()
            }
        }
    }

    // MARK: - Pregnancy content

    private var pregnancyTimingContent: some View {
        VStack(spacing: 16) {
            OBDueDateCard(
                dueDate: $dueDate,
                gestationalAgeAtStart: gestationalAgeAtStart,
                minimumDate: minimumStartDate
            )

            OBStartDateCard(
                startDate: $planStart,
                planWeeks: pregnancyPlanWeeks,
                isRacePlan: false,
                minimumDate: minimumStartDate,
                maximumDate: maximumStartDate
            )
        }
        .onChange(of: planStart) { _, _ in recalibrateDueDate() }
    }

    private var pregnancyHealthContent: some View {
        VStack(spacing: 16) {
            OBPregnancyHealthCheckCard(isConfirmed: $pregnancyScreeningConfirmed)
            OBPrePregnancyRunningCard(
                weeklyMinutes: $prePregnancyWeeklyMinutes,
                habituallyVigorous: $pregnancyHabituallyVigorous,
                onEditMinutes: { didEditPrePregnancyMinutes = true }
            )
        }
    }

    // MARK: - Start Running

    /// Points onboarding at a Start Running plan. It has no goal race, which is what
    /// `.maintainFitness` means; `PlanKind` carries the rest. Someone choosing it is new to
    /// running or coming back to it, so the level step opens on that answer.
    private func chooseStartRunning() {
        planKind = .startRunning
        goalRace = .maintainFitness
        fitnessSelection = .newToRunning
        fitnessLevel = OBFitnessSelection.newToRunning.fitnessLevel
    }

    private var levelSubtitle: String {
        switch planKind {
        case .pregnancy:
            return "Sets the starting point for your weekly volume. A pregnancy plan prescribes effort, not pace."
        case .startRunning:
            return "Helps your coach pitch its advice. Where the plan starts is the next question."
        case .standard:
            return "We'll calibrate volume and pace from here."
        }
    }

    /// Keeps the due date ahead of the start date. A plan that ends before it begins is the
    /// one input combination `PregnancyPlanService` refuses outright.
    private func recalibrateDueDate() {
        if dueDate.startOfDay < planStartDate {
            dueDate = planStartDate.adding(weeks: 1)
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

    // MARK: - Level + units content

    private var levelContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ForEach(OBFitnessSelection.allCases, id: \.self) { selection in
                    OBFitnessRow(
                        selection: selection,
                        startingKm: planKind == .standard
                            ? previewWeeks(for: selection.fitnessLevel).first?.scheduledKm
                            : nil,
                        isSelected: fitnessSelection == selection
                    ) {
                        fitnessSelection = selection
                        fitnessLevel = selection.fitnessLevel
                        seedPrePregnancyMinutesIfUntouched()
                    }
                }
            }
            if planKind == .standard, fitnessSelection == .newToRunning {
                OBStartRunningSwitchHint { chooseStartRunning() }
            }
            unitsRow
        }
    }

    /// A pregnancy plan tapers from the runner's pre-pregnancy weekly minutes, so the field
    /// on the next step opens at something plausible for the level they just picked rather
    /// than at the same number for everyone.
    private func seedPrePregnancyMinutesIfUntouched() {
        guard isPregnancyPlan, !didEditPrePregnancyMinutes else { return }
        prePregnancyWeeklyMinutes = PregnancyRunningPolicy.defaultWeeklyRunMinutes(for: fitnessLevel)
    }

    /// Units, folded into the step above rather than asked as one of its own (U10).
    ///
    /// A compact control rather than the pair of full-width cards this used to be: the
    /// value arrives already correct for the device (`UnitPreference.localeDefault`), so
    /// this is a correction, not a decision — and the options are two words each.
    ///
    /// It shares `UnitPreferencePicker` with Settings. This used to be a stock
    /// `.pickerStyle(.segmented)` while Settings drew a custom brand-filled pill, so the
    /// same setting had two visual languages depending on where you met it (S24).
    private var unitsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Units")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
            UnitPreferencePicker(selection: Bindable(appSettings).unitPreference)
                .accessibilityIdentifier("onboarding.units")
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.md)
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
            .strideCard(cornerRadius: AppRadius.lg)

            HStack(spacing: 14) {
                // An icon tile: a brand-tinted circle leading the card.
                ZStack {
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Text(String(format: "%.0f", vdotValue))
                        .font(.dsSubhead.weight(.bold).monospacedDigit())
                        .foregroundStyle(.brandText)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VDOT \(String(format: "%.0f", vdotValue)) · \(vdotLabel)")
                        .font(.dsSubhead.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Easy \(shortPace(paces.easyRange.lowerBound)) · Tempo \(tempoLabel) · Interval \(intervalLabel)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 14)
            .strideCard(cornerRadius: AppRadius.md)

            hrCalibrationCard
        }
    }

    /// Optional age + max-HR entry used for heart-rate training zones.
    private var onboardingMaxHR: Int { maxHROverride ?? UserProfile.estimatedMaxHeartRate(forAge: age) }

    private var hrCalibrationCard: some View {
        VStack(spacing: 12) {
            // Typable as well as steppable: going from the assumed 30 to 45 used to be
            // fifteen taps with no way to just say "45" (S25).
            NumericStepperField(
                title: "Age",
                value: Binding(get: { age }, set: { age = $0 }),
                range: 10...100,
                onEdit: { didEnterHR = true }
            )
            Divider()
            NumericStepperField(
                title: "Max HR",
                value: Binding(get: { onboardingMaxHR }, set: { maxHROverride = $0 }),
                range: 120...220,
                suffix: "bpm",
                onEdit: { didEnterHR = true }
            )
            Text("Sets your heart-rate zones. Estimated from age (208 − 0.7 × age) — adjust if you know your true max.")
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, 14)
        .strideCard(cornerRadius: AppRadius.md)
    }

    // MARK: - Schedule content

    private var scheduleContent: some View {
        VStack(spacing: 16) {
            // The shared day picker (route on, card off), with this week's dates.
            DayOfWeekPicker(selectedDays: $selectedDays, showsDates: true)
                .padding(14)
                .strideCard(cornerRadius: AppRadius.lg)

            VStack(alignment: .leading, spacing: 10) {
                Text("Long run day")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                StrideSegmentedControl(selection: $longRunDay, options: LongRunDay.allCases) {
                    Text(verbatim: $0.rawValue).accessibilityLabel($0.accessibilityName)
                }

                HStack {
                    Text("Runs per week")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(selectedDays.count)")
                        .font(.dsTitle3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.brandText)
                }
                .padding(.top, AppSpacing.xs)
            }
            .padding(AppSpacing.lg)
            .strideCard(cornerRadius: AppRadius.md)
        }
    }

    // MARK: - Strength content

    private var strengthContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            OBEquipmentGrid(selectedEquipment: $selectedEquipment)

            VStack(alignment: .leading, spacing: 8) {
                OBStrengthFocusPicker(focus: $strengthFocus)
                    .opacity(selectedEquipment.isEmpty ? 0.4 : 1)
                    .disabled(selectedEquipment.isEmpty)

                // A dimmed section with a pre-checked radio and nothing saying why is the
                // state this step opens in, since nothing is selected on arrival (S13). The
                // Plan tab's disabled Smart Adapt card gets this right — it carries its
                // unlock condition directly beneath it. So does this now.
                if selectedEquipment.isEmpty {
                    Text("Pick your equipment above to choose a focus.")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                        .transition(.opacity)
                }
            }
            .adaptiveAnimation(AppAnimation.bouncy, value: selectedEquipment.isEmpty)
        }
    }

    // MARK: - Permissions content

    private var permissionsContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                OBPermissionRow(icon: .location, label: "Location",
                                desc: "Record GPS routes during runs.",
                                tint: .brand, isOn: locationEnabled,
                                isActive: activePermission == 0)
                    .strideEntrance(permRowsVisible[0], rise: 14)

                OBPermissionRow(icon: .heart, label: "Apple Health",
                                desc: "Heart rate, VO2 max, workouts.",
                                tint: .brand, isOn: healthEnabled,
                                isActive: activePermission == 1)
                    .strideEntrance(permRowsVisible[1], rise: 14)

                OBPermissionRow(icon: .bell, label: "Notifications",
                                desc: "Plan reminders, daily workout ping.",
                                tint: .brand, isOn: notificationsEnabled,
                                isActive: activePermission == 2)
                    .strideEntrance(permRowsVisible[2], rise: 14)

                // The Apple Watch row is gone (S15). It was not a permission — nothing in
                // `requestPermissionsSequentially` touched it and both its flags were
                // hardcoded `false` — so it sat permanently unchecked among three rows that
                // do change state, in a list whose whole job is to report what was granted.
                // It also borrowed the notifications row's `permRowsVisible[2]`, in an array
                // sized for three.
            }
        }
        .task {
            await refreshPermissionStates()

            // All permissions already granted — skip this step, but only on the way forward.
            // Coming Back from the summary would otherwise bounce straight forward again.
            if goingForward && healthEnabled && locationEnabled && notificationsEnabled {
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
        case 40..<50: return "intermediate"
        case 50..<60: return "advanced"
        default: return "elite"
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

    /// Auto-generated race name for the current goal. Custom distances use a
    /// unit-aware distance label so the field is never blank.
    private var defaultRaceName: String {
        guard goalRace.usesCustomDistance else { return goalRace.displayName }
        return appSettings.unitPreference == .imperial
            ? String(format: "%.1f mi Race", customDistanceKm * 0.621371)
            : String(format: "%.1f km Race", customDistanceKm)
    }

    private func recalibrateRaceDate() {
        guard goalRace.isGoalRace else { return }
        if raceDate < minimumRaceDate {
            raceDate = minimumRaceDate
        }
        let trimmedRaceName = raceName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace the name only while it still looks auto-generated, so a name the
        // user typed is preserved when they revisit the goal step.
        let generatedRaceNames = Set(RaceType.allCases.map(\.displayName))
        let looksAutoGenerated = trimmedRaceName.isEmpty
            || generatedRaceNames.contains(trimmedRaceName)
            || (trimmedRaceName.hasSuffix(" Race") && (trimmedRaceName.first?.isNumber ?? false))
        if looksAutoGenerated {
            raceName = defaultRaceName
        }
    }

    private var goalFinishTimeSeconds: Double {
        PaceCalculatorService.predictedTime(vdot: vdotValue, distanceMeters: effectiveRaceDistanceMeters)
    }

    // MARK: - Permissions

    /// Reconciles the row flags with the *actual* system authorization status.
    /// Location and notification grants are observable, so they're set in both
    /// directions (a denial flips the row back off). HealthKit read authorization
    /// is deliberately opaque in iOS — a denial is indistinguishable from
    /// "not yet asked" — so the only positive signal we can trust is share status,
    /// and we never flip HealthKit back off from here.
    private func refreshPermissionStates() async {
        let locStatus = locationManager.authorizationStatus
        let notifStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        withAnimation {
            locationEnabled = (locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways)
            notificationsEnabled = (notifStatus == .authorized || notifStatus == .provisional)
        }

        // Health share status is a synchronous call into healthd. Made here on the main
        // actor it froze the permissions step for minutes on CI (healthd never answered;
        // the spindump in run 45896042847 is parked in this function). Off the main
        // actor and the cooperative pool, and after the other rows, so a slow healthd
        // only delays the Health row.
        guard await container.healthKitRepository.isAuthorizedOffCooperativePool() else { return }
        withAnimation { healthEnabled = true }
    }

    private func requestPermissionsSequentially() async {
        // 1. Location (skip if already granted)
        if !locationEnabled {
            activePermission = 0
            locationManager.requestWhenInUseAuthorization()
            // Wait for the answer, so the Health sheet never stacks on the location prompt.
            await awaitLocationAnswer()
            // Reflect the user's actual choice instead of assuming a grant.
            await refreshPermissionStates()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 2. HealthKit (skip if already granted)
        if !healthEnabled {
            activePermission = 1
            if HKHealthStore.isHealthDataAvailable() {
                try? await container.healthKitRepository.requestAuthorization()
                await container.workoutSyncService.startObserving()
            }
            // Read authorization is opaque; a share grant is the only signal iOS
            // exposes, so a fully denied sheet correctly leaves the row off.
            await refreshPermissionStates()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 3. Notifications (skip if already granted)
        if !notificationsEnabled {
            activePermission = 2
            try? await NotificationService.shared.requestAuthorization()
            // A denied notification prompt now leaves the row off.
            await refreshPermissionStates()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        activePermission = nil
        isRequestingPermissions = false
        advance()
    }

    /// Returns once the location prompt has been answered: the status only leaves
    /// `.notDetermined` when the runner taps. Polled rather than delegate-driven so it needs
    /// no nonisolated callback; capped so a prompt that never appears cannot stall the flow.
    private func awaitLocationAnswer(timeout: Duration = .seconds(60)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while locationManager.authorizationStatus == .notDetermined, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
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
        if step == .welcome { advance() }
    }

    // MARK: - Create profile and plan

    /// Reads the runner's recent running from Health, then builds the profile and plan, so
    /// someone coming back from a break starts from what they have actually been running
    /// rather than from the fitness level alone (`RecentRunningVolume`).
    private func createProfileAndPlan() {
        Task {
            let recentVolume = await recentVolumeForPlan()
            createProfileAndPlan(recentVolume: recentVolume)
        }
    }

    /// The recent running the earlier steps already read, or a fresh read that waits at
    /// most a few seconds. Health can be slow to answer (on CI it took over a minute), and
    /// the runner has just tapped Start training: a plan from the table beats a spinner.
    private func recentVolumeForPlan() async -> RecentRunningVolume? {
        if let recentVolume { return recentVolume }
        let repository = container.healthKitRepository
        let first = FirstResult<RecentRunningVolume?>()
        return await withCheckedContinuation { continuation in
            first.start(continuation)
            Task { first.finish(await repository.recentRunningVolume()) }
            Task {
                try? await Task.sleep(for: .seconds(3))
                first.finish(nil)
            }
        }
    }

    private func createProfileAndPlan(recentVolume: RecentRunningVolume?) {
        // CloudKit may have delivered the user's existing profile while they were
        // going through onboarding. If so, skip creation entirely — ContentView's
        // @Query will detect the non-empty profile list and switch to MainTabView.
        let check = FetchDescriptor<UserProfile>()
        if let existing = try? context.fetch(check), !existing.isEmpty {
            isCreatingPlan = false
            return
        }

        // Only treat the 5K entry as real when the user actually confirmed it. If they
        // skipped, persist a nil estimate and no goal time so the plan derives VDOT from
        // fitness level rather than the default 26:24.
        let estimated5K: Double? = didEnter5KTime ? fiveKTimeSeconds : nil
        let goalFinishTime: Double = estimated5K.map { time in
            let v = PaceCalculatorService.vdot(distanceMeters: 5_000, timeSeconds: time)
            return PaceCalculatorService.predictedTime(vdot: v, distanceMeters: effectiveRaceDistanceMeters)
        } ?? 0
        let profile = UserProfile(
            name: "",
            goalRace: goalRace,
            goalFinishTime: goalFinishTime,
            raceName: goalRace.isGoalRace ? raceName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            raceDate: goalRace.isGoalRace ? raceDate.startOfDay : nil,
            weeklyRunDays: max(selectedDays.count, 1),
            fitnessLevel: fitnessLevel,
            gender: .preferNotToShare,
            currentEstimated5KTimeSeconds: estimated5K,
            preferredRunDayIndices: selectedDays.sorted()
        )
        profile.customDistanceMeters = goalRace.usesCustomDistance ? effectiveRaceDistanceMeters : nil
        profile.selectedEquipment = Array(selectedEquipment)
        profile.strengthFocus = strengthFocus
        if isPregnancyPlan {
            profile.dueDate = dueDate.startOfDay
            // The screening step's Continue button is the only thing that reaches here, so
            // this records that the gate was passed for the plan about to be built.
            profile.pregnancyClearedAt = Date()
            profile.prePregnancyWeeklyRunMinutes = prePregnancyWeeklyMinutes
            profile.pregnancyHabituallyVigorous = pregnancyHabituallyVigorous
        }
        // Only record HR-zone inputs if the user actually engaged with them. Left nil, zones
        // use the same assumed-age estimate this step showed (`effectiveMaxHeartRate`).
        if didEnterHR {
            profile.age = age
            profile.maxHeartRateBPM = maxHROverride
        }
        context.insert(profile)
        let plan: TrainingPlan
        if isStartRunningPlan {
            plan = StartRunningPlanService().generatePlan(
                profile: profile,
                startDate: planStartDate,
                firstStage: startingPoint.firstStage
            )
        } else if isPregnancyPlan {
            do {
                plan = try container.pregnancyPlanService.generatePlan(
                    profile: profile,
                    startDate: planStartDate
                )
            } catch {
                // Unreachable by the UI: the screening step's Continue button is what sets
                // `pregnancyClearedAt` above, and `startDateValid` already bounds the start
                // date by the due date. If it does fire, keep the profile — the Plan tab can
                // build a plan — rather than stranding onboarding on a spinner.
                AppLogger.log(
                    "Pregnancy plan generation failed during onboarding: \(error.localizedDescription)",
                    label: "Onboarding",
                    level: .error
                )
                context.saveOrLog("the profile created during onboarding")
                isCreatingPlan = false
                return
            }
        } else if goalRace.isGoalRace {
            plan = container.trainingPlanService.generateRacePlan(
                profile: profile,
                startDate: planStartDate,
                raceDate: raceDate,
                raceName: raceName.trimmingCharacters(in: .whitespacesAndNewlines),
                runDayIndices: selectedDays.sorted(),
                recentVolume: recentVolume,
                unitPreference: appSettings.unitPreference
            )
        } else {
            plan = container.trainingPlanService.generatePlan(
                profile: profile,
                startDate: planStartDate,
                numberOfWeeks: planWeeks,
                runDayIndices: selectedDays.sorted(),
                recentVolume: recentVolume,
                unitPreference: appSettings.unitPreference
            )
        }
        context.insert(plan)
        context.saveOrLog("the plan created during onboarding")

        Task {
            if appSettings.morningReminderEnabled {
                await container.notificationService.scheduleMorningReminders(for: plan)
            }
            try? await container.healthKitRepository.syncWorkoutPlans(for: plan, unitPreference: appSettings.unitPreference)
            context.saveOrLog("the new plan's WorkoutKit ids")
            isCreatingPlan = false
        }
    }
}

/// Resumes a continuation with whichever result arrives first, once.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
