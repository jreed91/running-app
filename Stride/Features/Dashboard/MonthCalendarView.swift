import SwiftUI
import SwiftData

// MARK: - MonthCalendarView

/// The whole month at once, opened from the month label above Home's week strip. The
/// strip only steps a week at a time, so this is where a runner sees the plan's shape:
/// sessions ahead, finished and missed ones behind, and race day.
///
/// Same marks as the strip's `DayCell` (filled for planned, a check for done, hollow for
/// missed), so the two read as one calendar. Tapping a day picks it on Home and closes
/// the sheet.
struct MonthCalendarView: View {
    let activePlan: TrainingPlan?
    @Binding var selectedDate: Date

    @State private var monthStart: Date
    /// Days in the shown month that hold a finished run, from the run log rather than the
    /// plan, so a run with no plan session still shows.
    @State private var runDays: Set<Date> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    init(activePlan: TrainingPlan?, selectedDate: Binding<Date>) {
        self.activePlan = activePlan
        self._selectedDate = selectedDate
        let start = Calendar.current.dateInterval(of: .month, for: selectedDate.wrappedValue)?.start
        self._monthStart = State(initialValue: start ?? selectedDate.wrappedValue)
    }

    var body: some View {
        // Grouped once per render, not once per cell.
        let byDay = sessionsByDay
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    VStack(spacing: 0) {
                        monthHeader
                        weekdayRow
                        LazyVGrid(columns: columns, spacing: AppSpacing.xs) {
                            ForEach(gridDays, id: \.self) { day in
                                if let day {
                                    dayButton(day, sessions: byDay[cal.startOfDay(for: day)] ?? [])
                                } else {
                                    Color.clear.frame(height: 56)
                                }
                            }
                        }
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.bottom, AppSpacing.md)
                    }
                    .strideCard()

                    if let summary = monthSummary(byDay) {
                        Text(summary)
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppSpacing.xs)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .background(Color.surfacePrimary)
            .navigationTitle(String(localized: "Calendar", comment: "Month calendar sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                        .accessibilityIdentifier("monthCalendar.done")
                }
            }
            .task(id: monthStart) { loadRunDays() }
        }
    }

    // MARK: Header

    private var monthHeader: some View {
        HStack {
            monthChevron(icon: .chevronLeft, label: String(localized: "Previous month"), months: -1)
            Spacer()
            Text(monthStart.formatted(.dateTime.month(.wide).year()))
                .strideEyebrow()
                .foregroundStyle(.primary)
                // The shared rolling figure, which cross-fades under Reduce Motion.
                .strideNumericTransition()
            Spacer()
            monthChevron(icon: .chevronRight, label: String(localized: "Next month"), months: 1)
        }
        .padding(.top, AppSpacing.xs)
    }

    private func monthChevron(icon: StrideIconName, label: String, months: Int) -> some View {
        Button {
            withAnimation(AppAnimation.bouncy) {
                monthStart = cal.date(byAdding: .month, value: months, to: monthStart) ?? monthStart
            }
        } label: {
            StrideIcon(name: icon, size: 13, color: .secondary, strokeWeight: 2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Weekday initials in the runner's own first-weekday order.
    private var weekdayRow: some View {
        let symbols = cal.veryShortWeekdaySymbols
        let first = cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.bottom, AppSpacing.xs)
        .accessibilityHidden(true)
    }

    // MARK: Grid

    /// The month's days with leading blanks so the 1st lands under its weekday.
    private var gridDays: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        let weekday = cal.component(.weekday, from: monthStart)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        let days: [Date?] = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        return Array(repeating: nil, count: leading) + days
    }

    private func dayButton(_ day: Date, sessions: [ScheduledWorkout]) -> some View {
        Button {
            selectedDate = day
            dismiss()
        } label: {
            MonthDayCell(
                date: day,
                sessions: sessions.filter { $0.workoutType != .rest },
                isRestDay: sessions.contains { $0.workoutType == .rest },
                hasRun: runDays.contains(cal.startOfDay(for: day)),
                isSelected: cal.isDate(day, inSameDayAs: selectedDate),
                isRaceDay: isRaceDay(day, sessions: sessions)
            )
        }
        .buttonStyle(.plain)
    }

    private func isRaceDay(_ day: Date, sessions: [ScheduledWorkout]) -> Bool {
        if let raceDate = activePlan?.raceDate, cal.isDate(raceDate, inSameDayAs: day) { return true }
        return sessions.contains { $0.workoutType == .race }
    }

    // MARK: Data

    /// Every plan session, keyed by day.
    private var sessionsByDay: [Date: [ScheduledWorkout]] {
        let all = (activePlan?.weeks ?? []).flatMap { $0.workouts ?? [] }
        return Dictionary(grouping: all) { cal.startOfDay(for: $0.scheduledDate) }
    }

    /// "9 of 14 sessions done · 2 missed" for the shown month, or nil with no plan in it.
    private func monthSummary(_ byDay: [Date: [ScheduledWorkout]]) -> String? {
        guard let interval = cal.dateInterval(of: .month, for: monthStart) else { return nil }
        let sessions = byDay
            .filter { interval.contains($0.key) }
            .flatMap(\.value)
            .filter { $0.workoutType != .rest }
        guard !sessions.isEmpty else { return nil }
        let done = sessions.filter(\.isCompleted).count
        let missed = sessions.filter { MissedWorkoutDetector.isMissed($0) }.count
        let base = String(localized: "\(done) of \(sessions.count) sessions done")
        return missed > 0 ? base + " · " + String(localized: "\(missed) missed") : base
    }

    private func loadRunDays() {
        guard let interval = cal.dateInterval(of: .month, for: monthStart) else { return }
        let start = interval.start
        let end = interval.end
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        let descriptor = FetchDescriptor<RunWorkout>(
            predicate: #Predicate {
                $0.date >= start && $0.date < end
                    && $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            }
        )
        let runs = (try? context.fetch(descriptor)) ?? []
        runDays = Set(runs.map { cal.startOfDay(for: $0.date) })
    }
}

