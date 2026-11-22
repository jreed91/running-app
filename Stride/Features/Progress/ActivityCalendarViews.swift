import SwiftUI
import SwiftData
import MapKit

// MARK: - Shared

extension ActivityCalendar {
    /// Runs only, the way every other Progress figure counts.
    @MainActor
    static func runs(from workouts: [RunWorkout]) -> [Run] {
        workouts.filter(\.countsAsRunning).map { Run(id: $0.id, date: $0.date, meters: $0.distanceMeters) }
    }

    /// All-time runs, no walks or cross-training.
    static func query() -> Query<RunWorkout, [RunWorkout]> {
        // Numbers only. The heatmap reads routes after its tap, up to its route limit,
        // and SwiftData faults those in one run at a time.
        Query(RunWorkout.allRunsSummaryDescriptor)
    }
}

/// One square of the grid.
private struct CalendarCell: View {
    let day: ActivityCalendar.Day
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.micro)
            .fill(fill)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppRadius.micro)
                        .stroke(Color.primary, lineWidth: 1.5)
                }
            }
    }

    private var fill: Color {
        if day.isFuture { return .clear }
        switch day.level {
        case 0: return Color.surfaceTertiary
        case 1: return Color.brand.opacity(0.28)
        case 2: return Color.brand.opacity(0.5)
        case 3: return Color.brand.opacity(0.75)
        default: return Color.brand
        }
    }
}

/// Less to more, under the grid.
private struct CalendarLegend: View {
    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Text("Less").fixedSize()
            ForEach(0..<5, id: \.self) { level in
                CalendarCell(day: ActivityCalendar.Day(
                    date: .distantPast, meters: 0, runIDs: [], level: level, isFuture: false
                ))
                .frame(width: 10, height: 10)
            }
            Text("More").fixedSize()
        }
        .fixedSize()
        .font(.dsCaption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

// MARK: - Progress card

/// "Running days" on Progress: the page's period as a grid of days (up to half a year),
/// the week streak, and a tap on any day to drill the page into it.
struct ActivityCalendarCard: View {
    let runType: ProgressFilter.RunType
    /// Weeks to draw, the current one included.
    let weeks: Int
    /// The page's drill-in, outlined when it is one of these days.
    let selectedDay: DateInterval?
    /// Drills the page into a day.
    let onPick: (DateInterval) -> Void

    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]

    init(
        runType: ProgressFilter.RunType,
        weeks: Int,
        selectedDay: DateInterval?,
        onPick: @escaping (DateInterval) -> Void
    ) {
        self.runType = runType
        self.weeks = weeks
        self.selectedDay = selectedDay
        self.onPick = onPick
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        let runs = ActivityCalendar.runs(
            from: workouts.filter { runType.includes($0.workoutType.progressRunKind) }
        )
        let grid = ActivityCalendar.weeks(weeks, runs: runs, now: .now, calendar: .current)
        let streak = ActivityCalendar.currentWeekStreak(grid)
        let activeDays = grid.reduce(0) { $0 + $1.days.filter { !$0.runIDs.isEmpty }.count }

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(weeks >= 26 ? "RUNNING DAYS · LAST 26 WEEKS" : "RUNNING DAYS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                Text("Tap a day to drill in")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(alignment: .top, spacing: weeks > 16 ? 3 : 5) {
                    ForEach(grid) { week in
                        VStack(spacing: weeks > 16 ? 3 : 5) {
                            ForEach(week.days) { day in
                                dayButton(day)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                // The legend moves under the streak when they don't fit on one line,
                // instead of squeezing to "Le ss" and "Mor e".
                ViewThatFits(in: .horizontal) {
                    HStack {
                        streakLine(streak: streak, activeDays: activeDays)
                        Spacer(minLength: AppSpacing.sm)
                        CalendarLegend()
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        streakLine(streak: streak, activeDays: activeDays)
                        CalendarLegend()
                    }
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
        }
    }

    private func dayButton(_ day: ActivityCalendar.Day) -> some View {
        let isSelected = selectedDay?.start == day.date
        return Button {
            guard !day.isFuture else { return }
            let end = Calendar.current.date(byAdding: .day, value: 1, to: day.date) ?? day.date
            onPick(DateInterval(start: day.date, end: end))
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            CalendarCell(day: day, isSelected: isSelected)
                .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
        .disabled(day.isFuture)
        .accessibilityLabel(dayLabel(day))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows that day's runs")
    }

    private func dayLabel(_ day: ActivityCalendar.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard !day.runIDs.isEmpty else { return String(localized: "\(date), no run") }
        return "\(date), \(day.meters.distanceString(unit: appSettings.unitPreference))"
    }

    private func streakLine(streak: Int, activeDays: Int) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(streak == 1 ? "1 week in a row" : "\(streak) weeks in a row")
                .font(.captionStrong)
            Text("· \(activeDays) running days")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

// MARK: - Every route

/// Every route in the page's period on one map, each drawn faint so the streets run most
/// often glow brightest. The map waits for a tap: a few hundred polylines are more work
/// than the rest of the page together.
struct RouteHeatmapCard: View {
    let periodDays: Int?
    let runType: ProgressFilter.RunType

    @Query private var workouts: [RunWorkout]
    @State private var showsMap = false
    @State private var routes: [[CLLocationCoordinate2D]] = []

    /// Routes drawn at once, newest first, and points kept per route: enough to show the
    /// streets, few enough that the map stays smooth.
    private static let routeLimit = 400
    private static let pointsPerRoute = 200

    init(periodDays: Int?, runType: ProgressFilter.RunType) {
        self.periodDays = periodDays
        self.runType = runType
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("EVERY ROUTE")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            if showsMap {
                if routes.isEmpty {
                    Text("Outdoor runs with a route show up here.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .padding(AppSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .strideCard()
                } else {
                    Map(interactionModes: [.zoom, .pan]) {
                        ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                            MapPolyline(coordinates: route)
                                .stroke(
                                    Color.brand.opacity(0.28),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                                )
                        }
                    }
                    .mapStyle(.standard(emphasis: .muted))
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .accessibilityLabel("Map of \(routes.count) routes")
                    Text("\(routes.count) routes. Pinch to zoom into the streets you run most.")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                }
            } else {
                Button {
                    withAnimation(AppAnimation.quick) { showsMap = true }
                } label: {
                    Text("Show the map")
                }
                .buttonStyle(.strideButton(.quiet))
            }
        }
        .task(id: TaskKey(show: showsMap, days: periodDays, type: runType, count: workouts.count)) {
            guard showsMap else { return }
            routes = heatmapRoutes()
        }
    }

    private struct TaskKey: Equatable {
        let show: Bool
        let days: Int?
        let type: ProgressFilter.RunType
        let count: Int
    }

    private func heatmapRoutes() -> [[CLLocationCoordinate2D]] {
        let cutoff = periodDays.map { Date.now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        return workouts
            .filter {
                $0.date >= cutoff && $0.routeData != nil && runType.includes($0.workoutType.progressRunKind)
            }
            .suffix(Self.routeLimit)
            .compactMap { workout in
                let route = RouteThinning.thinned(workout.routeCoordinates, limit: Self.pointsPerRoute)
                return route.count > 1 ? route.map(\.clCoordinate) : nil
            }
    }
}
