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

    /// Status colours, always beside the zone's name. Not the training-zone colours
    /// (Route Loop rule 6: those mark intensity only), and not grey: "Balanced" is a
    /// good place to be, and a grey dot read as switched off.
    var tint: Color {
        switch self {
        case .fresh: return .success
        case .neutral: return .brandGlow
        case .building: return .brand
        case .overreaching: return .warning
        }
    }
}

// MARK: - Progress card

/// "Fitness & freshness" on Progress: fitness, fatigue and form as of today (or the end
/// of the drilled-in stretch), and the page's period as two lines.
///
/// Counts every session but walks, whatever run type the page filters to: a ride or a
/// tempo is load all the same, and fatigue from the sessions left out is still fatigue.
struct FitnessFreshnessCard: View {
    /// Days the page's period spans, or `nil` for all time.
    let periodDays: Int?
    /// The day the readout describes: the end of the drill-in, or `nil` for today.
    let asOf: Date?

    @Query private var workouts: [RunWorkout]
    @Query private var profiles: [UserProfile]

    init(periodDays: Int?, asOf: Date?) {
        self.periodDays = periodDays
        self.asOf = asOf
        _workouts = FitnessFreshnessData.query()
    }

    var body: some View {
        let days = FitnessFreshnessData.days(from: workouts, profile: profiles.first)
        let recent = periodDays.map { Array(days.suffix($0)) } ?? days
        let readout = asOf.flatMap { date in days.last { $0.date <= date } } ?? days.last
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("FITNESS & FRESHNESS")
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppSpacing.sm)
                Text("All training")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if let readout {
                    FitnessFreshnessReadout(day: readout, isToday: Calendar.current.isDateInToday(readout.date))
                    Chart {
                        ForEach(recent) { day in
                            LineMark(x: .value("Date", day.date), y: .value("Fitness", day.fitness),
                                     series: .value("Series", "Fitness"))
                                .foregroundStyle(.route)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            LineMark(x: .value("Date", day.date), y: .value("Fatigue", day.fatigue),
                                     series: .value("Series", "Fatigue"))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                        }
                        // The start pin's "you are here": the day the readout describes.
                        PointMark(x: .value("Date", readout.date), y: .value("Fitness", readout.fitness))
                            .foregroundStyle(Color.brand)
                            .symbolSize(60)
                    }
                    .frame(height: 110)
                    .chartXAxis {
                        // A handful of month labels, whatever the period's length.
                        AxisMarks(values: .automatic(desiredCount: 4)) {
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .chartYAxis(.hidden)
                    .accessibilityHidden(true)
                    // Without it the dashed grey line read as noise next to the route.
                    FitnessFreshnessLegend()
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

/// Which line is which: fitness is the route, fatigue the dashed grey line.
struct FitnessFreshnessLegend: View {
    var body: some View {
        HStack(spacing: AppSpacing.lg) {
            item(dashed: false, "Fitness")
            item(dashed: true, "Fatigue")
        }
        .accessibilityHidden(true)
    }

    private func item(dashed: Bool, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Group {
                if dashed {
                    Capsule()
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                } else {
                    Capsule().fill(.route)
                }
            }
            .frame(width: 18, height: 3)
            Text(title)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
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
                // Scales with the text size, like the hero's totals; the fixed `metric`
                // sizes are for the run screen.
                .font(.dsTitle2.monospacedDigit())
                .strideNumericTransition()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