// MARK: - MonthDayCell

private struct MonthDayCell: View {
    let date: Date
    /// The day's real sessions, rest excluded.
    let sessions: [ScheduledWorkout]
    let isRestDay: Bool
    let hasRun: Bool
    let isSelected: Bool
    let isRaceDay: Bool

    private let cal = Calendar.current
    private var isToday: Bool { cal.isDateInToday(date) }

    var body: some View {
        VStack(spacing: AppSpacing.xxs) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 32, height: 32)
                Text(date.formatted(.dateTime.day()))
                    .font(
                        .system(.subheadline, design: .rounded, weight: isToday || isSelected ? .bold : .semibold)
                            .monospacedDigit()
                    )
                    .foregroundStyle(isToday ? Color.onFill : .primary)
            }
            marks
                .frame(height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var circleFill: AnyShapeStyle {
        if isToday { return AnyShapeStyle(.route) }
        if isSelected { return AnyShapeStyle(Color.brand.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }

    @ViewBuilder
    private var marks: some View {
        if isRaceDay {
            StrideIcon(name: .flag, size: 10, color: .brandText, strokeWeight: 2.2)
        } else if !sessions.isEmpty {
            HStack(spacing: 3) {
                ForEach(sessions.prefix(2)) { session in
                    mark(for: session)
                }
            }
        } else if hasRun {
            // A run with no plan session behind it: done, but not the plan's colour.
            StrideIcon(name: .check, size: 8, color: .secondary, strokeWeight: 2.5)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func mark(for session: ScheduledWorkout) -> some View {
        let color = session.workoutType.color
        if session.isCompleted {
            StrideIcon(name: .check, size: 8, color: color, strokeWeight: 2.5)
        } else if MissedWorkoutDetector.isMissed(session) {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: 6, height: 6)
        } else {
            RoundedRectangle(cornerRadius: AppRadius.micro)
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }

    private var accessibilityDescription: String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        var parts = [day]
        if isRaceDay { parts.append(String(localized: "race day")) }
        if sessions.isEmpty {
            if hasRun {
                parts.append(String(localized: "run logged"))
            } else if isRestDay {
                parts.append(String(localized: "rest day"))
            }
        } else {
            for session in sessions {
                var text = session.workoutType.localizedName
                if session.isCompleted {
                    text += ", " + String(localized: "completed")
                } else if MissedWorkoutDetector.isMissed(session) {
                    text += ", " + String(localized: "missed")
                }
                parts.append(text)
            }
        }
        return parts.joined(separator: ", ")
    }
}
