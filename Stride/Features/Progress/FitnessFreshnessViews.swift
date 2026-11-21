import SwiftUI
import SwiftData
import Charts

// MARK: - Shared inputs

/// Turns runs into `TrainingLoad` sessions and works out the daily series, for both the
/// Progress card and the full page.
enum FitnessFreshnessData {

    /// The heart-rate reserve fraction a session of this type usually averages, for runs
    /// with neither heart rate nor a feel rating.
    static func typeIntensity(_ type: WorkoutType) -> Double {
        switch type {
        case .easy: return 0.60
        case .longRun: return 0.65
        case .tempo: return 0.80
        case .interval: return 0.82
        case .race: return 0.90
        case .crossTraining: return 0.60
        default: return 0.55
        }
    }

    @MainActor
    static func sessions(from workouts: [RunWorkout]) -> [TrainingLoad.Session] {
        workouts.compactMap { run in
            guard run.durationSeconds > 0 else { return nil }
            return TrainingLoad.Session(
                id: run.id,
                date: run.date,
                durationSeconds: run.durationSeconds,
                averageHeartRate: run.averageHeartRate,
                fallbackIntensity: TrainingLoad.fallbackIntensity(
                    feel: run.feel?.rawValue,
                    typeIntensity: typeIntensity(run.workoutType)
                )
            )
        }
    }

    @MainActor
    static func days(from workouts: [RunWorkout], profile: UserProfile?, now: Date = .now) -> [TrainingLoad.Day] {
        TrainingLoad.days(
            for: sessions(from: workouts),
            maxHeartRate: profile?.effectiveMaxHeartRate.map { Double($0) },
            through: now,
            calendar: .current
        )
    }

    /// Everything but walks: a ride or a swim is load too.
    static func query() -> Query<RunWorkout, [RunWorkout]> {
        let walkRaw = WorkoutType.walk.rawValue
        return Query(
            filter: #Predicate<RunWorkout> { $0.workoutTypeRaw != walkRaw },
            sort: [SortDescriptor(\RunWorkout.date)]
        )
    }
}

extension TrainingLoad.FormZone {
    var title: String {
        switch self {
        case .fresh: return String(localized: "Fresh")
        case .neutral: return String(localized: "Balanced")
        case .building: return String(localized: "Building")
        case .overreaching: return String(localized: "Very tired")
        }
    }

    var advice: String {
        switch self {
        case .fresh: return String(localized: "Rested and ready. Good for a race; fitness slips if it lasts weeks.")
        case .neutral: return String(localized: "Training and recovery are in balance.")
        case .building: return String(localized: "The productive range: tired enough to be getting fitter.")
        case .overreaching: return String(localized: "Fatigue is well above fitness. An easy few days would help.")
        }
    }

    var tint: Color {
        switch self {
        case .fresh: return .zoneEasy
        case .neutral: return .secondary
        case .building: return .brand
        case .overreaching: return .warning
        }
    }
}

// MARK: - Progress card

/// "Fitness & freshness" on Progress: today's fitness, fatigue and form, the last three
/// months as two lines, and a link to the full page.
struct FitnessFreshnessCard: View {
    @Query private var workouts: [RunWorkout]
    @Query private var profiles: [UserProfile]

    init() {
        _workouts = FitnessFreshnessData.query()
    }

    var body: some View {
        let days = FitnessFreshnessData.days(from: workouts, profile: profiles.first)
        let recent = days.suffix(90)
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("FITNESS & FRESHNESS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                if !days.isEmpty {
                    NavigationLink {
                        FitnessFreshnessView()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Explore")
                            StrideIcon(name: .chevronRight, size: 10, color: .brandText, strokeWeight: 2.2)
                        }
                        .font(.captionStrong)
                        .foregroundStyle(Color.brandText)
                    }
                    .accessibilityLabel("Explore fitness and freshness")
                }
            }
            .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if let today = days.last {
                    FitnessFreshnessReadout(day: today, isToday: true)
                    Chart {
                        ForEach(Array(recent)) { day in
                            LineMark(x: .value("Date", day.date), y: .value("Fitness", day.fitness),
                                     series: .value("Series", "Fitness"))
                                .foregroundStyle(.route)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            LineMark(x: .value("Date", day.date), y: .value("Fatigue", day.fatigue),
                                     series: .value("Series", "Fatigue"))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                        }
                    }
                    .frame(height: 110)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) {
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .chartYAxis(.hidden)
                    .accessibilityHidden(true)
                } else {
                    Text("Log a few runs to see your fitness build.")
                        .font(.bodyRegular)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
        }
    }
}

/// Fitness, fatigue and form for one day, with what the form means.
struct FitnessFreshnessReadout: View {
    let day: TrainingLoad.Day
    let isToday: Bool

