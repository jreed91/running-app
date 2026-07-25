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
                .font(.sectionHeader)
                .foregroundStyle(.primary)
            Spacer()
            if let label = planWeekLabel {
                Text(label)
                    .font(.sectionHeader)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
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
        .padding(.bottom, 8)
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
                .frame(width: 28, height: 44)
        }
        .accessibilityLabel(label)
    }

    private var monthRangeLabel: String {
        let end = weekStart.adding(days: 6)
        if cal.component(.month, from: weekStart) == cal.component(.month, from: end) {
            return weekStart.formatted(.dateTime.month(.wide).year())
        }
        return "\(weekStart.formatted(.dateTime.month(.abbreviated))) / "
             + end.formatted(.dateTime.month(.abbreviated).year())
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

    private let cal = Calendar.current
    private var isToday: Bool { cal.isDateInToday(date) }

    /// The day's real sessions — an explicit rest day gets no indicator.
    private var sessions: [ScheduledWorkout] {
        workouts.filter { $0.workoutType != .rest }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isToday ? .brand : .secondary)

            ZStack {
                Circle()
                    .fill(circleBackground)
                    .frame(width: 32, height: 32)
                    .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(numberForeground)
                    .adaptiveAnimation(AppAnimation.snappy, value: isSelected)
            }

            indicatorArea
                .frame(height: 10)
        }
        .padding(.vertical, 4)
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
            StrideIcon(name: .check, size: 8, color: dotColor(for: workout.workoutType), strokeWeight: 2.5)
        } else {
            // Long run gets a wider pill indicator — unless the day is shared, where
            // two full-width pills wouldn't fit under a 32pt date circle.
            let isLong = workout.workoutType == .longRun && sessions.count == 1
            RoundedRectangle(cornerRadius: 3)
                .fill(dotColor(for: workout.workoutType))
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
            .map { "\($0.workoutType.displayName)\($0.isCompleted ? ", completed" : "")" }
            .joined(separator: ", ")
        return "\(day), \(list)"
    }

    private var circleBackground: Color {
        if isToday { return .brand }
        if isSelected { return Color.brand.opacity(0.12) }
        return .clear
    }

    private var numberForeground: Color {
        if isToday { return .white }
        if isSelected { return .brand }
        return .primary
    }

    private func dotColor(for type: WorkoutType) -> Color {
        switch type {
        case .easy, .longRun:       return .zoneEasy
        case .tempo:                return .zoneTempo
        case .interval, .race:      return .zoneInterval
        case .rest, .crossTraining: return Color.secondary
        case .strength:             return .brand
        }
    }
}

// MARK: - WeeklyLoadBar

