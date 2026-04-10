import SwiftUI
import HealthKit

/// Minimal live-metrics view shown on the watch face during a run.
/// Full workout management is handled by `WatchWorkoutManager`.
struct ActiveRunWatchView: View {
    @StateObject private var manager = WatchWorkoutManager()

    var body: some View {
        VStack(spacing: 8) {
            metricRow(value: manager.distanceString, label: manager.distanceUnitLabel)
            metricRow(value: manager.elapsedTimeString, label: "TIME")
            metricRow(value: manager.currentPaceString, label: "PACE")

            HStack(spacing: 16) {
                Button(action: manager.togglePause) {
                    Image(systemName: manager.isRunning ? "pause" : "play")
                }
                .tint(.orange)

                Button(action: manager.endWorkout) {
                    Image(systemName: "stop")
                }
                .tint(.red)
            }
            .padding(.top, 4)
        }
        .onAppear { manager.startWorkout() }
    }

    private func metricRow(value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
