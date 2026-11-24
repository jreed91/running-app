import SwiftUI
import SwiftData
import MapKit

// MARK: - Full-screen heatmap

/// The heatmap on the whole screen: every street you've run, with its own period, year
/// and run type filters, a choice of base map, and what the chosen runs add up to.
///
/// Opens on what the Progress card was showing. The filters here are the screen's own,
/// so trying "2024" doesn't change the Progress page underneath.
struct RouteHeatmapScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]

    @State private var period: HeatmapPeriod
    @State private var runType: ProgressFilter.RunType
    @State private var style: RouteHeatmapMap.Style = .dark
    @State private var heatmap: RouteHeatmap.Heatmap?
    @State private var isLoading = false
    @State private var recenter = 0
    /// The spot tapped, and the runs that went through it, newest first.
    @State private var spot: RouteHeatmap.Point?
    @State private var spotRuns: [RunWorkout] = []
    @State private var showsNewGround = false
    @State private var shareImage: ShareCardImage?
    @State private var isSharing = false
    @State private var newGround: RouteHeatmap.NewGround?

    init(period: HeatmapPeriod, runType: ProgressFilter.RunType) {
        _period = State(initialValue: period)
        _runType = State(initialValue: runType)
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        ZStack {
            if let heatmap {
                RouteHeatmapMap(
                    heatmap: heatmap,
                    style: style,
                    recenter: recenter,
                    selection: spot,
                    onTap: { point, radius in pick(point, radiusMeters: radius) },
                    newGround: showsNewGround ? newGround : nil
                )
                .ignoresSafeArea()
            } else {
                Color.inkDeep.ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) {
            if spot != nil {
                spotPanel
            } else {
                statsPanel
            }
        }
        .overlay {
            if heatmap == nil {
                VStack(spacing: AppSpacing.sm) {
                    ProgressView()
                    Text("Tracing your routes…")
                        .font(.bodyRegular)
                }
                .foregroundStyle(Color.onInk)
                .tint(Color.onInk)
            }
        }
        .sheet(item: $shareImage) { card in
            ShareSheet(image: card.image)
        }
        .task(id: LoadKey(period: period, type: runType, count: workouts.count)) {
            isLoading = true
            let all = RouteHeatmapLoader.keys(from: workouts)
            let shown = shownKeys()
            heatmap = await RouteHeatmapLoader.load(all: all, shown: shown, context: context)
            newGround = await loadNewGround(shown: shown)
            isLoading = false
            clearSpot()
        }
    }

    // MARK: Share

    /// Renders the poster from every shown run trimmed by the runner's privacy settings,
    /// then opens the share sheet. The map on screen stays untrimmed: it never leaves the
    /// phone.
    private func share() async {
        isSharing = true
        defer { isSharing = false }
        let privacy = RoutePrivacy.load()
        let trimmed = await RouteHeatmapCache.shared.sharedHeatmap(
            for: shownKeys(),
            privacy: RouteHeatmap.Privacy(
                hideEndsMeters: privacy.hideEndsMeters,
                zones: privacy.places.map {
                    .init(
                        center: RouteHeatmap.Point(latitude: $0.center.latitude, longitude: $0.center.longitude),
                        radiusMeters: $0.radiusMeters
                    )
                }
            )
        )
        guard !trimmed.isEmpty else {
            AppLogger.log("Heatmap poster: nothing left after privacy trim", label: "Share", level: .info)
            return
        }
        // The heat itself is drawn off the main actor, like the Progress card's picture.
        let colors = HeatDots.heatColors()
        let background = HeatDots.rgba(Color.inkDeep)
        let size = HeatmapPosterView.heatSize
        let heatImage = await Task.detached(priority: .userInitiated) {
            HeatDots(trimmed, colors: colors).preview(size: size, background: background, pixelScale: 3)
        }.value
        let renderer = ImageRenderer(content: HeatmapPosterView(
            heatmap: trimmed,
            heatImage: heatImage,
            title: Self.title(of: period),
            subtitle: runType == .all ? nil : runType.title,
            unit: appSettings.unitPreference
        ))
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            AppLogger.log("Heatmap poster render produced no image", label: "Share", level: .error)
            return
        }
        shareImage = ShareCardImage(image: image)
    }

    // MARK: New ground

    /// The period's new streets: compared against every earlier run of any kind, since a
    /// street first run on an easy day isn't new on a long run. All time has none.
    private func loadNewGround(shown: [RouteHeatmapCache.Key]) async -> RouteHeatmap.NewGround? {
        guard let start = period.interval(now: .now, calendar: .current)?.start else { return nil }
        let earlier = RouteHeatmapLoader.keys(from: workouts.filter { $0.date < start })
        return await RouteHeatmapCache.shared.newGround(for: shown, before: earlier)
    }

    private var newGroundChip: some View {
        Button {
            // All time has nothing to compare against, and the map opens on All when the
            // Progress page is on All: rather than a chip that does nothing, turning it on
            // there moves to the last 90 days.
            if !showsNewGround, period == .all { period = Self.newGroundPeriod }
            withAnimation(AppAnimation.quick) { showsNewGround.toggle() }
        } label: {
            Label("New ground", systemImage: "sparkles")
        }
        .buttonStyle(.strideChip(selected: showsNewGround))
        .accessibilityHint(
            period == .all
                ? "Switches to the last 90 days and shows the streets you ran for the first time in them"
                : "Shows the streets you ran for the first time in this period"
        )
    }

    /// The period New ground moves to from All time.
    static let newGroundPeriod = HeatmapPeriod.lastDays(90)

    // MARK: Tap a spot

    private func pick(_ point: RouteHeatmap.Point, radiusMeters: Double) {
        let shown = shownKeys()
        Task {
            let ids = await RouteHeatmapCache.shared.runs(near: point, radiusMeters: radiusMeters, among: shown)
            let byID = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            withAnimation(AppAnimation.quick) {
                spot = point
                spotRuns = ids.compactMap { byID[$0] }.sorted { $0.date > $1.date }
            }
        }
    }

    private func clearSpot() {
        spot = nil
        spotRuns = []
    }

    private var spotPanel: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(spotTitle)
                    .font(.dsHeadline)
                Spacer()
                Button {
                    withAnimation(AppAnimation.quick) { clearSpot() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.dsFootnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the totals")
            }
            if spotRuns.isEmpty {
                Text("Tap a coloured street to see the runs that went along it.")
                    .font(.bodyRegular)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(spotRuns) { workout in
                            NavigationLink {
                                RunSummaryView(workout: workout)
                            } label: {
                                ProgressRunRow(workout: workout, unit: appSettings.unitPreference)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.sm)
        .strideReadableWidth()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var spotTitle: String {
        switch spotRuns.count {
        case 0: return String(localized: "No runs here")
        case 1: return String(localized: "1 run went here")
        default: return String(localized: "\(spotRuns.count) runs went here")
        }
    }

    private struct LoadKey: Equatable {
        let period: HeatmapPeriod
        let type: ProgressFilter.RunType
        let count: Int
    }

    private func shownKeys() -> [RouteHeatmapCache.Key] {
        let now = Date.now
        let calendar = Calendar.current
        return RouteHeatmapLoader.keys(from: workouts.filter {
            period.contains($0.date, now: now, calendar: calendar)
                && runType.includes($0.workoutType.progressRunKind)
        })
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("Heatmap")
                    .font(.dsTitle2.weight(.bold))
                    .foregroundStyle(Color.onInk)
                Spacer()
                Button {
                    Task { await share() }
                } label: {
                    Group {
                        if isSharing {
                            ProgressView().tint(Color.onInk)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.dsSubhead.weight(.bold))
                        }
                    }
                    .foregroundStyle(Color.onInk)
                    .frame(width: 36, height: 36)
                    .background(Color.inkDeep.opacity(0.7), in: Circle())
                }
                .disabled(isSharing || (heatmap?.isEmpty ?? true))
                .accessibilityLabel("Share heatmap")
                .accessibilityHint("Makes a poster of this heatmap, with your private places and run starts left out")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.dsSubhead.weight(.bold))
                        .foregroundStyle(Color.onInk)
                        .frame(width: 36, height: 36)
                        .background(Color.inkDeep.opacity(0.7), in: Circle())
                }
                .accessibilityLabel("Close")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    periodMenu
                    runTypeMenu
                    newGroundChip
                    styleMenu
                    Button {
                        recenter += 1
                    } label: {
                        Label("Home streets", systemImage: "scope")
                    }
                    .buttonStyle(.strideChip())
                    .accessibilityHint("Moves the map back to the streets you run most")
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.md)
        .background(
            LinearGradient(
                colors: [Color.inkDeep.opacity(0.85), Color.inkDeep.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var periodChoices: [HeatmapPeriod] {
        var choices = HeatmapPeriod.choices(runDates: workouts.map(\.date), calendar: .current)
        if !choices.contains(period) { choices.insert(period, at: 1) }
        return choices
    }

    private var periodMenu: some View {
        Menu {
            Picker("Period", selection: $period) {
                ForEach(periodChoices) { choice in
                    Text(Self.title(of: choice)).tag(choice)
                }
            }
        } label: {
            Label(Self.title(of: period), systemImage: "calendar")
        }
        .buttonStyle(.strideChip(selected: true))
    }

    private var runTypeMenu: some View {
        Menu {
            Picker("Runs", selection: $runType) {
                ForEach(ProgressFilter.RunType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
        } label: {
            Text(runType.title)
        }
        .buttonStyle(.strideChip(selected: runType != .all))
    }

    private var styleMenu: some View {
        Menu {
            Picker("Map", selection: $style) {
                ForEach(RouteHeatmapMap.Style.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
        } label: {
            Label(style.title, systemImage: "map")
        }
        .buttonStyle(.strideChip())
    }

    static func title(of period: HeatmapPeriod) -> String {
        switch period {
        case .all: return String(localized: "All time")
        case .lastDays(30): return String(localized: "Last 30 days")
        case .lastDays(365): return String(localized: "Last 12 months")
        case .lastDays(let days): return String(localized: "Last \(days) days")
        case .year(let year): return String(year)
        }
    }

    // MARK: Stats

    @ViewBuilder
    private var statsPanel: some View {
        if let heatmap {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if heatmap.isEmpty {
                    Text("No outdoor runs with a route in this period.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                } else {
                    if showsNewGround, let newGround {
                        newGroundSummary(newGround)
                    }
                    HStack(alignment: .top, spacing: AppSpacing.lg) {
                        stat(
                            value: "\(heatmap.runCount)",
                            label: heatmap.runCount == 1 ? String(localized: "run") : String(localized: "runs")
                        )
                        stat(
                            value: heatmap.uniqueMeters.distanceString(unit: appSettings.unitPreference),
                            label: String(localized: "of ground")
                        )
                        stat(
                            value: "\(heatmap.maxRuns)×",
                            label: String(localized: "busiest stretch")
                        )
                    }
                    HeatLegend()
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
            .opacity(isLoading ? 0.6 : 1)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)
            .strideReadableWidth()
        }
    }

    private func newGroundSummary(_ ground: RouteHeatmap.NewGround) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Rectangle()
                .fill(RouteHeatmapMap.newGroundColor)
                .frame(width: 12, height: 12)
            Text(ground.meters > 0
                ? "\(ground.meters.distanceString(unit: appSettings.unitPreference)) of streets new to you"
                : "No new streets in this period")
                .font(.dsFootnote.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dsTitle3.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The heat colours from "once" to "most", as the map draws them.
private struct HeatLegend: View {
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("Once")
            HStack(spacing: 3) {
                ForEach(1...RouteHeatmap.levels, id: \.self) { level in
                    Rectangle()
                        .fill(RouteHeatmapMap.color(level: level))
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: 160)
            Text("Most")
        }
        .font(.dsCaption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brighter squares are streets you run more often")
    }
}
