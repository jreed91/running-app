import SwiftUI

struct WeeklySummaryIntentView: View {
    let data: WeeklySummaryData

    private var unit: UnitPreference { AppSettings.syncedUnitPreference() }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.brand.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "chart.bar.fill")
                    .font(.dsTitle2)
                    .foregroundStyle(Color.brandText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("This Week")
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                Text(data.totalMeters.distanceString(unit: unit))
                    .font(.dsTitle2.monospacedDigit())
            }
            Spacer()
        }
        .padding()
    }
}
