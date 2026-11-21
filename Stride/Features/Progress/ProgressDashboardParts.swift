import SwiftUI

// MARK: - Volume units

/// Writes a `VolumeExplorer` amount for the Progress page: the hero's totals, the main
/// chart's axis and its spoken values. Base units in (metres, seconds, runs, metres
/// climbed), the runner's units out.
struct VolumeUnits {
    let metric: VolumeExplorer.Metric
    let unit: UnitPreference

    /// What the chart plots: distance in km or mi, time in hours, climb in metres or
    /// feet, runs as a count.
    func plotted(_ base: Double) -> Double {
        switch metric {
        case .distance: return base.distanceValue(unit: unit)
        case .time: return base / 3_600
        case .runs: return base
        case .climb: return base.elevationValue(unit: unit)
        }
    }

    /// A total, written out: "55.9 mi", "9h 12m", "23 runs", "1,240 ft".
    func text(_ base: Double) -> String {
        switch metric {
        case .distance:
            return base.distanceString(unit: unit)
        case .time:
            let minutes = Int((base / 60).rounded())
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        case .runs:
            let count = base.rounded()
            if count == base { return count == 1 ? String(localized: "1 run") : String(localized: "\(Int(count)) runs") }
            return String(format: "%.1f runs", base)
        case .climb:
            return base.elevationString(unit: unit)
        }
    }

    /// The hero tile's figure: the total without "runs" after it, which the tile's
    /// label already says.
    func figure(_ base: Double) -> String {
        metric == .runs ? "\(Int(base.rounded()))" : text(base)
    }

    /// An axis value, already in plotted units, with its unit.
    func axis(_ plotted: Double) -> String {
        switch metric {
        case .distance: return String(format: "%.0f %@", plotted, unit.distanceLabel)
        case .time: return String(format: "%.0f h", plotted)
        case .runs: return String(format: "%.0f", plotted)
        case .climb: return String(format: "%.0f %@", plotted, unit.elevationLabel)
        }
    }
}

// MARK: - Run row

/// One run in the Progress page's run list: what kind, when, how far and how fast.
struct ProgressRunRow: View {
    let workout: RunWorkout
    let unit: UnitPreference

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            // The icon tile of a row: a 32pt circle tinted at 12%, the glyph in the tint.
            StrideIcon(name: workout.workoutType.strideIcon, size: 16, color: workout.workoutType.color)
                .frame(width: 32, height: 32)
                .background(workout.workoutType.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.workoutType.localizedName)
                    .font(.bodyStrong)
                    .foregroundStyle(.primary)
                Text(workout.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(workout.distanceMeters.distanceString(unit: unit))
                    .font(.bodyStrong.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(workout.averagePaceSecondsPerKm.paceString(unit: unit))
                    .font(.dsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            StrideIcon(name: .chevronRight, size: 12, color: .secondary, strokeWeight: 2)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the run")
    }
}

// MARK: - Labels

extension VolumeExplorer.Metric {
    var title: String {
        switch self {
        case .distance: return String(localized: "Distance")
        case .time: return String(localized: "Time")
        case .runs: return String(localized: "Runs")
        case .climb: return String(localized: "Climb")
        }
    }
}

extension VolumeExplorer.Grouping {
    var noun: String {
        switch self {
        case .week: return String(localized: "week")
        case .month: return String(localized: "month")
        }
    }
}

extension VolumeExplorer.Window {
    /// "3 months", for "the 3 months before".
    var spokenLength: String {
        switch self {
        case .month: return String(localized: "month")
        case .threeMonths: return String(localized: "3 months")
        case .sixMonths: return String(localized: "6 months")
        case .year: return String(localized: "year")
        case .all: return String(localized: "all time")
        }
    }
}

extension ProgressFilter.Period {
    /// The hero's eyebrow: "Last 3 months".
    var title: String {
        switch self {
        case .month: return String(localized: "Last month")
        case .threeMonths: return String(localized: "Last 3 months")
        case .sixMonths: return String(localized: "Last 6 months")
        case .year: return String(localized: "Last year")
        case .all: return String(localized: "All time")
        }
    }
}

extension ProgressFilter.RunType {
    var title: String {
        switch self {
        case .all: return String(localized: "All runs")
        case .easyAndLong: return String(localized: "Easy & long")
        case .workouts: return String(localized: "Workouts")
        case .races: return String(localized: "Races")
        }
    }
}

extension WorkoutType {
    /// Where the Progress filter's run types put this session.
    var progressRunKind: ProgressFilter.RunKind {
        switch self {
        case .easy: return .easy
        case .longRun: return .long
        case .tempo, .interval: return .workout
        case .race: return .race
        case .rest, .strength, .crossTraining, .walk: return .other
        }
    }
}
