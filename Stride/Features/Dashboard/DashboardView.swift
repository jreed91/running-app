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
            navChevron(systemImage: "chevron.left") {
                weekStart = weekStart.adding(weeks: -1)
            }

            ForEach(0..<7, id: \.self) { offset in
                let date = weekStart.adding(days: offset)
                DayCell(
                    date: date,
                    workout: workout(on: date),
                    isSelected: cal.isDate(date, inSameDayAs: selectedDate)
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(AppAnimation.bouncy) {
                        selectedDate = date
                    }
                }
            }

            navChevron(systemImage: "chevron.right") {
                weekStart = weekStart.adding(weeks: 1)
            }
        }
        .padding(.bottom, 8)
    }

    private func navChevron(systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(AppAnimation.bouncy) { action() }
        } label: {
            let iconName: StrideIconName = systemImage == "chevron.left" ? .chevronLeft : .chevronRight
            StrideIcon(name: iconName, size: 13, color: .secondary, strokeWeight: 2)
                .frame(width: 28, height: 44)
        }
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

    private func workout(on date: Date) -> ScheduledWorkout? {
        guard let plan = activePlan else { return nil }
        for week in plan.weeks ?? [] {
            for w in week.workouts ?? [] where cal.isDate(w.scheduledDate, inSameDayAs: date) {
                return w
            }
        }
        return nil
    }
}

// MARK: - DayCell

private struct DayCell: View {
    let date: Date
    let workout: ScheduledWorkout?
    let isSelected: Bool

    private let cal = Calendar.current
    private var isToday: Bool { cal.isDateInToday(date) }

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
    }

    @ViewBuilder
    private var indicatorArea: some View {
        if let w = workout, w.workoutType != .rest {
            if w.isCompleted {
                StrideIcon(name: .check, size: 8, color: dotColor(for: w.workoutType), strokeWeight: 2.5)
            } else {
                // Long run gets a wider pill indicator
                let isLong = w.workoutType == .longRun
                RoundedRectangle(cornerRadius: 3)
                    .fill(dotColor(for: w.workoutType))
                    .frame(width: isLong ? 12 : 6, height: 6)
            }
        } else {
            Color.clear
        }
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

    @Query(sort: \RunWorkout.date, order: .reverse)
    private var recentWorkouts: [RunWorkout]

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appContainer) private var container
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]
    @State private var showActiveRun = false
    @State private var showStrengthWorkout = false
    /// The scheduled workout to fulfill when the active-run sheet is a planned run
    /// (set by "Start This Workout"); `nil` for a free run (H4).
    @State private var activeRunScheduled: ScheduledWorkout?
    @State private var selectedDate = Date()
    /// Timestamp of the last time the rearrange-workouts prompt was flagged
    /// (dismissed or acted on). Used to limit the prompt to once per week.
    @AppStorage("missedWorkoutPromptFlaggedDate") private var missedWorkoutPromptFlaggedInterval: Double = 0
    @State private var isHandlingRecovery = false

    @Namespace private var workoutCardNamespace
    @State private var dashboardAppeared = false

    private var activePlan: TrainingPlan? { activePlans.first }

    private var missedWorkoutInfo: MissedWorkoutInfo? {
        guard let plan = activePlan else { return nil }
        guard let info = MissedWorkoutDetector().detect(in: plan) else { return nil }
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
            .fullScreenCover(isPresented: $showStrengthWorkout) {
                if let workout = workoutForSelectedDate, workout.workoutType == .strength {
                    StrengthActiveView(scheduledWorkout: workout)
                }
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

    private var weeklyLoadChart: some View {
        let today = Date()
        let cal = Calendar.current
        let monday = today.startOfWeek

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

            // Normalize: 15km = full bar
            let fraction = CGFloat(min(dist / 15_000, 1.0))
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
            if let workout = workoutForSelectedDate {
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                        .navigationTransition(.zoom(sourceID: workout.persistentModelID, in: workoutCardNamespace))
                } label: {
                    WorkoutCardView(workout: workout)
                        .matchedTransitionSource(id: workout.persistentModelID, in: workoutCardNamespace)
                }
                .buttonStyle(.plain)

                if Calendar.current.isDateInToday(selectedDate) && !workout.isCompleted {
                    Button {
                        if workout.workoutType == .strength {
                            showStrengthWorkout = true
                        } else {
                            activeRunScheduled = workout
                            showActiveRun = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            StrideIcon(name: .play, size: 18, color: .white, strokeWeight: 2.2)
                            Text(workout.workoutType == .strength ? "Start Strength Workout" : "Start This Workout")
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
                }
            } else {
                restDayCard
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

    private var restDayCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.zoneEasy.opacity(0.15))
                    .frame(width: 48, height: 48)
                StrideIcon(name: .moon, size: 22, color: .zoneEasy, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Rest day")
                    .font(.bodyStrong)
                Text("Recovery is part of training.")
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
                        colors: [Color.zoneEasy.opacity(0.12), Color.zoneEasy.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.zoneEasy.opacity(0.2), lineWidth: 0.5)
                )
        )
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

    private var workoutForSelectedDate: ScheduledWorkout? {
        guard let plan = activePlan else { return nil }
        for week in plan.weeks ?? [] {
            for w in week.workouts ?? []
            where Calendar.current.isDate(w.scheduledDate, inSameDayAs: selectedDate) {
                return w.workoutType == .rest ? nil : w
            }
        }
        return nil
    }

    private func workoutOnDay(_ date: Date) -> ScheduledWorkout? {
        guard let plan = activePlan else { return nil }
        let cal = Calendar.current
        for week in plan.weeks ?? [] {
            for w in week.workouts ?? [] where cal.isDate(w.scheduledDate, inSameDayAs: date) {
                return w
            }
        }
        return nil
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
        guard let plan = activePlan else { return }
        isHandlingRecovery = true
        do {
            try container.shiftMissedWorkoutsForward(plan: plan, by: info.daysToShift, context: context)
            missedWorkoutPromptFlaggedInterval = Date().timeIntervalSince1970
        } catch {
            AppLogger.log("Recovery shift failed: \(error)", label: "Dashboard", level: .error)
        }
        isHandlingRecovery = false
    }

    private func handleRebuild() {
        guard let plan = activePlan, let profile = profiles.first else { return }
        isHandlingRecovery = true
        do {
            try container.rebuildPlan(
                replacing: plan,
                profile: profile,
                context: context,
                unitPreference: appSettings.unitPreference
            )
            missedWorkoutPromptFlaggedInterval = Date().timeIntervalSince1970
        } catch {
            AppLogger.log("Plan rebuild failed: \(error)", label: "Dashboard", level: .error)
        }
        isHandlingRecovery = false
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
