import SwiftUI
import Charts
import SwiftData

struct ProgressDashboardView: View {
    @Query(sort: [SortDescriptor(\RunWorkout.date)])
    private var workouts: [RunWorkout]

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
                    totalStatsSummary
                }
                .padding()
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
                    y: .value("km", bucket.distanceKm)
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
                            Text(secs.paceString.replacingOccurrences(of: " /km", with: ""))
                        }
                    }
                }
            }
            Text("Lower = faster")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Summary stats

    private var totalStatsSummary: some View {
        let runs = filteredWorkouts
        let totalKm = runs.reduce(0) { $0 + $1.distanceMeters } / 1_000
        let avgPace = runs.isEmpty ? 0
            : runs.reduce(0) { $0 + $1.averagePaceSecondsPerKm } / Double(runs.count)

        return LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 16) {
            summaryCell(value: "\(runs.count)", label: "Runs")
            summaryCell(value: String(format: "%.0f km", totalKm), label: "Distance")
            summaryCell(value: avgPace > 0 ? avgPace.paceString : "--", label: "Avg Pace")
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

    private struct WeekBucket: Identifiable {
        let id = UUID()
        let week: Date
        let distanceKm: Double
    }

    private var weeklyBuckets: [WeekBucket] {
        var byWeek: [Date: Double] = [:]
        for workout in filteredWorkouts {
            let key = workout.date.startOfWeek
            byWeek[key, default: 0] += workout.distanceMeters / 1_000
        }
        return byWeek.map { WeekBucket(week: $0.key, distanceKm: $0.value) }
            .sorted { $0.week < $1.week }
    }
}
