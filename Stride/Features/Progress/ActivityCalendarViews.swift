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
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        return Query(
            filter: #Predicate<RunWorkout> {
                $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
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

/// "Running days" on Progress: the last half year as a grid, the week streak, and
/// a link to the full year and the route heatmap.
struct ActivityCalendarCard: View {
    @Query private var workouts: [RunWorkout]

    init() {
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        let runs = ActivityCalendar.runs(from: workouts)
        let weeks = ActivityCalendar.weeks(26, runs: runs, now: .now, calendar: .current)
        let streak = ActivityCalendar.currentWeekStreak(weeks)
        let activeDays = weeks.reduce(0) { $0 + $1.days.filter { !$0.runIDs.isEmpty }.count }

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                // The card shows 26 weeks; "Your running year" promised twelve months.
                Text("RUNNING DAYS · 6 MONTHS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                NavigationLink {
                    ActivityYearView()
                } label: {
                    HStack(spacing: 2) {
                        Text("Explore")
                        StrideIcon(name: .chevronRight, size: 10, color: .brandText, strokeWeight: 2.2)
                    }
                    .font(.captionStrong)
                    .foregroundStyle(Color.brandText)
                }
                .accessibilityLabel("Explore your running year")
            }
            .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks) { week in
                        VStack(spacing: 3) {
                            ForEach(week.days) { day in
                                CalendarCell(day: day)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Running days, last six months")
                .accessibilityValue("\(activeDays) days with a run")
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
}

extension ActivityCalendarCard {
    fileprivate func streakLine(streak: Int, activeDays: Int) -> some View {
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

// MARK: - Full page

/// A year of running days, tap any day to list its runs, and every route of the year on
/// one map, brighter where run more often.
struct ActivityYearView: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @State private var selectedDay: Date?
    @State private var routes: [[CLLocationCoordinate2D]] = []

    /// Routes drawn at once, newest first, and points kept per route: enough to show the
    /// streets, few enough that the map stays smooth.
    private static let routeLimit = 400
    private static let pointsPerRoute = 200

    init() {
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        let runs = ActivityCalendar.runs(from: workouts)
        let weeks = ActivityCalendar.weeks(53, runs: runs, now: .now, calendar: .current)
        let selected = selectedDay.flatMap { date in weeks.lazy.flatMap(\.days).first { $0.date == date } }

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                yearGrid(weeks, selected: selected)
                if let selected {
                    dayRuns(selected)
                }
                heatmap
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Your running year")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workouts.count) {
            routes = Self.heatmapRoutes(from: workouts)
        }
    }

    // MARK: Grid

    private func yearGrid(_ weeks: [ActivityCalendar.Week], selected: ActivityCalendar.Day?) -> some View {
        let total = weeks.reduce(0.0) { $0 + $1.days.reduce(0) { $0 + $1.meters } }
        let activeDays = weeks.reduce(0) { $0 + $1.days.filter { !$0.runIDs.isEmpty }.count }
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("LAST 12 MONTHS")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Text("\(activeDays) running days · \(total.distanceString(unit: appSettings.unitPreference))")
                .font(.dsTitle3)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks) { week in
                        VStack(spacing: 3) {
                            ForEach(week.days) { day in
                                Button {
                                    guard !day.isFuture else { return }
                                    selectedDay = selectedDay == day.date ? nil : day.date
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    CalendarCell(day: day, isSelected: day.date == selected?.date)
                                        .frame(width: 15, height: 15)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(dayLabel(day))
                            }
                        }
                    }
                }
                .padding(.vertical, AppSpacing.xxs)
            }
            .defaultScrollAnchor(.trailing)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Tap a day to see its runs")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer(minLength: AppSpacing.sm)
                    CalendarLegend()
                }
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Tap a day to see its runs")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    CalendarLegend()
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func dayLabel(_ day: ActivityCalendar.Day) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard !day.runIDs.isEmpty else { return "\(date), no run" }
        return "\(date), \(day.meters.distanceString(unit: appSettings.unitPreference))"
    }

    @ViewBuilder
    private func dayRuns(_ day: ActivityCalendar.Day) -> some View {
        let listed = day.runIDs.compactMap { id in workouts.first { $0.id == id } }
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            if listed.isEmpty {
                Text("A rest day.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(listed) { workout in
                        NavigationLink {
                            RunSummaryView(workout: workout)
                        } label: {
                            HStack {
                                Text(workout.workoutType.localizedName)
                                    .font(.bodyStrong)
                                Spacer()
                                Text(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
                                    .font(.bodyStrong.monospacedDigit())
                                Text(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                    .font(.dsCaption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2)
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .strideCard()
            }
        }
    }

    // MARK: Route heatmap

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("EVERY ROUTE, LAST 12 MONTHS")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            if routes.isEmpty {
                Text("Outdoor runs with a route show up here.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
            } else {
                // Each route is drawn faint; where they overlap they add up, so the
                // streets run most often glow brightest.
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
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                .accessibilityLabel("Map of \(routes.count) routes from the last year")
                Text("\(routes.count) routes. Pinch to zoom into the streets you run most.")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.xs)
            }
        }
    }

    @MainActor
    private static func heatmapRoutes(from workouts: [RunWorkout]) -> [[CLLocationCoordinate2D]] {
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
        return workouts
            .filter { $0.date >= cutoff && $0.routeData != nil }
            .suffix(routeLimit)
            .compactMap { workout in
                let route = RouteThinning.thinned(workout.routeCoordinates, limit: pointsPerRoute)
                return route.count > 1 ? route.map(\.clCoordinate) : nil
            }
    }
}
