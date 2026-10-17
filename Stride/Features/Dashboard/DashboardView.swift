import SwiftUI
import SwiftData

// MARK: - WeekCalendarView

struct WeekCalendarView: View {
    let activePlan: TrainingPlan?
    @Binding var selectedDate: Date

    @State private var weekStart: Date

    private let cal = Calendar.current

    init(activePlan: TrainingPlan?, selectedDate: Binding<Date>) {
        self.activePlan = activePlan
        self._selectedDate = selectedDate
        self._weekStart = State(initialValue: selectedDate.wrappedValue.startOfWeek)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            dayStrip
        }
        .onChange(of: selectedDate) { _, newDate in
            let target = newDate.startOfWeek
            guard !cal.isDate(target, inSameDayAs: weekStart) else { return }
            withAnimation(AppAnimation.bouncy) {
                weekStart = target
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text(monthRangeLabel)
                .strideEyebrow()
                .foregroundStyle(.primary)
            Spacer()
            if let label = planWeekLabel {
                Text(label)
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, 6)
    }

    private var dayStrip: some View {
        HStack(spacing: 0) {
            navChevron(icon: .chevronLeft, label: "Previous week") {
                weekStart = weekStart.adding(weeks: -1)
            }

            // Day cells were `.onTapGesture` on a `Rectangle` content shape, so they
            // were not buttons to assistive tech and exposed no label — `StrideIcon`
            // is a raw `Canvas` and the date/indicator read as loose fragments (N18).
            ForEach(0..<7, id: \.self) { offset in
                let date = weekStart.adding(days: offset)
                Button {
                    withAnimation(AppAnimation.bouncy) {
                        selectedDate = date
                    }
                } label: {
                    DayCell(
                        date: date,
                        workouts: workouts(on: date),
                        isSelected: cal.isDate(date, inSameDayAs: selectedDate)
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            navChevron(icon: .chevronRight, label: "Next week") {
                weekStart = weekStart.adding(weeks: 1)
            }
        }
        .padding(.bottom, AppSpacing.sm)
        // Seven day columns plus two chevrons across the screen width — the other
        // layout that can't reflow, so it scales up to accessibility1 and stops (U2).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func navChevron(
        icon: StrideIconName,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(AppAnimation.bouncy) { action() }
        } label: {
            StrideIcon(name: icon, size: 13, color: .secondary, strokeWeight: 2)
                // 28pt wide was under the 44pt minimum target — and this is the
                // control that moves the calendar a week at a time (U10). The glyph
                // is unchanged; only the tappable area grew.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var monthRangeLabel: String {
        let end = weekStart.adding(days: 6)
        if cal.component(.month, from: weekStart) == cal.component(.month, from: end) {
            return weekStart.formatted(.dateTime.month(.wide).year())
        }
        // The system's own interval format: "Oct – Nov 2026", or both years across December.
        return (weekStart..<end).formatted(.interval.month(.abbreviated).year())
    }

    private var planWeekLabel: String? {
        guard let plan = activePlan else { return nil }
        let match = (plan.weeks ?? []).first { cal.isDate($0.startDate, inSameDayAs: weekStart) }
        guard let week = match else { return nil }
        return "Week \(week.weekNumber) of \(plan.totalWeeks)"
    }

    /// Every session the plan schedules on `date`. A day can hold a run *and* a gym
    /// session, so the strip resolves all of them rather than the arbitrary first
    /// match an unordered relationship happened to yield (N12).
    private func workouts(on date: Date) -> [ScheduledWorkout] {
        ScheduledDayResolver.workouts(on: date, in: activePlan, calendar: cal)
    }
}

// MARK: - DayCell

private struct DayCell: View {
    let date: Date
    /// Every session scheduled on this day, runs first (N12).
    let workouts: [ScheduledWorkout]
    let isSelected: Bool

    /// The week strip encodes workout type as colour and nothing else, so with
    /// Differentiate Without Color switched on a tempo day and an interval day were
    /// the same 6×6 dot (U3d). The glyph below is the fallback; the colour stays,
    /// because the setting means "don't rely on colour alone", not "remove colour".
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private let cal = Calendar.current
    private var isToday: Bool { cal.isDateInToday(date) }

    /// The day's real sessions — an explicit rest day gets no indicator.
    private var sessions: [ScheduledWorkout] {
        workouts.filter { $0.workoutType != .rest }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.dsCaption2.weight(.semibold))
                .foregroundStyle(isToday ? .brand : .secondary)

            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 32, height: 32)
                    .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
                Text(date.formatted(.dateTime.day()))
                    .font(.dsSubhead.weight(isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(numberForeground)
                    .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
            }

            indicatorArea
                .frame(height: 10)
        }
        .padding(.vertical, AppSpacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// One indicator per session, so a paired run + gym day is visible instead of
    /// showing whichever of the two the relationship happened to return first (N12).
    @ViewBuilder
    private var indicatorArea: some View {
        if sessions.isEmpty {
            Color.clear
        } else {
            HStack(spacing: 3) {
                ForEach(sessions.prefix(2)) { session in
                    indicator(for: session)
                }
            }
        }
    }

    @ViewBuilder
    private func indicator(for workout: ScheduledWorkout) -> some View {
        if workout.isCompleted {
            StrideIcon(name: .check, size: 8, color: workout.workoutType.color, strokeWeight: 2.5)
        } else if differentiateWithoutColor {
            // Each type's own glyph, so the day is identifiable without reading the
            // colour. Sized to the strip's 10pt indicator row.
            StrideIcon(
                name: workout.workoutType.strideIcon,
                size: 9,
                color: workout.workoutType.color,
                strokeWeight: 2.2
            )
        } else {
            // Long run gets a wider pill indicator — unless the day is shared, where
            // two full-width pills wouldn't fit under a 32pt date circle.
            let isLong = workout.workoutType == .longRun && sessions.count == 1
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(workout.workoutType.color)
                .frame(width: isLong ? 12 : 6, height: 6)
        }
    }

    /// Spoken description of the day: its date, then each session and whether it is
    /// done. Without it VoiceOver read a bare day number and a decorative dot (N18).
    private var accessibilityDescription: String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard !sessions.isEmpty else {
            let isRestDay = workouts.contains { $0.workoutType == .rest }
            return "\(day), \(isRestDay ? "rest day" : "nothing scheduled")"
        }
        let list = sessions
            .map { "\($0.workoutType.localizedName)\($0.isCompleted ? ", completed" : "")" }
            .joined(separator: ", ")
        return "\(day), \(list)"
    }

    /// Today is the route gradient — "you are here" in the Route Loop language — with
    /// `onFill` digits (6:1). White on orange was 3.1:1.
    private var circleFill: AnyShapeStyle {
        if isToday { return AnyShapeStyle(.route) }
        if isSelected { return AnyShapeStyle(Color.brand.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }

    private var numberForeground: Color {
        // The selected day's tint carries the state; orange digits on it would be
        // about 2.8:1, so the number stays `.primary` (bold) like any other day.
        if isToday { return .onFill }
        return .primary
    }
}

// MARK: - WeeklyLoadBar

private struct WeeklyLoadBar: View {
    let fraction: CGFloat    // 0–1
    let color: Color
    let isActive: Bool       // today (no bar yet)
    /// One-letter weekday initial drawn under the bar.
    ///
    /// Seven bars with nothing under them were unreadable on a fresh install: the only
    /// filled one is today's `isActive` marker, in the brand colour, sitting directly below
    /// "0.0 mi / 0 Runs" — which makes it look like a progress meter reading 1/7 rather than
    /// a day marker. The chart already had a full `chartAccessibility` summary, so VoiceOver
    /// users could read this strip and sighted ones could not (S22).
    let dayLetter: String

    var body: some View {
        VStack(spacing: 4) {
            bar
            Text(dayLetter)
                .font(.dsCaption2)
                .foregroundStyle(isActive ? Color.brand : .secondary)
                .fontWeight(isActive ? .bold : .regular)
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if isActive {
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(Color.brand)
                    .frame(height: 3)
            } else if fraction > 0 {
                // Full height, scaled from the bottom, rather than a measured height: it
                // retires the `GeometryReader` this view existed inside (U7) and draws the
                // same bar. The only casualty is the corner radius, which squashes with the
                // bar — at `micro` on a chart bar that is a fraction of a point.
                // The route, like Progress's weekly bars: distance is progress, and the
                // workout type already shows on the calendar strip above.
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(.routeBar)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: fraction, anchor: .bottom)
            } else {
                RoundedRectangle(cornerRadius: AppRadius.micro)
                    .fill(Color.surfaceTertiary)
                    .frame(height: 3)
            }
        }
    }
}

// MARK: - DashboardView

struct DashboardView: View {
    @Query(
        filter: #Predicate<TrainingPlan> { $0.isActive },
        sort: \TrainingPlan.createdAt, order: .reverse
    )
    private var activePlans: [TrainingPlan]

    /// The dashboard reads runs only for *this week* — the seven load bars and the two
    /// week totals — so the newest 60 is far more than it can use, where the unbounded
    /// query loaded every run ever logged on every render (D6).
    ///
    /// Imported walks are excluded in the fetch rather than in the bars: every number on
    /// this screen is a running number, and the limit has to count runs to mean what the
    /// comment above says (N38).
    static var recentRunsDescriptor: FetchDescriptor<RunWorkout> {
        RunWorkout.runsOnlyDescriptor(
            sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)],
            fetchLimit: 60
        )
    }

    @Query(DashboardView.recentRunsDescriptor)
    private var recentWorkouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    /// The strength workout to present. Captured at tap time and driven through
    /// `fullScreenCover(item:)` so the cover can never open onto an empty,
    /// undismissable screen when the selected day changes mid-presentation.
    @State private var strengthWorkout: ScheduledWorkout?
    @State private var selectedDate = Date()
    /// Timestamp of the last time the rearrange-workouts prompt was flagged
    /// (dismissed or acted on). Used to limit the prompt to once per week.
    @AppStorage(MissedWorkoutDetector.promptFlaggedDateKey) private var missedWorkoutPromptFlaggedInterval: Double = 0
    @State private var isHandlingRecovery = false
    @State private var recoveryAlert: RecoveryAlert?

    /// What a plan recovery has to tell the runner: a failure, or a success that did
    /// less than the button promised — today, a shift race day left no room for (N6).
    ///
    /// One piece of state and one `.alert`, because two `.alert` modifiers on the same
    /// view do not reliably both present.
    private struct RecoveryAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Namespace private var workoutCardNamespace
    @State private var dashboardAppeared = false

    /// The advisory whose sheet is open. Held separately from the service's published
    /// advisory so that answering it can take the card down immediately without pulling
    /// the sheet out from under itself mid-dismissal.
    @State private var heatSheetAdvisory: HeatAdvisory?
    /// Route Genius, opened from beside the free-run button. It used to be a card on the
    /// Plan tab, a long way from the moment a route is wanted: just before heading out.
    @State private var showRouteGenius = false

    /// The live heat advisory, published by the service rather than read here: the
    /// refresh that produces it runs from the scene root, so a copy cached in `@State` on
    /// appear would miss the one that arrives a moment later.
    private var heatAdvisory: HeatAdvisory? { container.heatAdvisoryService.advisory }

    /// Last night's HRV, resting heart rate and sleep, for the readiness card (B7). Read
    /// on every return to the foreground rather than once, because the screen can stay
    /// alive overnight and yesterday's readings are the wrong answer the next morning.
    @State private var recoveryReadings: RecoveryReadings?
    @Environment(\.scenePhase) private var scenePhase

    /// Apple Intelligence's wording for the Coach Tips, each bound to the card text it was
    /// written from. Empty until the model answers, and for good on a device without it —
    /// either way the cards keep their hard-coded copy. See `CoachTipRewriter`.
    @State private var coachTipWording: [CoachTipWording] = []

    private var activePlan: TrainingPlan? { activePlans.first }

    /// The goal race, but only once it is close enough to be a thing about *today* — the
    /// Plan tab is where the countdown lives all season (A10).
    private var racePlan: RaceDayPlan? {
        guard let resolved = RaceDayPlan.resolve(
            profile: profiles.first,
            plan: activePlan,
            runs: recentWorkouts
        ), resolved.deservesDashboardPlacement else { return nil }
        return resolved
    }

    private var missedWorkoutInfo: MissedWorkoutInfo? {
        guard let plan = activePlan else { return nil }
        guard let info = MissedWorkoutDetector.detect(in: plan) else { return nil }
        // Only surface the rearrange-workouts prompt once per week. If the user
        // already flagged it this week (dismissed or acted on it), stay hidden
        // until the next week begins.
        if missedWorkoutPromptFlaggedInterval != 0,
           Date(timeIntervalSince1970: missedWorkoutPromptFlaggedInterval).startOfWeek == Date().startOfWeek {
            return nil
        }
        return info
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // The week strip scrolls with the page, on the page's own ground, so the
                // large title collapses over it like every other tab's content.
                VStack(spacing: 0) {
                    WeekCalendarView(activePlan: activePlan, selectedDate: $selectedDate)

                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        // Today first: the screen used to open on a week readout and up to
                        // three alert cards before it got to the run. The selected day's
                        // session, with its Start button, is now what Home leads with.
                        selectedDaySection
                            .dashboardEntrance(appeared: dashboardAppeared, delay: 0.03)
                        alertSlot
                            .dashboardEntrance(appeared: dashboardAppeared, delay: 0.05)
                        if let racePlan = racePlan {
                            NavigationLink {
                                RaceDayHubView()
                            } label: {
                                RaceCountdownCard(racePlan: racePlan, unit: appSettings.unitPreference)
                            }
                            .buttonStyle(.plain)
                            .dashboardEntrance(appeared: dashboardAppeared, delay: 0.07)
                        }
                        if let session = nextUpSession {
                            nextUpSection(session)
                                .dashboardEntrance(appeared: dashboardAppeared, delay: 0.1)
                        }
                        weekSummaryCard
                            .dashboardEntrance(appeared: dashboardAppeared, delay: 0.12)
                        if !coachCards.isEmpty {
                            SmartCoachCardsSection(cards: CoachTipRewriter.apply(coachTipWording, to: coachCards))
                                .dashboardEntrance(appeared: dashboardAppeared, delay: 0.15)
                        }
                        VStack(spacing: AppSpacing.sm) {
                            startRunButton
                            planRouteButton
                        }
                        .dashboardEntrance(appeared: dashboardAppeared, delay: 0.18, offset: 16)
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.lg)
                }
            }
            .task { dashboardAppeared = true }
            .background(Color.surfacePrimary)
            // A large title like Plan, History and Progress. "Home" rather than "Today":
            // the selected day's section below already says "Today".
            .navigationTitle("Home")
            // The active-run HUD is presented by `MainTabView`, not here: a run started
            // from this tab now outlives the screen that shows it, so it can be
            // minimised into the tab-bar accessory instead of only finished (U7).
            // Strength stays local — it has no minimised form.
            .fullScreenCover(item: $strengthWorkout) { workout in
                StrengthActiveView(scheduledWorkout: workout)
            }
            .sheet(isPresented: $showRouteGenius) {
                RouteGeniusView(
                    viewModel: container.makeRouteGeniusViewModel(appSettings: appSettings)
                )
                .strideSheet()
            }
            .sheet(item: $heatSheetAdvisory) { advisory in
                HeatAdaptationSheet(
                    advisory: advisory,
                    workout: scheduledWorkout(id: advisory.workoutID),
                    unit: appSettings.unitPreference,
                    onAnswered: { answerHeatAdvisory(advisory) }
                )
                // The decision is the feature. A swipe-away is the outcome the runner
                // would take at 21:00 on a Monday and regret at 16:00 on a Tuesday, so
                // the sheet has no Close button and no drag-to-dismiss — the only exits
                // are its two buttons, and both of them count as an answer.
                .interactiveDismissDisabled(true)
                .strideSheet()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                recoveryReadings = await container.healthKitRepository.fetchRecoveryReadings(
                    endingAt: Date(),
                    baselineDays: RecoveryReadiness.baselineDays
                )
            }
            // Keyed on the cards' text, so it runs when a tip changes and not on every
            // render; `refreshCoachTipWording` then asks only about the ones that did.
            .task(id: CoachTipRewriter.requestKey(for: coachCards)) {
                await refreshCoachTipWording()
            }
            .task {
                // An advisory written last night should be on screen before the forecast
                // refresh at the scene root has had a chance to run.
                container.heatAdvisoryService.loadStoredAdvisory()
            }
            // Raised, not merely offered. An unanswered advisory presents itself the
            // moment Home is on screen — including the launch that follows a tap on the
            // evening banner, where `initial: true` is what catches an advisory that was
            // already loaded before this modifier started observing.
            .onChange(of: heatAdvisory, initial: true) { _, _ in
                presentHeatAdvisoryIfNeeded()
            }
            // A strength session is a `fullScreenCover` owned by this same view, and a
            // sheet raised over one from the same presenter does not reliably appear —
            // it just leaves the binding set with nothing on screen. So the advisory
            // waits for the cover to close and asks then.
            .onChange(of: strengthWorkout) { _, _ in
                presentHeatAdvisoryIfNeeded()
            }
            // The evening banner promises "tap to move it", so a tap has to land on the
            // sheet rather than merely foregrounding the app. A tap that arrives before
            // this loop exists — the cold-launch case — is buffered by the service and
            // replayed here, the same way a synced-run tap is (D4).
            // The evening nudges point at surfaces rather than at a sheet: the recovery
            // card is on this screen, the streak lives on Progress' Achievements tab, and
            // so does the week the recap summarises. Buffered and replayed the same way a
            // heat-advisory tap is, for the cold-launch case (A9, D4).
            .task {
                for await kind in container.notificationService.trainingNudgeTaps {
                    switch kind {
                    case .streak, .weeklyRecap:
                        container.appNavigation.select(.progress)
                    case .missedWorkouts:
                        container.appNavigation.select(.home)
                    }
                }
            }
            .task {
                for await idString in container.notificationService.heatAdvisoryTaps {
                    guard let id = UUID(uuidString: idString) else { continue }
                    container.appNavigation.select(.home)
                    let advisory = container.heatAdvisoryService.loadStoredAdvisory()
                    if let advisory, advisory.workoutID == id {
                        heatSheetAdvisory = advisory
                    }
                }
            }
            // `alert(_:item:)` (iOS 27): presentation follows the optional directly, so
            // the bridging `Binding` is gone and the message reads the item it was
            // given rather than re-reading the state behind a `?? ""`.
            .alert(
                recoveryAlert?.title ?? "",
                item: $recoveryAlert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    // MARK: - Heat advisory

    /// Raises the adaptation sheet for an unanswered advisory.
    ///
    /// The advisory is a question rather than a notice, so it is presented rather than
    /// left to be noticed — the card behind it is what the runner sees *after* answering
    /// has become impossible to avoid, and on the session's own day once the evening's
    /// window has closed.
    ///
    /// Held back in UI tests, where an unconditional modal over the Home tab would block
    /// every flow that starts there.
    private func presentHeatAdvisoryIfNeeded() {
        guard let advisory = heatAdvisory else { return }
        guard heatSheetAdvisory == nil, strengthWorkout == nil else { return }
        guard !UITestingSupport.isEnabled, !UITestingSupport.isHostingUnitTests else { return }
        heatSheetAdvisory = advisory
    }

    /// Records the runner's answer and takes the card down.
    ///
    /// Both answers land here — applying the adaptation and declining it — because both
    /// are decisions, and a card that stays up after the runner has decided is a card they
    /// learn to ignore. The dismissal is keyed by session *and* tier in
    /// `HeatAdvisoryStore`, so a forecast that worsens overnight still gets to ask again.
    private func answerHeatAdvisory(_ advisory: HeatAdvisory) {
        withAnimation(AppAnimation.bouncy) {
            container.heatAdvisoryService.markAnswered(advisory)
        }
    }

    /// The plan row an advisory names, or `nil` if it has since been completed or deleted.
    private func scheduledWorkout(id: UUID) -> ScheduledWorkout? {
        var descriptor = FetchDescriptor<ScheduledWorkout>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Alert slot

    /// The one card on Home that asks something of the runner, when anything does. Heat,
    /// missed sessions and worn shoes used to stack as three cards above today's run; only
    /// the most urgent shows now. Heat first, because it goes stale at midnight; then the
    /// missed sessions, which hold up the plan; then the shoes, which can wait a run.
    /// The others surface in turn once the one above them is answered.
    @ViewBuilder
    private var alertSlot: some View {
        if let advisory = heatAdvisory {
            HeatAdvisoryCard(
                advisory: advisory,
                unit: appSettings.unitPreference,
                onAdapt: { heatSheetAdvisory = advisory },
                onKeepAsPlanned: { answerHeatAdvisory(advisory) }
            )
        } else if let info = missedWorkoutInfo {
            MissedWorkoutsRecoveryCard(
                info: info,
                isLoading: isHandlingRecovery,
                onPickUpWhereLeftOff: { handlePickUp(info: info) },
                onRebuild: { handleRebuild() },
                onDismiss: { flagMissedWorkoutPrompt() }
            )
        } else {
            // Draws nothing unless a pair is due for replacement.
            ShoeReplacementCard()
        }
    }

    // MARK: - Week Summary Card

    private var weekSummaryCard: some View {
        // The header above the card, like "Today" and "Coach Tips" below it.
        VStack(alignment: .leading, spacing: 10) {
            Text("This Week")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
                .accessibilityIdentifier("dashboard.thisWeekHeader")
            weekSummaryCardBody
        }
    }

    private var weekSummaryCardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                statItem(value: weekDistanceString, label: "Distance")
                Spacer()
                statItem(value: weekRunCountString, label: "Runs")
                Spacer()
                if let plan = activePlan, let week = plan.currentWeek,
                   week.targetDistanceKm > 0 {
                    let pct = min(week.completedDistanceKm / week.targetDistanceKm, 1.0)
                    statItem(
                        value: String(format: "%.0f%%", pct * 100),
                        label: "Plan",
                        color: .brandText
                    )
                    Spacer()
                    // The ring draws the number the `statItem` beside it just spoke, so
                    // it is redundant to VoiceOver rather than missing from it — say so
                    // explicitly instead of leaving an unlabelled element (U10). It also
                    // used to recompute `pct` under a second name.
                    ProgressRingView(progress: pct, size: 44, lineWidth: 5)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(AppSpacing.lg)
        .strideCard(cornerRadius: AppRadius.lg)
    }

    // MARK: - Selected Day Section

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedDayLabel)
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
                .adaptiveAnimation(AppAnimation.bouncy, value: selectedDate)

            Group {
            // A day can hold more than one session — a plan pairs a run with a gym
            // day, and "pick up where I left off" shifts a run onto one. Render every
            // session instead of an arbitrary first match, which left the other one
            // unreachable from the dashboard entirely (N12).
            if sessionsForSelectedDate.isEmpty {
                // "Nothing scheduled" is three different things, and calling them all a
                // rest day claimed a plan said something it never said (N23).
                switch selectedDayState {
                case .rest, .scheduled: restDayCard
                case .beforePlanStart(let daysUntilStart):
                    planStartsSoonCard(daysUntilStart: daysUntilStart)
                case .outsidePlan:      outsidePlanCard
                case .noPlan:
                    VStack(spacing: AppSpacing.sm) {
                        noPlanCard
                        // The card used to point at the Plan tab with no way to get there.
                        Button("Create a Plan") { container.appNavigation.select(.plan) }
                            .buttonStyle(.strideButton(.secondary, compact: true))
                    }
                }
            } else {
                ForEach(sessionsForSelectedDate) { workout in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink {
                            WorkoutDetailView(workout: workout)
                                .navigationTransition(
                                    .zoom(sourceID: workout.persistentModelID, in: workoutCardNamespace)
                                )
                        } label: {
                            WorkoutCardView(workout: workout)
                                .matchedTransitionSource(id: workout.persistentModelID, in: workoutCardNamespace)
                        }
                        .buttonStyle(.plain)

                        if canStartSelectedDay && !workout.isCompleted {
                            startButton(for: workout)
                        }
                    }
                }
            }
            }
            .id(selectedDate)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
            .adaptiveAnimation(AppAnimation.bouncy, value: selectedDate)
        }
    }

    /// Start control for one of the selected day's sessions.
    ///
    /// Also offered for a session missed by a day: the linker already accepts a
    /// one-day-late completion, so refusing to *start* one made the UI stricter than
    /// the data model and left "run it untracked and hope the importer links it" as
    /// the only way to finish yesterday's tempo (N24). The title names the day so a
    /// late start is never ambiguous.
    private func startButton(for workout: ScheduledWorkout) -> some View {
        Button {
            if workout.workoutType == .strength {
                strengthWorkout = workout
            } else {
                startRun(fulfilling: workout)
            }
        } label: {
            HStack(spacing: 10) {
                // `onFill`, the style's text colour on the route: white on orange is 2.8:1 (U3a).
                StrideIcon(name: .play, size: 18, color: .onFill, strokeWeight: 2.2)
                Text(startButtonTitle(for: workout))
            }
        }
        .buttonStyle(.strideButton())
        .accessibilityIdentifier("dashboard.startScheduledWorkout.\(workout.workoutType.sessionKind.rawValue)")
    }

    private func startButtonTitle(for workout: ScheduledWorkout) -> LocalizedStringKey {
        let isStrength = workout.workoutType == .strength
        if Calendar.current.isDateInToday(selectedDate) {
            return isStrength ? "Start Strength Workout" : "Start This Workout"
        }
        return isStrength ? "Start Yesterday's Strength Workout" : "Start Yesterday's Workout"
    }

    private var restDayCard: some View {
        emptyDayCard(
            icon: .moon,
            tint: .secondary,
            title: "Rest day",
            subtitle: "Recovery is part of training."
        )
    }

    /// Shown for a date before the plan begins — which, because the default start is the
    /// next Monday, is the *first* thing most runners see after finishing onboarding.
    ///
    /// `outsidePlanCard` used to cover this, and it is the wrong voice for it: grey, past
    /// tense, and framed as an absence. A plan that hasn't started yet is good news with a
    /// date attached, so this one is branded, counts down, and names what to do meanwhile —
    /// the free-run button is directly beneath it (S4).
    private func planStartsSoonCard(daysUntilStart: Int) -> some View {
        let when: String = {
            switch daysUntilStart {
            case 0:
                return String(localized: "today", comment: "When a training plan's first day falls")
            case 1:
                return String(localized: "tomorrow", comment: "When a training plan's first day falls")
            default:
                return String(
                    localized: "in \(daysUntilStart) days",
                    comment: "When a training plan's first day falls"
                )
            }
        }()

        return emptyDayCard(
            icon: .calendar,
            tint: .brand,
            title: String(
                localized: "Your plan starts soon",
                comment: "Title for the day card shown before a plan's first day"
            ),
            subtitle: String(
                localized: "Week 1 begins \(when). Start a free run any time before then.",
                comment: "Subtitle for the day card shown before a plan's first day"
            )
        )
    }

    /// Shown for a date past the end of the active plan — scrolling to next month is not
    /// the plan prescribing rest (N23).
    ///
    /// Dates *before* the plan begins never reach here: `ScheduledDayResolver` classifies
    /// those as `.beforePlanStart`, which `planStartsSoonCard` answers. That split matters
    /// because onboarding hands back a plan starting on the coming week boundary, so the
    /// runner's very first Home screen used to be this grey card — the same dead end shown
    /// for scrolling into December, on the one day they most need to be told things work.
    private var outsidePlanCard: some View {
        VStack(spacing: AppSpacing.sm) {
            emptyDayCard(
                icon: .calendar,
                tint: .secondary,
                title: "Outside your plan",
                subtitle: activePlan.map { plan in
                    "Your plan ran \(plan.startDate.formatted(.dateTime.month().day())) – "
                        + "\(plan.endDate.formatted(.dateTime.month().day()))."
                } ?? "This day isn't part of your training plan."
            )
            // A way on from the dead end, like the no-plan card's "Create a Plan".
            Button("View Plan") { container.appNavigation.select(.plan) }
                .buttonStyle(.strideButton(.secondary, compact: true))
        }
    }

    // MARK: - Up Next

    /// What the plan asks for next, with enough of the prescription to plan a day around.
    ///
    /// This used to be a one-line label — workout type, date, chevron — shown *only* on
    /// days the plan left empty (S23). It is now a standing part of the screen and carries
    /// the prescription with it, so "what am I doing next, and can I fit it in today?" is
    /// answerable without opening anything.
    ///
    /// It reads ``ScheduledDayResolver/upcomingSession(onOrAfter:in:calendar:)`` — anchored
    /// to today, not to the browsed day — and looks one session further ahead when the
    /// selected day is already rendering the upcoming one in full above.
    ///
    /// Tapping it opens the session's detail rather than starting it: `canStart`
    /// deliberately refuses future days so the plan is not run out of order, and a card
    /// that looks like a start button but is not one would be worse than no card.
    private func nextUpSection(_ workout: ScheduledWorkout) -> some View {
        NavigationLink {
            WorkoutDetailView(workout: workout)
        } label: {
            NextUpCardView(
                briefing: NextUpBriefing.make(for: workout, unit: appSettings.unitPreference),
                workoutType: workout.workoutType,
                // Today's session leads the screen now, so this is a plain card under it.
                isHero: false
            )
        }
        .buttonStyle(.plain)
    }

    /// Shown when there is no active plan at all — a CTA, not a rest day (N23).
    private var noPlanCard: some View {
        emptyDayCard(
            icon: .calendar,
            tint: .brand,
            title: "No training plan yet",
            subtitle: "Build a plan around your race, or start a free run below."
        )
    }

    private func emptyDayCard(
        icon: StrideIconName,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 48, height: 48)
                StrideIcon(name: icon, size: 22, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.bodyStrong)
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(AppSpacing.lg)
        // A plain card: the tint lives in the icon tile. A tinted ground made this one of
        // three different card treatments stacked on Home.
        .strideCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: - Free Run Button

    /// True when the selected day's own session has its start button on screen. The free
    /// run then steps down to a secondary button, so the screen has one primary action.
    private var scheduledStartIsShowing: Bool {
        canStartSelectedDay && sessionsForSelectedDate.contains { !$0.isCompleted }
    }

    @ViewBuilder
    private var startRunButton: some View {
        if scheduledStartIsShowing && !container.workoutTrackerService.isRecording {
            Button {
                startRun(fulfilling: nil)
            } label: {
                HStack(spacing: 10) {
                    StrideIcon(name: .run, size: 20, color: .brandText, strokeWeight: 2.0)
                    Text(freeRunButtonTitle)
                }
            }
            .buttonStyle(.strideButton(.secondary))
            .accessibilityIdentifier("dashboard.startFreeRun")
        } else {
            primaryFreeRunButton
        }
    }

    /// Route Genius, as a quiet button under the run button.
    private var planRouteButton: some View {
        Button {
            showRouteGenius = true
        } label: {
            HStack(spacing: 8) {
                StrideIcon(name: .bolt, size: 16, color: .brandText, strokeWeight: 2.2)
                Text("Plan a Route")
            }
        }
        .buttonStyle(.strideButton(.quiet))
        .accessibilityHint(
            String(
                localized: "Builds a route matched to today's distance and elevation",
                comment: "Hint on Home's route button"
            )
        )
    }

    private var primaryFreeRunButton: some View {
        Button {
            startRun(fulfilling: nil)
        } label: {
            HStack(spacing: 10) {
                StrideIcon(name: .run, size: 20, color: .onFill, strokeWeight: 2.0)
                Text(freeRunButtonTitle)
            }
        }
        .buttonStyle(.strideButton())
        .accessibilityIdentifier("dashboard.startFreeRun")
    }

    /// The app's most-tapped control has a second job since U7: a run can be minimised
    /// into the tab-bar accessory, and this button stays on screen underneath it. Tapping
    /// it then reopens the run rather than starting another, so it has to say so.
    ///
    /// Typed `LocalizedStringKey` explicitly — a ternary of two bare literals infers
    /// `String`, which picks `Text`'s non-localizing overload and drops both strings out
    /// of the catalog.
    private var freeRunButtonTitle: LocalizedStringKey {
        container.workoutTrackerService.isRecording ? "Back to Your Run" : "Start a Free Run"
    }

    /// Starts a run, or reopens the one already recording (U7).
    private func startRun(fulfilling workout: ScheduledWorkout?) {
        container.activeRunPresentation.startOrReopen(
            scheduledWorkout: workout,
            isRunInProgress: container.workoutTrackerService.isRecording
        )
    }

    // MARK: - Helpers

    private func statItem(value: String, label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.metricSmall)
                .foregroundStyle(color)
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedDayLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "Today" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "Tomorrow" }
        return selectedDate.formatted(.dateTime.weekday(.wide).month().day())
    }

    /// Sessions scheduled on the selected day, excluding an explicit rest day.
    private var sessionsForSelectedDate: [ScheduledWorkout] {
        ScheduledDayResolver.sessions(on: selectedDate, in: activePlan)
    }

    /// What the selected day means when it holds no session: an actual rest day, a date
    /// outside the plan, or no plan at all (N23).
    private var selectedDayState: ScheduledDayResolver.DayState {
        ScheduledDayResolver.dayState(on: selectedDate, in: activePlan)
    }

    /// The session the runner is training toward right now — today's, if it is still
    /// outstanding, otherwise the next one on the plan.
    ///
    /// Anchored to *today* rather than to `selectedDate`: the coaching cards answer
    /// "what should I do about my next run", and that answer must not change because the
    /// calendar strip was scrolled back to look at last Tuesday.
    private var upcomingSession: ScheduledWorkout? {
        ScheduledDayResolver.upcomingSession(onOrAfter: Date(), in: activePlan)
    }

    /// What the "Up next" card shows: the upcoming session, unless the selected day is
    /// already rendering it in full above — in which case the card looks one further
    /// ahead rather than repeating the card directly above it.
    private var nextUpSession: ScheduledWorkout? {
        guard let upcoming = upcomingSession else { return nil }
        guard sessionsForSelectedDate.contains(where: { $0.id == upcoming.id }) else { return upcoming }
        return ScheduledDayResolver.nextSession(after: upcoming.scheduledDate, in: activePlan)
    }

    /// The coaching strip's cards. Rebuilt on each render from the same queries the rest
    /// of the screen reads, so a run saved moments ago is already reflected in them.
    ///
    /// The day state is resolved for **today**, not for `selectedDate`: it is what tells
    /// the coach whether the runner is on a rest day, waiting for a plan to start, or
    /// past the end of one, and scrolling the week strip to look at last Tuesday must not
    /// change the advice.
    private var coachCards: [SmartCoachCard] {
        let cards = SmartCoachCards.cards(
            SmartCoachCards.Context(
                nextSession: upcomingSession,
                recentRuns: recentWorkouts,
                profile: profiles.first,
                dayState: ScheduledDayResolver.dayState(on: Date(), in: activePlan),
                unit: appSettings.unitPreference,
                recoveryReadings: recoveryReadings
            )
        )
        // The coach's heat card reasons backwards, from the weather recorded on the last
        // run; the advisory reasons forwards, from tomorrow's forecast. Both are about the
        // heat, and stacking them puts two hydration tips on one screen — so when there is
        // a forecast on the page, the retrospective one stands down.
        // The day card above already says the plan starts soon, or that there is no plan;
        // the coach repeating it put "Week 1 begins…" on the screen twice.
        var fresh = cards.filter { $0.kind != .planStartsSoon && $0.kind != .noPlan }
        if heatAdvisory != nil {
            fresh = fresh.filter { $0.kind != .heat }
        }
        // One tip, the top-ranked one. Home used to show a primary card and two supporting
        // ones; the ranking already says which matters, so the others are not drawn (and not
        // sent to the model for rewording either).
        return Array(fresh.prefix(1))
    }

    /// Asks Apple's model (the runner's AI Coach choice, Private Cloud Compute by
    /// default) to reword whichever Coach Tips have no wording for their current text yet.
    /// The hard-coded copy stays on screen until an answer passes
    /// `CoachTipRewriter`'s checks, and stays for good on a card whose rewrite does not.
    ///
    /// Held back in UI tests and unit-test hosting, where the copy has to be the
    /// deterministic one.
    private func refreshCoachTipWording() async {
        guard !UITestingSupport.isEnabled, !UITestingSupport.isHostingUnitTests else { return }
        let cards = coachCards
        let pending = CoachTipRewriter.cardsNeedingWording(cards, existing: coachTipWording)
        guard !pending.isEmpty else { return }
        let fresh = await container.aiCoachService.writeCoachTips(
            for: pending,
            provider: appSettings.aiProvider
        )
        // A newer set of cards has already started its own request.
        guard !Task.isCancelled else { return }
        coachTipWording = CoachTipRewriter.merging(fresh, into: coachTipWording, keeping: coachCards)
    }

    /// Whether the selected day's sessions can still be started (today, or one day
    /// late — the same tolerance the sync linker applies).
    private var canStartSelectedDay: Bool {
        ScheduledDayResolver.canStart(workoutScheduledOn: selectedDate)
    }

    private func workoutOnDay(_ date: Date) -> ScheduledWorkout? {
        ScheduledDayResolver.workouts(on: date, in: activePlan).first
    }

    private var weekDistanceString: String {
        let monday = Date().startOfWeek
        let total = recentWorkouts
            .filter { $0.date >= monday }
            .reduce(0) { $0 + $1.distanceMeters }
        return total.distanceString(unit: appSettings.unitPreference)
    }

    private var weekRunCountString: String {
        let monday = Date().startOfWeek
        let count = recentWorkouts.filter { $0.date >= monday }.count
        return "\(count)"
    }

    // MARK: - Missed Workout Recovery

    /// Puts the recovery card away for the week — and takes the evening push down with
    /// it. The two share one dismissal (`MissedWorkoutDetector.promptFlaggedDateKey`), so
    /// a card the runner has just answered must not resurface on the Lock Screen at 18:00
    /// (A9).
    private func flagMissedWorkoutPrompt() {
        missedWorkoutPromptFlaggedInterval = Date().timeIntervalSince1970
        container.notificationService.cancelTrainingNudge(.missedWorkouts)
    }

    private func handlePickUp(info: MissedWorkoutInfo) {
        guard let plan = activePlan, !isHandlingRecovery else { return }
        runRecovery(failureMessage: String(
            localized: "We couldn't move your missed workouts forward.",
            comment: "Alert message when shifting missed workouts fails"
        )) {
            let outcome = try container.planLifecycle.shiftMissedWorkoutsForward(
                plan: plan,
                by: info.daysToShift,
                context: context
            )
            // A shift the race date blocked outright changed nothing, so the card has
            // to stay: Rebuild is the only recovery left and hiding the prompt for a
            // week would take it away.
            return (notice: pickUpNotice(for: outcome), flagPrompt: !outcome.isNoOp)
        }
    }

    /// What to tell the runner when race day limited the shift they asked for (N6).
    private func pickUpNotice(for outcome: MissedWorkoutShift.Outcome) -> String? {
        guard outcome.wasClampedByRace else { return nil }
        guard !outcome.wasBlockedByRace else {
            return String(
                localized: """
                    Your remaining sessions are already as close to race day as they can go, \
                    so nothing moved. Rebuild My Plan will fit a fresh block into the time you \
                    have left.
                    """,
                comment: "Alert message when race day blocked the missed-workout shift entirely"
            )
        }
        // Inflection only happens in an `AttributedString`, so build one and take its text.
        let message = AttributedString(
            localized: """
                Moved your remaining sessions forward by ^[\(outcome.appliedDays) day](inflect: true) — \
                any further and they'd land on or after race day.
                """,
            comment: "Alert message when race day limited the missed-workout shift"
        )
        return String(message.characters)
    }

    private func handleRebuild() {
        guard let plan = activePlan, let profile = profiles.first, !isHandlingRecovery else { return }
        runRecovery(failureMessage: String(
            localized: "We couldn't rebuild your plan.",
            comment: "Alert message when rebuilding the plan fails"
        )) {
            try container.planLifecycle.rebuildPlan(
                replacing: plan,
                profile: profile,
                context: context,
                unitPreference: appSettings.unitPreference
            )
            return (notice: nil, flagPrompt: true)
        }
    }

    /// Runs a plan-recovery mutation with the card's loading state applied.
    ///
    /// The work itself is synchronous main-actor SwiftData work, so it is hopped
    /// through a `Task` — that yields a render pass between raising the flag and
    /// doing the work, which is what makes `MissedWorkoutsRecoveryCard`'s loading
    /// overlay reachable at all. Failures now surface in an alert instead of only
    /// reaching the log.
    ///
    /// The work reports back whether it did anything the runner should be told about,
    /// and whether the prompt has earned its once-a-week dismissal.
    private func runRecovery(
        failureMessage: String,
        _ work: @escaping () throws -> (notice: String?, flagPrompt: Bool)
    ) {
        isHandlingRecovery = true
        Task { @MainActor in
            defer { isHandlingRecovery = false }
            do {
                let result = try work()
                if result.flagPrompt {
                    flagMissedWorkoutPrompt()
                }
                recoveryAlert = result.notice.map {
                    RecoveryAlert(
                        title: String(localized: "Race day is in the way", comment: "Plan recovery alert title"),
                        message: $0
                    )
                }
            } catch {
                recoveryAlert = RecoveryAlert(
                    title: String(localized: "Couldn't update your plan", comment: "Plan recovery alert title"),
                    message: "\(failureMessage)\n\n\(error.localizedDescription)"
                )
                AppLogger.log("Plan recovery failed: \(error)", label: "Dashboard", level: .error)
            }
        }
    }
}

// MARK: - ProgressRingView

/// The week's progress drawn as a route: the Route Loop gradient on a faint track.
private struct ProgressRingView: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat

    /// False until the ring first appears, so the route fills in from zero rather than
    /// showing up already drawn — the same entrance as the app mark's loop.
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.surfaceTertiary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: hasAppeared ? progress : 0)
                .stroke(.route, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .adaptiveAnimation(AppAnimation.gentle, value: progress)
                .adaptiveAnimation(AppAnimation.gentle, value: hasAppeared)
        }
        .frame(width: size, height: size)
        .onAppear { hasAppeared = true }
    }
}

// MARK: - Entrance

private extension View {
    /// The fade-and-rise each Home section enters with, staggered by `delay`.
    func dashboardEntrance(appeared: Bool, delay: Double, offset: CGFloat = 20) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : offset)
            .adaptiveAnimation(AppAnimation.entrance.delay(delay), value: appeared)
    }
}
