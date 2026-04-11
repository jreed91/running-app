import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

    @Query private var profiles: [UserProfile]
    private var profile: UserProfile? { profiles.first }

    @Environment(AppSettings.self) private var appSettings
    @State private var selectedRange: ChartRange = .threeMonths

    enum ChartRange: String, CaseIterable {
        case month = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case year = "1Y"

        var days: Int {
            switch self {
            case .month: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .year: return 365
            }
        }
    }

    private var filteredWorkouts: [RunWorkout] {
        let cutoff = Date().addingTimeInterval(-Double(selectedRange.days) * 86_400)
        return workouts.filter { $0.date >= cutoff }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    rangePicker
                    weeklyVolumeChart
                    paceProgressChart
                    racePacePredictionChart
                    racePaceSummaryCard
                    totalStatsSummary
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Progress")
        }
    }

    // MARK: Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(ChartRange.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Weekly volume chart

    private var weeklyVolumeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WEEKLY VOLUME").font(.sectionHeader).foregroundStyle(.secondary)
            Chart(weeklyBuckets, id: \.week) { bucket in
                BarMark(
                    x: .value("Week", bucket.week, unit: .weekOfYear),
                    y: .value(appSettings.unitPreference.distanceLabel, bucket.distanceValue)
                )
                .foregroundStyle(.brand)
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
        }
    }

    // MARK: Pace trend chart

    private var paceProgressChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AVERAGE PACE").font(.sectionHeader).foregroundStyle(.secondary)
            Chart(filteredWorkouts.filter { $0.averagePaceSecondsPerKm > 0 }) { workout in
                LineMark(
                    x: .value("Date", workout.date),
                    y: .value("sec/km", workout.averagePaceSecondsPerKm)
                )
                .foregroundStyle(.brand)
                PointMark(
                    x: .value("Date", workout.date),
                    y: .value("sec/km", workout.averagePaceSecondsPerKm)
                )
                .foregroundStyle(.brand)
            }
            .frame(height: 140)
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let secs = value.as(Double.self) {
                            Text(secs.paceString(unit: appSettings.unitPreference)
                                .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""))
                        }
                    }
                }
            }
            Text("Lower = faster")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Predicted race pace chart

    private var racePacePredictionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREDICTED RACE PACE").font(.sectionHeader).foregroundStyle(.secondary)
            if pacePredictionPoints.isEmpty {
                Text("Log at least 2 runs of 1.5 km+ to see a prediction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Chart(pacePredictionPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Predicted Pace", point.predictedPaceSecondsPerKm)
                    )
                    .foregroundStyle(.brand)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Predicted Pace", point.predictedPaceSecondsPerKm)
                    )
                    .foregroundStyle(.brand)
                }
                .frame(height: 140)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let secs = value.as(Double.self) {
                                Text(secs.paceString(unit: appSettings.unitPreference)
                                    .replacingOccurrences(of: " \(appSettings.unitPreference.paceLabel)", with: ""))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                Text("Lower = faster")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Race fitness summary card

    private var racePaceSummaryCard: some View {
        let trend = paceTrend
        let raceName = profile?.goalRace.displayName ?? "Race"
        return VStack(alignment: .leading, spacing: 12) {
            Text("RACE FITNESS SUMMARY").font(.sectionHeader).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Predicted \(raceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currentPredictedFinishTime)
                        .font(.metricSmall)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Fitness Trend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(trend.label)
                        .font(.bodyStrong)
                        .foregroundStyle(trend.color)
                }
            }
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Summary stats

    private var totalStatsSummary: some View {
        let runs = filteredWorkouts
        let totalMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        let avgPace = runs.isEmpty ? 0
            : runs.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(runs.count)

        return LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 16) {
            summaryCell(value: "\(runs.count)", label: "Runs")
            summaryCell(value: totalMeters.distanceString(unit: appSettings.unitPreference), label: "Distance")
            summaryCell(
                value: avgPace > 0 ? avgPace.paceString(unit: appSettings.unitPreference) : "--",
                label: "Avg Pace"
            )
        }
    }

    private func summaryCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.metricSmall)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Data helpers

    private struct PacePredictionPoint: Identifiable {
        let id = UUID()
        let date: Date
        let predictedPaceSecondsPerKm: Double
    }

    private var pacePredictionPoints: [PacePredictionPoint] {
        guard let raceDistance = profile?.goalRace.distanceMeters else { return [] }
        return filteredWorkouts.compactMap { workout in
            guard let pace = PaceCalculatorService.predictedRacePaceSecondsPerKm(
                workoutDistanceMeters: workout.distanceMeters,
                workoutDurationSeconds: workout.durationSeconds,
                raceDistanceMeters: raceDistance
            ) else { return nil }
            return PacePredictionPoint(date: workout.date, predictedPaceSecondsPerKm: pace)
        }
        .sorted { $0.date < $1.date }
    }

    private var paceTrend: (label: String, color: Color) {
        guard pacePredictionPoints.count >= 3 else {
            return ("Not enough data", .secondary)
        }
        let rawPoints = pacePredictionPoints.map {
            (x: $0.date.timeIntervalSinceReferenceDate, y: $0.predictedPaceSecondsPerKm)
        }
        guard let slopePerSecond = PaceCalculatorService.linearRegressionSlope(rawPoints) else {
            return ("Stable", .secondary)
        }
        let slopePerWeek = slopePerSecond * 7 * 86_400
        switch slopePerWeek {
        case ..<(-1.0): return ("Improving", Color.green)
        case 1.0...:    return ("Declining", Color.red)
        default:        return ("Stable", Color.orange)
        }
    }

    private var currentPredictedFinishTime: String {
        guard let raceDistance = profile?.goalRace.distanceMeters,
              let mostRecent = filteredWorkouts.last(where: { $0.distanceMeters >= 1_500 }),
              let pace = PaceCalculatorService.predictedRacePaceSecondsPerKm(
                  workoutDistanceMeters: mostRecent.distanceMeters,
                  workoutDurationSeconds: mostRecent.durationSeconds,
                  raceDistanceMeters: raceDistance
              )
        else { return "--:--" }
        return (pace * (raceDistance / 1_000)).durationString
    }

    private struct WeekBucket: Identifiable {
        let id = UUID()
        let week: Date
        let distanceValue: Double
    }

    private var weeklyBuckets: [WeekBucket] {
        var byWeek: [Date: Double] = [:]
        for workout in filteredWorkouts {
            let key = workout.date.startOfWeek
            byWeek[key, default: 0] += workout.distanceMeters
        }
        return byWeek.map { key, meters -> WeekBucket in
            let value: Double
            switch appSettings.unitPreference {
            case .metric: value = meters / 1_000
            case .imperial: value = meters / 1_609.344
            }
            return WeekBucket(week: key, distanceValue: value)
        }
        .sorted { $0.week < $1.week }
    }
}
