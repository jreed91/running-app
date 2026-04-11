import SwiftUI

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
        // Week spans two months
        return "\(weekStart.formatted(.dateTime.month(.abbreviated))) / "
             + end.formatted(.dateTime.month(.abbreviated).year())
    }

    private var planWeekLabel: String? {
        guard let plan = activePlan else { return nil }
        let match = plan.weeks.first { cal.isDate($0.startDate, inSameDayAs: weekStart) }
        guard let week = match else { return nil }
        return "Week \(week.weekNumber) of \(plan.totalWeeks)"
    }

    private func workout(on date: Date) -> ScheduledWorkout? {
        guard let plan = activePlan else { return nil }
        for week in plan.weeks {
            for w in week.workouts where cal.isDate(w.scheduledDate, inSameDayAs: date) {
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
            // Single-letter day name — "M", "T", "W" …
            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isToday ? .brand : .secondary)

            // Day-number circle
            ZStack {
                Circle()
                    .fill(circleBackground)
                    .frame(width: 34, height: 34)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(numberForeground)
            }

            // Workout type indicator
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

    // MARK: Style

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
        case .easy, .longRun:        return .zoneEasy
        case .tempo:                 return .zoneTempo
        case .interval, .race:       return .zoneInterval
        case .rest, .crossTraining:  return Color.secondary
        }
    }
}
