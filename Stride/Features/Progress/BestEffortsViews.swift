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

/// "Best efforts" on Progress: the fastest stretch at each distance among the runs the
/// page's filter shows, found inside any run, with the all-time records marked.
///
/// Its own view with its own all-time query, because the all-time record is what each
/// row is measured against even when the filter shows one week.
struct BestEffortsCard: View {
    /// The runs the page's filter and drill-in show.
    let scope: Set<UUID>

    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @State private var efforts: [BestEfforts.RunEfforts] = []
    @State private var hasLoaded = false

    init(scope: Set<UUID>) {
        self.scope = scope
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
        let allTime = BestEfforts.records(in: efforts)
        let records = BestEfforts.records(in: efforts.filter { scope.contains($0.id) })
        let rows = Self.shown.compactMap { distance in records[distance].map { (distance, $0) } }

        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("BEST EFFORTS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                Text("In this filter")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            Group {
                if rows.isEmpty {
                    Text(!hasLoaded
                         ? "Finding your fastest stretches…"
                         : efforts.isEmpty
                            ? "Run a kilometre or more and your fastest stretches show up here."
                            : "No runs in this filter long enough for a best effort.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    VStack(spacing: AppSpacing.sm) {
                        ForEach(rows, id: \.0) { row in
                            recordRow(row.0, row.1, isAllTime: allTime[row.0]?.runID == row.1.runID)
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

    private func recordRow(_ distance: BestEfforts.Distance, _ effort: BestEfforts.Effort, isAllTime: Bool) -> some View {
        let unit = appSettings.unitPreference
        return HStack(alignment: .firstTextBaseline) {
            Text(distance.title)
                .font(.bodyStrong)
                .frame(minWidth: 64, alignment: .leading)
            Text(effort.seconds.durationString)
                .font(.bodyStrong.monospacedDigit())
            Text((effort.seconds / distance.meters * 1_000).paceString(unit: unit))
                .font(.dsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.sm)
            if isAllTime {
                StrideTag("Record", tone: .brand)
            }
            Text(effort.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits)))
                .font(.dsCaption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
