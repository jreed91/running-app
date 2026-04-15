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

    // Chart selection state
    @State private var selectedVolumeDate: Date? = nil
    @State private var selectedPaceDate: Date? = nil
    @State private var selectedPredictionDate: Date? = nil
    @State private var selectedHRDate: Date? = nil
    @State private var selectedElevationDate: Date? = nil
    @State private var selectedVO2Date: Date? = nil

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

    private struct VO2Point: Identifiable {
        let id = UUID()
        let date: Date
        let vdot: Double
    }

    private var filteredWorkouts: [RunWorkout] {
        let cutoff = Date().addingTimeInterval(-Double(selectedRange.days) * 86_400)
        return workouts.filter { $0.date >= cutoff }
    }

    private var vo2Points: [VO2Point] {
        filteredWorkouts.compactMap { w in
            guard w.distanceMeters >= 400, w.durationSeconds > 0 else { return nil }
            let v = PaceCalculatorService.vdot(distanceMeters: w.distanceMeters, timeSeconds: w.durationSeconds)
            return v > 0 ? VO2Point(date: w.date, vdot: v) : nil
        }
    }

    private var elevationUnit: String {
        appSettings.unitPreference == .metric ? "m" : "ft"
    }

    private func elevationDisplay(_ meters: Double) -> Double {
        appSettings.unitPreference == .metric ? meters : meters * 3.28084
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
                    heartRateTrendChart
                    elevationTrendChart
                    vo2MaxTrendChart
                    totalStatsSummary
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Progress")
        }
        .onChange(of: selectedRange) {
            selectedVolumeDate = nil
            selectedPaceDate = nil
            selectedPredictionDate = nil
            selectedHRDate = nil
            selectedElevationDate = nil
            selectedVO2Date = nil
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
            Chart {
                ForEach(weeklyBuckets, id: \.week) { bucket in
                    BarMark(
                        x: .value("Week", bucket.week, unit: .weekOfYear),
                        y: .value(appSettings.unitPreference.distanceLabel, bucket.distanceValue)
                    )
                    .foregroundStyle(.brand)
                }
                if let selected = selectedVolumeDate, let bucket = closestWeekBucket(to: selected) {
                    RuleMark(x: .value("Week", bucket.week))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bucket.week, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(String(format: "%.1f %@", bucket.distanceValue, appSettings.unitPreference.distanceLabel))
                                    .font(.caption).bold()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        }
                }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartXSelection(value: $selectedVolumeDate)
        }
    }

    // MARK: Pace trend chart

    private var paceProgressChart: some View {
        let paceWorkouts = filteredWorkouts.filter { $0.averagePaceSecondsPerKm > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("AVERAGE PACE").font(.sectionHeader).foregroundStyle(.secondary)
            Chart {
                ForEach(paceWorkouts) { workout in
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
                    .symbolSize(
                        selectedPaceDate.flatMap { closestWorkout(to: $0, in: paceWorkouts) }?.id == workout.id ? 80 : 36
                    )
                }
                if let selected = selectedPaceDate,
                   let workout = closestWorkout(to: selected, in: paceWorkouts) {
                    RuleMark(x: .value("Date", workout.date))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(workout.averagePaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                    .font(.caption).bold()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        }
                }
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
            .chartXSelection(value: $selectedPaceDate)
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
                Chart {
                    ForEach(pacePredictionPoints) { point in
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
                        .symbolSize(
                            selectedPredictionDate.flatMap { closestPredictionPoint(to: $0) }?.id == point.id ? 80 : 36
                        )
                    }
                    if let selected = selectedPredictionDate,
                       let point = closestPredictionPoint(to: selected) {
                        RuleMark(x: .value("Date", point.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .annotation(
                                position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(point.predictedPaceSecondsPerKm.paceString(unit: appSettings.unitPreference))
                                        .font(.caption).bold()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            }
                    }
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
                .chartXSelection(value: $selectedPredictionDate)
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

    // MARK: Heart rate trend chart

    private var heartRateTrendChart: some View {
        let withHR = filteredWorkouts.filter { $0.averageHeartRate != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("AVERAGE HEART RATE").font(.sectionHeader).foregroundStyle(.secondary)
            if withHR.isEmpty {
                emptyDataPlaceholder("No heart rate data in this period")
            } else {
                Chart {
                    ForEach(withHR) { workout in
                        LineMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        .foregroundStyle(.zoneInterval)
                        PointMark(
                            x: .value("Date", workout.date),
                            y: .value("bpm", workout.averageHeartRate ?? 0)
                        )
                        .foregroundStyle(.zoneInterval)
                        .symbolSize(
                            selectedHRDate.flatMap { closestWorkout(to: $0, in: withHR) }?.id == workout.id ? 80 : 36
                        )
                    }
                    if let selected = selectedHRDate,
                       let workout = closestWorkout(to: selected, in: withHR),
                       let hr = workout.averageHeartRate {
                        RuleMark(x: .value("Date", workout.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .annotation(
                                position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text("\(Int(hr)) bpm")
                                        .font(.caption).bold()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel("bpm")
                .chartXSelection(value: $selectedHRDate)
            }
        }
    }

    // MARK: Elevation trend chart

    private var elevationTrendChart: some View {
        let withElev = filteredWorkouts.filter { ($0.elevationGainMeters ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("ELEVATION GAIN").font(.sectionHeader).foregroundStyle(.secondary)
            if withElev.isEmpty {
                emptyDataPlaceholder("No elevation data in this period")
            } else {
                Chart {
                    ForEach(withElev) { workout in
                        BarMark(
                            x: .value("Date", workout.date, unit: .day),
                            y: .value(elevationUnit, elevationDisplay(workout.elevationGainMeters ?? 0))
                        )
                        .foregroundStyle(Color.success)
                    }
                    if let selected = selectedElevationDate,
                       let workout = closestWorkout(to: selected, in: withElev),
                       let gain = workout.elevationGainMeters {
                        RuleMark(x: .value("Date", workout.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .annotation(
                                position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workout.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(String(format: "+%.0f %@", elevationDisplay(gain), elevationUnit))
                                        .font(.caption).bold()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel(elevationUnit)
                .chartXSelection(value: $selectedElevationDate)
            }
        }
    }

    // MARK: VO₂ max trend chart

    private var vo2MaxTrendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ESTIMATED VO₂ MAX").font(.sectionHeader).foregroundStyle(.secondary)
            if vo2Points.isEmpty {
                emptyDataPlaceholder("Not enough run data in this period")
            } else {
                Chart {
                    ForEach(vo2Points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        .foregroundStyle(.brandSecondary)
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("VDOT", point.vdot)
                        )
                        .foregroundStyle(.brandSecondary)
                        .symbolSize(
                            selectedVO2Date.flatMap { closestVO2Point(to: $0) }?.id == point.id ? 80 : 36
                        )
                    }
                    if let selected = selectedVO2Date,
                       let point = closestVO2Point(to: selected) {
                        RuleMark(x: .value("Date", point.date))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            .annotation(
                                position: .top,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(String(format: "%.1f VDOT", point.vdot))
                                        .font(.caption).bold()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.surfacePrimary, in: RoundedRectangle(cornerRadius: 8))
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            }
                    }
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartXSelection(value: $selectedVO2Date)
                Text("Higher = better fitness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Summary stats

    private var totalStatsSummary: some View {
        let runs = filteredWorkouts
        let totalMeters = runs.reduce(0) { $0 + $1.distanceMeters }
        let avgPace = runs.isEmpty ? 0
            : runs.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(runs.count)

        let hrValues = runs.compactMap(\.averageHeartRate)
        let avgHR: Double? = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)

        let elevValues = runs.compactMap(\.elevationGainMeters).filter { $0 > 0 }
        let avgElev: Double? = elevValues.isEmpty ? nil : elevValues.reduce(0, +) / Double(elevValues.count)

        let avgVO2: Double? = vo2Points.isEmpty ? nil
            : vo2Points.reduce(0) { $0 + $1.vdot } / Double(vo2Points.count)

        return LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
            summaryCell(value: "\(runs.count)", label: "Runs")
            summaryCell(value: totalMeters.distanceString(unit: appSettings.unitPreference), label: "Total Distance")
            summaryCell(
                value: avgPace > 0 ? avgPace.paceString(unit: appSettings.unitPreference) : "--",
                label: "Avg Pace"
            )
            summaryCell(
                value: avgHR.map { "\(Int($0)) bpm" } ?? "--",
                label: "Avg Heart Rate"
            )
            summaryCell(
                value: avgElev.map {
                    appSettings.unitPreference == .metric
                        ? String(format: "%.0f m", $0)
                        : String(format: "%.0f ft", $0 * 3.28084)
                } ?? "--",
                label: "Avg Elevation"
            )
            summaryCell(
                value: avgVO2.map { String(format: "%.1f", $0) } ?? "--",
                label: "Avg VO₂ Max"
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

    private func emptyDataPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.bodyRegular)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 60)
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

    // MARK: Selection helpers

    private func closestWorkout(to date: Date, in list: [RunWorkout]) -> RunWorkout? {
        list.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private func closestWeekBucket(to date: Date) -> WeekBucket? {
        weeklyBuckets.min(by: { abs($0.week.timeIntervalSince(date)) < abs($1.week.timeIntervalSince(date)) })
    }

    private func closestPredictionPoint(to date: Date) -> PacePredictionPoint? {
        pacePredictionPoints.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    private func closestVO2Point(to date: Date) -> VO2Point? {
        vo2Points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    // MARK: Weekly buckets

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
