import SwiftUI
import SwiftData

// MARK: - WeekCalendarView

/// Persistent horizontal week-strip calendar.
///
/// Displays seven day cells with colour-coded workout indicator dots
/// sourced from the active training plan. Tapping a day updates
/// ``selectedDate``; the left/right chevrons navigate by week.
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
            withAnimation(.easeInOut(duration: 0.2)) {
                weekStart = target
            }
        }
    }

    // MARK: Header

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

    // MARK: Day strip

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
                    withAnimation(.easeInOut(duration: 0.15)) {
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
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 44)
        }
    }

    // MARK: Helpers

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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isToday ? .brand : .secondary)

            ZStack {
                Circle()
                    .fill(circleBackground)
                    .frame(width: 34, height: 34)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(numberForeground)
            }

            indicator
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var indicator: some View {
        if let w = workout, w.workoutType != .rest {
            if w.isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(dotColor(for: w.workoutType))
            } else {
                Circle()
                    .fill(dotColor(for: w.workoutType))
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
    @State private var showActiveRun = false
    @State private var selectedDate = Date()

    private var activePlan: TrainingPlan? { activePlans.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WeekCalendarView(activePlan: activePlan, selectedDate: $selectedDate)
                    .background(.surfaceSecondary)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        weekSummaryCard
                        selectedDaySection
                        startRunButton
                    }
                    .padding()
                }
            }
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showActiveRun) {
                ActiveRunView()
            }
        }
    }

    // MARK: Subviews

    private var weekSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                statItem(value: weekDistanceString, label: "Distance")
                statItem(value: weekRunCountString, label: "Runs")
                if let plan = activePlan, let week = plan.currentWeek {
                    statItem(
                        value: String(format: "%.0f%%", week.completedDistanceKm / week.targetDistanceKm * 100),
                        label: "Plan"
                    )
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDayLabel)
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            if let workout = workoutForSelectedDate {
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutCardView(workout: workout)
                }
                .buttonStyle(.plain)

                if Calendar.current.isDateInToday(selectedDate) && !workout.isCompleted {
                    Button {
                        showActiveRun = true
                    } label: {
                        Label("Start This Workout", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars")
                        .foregroundStyle(.secondary)
                    Text("Rest day – recovery is part of training.")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var startRunButton: some View {
        Button {
            showActiveRun = true
        } label: {
            Label("Start a Free Run", systemImage: "figure.run")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Computed

    private var selectedDayLabel: String {
        if Calendar.current.isDateInToday(selectedDate) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(selectedDate) { return "TOMORROW" }
        return selectedDate
            .formatted(.dateTime.weekday(.wide).month().day())
            .uppercased()
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
}
