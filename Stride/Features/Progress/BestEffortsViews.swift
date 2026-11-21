import SwiftUI
import SwiftData
import Charts

// MARK: - Loading

/// Works out every run's best efforts off the main actor.
///
/// A long run's distance series is a few thousand readings, and a runner can have
/// hundreds of runs, so the decoding and the sliding windows run in a detached task. The
/// views hand over plain `Sendable` inputs read from the models on the main actor.
enum BestEffortsLoader {
    struct Input: Sendable, Equatable {
        let id: UUID
        let date: Date
        let series: Data
    }

    /// Runs that carry a distance series. Runs from before the series was stored have
    /// none and can't be searched inside; their whole-run times still count on Progress.
    @MainActor
    static func inputs(from workouts: [RunWorkout]) -> [Input] {
        workouts.compactMap { run in
            guard run.workoutType.countsAsRunning, let data = run.distanceSeriesData else { return nil }
            return Input(id: run.id, date: run.date, series: data)
        }
    }

    /// Changes whenever a run is added, removed or gets a series, so a `.task(id:)`
    /// recomputes exactly then.
    static func fingerprint(_ inputs: [Input]) -> Int {
        var hasher = Hasher()
        for input in inputs {
            hasher.combine(input.id)
            hasher.combine(input.series.count)
        }
        return hasher.finalize()
    }

    static func load(_ inputs: [Input]) async -> [BestEfforts.RunEfforts] {
        await Task.detached(priority: .utility) {
            inputs.compactMap { input -> BestEfforts.RunEfforts? in
                guard let points = input.series.decode([SplitBucketing.DistancePoint].self) else { return nil }
                let samples = points.map {
                    BestEfforts.Sample(elapsedSeconds: $0.elapsedSeconds, meters: $0.cumulativeMeters)
                }
                let efforts = BestEfforts.efforts(in: samples)
                guard !efforts.isEmpty else { return nil }
                return BestEfforts.RunEfforts(id: input.id, date: input.date, efforts: efforts)
            }
        }.value
    }
}

// MARK: - Progress card

/// "Best efforts" on Progress: the all-time record at each distance, found inside any
/// run, with a link to the full page.
///
/// Its own view with its own all-time query: Progress's query only reaches back a year,
/// and a record set two years ago is still the record.
struct BestEffortsCard: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @State private var efforts: [BestEfforts.RunEfforts] = []
    @State private var hasLoaded = false

    init() {
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }

    /// The distances the card lists: the ones runners race. 400 m is on the full page.
    private static let shown: [BestEfforts.Distance] = [.oneK, .mile, .fiveK, .tenK, .half, .marathon]

    var body: some View {
        let inputs = BestEffortsLoader.inputs(from: workouts)
        let records = BestEfforts.records(in: efforts)
        let rows = Self.shown.compactMap { distance in records[distance].map { (distance, $0) } }

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("BEST EFFORTS · ALL TIME")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                if !rows.isEmpty {
                    NavigationLink {
                        BestEffortsView(efforts: efforts, distance: records[.fiveK] != nil ? .fiveK : rows[0].0)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Explore")
                            StrideIcon(name: .chevronRight, size: 10, color: .brandText, strokeWeight: 2.2)
                        }
                        .font(.captionStrong)
                        .foregroundStyle(Color.brandText)
                    }
                    .accessibilityLabel("Explore best efforts")
                }
            }
            .padding(.horizontal, AppSpacing.xs)

            Group {
                if rows.isEmpty {
                    Text(hasLoaded
                         ? "Run a kilometre or more and your fastest stretches show up here."
                         : "Finding your fastest stretches…")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(rows, id: \.0) { row in
                            recordRow(row.0, row.1)
                        }
                    }
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
        }
        .task(id: BestEffortsLoader.fingerprint(inputs)) {
            efforts = await BestEffortsLoader.load(inputs)
            hasLoaded = true
        }
    }

    private func recordRow(_ distance: BestEfforts.Distance, _ effort: BestEfforts.Effort) -> some View {
        let unit = appSettings.unitPreference
        return HStack(alignment: .firstTextBaseline) {
            Text(distance.title)
                .font(.bodyStrong)
                .frame(width: 84, alignment: .leading)
            Text(effort.seconds.durationString)
                .font(.bodyStrong.monospacedDigit())
            Text((effort.seconds / distance.meters * 1_000).paceString(unit: unit))
                .font(.dsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.sm)
            Text(effort.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)))
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Full page

