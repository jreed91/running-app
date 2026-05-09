import SwiftUI

struct WeeklySummaryIntentView: View {
    let data: WeeklySummaryData

    private var unit: UnitPreference { AppSettings.syncedUnitPreference() }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.zoneEasy.opacity(0.15))
                    .frame(width: 52, height: 52)
                StrideIcon(name: .chart, size: 24, color: .zoneEasy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("This Week")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(data.totalMeters.distanceString(unit: unit))
                    .font(.title2.bold())
            }
            Spacer()
        }
        .padding()
    }
}
