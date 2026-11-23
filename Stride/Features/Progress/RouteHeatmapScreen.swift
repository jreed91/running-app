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

    init(period: HeatmapPeriod, runType: ProgressFilter.RunType) {
        _period = State(initialValue: period)
        _runType = State(initialValue: runType)
        _workouts = ActivityCalendar.query()
    }

    var body: some View {
        ZStack {
            if let heatmap {
                RouteHeatmapMap(heatmap: heatmap, style: style, recenter: recenter)
                    .ignoresSafeArea()
            } else {
                Color.inkDeep.ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { statsPanel }
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
        .task(id: LoadKey(period: period, type: runType, count: workouts.count)) {
            isLoading = true
            let all = RouteHeatmapLoader.keys(from: workouts)
            let shown = shownKeys()
            heatmap = await RouteHeatmapLoader.load(all: all, shown: shown, context: context)
            isLoading = false
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
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
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
                if heatmap.lines.isEmpty {
                    Text("No outdoor runs with a route in this period.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                } else {
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
                    Capsule()
                        .fill(RouteHeatmapMap.color(level: level))
                        .frame(height: RouteHeatmapMap.width(level: level))
                }
            }
            .frame(maxWidth: 160)
            Text("Most")
        }
        .font(.dsCaption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brighter, thicker lines are streets you run more often")
    }
}