/// Every run's best effort at one distance over time, the record's history as a falling
/// step line, and the top five, each opening its run.
struct BestEffortsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]

    let efforts: [BestEfforts.RunEfforts]
    @State private var distance: BestEfforts.Distance
    @State private var pinnedID: UUID?
    @State private var rawSelection: Date?

    init(efforts: [BestEfforts.RunEfforts], distance: BestEfforts.Distance) {
        self.efforts = efforts
        _distance = State(initialValue: distance)
        _workouts = Query(sort: [SortDescriptor(\RunWorkout.date)])
    }

    private var unit: UnitPreference { appSettings.unitPreference }

    private var availableDistances: [BestEfforts.Distance] {
        BestEfforts.Distance.allCases.filter { candidate in efforts.contains { $0.efforts[candidate] != nil } }
    }

    var body: some View {
        let ranked = BestEfforts.ranked(distance, in: efforts)
        let progression = BestEfforts.progression(distance, in: efforts)
        let selected = pinnedID.flatMap { id in ranked.first { $0.runID == id } } ?? ranked.first

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                distancePicker
                if let record = ranked.first {
                    hero(record)
                    chartCard(ranked: ranked, progression: progression, selected: selected)
                    if let selected {
                        selectedCard(selected, rank: (ranked.firstIndex(of: selected) ?? 0) + 1, of: ranked.count)
                    }
                    topList(Array(ranked.prefix(5)))
                }
                Text("""
                    Found inside every run that recorded its distance as it went: the fastest \
                    stretch of each length, not only whole runs of it. Older runs that never \
                    stored that detail are left out.
                    """)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.xs)
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Best efforts")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: distance) { pinnedID = nil }
        .onChange(of: rawSelection) {
            guard let rawSelection,
                  let nearest = ranked.min(by: {
                      abs($0.date.timeIntervalSince(rawSelection)) < abs($1.date.timeIntervalSince(rawSelection))
                  })
            else { return }
            if pinnedID != nearest.runID {
                pinnedID = nearest.runID
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    // MARK: Controls

    private var distancePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(availableDistances, id: \.self) { option in
                    Button {
                        withAnimation(AppAnimation.bouncy) { distance = option }
                    } label: {
                        Text(option.title)
                    }
                    .buttonStyle(.strideChip(selected: distance == option))
                    .accessibilityAddTraits(distance == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, AppSpacing.xxs)
        }
    }

    // MARK: Hero

    private func hero(_ record: BestEfforts.Effort) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("\(distance.title) record".uppercased())
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Text(record.seconds.durationString)
                .font(.metricM)
                .strideNumericTransition()
            Text("\(pace(record)) · \(record.date.formatted(.dateTime.month(.wide).day().year()))")
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heroCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chartCard(
        ranked: [BestEfforts.Effort],
        progression: [BestEfforts.Effort],
        selected: BestEfforts.Effort?
    ) -> some View {
        // The record holds until today, so the step line runs on to the right edge.
        let steps = progression + (progression.last.map {
            [BestEfforts.Effort(runID: UUID(), date: max(Date(), $0.date), seconds: $0.seconds)]
        } ?? [])
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Each run's fastest \(distance.title), and your record over time".uppercased())
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Chart {
                ForEach(ranked) { effort in
                    PointMark(
                        x: .value("Date", effort.date),
                        y: .value("Time", effort.seconds)
                    )
                    .foregroundStyle(Color.secondary)
                    .opacity(effort.runID == selected?.runID ? 1 : 0.4)
                    .symbolSize(effort.runID == selected?.runID ? 110 : 30)
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    LineMark(
                        x: .value("Date", step.date),
                        y: .value("Time", step.seconds),
                        series: .value("Series", "Record")
                    )
                    .foregroundStyle(.route)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if let selected {
                    RuleMark(x: .value("Date", selected.date))
                        .foregroundStyle(Color.brand.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
                }
            }
            .frame(height: 240)
            // Faster sits higher, so a new record is a step up.
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self), seconds > 0 {
                            Text(seconds.durationString)
                        }
                    }
                }
            }
            .chartXSelection(value: $rawSelection)
            .chartAccessibility("\(distance.title) best efforts", accessibilitySeries(ranked))
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func accessibilitySeries(_ ranked: [BestEfforts.Effort]) -> ChartAccessibility.Series {
        ChartAccessibility.Series(
            points: ranked.sorted { $0.date < $1.date }.map {
                ChartAccessibility.Point(
                    label: $0.date.formatted(.dateTime.month(.abbreviated).day()),
                    value: $0.seconds
                )
            },
            valueAxisLabel: String(localized: "Time")
        ) { SpokenMetric.spoken(measurement: $0.durationString) }
    }

    // MARK: Selected and top five

    private func selectedCard(_ effort: BestEfforts.Effort, rank: Int, of total: Int) -> some View {
        Group {
            if let workout = workout(for: effort) {
                NavigationLink {
                    RunSummaryView(workout: workout)
                } label: {
                    HStack(alignment: .center, spacing: AppSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effort.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()))
                                .strideEyebrow()
                                .foregroundStyle(.secondary)
                            Text(effort.seconds.durationString)
                                .font(.metricS)
                            Text(context(of: effort, in: workout))
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: AppSpacing.sm)
                        VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                            StrideTag(
                                rank == 1 ? "Record" : "#\(rank) of \(total)",
                                tone: rank == 1 ? .brand : .neutral
                            )
                            HStack(spacing: 2) {
                                Text("Open run")
                                StrideIcon(name: .chevronRight, size: 10, color: .brandText, strokeWeight: 2.2)
                            }
                            .font(.captionStrong)
                            .foregroundStyle(Color.brandText)
                        }
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the run")
            }
        }
    }

    private func topList(_ top: [BestEfforts.Effort]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("YOUR FASTEST \(distance.title.uppercased())")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.runID) { index, effort in
                    if let workout = workout(for: effort) {
                        NavigationLink {
                            RunSummaryView(workout: workout)
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                Text("\(index + 1)")
                                    .font(.bodyStrong.monospacedDigit())
                                    .foregroundStyle(index == 0 ? Color.brandText : .secondary)
                                    .frame(width: 20)
                                Text(effort.seconds.durationString)
                                    .font(.bodyStrong.monospacedDigit())
                                Text(pace(effort))
                                    .font(.dsCaption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: AppSpacing.sm)
                                Text(effort.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)))
                                    .font(.dsCaption)
                                    .foregroundStyle(.secondary)
                                StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2)
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens the run")
                        if index < top.count - 1 {
                            Divider().padding(.leading, AppSpacing.lg)
                        }
                    }
                }
            }
            .strideCard()
        }
    }

    // MARK: Helpers

    private func workout(for effort: BestEfforts.Effort) -> RunWorkout? {
        workouts.first { $0.id == effort.runID }
    }

    /// "4:31 /km · inside a 12.0 km long run"
    private func context(of effort: BestEfforts.Effort, in workout: RunWorkout) -> String {
        let run = workout.distanceMeters.distanceString(unit: unit)
        let kind = workout.workoutType.localizedName.lowercased()
        return "\(pace(effort)) · inside a \(run) \(kind)"
    }

    private func pace(_ effort: BestEfforts.Effort) -> String {
        (effort.seconds / distance.meters * 1_000).paceString(unit: unit)
    }
}

