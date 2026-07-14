import SwiftUI

struct RunDetailsIntentView: View {
    let run: RunWorkoutEntity

    private var unit: UnitPreference { AppSettings.syncedUnitPreference() }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.zoneEasy.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: "figure.run")
                    .font(.title2)
                    .foregroundStyle(Color.zoneEasy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(run.workoutTypeName)
                    .font(.headline)
                Text(run.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(run.distanceMeters.distanceString(unit: unit)) · \(run.averagePaceSecondsPerKm.paceString(unit: unit)) · \(run.durationSeconds.durationString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}