    var body: some View {
        let zone = TrainingLoad.zone(forForm: day.form)
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: 0) {
                cell(value: day.fitness, label: "Fitness")
                cell(value: day.fatigue, label: "Fatigue")
                cell(value: day.form, label: "Form", signed: true)
            }
            HStack(spacing: AppSpacing.sm) {
                Circle().fill(zone.tint).frame(width: 8, height: 8)
                Text(isToday ? "\(zone.title) today" : zone.title)
                    .font(.captionStrong)
                Text(zone.advice)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cell(value: Double, label: String, signed: Bool = false) -> some View {
        let rounded = Int(value.rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text(signed && rounded > 0 ? "+\(rounded)" : "\(rounded)")
                .font(.metricS)
                .strideNumericTransition()
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Full page

/// Fitness and fatigue as lines, form as bars under them on the same timeline, one
/// scrub moving both, and the day under the finger read out with its runs.
struct FitnessFreshnessView: View {
    @Environment(AppSettings.self) private var appSettings
    @Query private var workouts: [RunWorkout]
    @Query private var profiles: [UserProfile]

    @State private var window: VolumeExplorer.Window = .sixMonths
    @State private var pinnedDay: Date?
    @State private var rawSelection: Date?

    init() {
        _workouts = FitnessFreshnessData.query()
    }

    var body: some View {
        let all = FitnessFreshnessData.days(from: workouts, profile: profiles.first)
        let start = VolumeExplorer.windowStart(
            window, now: .now, earliestRun: all.first?.date, calendar: .current
        )
        let days = all.filter { $0.date >= Calendar.current.startOfDay(for: start) }
        let selected = pinnedDay.flatMap { pinned in days.first { $0.date == pinned } } ?? days.last

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                windowPicker
                if let selected {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(selected.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                            .strideEyebrow()
                            .foregroundStyle(.secondary)
                        FitnessFreshnessReadout(day: selected, isToday: Calendar.current.isDateInToday(selected.date))
                    }
                    .padding(AppSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .heroCard()

                    charts(days, selected: selected)
                    runsOn(selected)
                }
                explanation
            }
            .padding()
            .strideReadableWidth()
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Fitness & freshness")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: window) { pinnedDay = nil }
        .onChange(of: rawSelection) {
            guard let rawSelection else { return }
            let day = Calendar.current.startOfDay(for: rawSelection)
            guard days.contains(where: { $0.date == day }), pinnedDay != day else { return }
            pinnedDay = day
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var windowPicker: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(VolumeExplorer.Window.allCases, id: \.self) { option in
                Button {
                    withAnimation(AppAnimation.bouncy) { window = option }
                } label: {
                    Text(option.rawValue).monospacedDigit()
                }
                .buttonStyle(.strideChip(selected: window == option))
                .accessibilityAddTraits(window == option ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Charts

    /// Two charts on one timeline: the lines read as levels, the bars as a signed
    /// difference, and drawing them together on one axis would squash the bars. Both
    /// take the same selection, so one finger moves the rule across both.
    private func charts(_ days: [TrainingLoad.Day], selected: TrainingLoad.Day) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.lg) {
                legend(color: .brand, dashed: false, "Fitness")
                legend(color: .secondary, dashed: true, "Fatigue")
            }
            Chart {
                ForEach(days) { day in
                    LineMark(x: .value("Date", day.date), y: .value("Load", day.fitness),
                             series: .value("Series", "Fitness"))
                        .foregroundStyle(.route)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    LineMark(x: .value("Date", day.date), y: .value("Load", day.fatigue),
                             series: .value("Series", "Fatigue"))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                }
                RuleMark(x: .value("Date", selected.date))
                    .foregroundStyle(Color.brand.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            .frame(height: 200)
            .chartXAxis(.hidden)
            .chartXSelection(value: $rawSelection)
            .chartAccessibility("Fitness and fatigue", series(days, \.fitness, label: "Fitness"))

            Text("FORM")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            Chart {
                ForEach(days) { day in
                    BarMark(x: .value("Date", day.date, unit: .day), y: .value("Form", day.form))
                        .foregroundStyle(TrainingLoad.zone(forForm: day.form).tint)
                        .opacity(day.date == selected.date ? 1 : 0.55)
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                RuleMark(x: .value("Date", selected.date))
                    .foregroundStyle(Color.brand.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            .frame(height: 110)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartXSelection(value: $rawSelection)
            .chartAccessibility("Form", series(days, \.form, label: "Form"))
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard()
    }

    private func legend(color: Color, dashed: Bool, _ title: String) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: dashed ? [3, 3] : []))
                .frame(width: 18, height: 1)
            Text(title)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
    }

    /// Spoken weekly, not daily: a daily series of a year is 365 points nobody wants read.
    private func series(
        _ days: [TrainingLoad.Day],
        _ value: KeyPath<TrainingLoad.Day, Double>,
        label: String
    ) -> ChartAccessibility.Series {
        let weekly = days.enumerated().filter { $0.offset % 7 == 0 || $0.offset == days.count - 1 }.map(\.element)
        return ChartAccessibility.Series(
            points: weekly.map {
                ChartAccessibility.Point(
                    label: $0.date.formatted(.dateTime.month(.abbreviated).day()),
                    value: $0[keyPath: value]
                )
            },
            valueAxisLabel: label
        ) { "\(Int($0.rounded()))" }
    }

    // MARK: Runs on the day

    @ViewBuilder
    private func runsOn(_ day: TrainingLoad.Day) -> some View {
        let listed = day.sessionIDs.compactMap { id in workouts.first { $0.id == id } }
        if !listed.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("THAT DAY · LOAD \(Int(day.load.rounded()))")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.xs)
                VStack(spacing: 0) {
                    ForEach(listed) { workout in
                        NavigationLink {
                            RunSummaryView(workout: workout)
                        } label: {
                            HStack {
                                Text(workout.workoutType.localizedName)
                                    .font(.bodyStrong)
                                Text(workout.durationSeconds.durationString)
                                    .font(.dsCaption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(workout.distanceMeters.distanceString(unit: appSettings.unitPreference))
                                    .font(.bodyStrong.monospacedDigit())
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

    private var explanation: some View {
        Text("""
            Every session gets a load from its time and heart rate, or from how it felt \
            when there's no heart rate. Fitness is your load averaged over six weeks; \
            fatigue over one. Form is fitness minus fatigue: negative while you build, \
            positive once you've rested. The numbers mean most compared with your own.
            """)
            .font(.dsFootnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.xs)
    }
}