// MARK: - Labels

extension BestEfforts.Distance {
    var title: String {
        switch self {
        case .fourHundred: return String(localized: "400 m")
        case .oneK: return String(localized: "1K")
        case .mile: return String(localized: "Mile")
        case .fiveK: return String(localized: "5K")
        case .tenK: return String(localized: "10K")
        case .half: return String(localized: "Half")
        case .marathon: return String(localized: "Marathon")
        }
    }
}

// MARK: - Run screen

/// "Best efforts" on a run's own screen: the fastest stretch of each distance inside this
/// run, marked when it is the record or the second or third best ever. Draws nothing for
/// a run with no efforts (too short, or recorded before the distance series was stored).
///
/// A display card with no navigation of its own, and its own query and state, so adding
/// it to the run screen writes nothing of `RunSummaryView`'s (PR #338).
struct RunBestEffortsCard: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @State private var efforts: [BestEfforts.RunEfforts] = []

    init(workout: RunWorkout) {
        self.workout = workout
        let walkRaw = WorkoutType.walk.rawValue
        let crossTrainingRaw = WorkoutType.crossTraining.rawValue
        _workouts = Query(
            filter: #Predicate<RunWorkout> {
                $0.workoutTypeRaw != walkRaw && $0.workoutTypeRaw != crossTrainingRaw
            },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }

    var body: some View {
        let inputs = BestEffortsLoader.inputs(from: workouts)
        let mine = efforts.first { $0.id == workout.id }
        let rows = (mine?.efforts ?? [:]).keys.sorted()

        Group {
            if let mine, !rows.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("BEST EFFORTS IN THIS RUN")
                        .strideEyebrow()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppSpacing.xs)
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(rows, id: \.self) { distance in
                            row(distance, seconds: mine.efforts[distance] ?? 0)
                        }
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strideCard()
                }
            }
        }
        .task(id: BestEffortsLoader.fingerprint(inputs)) {
            efforts = await BestEffortsLoader.load(inputs)
        }
    }

    private func row(_ distance: BestEfforts.Distance, seconds: Double) -> some View {
        let rank = BestEfforts.rank(of: workout.id, distance, in: efforts)
        return HStack(alignment: .firstTextBaseline) {
            Text(distance.title)
                .font(.bodyStrong)
                .frame(width: 84, alignment: .leading)
            Text(seconds.durationString)
                .font(.bodyStrong.monospacedDigit())
            Text((seconds / distance.meters * 1_000).paceString(unit: appSettings.unitPreference))
                .font(.dsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.sm)
            switch rank ?? 0 {
            case 1: StrideTag("Record", tone: .brand)
            case 2: StrideTag("2nd best")
            case 3: StrideTag("3rd best")
            default: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
