import SwiftUI

struct TodaysRunIntentView: View {
    let data: TodaysRunData?

    var body: some View {
        if let data {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(data.workoutType.color.opacity(0.15))
                        .frame(width: 52, height: 52)
                    StrideIcon(name: data.workoutType.strideIcon, size: 24, color: data.workoutType.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.workoutType.displayName)
                        .font(.headline)
                    if let meters = data.distanceMeters {
                        Text(meters.distanceString(unit: AppSettings.syncedUnitPreference()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let notes = data.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding()
        } else {
            HStack(spacing: 12) {
                StrideIcon(name: .moon, size: 24, color: .secondary)
                Text("Rest day — no run scheduled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}