private struct WeeklyLoadBar: View {
    let fraction: CGFloat    // 0–1
    let color: Color
    let isActive: Bool       // today (no bar yet)

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()
                if isActive {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.brand)
                        .frame(height: 3)
                } else if fraction > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.9))
                        .frame(height: geo.size.height * fraction)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 3)
                }
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
    static var recentRunsDescriptor: FetchDescriptor<RunWorkout> {
        var descriptor = FetchDescriptor<RunWorkout>(
            sortBy: [SortDescriptor(\RunWorkout.date, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        return descriptor
    }

    @Query(DashboardView.recentRunsDescriptor)
    private var recentWorkouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var showActiveRun = false
    /// The strength workout to present. Captured at tap time and driven through
    /// `fullScreenCover(item:)` so the cover can never open onto an empty,
    /// undismissable screen when the selected day changes mid-presentation.
    @State private var strengthWorkout: ScheduledWorkout?
    /// The scheduled workout to fulfill when the active-run sheet is a planned run
    /// (set by "Start This Workout"); `nil` for a free run (H4).
    @State private var activeRunScheduled: ScheduledWorkout?
    @State private var selectedDate = Date()
    /// Timestamp of the last time the rearrange-workouts prompt was flagged
    /// (dismissed or acted on). Used to limit the prompt to once per week.
    @AppStorage("missedWorkoutPromptFlaggedDate") private var missedWorkoutPromptFlaggedInterval: Double = 0
    @State private var isHandlingRecovery = false
    @State private var recoveryAlert: RecoveryAlert?

    /// What a plan recovery has to tell the runner: a failure, or a success that did
    /// less than the button promised — today, a shift race day left no room for (N6).
    ///
    /// One piece of state and one `.alert`, because two `.alert` modifiers on the same
    /// view do not reliably both present.
    private struct RecoveryAlert {
        let title: String
        let message: String
    }

    @Namespace private var workoutCardNamespace
    @State private var dashboardAppeared = false

    private var activePlan: TrainingPlan? { activePlans.first }

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
            VStack(spacing: 0) {
                WeekCalendarView(activePlan: activePlan, selectedDate: $selectedDate)
                    .background(.surfaceSecondary)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        weekSummaryCard
                            .opacity(dashboardAppeared ? 1 : 0)
                            .offset(y: dashboardAppeared ? 0 : 20)
                            .adaptiveAnimation(AppAnimation.entrance.delay(0.05), value: dashboardAppeared)
                        if let info = missedWorkoutInfo {
                            MissedWorkoutsRecoveryCard(
                                info: info,
                                isLoading: isHandlingRecovery,
                                onPickUpWhereLeftOff: { handlePickUp(info: info) },
                                onRebuild: { handleRebuild() },
                                onDismiss: { missedWorkoutPromptFlaggedInterval = Date().timeIntervalSince1970 }
                            )
                            .opacity(dashboardAppeared ? 1 : 0)
                            .offset(y: dashboardAppeared ? 0 : 20)
                            .adaptiveAnimation(AppAnimation.entrance.delay(0.08), value: dashboardAppeared)
                        }
                        selectedDaySection
                            .opacity(dashboardAppeared ? 1 : 0)
                            .offset(y: dashboardAppeared ? 0 : 20)
                            .adaptiveAnimation(AppAnimation.entrance.delay(0.12), value: dashboardAppeared)
                        startRunButton
                            .opacity(dashboardAppeared ? 1 : 0)
                            .offset(y: dashboardAppeared ? 0 : 16)
                            .adaptiveAnimation(AppAnimation.entrance.delay(0.18), value: dashboardAppeared)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .task { dashboardAppeared = true }
            }
            .background(Color.surfacePrimary)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showActiveRun) {
                ActiveRunView(scheduledWorkout: activeRunScheduled)
            }
            .fullScreenCover(item: $strengthWorkout) { workout in
                StrengthActiveView(scheduledWorkout: workout)
            }
            .alert(
                recoveryAlert?.title ?? "",
                isPresented: Binding(
                    get: { recoveryAlert != nil },
                    set: { if !$0 { recoveryAlert = nil } }
                )
            ) {
                Button("OK", role: .cancel) { recoveryAlert = nil }
            } message: {
                Text(recoveryAlert?.message ?? "")
            }
        }
    }

    // MARK: - Week Summary Card

    private var weekSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This Week")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

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
                        color: .brand
                    )
                    Spacer()
                    // Progress ring
                    let pct2 = min(
                        (activePlan?.currentWeek?.completedDistanceKm ?? 0) /
                        max(activePlan?.currentWeek?.targetDistanceKm ?? 1, 1), 1.0
                    )
                    ProgressRingView(progress: pct2, size: 44, lineWidth: 5, color: .brand)
                }
            }

            // Weekly load mini bar chart
            weeklyLoadChart
        }
        .padding(16)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    /// Distance in meters that fills a weekly-load bar to the top.
    ///
    /// Derived from the runner's own week rather than a fixed 15 km: the longest
    /// day actually logged, and the plan's average target per run day, whichever
    /// is bigger. The 3 km floor keeps a very light week from making a short
    /// shakeout look like a peak effort.
    private var weeklyLoadScaleMeters: Double {
        let cal = Calendar.current
        let monday = Date().startOfWeek

        let longestLoggedDay = (0..<7).reduce(0.0) { longest, offset in
            let day = monday.adding(days: offset)
            let dayTotal = recentWorkouts
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.distanceMeters }
            return max(longest, dayTotal)
        }

        var plannedPerRunDay = 0.0
        if let week = activePlan?.currentWeek, week.targetDistanceKm > 0 {
            let runDays = (week.workouts ?? []).filter { $0.workoutType != .rest }.count
            plannedPerRunDay = week.targetDistanceKm * 1_000 / Double(max(runDays, 1))
        }

        return max(longestLoggedDay, plannedPerRunDay, 3_000)
    }

    private var weeklyLoadChart: some View {
        let today = Date()
        let cal = Calendar.current
        let monday = today.startOfWeek
        let scale = weeklyLoadScaleMeters

        // Build 7-day bars based on actual run data this week
        let bars: [(fraction: CGFloat, color: Color, isActive: Bool)] = (0..<7).map { offset in
            let day = monday.adding(days: offset)
            let isToday = cal.isDateInToday(day)
            let isFuture = day > today && !isToday

            if isFuture { return (0, .clear, false) }

            let dist = recentWorkouts
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.distanceMeters }

            // Color by dominant workout type that day
            let workout = workoutOnDay(day)
            let color: Color
            switch workout?.workoutType {
            case .tempo:                color = .zoneTempo
            case .interval, .race:      color = .zoneInterval
            default:                    color = .zoneEasy
            }

            let fraction = CGFloat(min(dist / scale, 1.0))
            return (fraction, color, isToday && dist == 0)
        }

        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<bars.count, id: \.self) { i in
                WeeklyLoadBar(fraction: bars[i].fraction, color: bars[i].color, isActive: bars[i].isActive)
            }
        }
        .frame(height: 28)
        .padding(.top, 4)
    }

    // MARK: - Selected Day Section

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedDayLabel)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
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
                case .outsidePlan:      outsidePlanCard
                case .noPlan:           noPlanCard
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
                activeRunScheduled = workout
                showActiveRun = true
            }
        } label: {
            HStack(spacing: 10) {
                StrideIcon(name: .play, size: 18, color: .white, strokeWeight: 2.2)
                Text(startButtonTitle(for: workout))
                    .font(.system(size: 17, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.brand)
                .shadow(color: Color.brand.opacity(0.4), radius: 14, y: 6)
        )
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.startScheduledWorkout.\(workout.workoutType.sessionKind.rawValue)")
    }

    private func startButtonTitle(for workout: ScheduledWorkout) -> String {
        let isStrength = workout.workoutType == .strength
        if Calendar.current.isDateInToday(selectedDate) {
            return isStrength ? "Start Strength Workout" : "Start This Workout"
        }
        return isStrength ? "Start Yesterday's Strength Workout" : "Start Yesterday's Workout"
    }

    private var restDayCard: some View {
        emptyDayCard(
            icon: .moon,
            tint: .zoneEasy,
            title: "Rest day",
            subtitle: "Recovery is part of training."
        )
    }

    /// Shown for a date the active plan doesn't cover — scrolling to next month is not
    /// the plan prescribing rest (N23).
    private var outsidePlanCard: some View {
        emptyDayCard(
            icon: .calendar,
            tint: .secondary,
            title: "Outside your plan",
            subtitle: activePlan.map { plan in
                "Your plan runs \(plan.startDate.formatted(.dateTime.month().day())) – "
                    + "\(plan.endDate.formatted(.dateTime.month().day()))."
            } ?? "This day isn't part of your training plan."
        )
    }

    /// Shown when there is no active plan at all — a CTA, not a rest day (N23).
    private var noPlanCard: some View {
        emptyDayCard(
            icon: .calendar,
            tint: .brand,
            title: "No training plan yet",
            subtitle: "Create a plan in the Plan tab, or start a free run below."
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.12), tint.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(tint.opacity(0.2), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: - Free Run Button

    private var startRunButton: some View {
        Button {
            activeRunScheduled = nil
            showActiveRun = true
        } label: {
            HStack(spacing: 10) {
                StrideIcon(name: .run, size: 20, color: .white, strokeWeight: 2.0)
                Text("Start a Free Run")
                    .font(.system(size: 17, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("dashboard.startFreeRun")
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.brand)
                .shadow(color: Color.brand.opacity(0.4), radius: 14, y: 6)
        )
        .buttonStyle(.plain)
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

    private func handlePickUp(info: MissedWorkoutInfo) {
        guard let plan = activePlan, !isHandlingRecovery else { return }
        runRecovery(failureMessage: "We couldn't move your missed workouts forward.") {
            let outcome = try container.shiftMissedWorkoutsForward(
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
            return """
            Your remaining sessions are already as close to race day as they can go, \
            so nothing moved. Rebuild My Plan will fit a fresh block into the time you \
            have left.
            """
        }
        let dayWord = outcome.appliedDays == 1 ? "day" : "days"
        return """
        Moved your remaining sessions forward by \(outcome.appliedDays) \(dayWord) — \
        any further and they'd land on or after race day.
        """
    }

    private func handleRebuild() {
        guard let plan = activePlan, let profile = profiles.first, !isHandlingRecovery else { return }
        runRecovery(failureMessage: "We couldn't rebuild your plan.") {
            try container.rebuildPlan(
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
                    missedWorkoutPromptFlaggedInterval = Date().timeIntervalSince1970
                }
                recoveryAlert = result.notice.map {
                    RecoveryAlert(title: "Race day is in the way", message: $0)
                }
            } catch {
                recoveryAlert = RecoveryAlert(
                    title: "Couldn't update your plan",
                    message: "\(failureMessage)\n\n\(error.localizedDescription)"
                )
                AppLogger.log("Plan recovery failed: \(error)", label: "Dashboard", level: .error)
            }
        }
    }
}

// MARK: - ProgressRingView

private struct ProgressRingView: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .adaptiveAnimation(AppAnimation.gentle, value: progress)
        }
        .frame(width: size, height: size)
    }
}
