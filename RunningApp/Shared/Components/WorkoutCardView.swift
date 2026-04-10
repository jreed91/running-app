import SwiftUI

/// Compact card showing a scheduled workout — used on the Dashboard.
struct WorkoutCardView: View {
    let workout: ScheduledWorkout
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        HStack(spacing: 16) {
            typeIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(workout.workoutType.displayName).font(.bodyStrong)
                if let dist = workout.targetDistanceMeters {
                    Text(dist.distanceString(unit: appSettings.unitPreference)).font(.caption).foregroundStyle(.secondary)
                }
                if let range = workout.targetPaceRange {
                    Text("\(range.lowerBound.paceString(unit: appSettings.unitPreference)) – \(range.upperBound.paceString(unit: appSettings.unitPreference))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = workout.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var typeIcon: some View {
        ZStack {
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 44, height: 44)
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        switch workout.workoutType {
        case .easy:         return "figure.run"
        case .tempo:        return "gauge.with.needle"
        case .interval:     return "repeat"
        case .longRun:      return "arrow.right.to.line"
        case .race:         return "trophy"
        case .rest:         return "moon.zzz"
        case .crossTraining: return "bicycle"
        }
    }

    private var iconColor: Color {
        switch workout.workoutType {
        case .easy, .longRun: return .zoneEasy
        case .tempo:          return .zoneTempo
        case .interval, .race: return .zoneInterval
        default:              return .secondary
        }
    }
}
