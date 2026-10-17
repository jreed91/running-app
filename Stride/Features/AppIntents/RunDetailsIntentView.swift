import SwiftUI

struct RunDetailsIntentView: View {
    let run: RunWorkoutEntity

    private var unit: UnitPreference { AppSettings.syncedUnitPreference() }

    /// The entity carries only the type's localized name (built from
    /// `WorkoutType.localizedName`), so the type is matched back from it to colour the
    /// snippet by the run's own zone, as `TodaysRunIntentView` does.
    private var workoutType: WorkoutType? {
        WorkoutType.allCases.first { $0.localizedName == run.workoutTypeName }
    }
    private var tint: Color { workoutType?.color ?? .brand }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: workoutType?.icon ?? "figure.run")
                    .font(.dsTitle2)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(run.workoutTypeName)
                    .font(.dsHeadline)
                Text(run.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                Text("\(run.distanceMeters.distanceString(unit: unit)) · \(run.averagePaceSecondsPerKm.paceString(unit: unit)) · \(run.durationSeconds.durationString)")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}
