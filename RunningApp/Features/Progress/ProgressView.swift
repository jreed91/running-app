import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

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

    // MARK: Heart rate trend chart

    private var heartRateTrendChart: some View {
        let withHR = filteredWorkouts.filter { $0.averageHeartRate != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text("AVERAGE HEART RATE").font(.sectionHeader).foregroundStyle(.secondary)
            if withHR.isEmpty {
                emptyDataPlaceholder("No heart rate data in this period")
            } else {
                Chart(withHR) { workout in
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
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel("bpm")
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
                Chart(withElev) { workout in
                    BarMark(
                        x: .value("Date", workout.date, unit: .day),
                        y: .value(elevationUnit, elevationDisplay(workout.elevationGainMeters ?? 0))
                    )
                    .foregroundStyle(Color.success)
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxisLabel(elevationUnit)
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
                Chart(vo2Points) { point in
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
                }
                .frame(height: 140)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
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
