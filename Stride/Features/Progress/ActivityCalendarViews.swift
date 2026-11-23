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

/// Reads route blobs off the main thread, in its own context.
@ModelActor
actor RouteHeatmapReader {
    /// The route blobs of the runs named. A run with no route is handed over empty, so
    /// the cache remembers it has none. Each call's objects are let go when it returns.
    func routes(of ids: [UUID]) -> [RouteHeatmapCache.Input] {
        var descriptor = FetchDescriptor<RunWorkout>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id, \.date, \.routeData]
        // A context per batch, on this actor's thread, so each batch's blobs are let go
        // when it returns rather than piling up in one long-lived context.
        let context = ModelContext(modelContainer)
        let runs = (try? context.fetch(descriptor)) ?? []
        return runs.map { RouteHeatmapCache.Input(id: $0.id, date: $0.date, route: $0.routeData ?? Data()) }
    }
}

/// Reads routes from the store for ``RouteHeatmapCache``: only the runs it hasn't traced,
/// a few at a time, on ``RouteHeatmapReader``'s background context. Reading them on the
/// main actor, as the first version did, stalled the app while years of routes loaded.
enum RouteHeatmapLoader {
    /// Route blobs read at once. A long run's route is a few hundred kilobytes of JSON.
    private static let batchSize = 25

    /// The last map shown, so a card that appears again draws straight away.
    @MainActor static var latest: RouteHeatmap.Heatmap?

    /// Every outdoor run, by id and date. Indoor runs never have a route.
    @MainActor
    static func keys(from workouts: [RunWorkout]) -> [RouteHeatmapCache.Key] {
        workouts.compactMap { run in
            run.workoutLocation == .indoor ? nil : RouteHeatmapCache.Key(id: run.id, date: run.date)
        }
    }

    /// - Parameters:
    ///   - all: every run the cache should know, so deleted runs drop out.
    ///   - shown: the runs on the map.
    @MainActor
    static func load(
        all: [RouteHeatmapCache.Key],
        shown: [RouteHeatmapCache.Key],
        context: ModelContext
    ) async -> RouteHeatmap.Heatmap {
        let cache = RouteHeatmapCache.shared
        let missing = await cache.missing(all)
        if !missing.isEmpty {
            let container = context.container
            // Made off the main actor: a model actor made on the main thread runs there.
            let reader = await Task.detached { RouteHeatmapReader(modelContainer: container) }.value
            var start = 0
            while start < missing.count, !Task.isCancelled {
                let batch = Array(missing[start..<min(start + batchSize, missing.count)])
                start += batchSize
                await cache.add(await reader.routes(of: batch))
            }
        }
        await cache.keep(only: Set(all.map(\.id)))
        let heatmap = await cache.heatmap(for: shown)
        latest = heatmap
        return heatmap
    }
}

/// Every route in the page's period as a still picture of the heat, each street coloured
/// by how many runs went along it. A tap opens the live, full-screen map.
///
/// A picture rather than a live map: an `MKMapView` on a scrolling page redraws as the
/// page moves, and with years of runs that made the whole Progress page slow. The first
/// time waits for a tap: tracing years of routes is a few seconds' work once, and
/// nothing after that.
struct RouteHeatmapCard: View {
    let periodDays: Int?
    let runType: ProgressFilter.RunType

    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @State private var showsMap = false
    @State private var heatmap: RouteHeatmap.Heatmap?
    @State private var preview: UIImage?
    @State private var showsFullScreen = false

    private static let previewSize = CGSize(width: 360, height: 240)

    init(periodDays: Int?, runType: ProgressFilter.RunType) {
        self.periodDays = periodDays
        self.runType = runType
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("EVERY ROUTE")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Full screen") { showsFullScreen = true }
                    .font(.dsFootnote.weight(.semibold))
                    .foregroundStyle(Color.brandText)
                    .accessibilityHint("Opens the heatmap with its own filters")
                    .accessibilityIdentifier("progress.heatmap.fullScreen")
            }
            .padding(.horizontal, AppSpacing.xs)
            if showsMap {
                if let heatmap {
                    if heatmap.isEmpty {
                        Text("Outdoor runs with a route show up here.")
                            .font(.bodyRegular)
                            .foregroundStyle(.secondary)
                            .padding(AppSpacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .strideCard()
                    } else {
                        Button {
                            showsFullScreen = true
                        } label: {
                            ZStack {
                                Color.inkDeep
                                if let preview {
                                    Image(uiImage: preview)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    ProgressView().tint(Color.onInk)
                                }
                            }
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Heatmap of \(heatmap.runCount) runs")
                        .accessibilityHint("Opens the map full screen")
                        Text(summary(heatmap))
                            .font(.dsFootnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppSpacing.xs)
                    }
                } else {
                    HStack(spacing: AppSpacing.sm) {
                        ProgressView()
                        Text("Tracing your routes…")
                            .font(.bodyRegular)
                            .foregroundStyle(.secondary)
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
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
        .fullScreenCover(isPresented: $showsFullScreen) {
            RouteHeatmapScreen(period: HeatmapPeriod(progressDays: periodDays), runType: runType)
                .environment(appSettings)
        }
        .onAppear {
            // Shown before this session: open straight onto the last map.
            if let latest = RouteHeatmapLoader.latest, heatmap == nil {
                heatmap = latest
                showsMap = true
            }
        }
        .task(id: TaskKey(show: showsMap, days: periodDays, type: runType, count: workouts.count)) {
            guard showsMap else { return }
            let all = RouteHeatmapLoader.keys(from: workouts)
            let shown = shownKeys()
            let loaded = await RouteHeatmapLoader.load(all: all, shown: shown, context: context)
            guard loaded != heatmap || preview == nil else { return }
            heatmap = loaded
            preview = await Self.renderPreview(loaded)
        }
    }

    /// The still picture, drawn off the main actor.
    private static func renderPreview(_ heatmap: RouteHeatmap.Heatmap) async -> UIImage? {
        guard !heatmap.isEmpty else { return nil }
        let colors = HeatDots.heatColors()
        let background = HeatDots.rgba(Color.inkDeep)
        let size = previewSize
        return await Task.detached(priority: .userInitiated) {
            HeatDots(heatmap, colors: colors).preview(size: size, background: background)
        }.value
    }

    private struct TaskKey: Equatable {
        let show: Bool
        let days: Int?
        let type: ProgressFilter.RunType
        let count: Int
    }

    /// The outdoor runs the page's period and run type show.
    private func shownKeys() -> [RouteHeatmapCache.Key] {
        let cutoff = periodDays.map { Date.now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        return RouteHeatmapLoader.keys(from: workouts.filter {
            $0.date >= cutoff && runType.includes($0.workoutType.progressRunKind)
        })
    }

    private func summary(_ heatmap: RouteHeatmap.Heatmap) -> String {
        let ground = heatmap.uniqueMeters.distanceString(unit: appSettings.unitPreference)
        let runs = heatmap.runCount == 1 ? "1 run" : "\(heatmap.runCount) runs"
        let busiest = heatmap.maxRuns > 1 ? " Your busiest stretch: \(heatmap.maxRuns) runs." : ""
        return "\(runs) over \(ground) of ground.\(busiest)"
    }
}
