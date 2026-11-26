import SwiftUI

// MARK: - WatchRunView

/// The run in progress, then its summary (Watch runs, PR 2). Shown in place of the home
/// pages whenever ``WatchRunRecorder`` is not idle.
///
/// Two pages, like Apple's Workout app: controls on the left, the numbers on the right,
/// and the numbers are where it opens.
struct WatchRunView: View {
    @Environment(WatchRunRecorder.self) private var recorder
    @State private var page = 1

    var body: some View {
        switch recorder.state {
        case .idle:
            EmptyView()
        case .starting:
            ProgressView("Starting…")
        case .running, .paused:
            TabView(selection: $page) {
                WatchRunControls()
                    .tag(0)
                WatchRunMetricsPage()
                    .tag(1)
            }
            .tabViewStyle(.page)
        case .saving:
            ProgressView("Saving…")
        case .finished(let final):
            WatchRunSummary(metrics: final)
        case .failed(let message):
            WatchRunFailure(message: message)
        }
    }
}

// MARK: - Metrics

private struct WatchRunMetricsPage: View {
    @Environment(WatchRunRecorder.self) private var recorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let metrics = recorder.metrics
            let metric = recorder.usesMetricUnits
            VStack(alignment: .leading, spacing: 2) {
                if recorder.state == .paused {
                    Text("Paused")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.strideBrand)
                }
                Text(verbatim: WatchRunMetrics.elapsedText(metrics.elapsedSeconds))
                    .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.strideBrand)
                metricRow(
                    WatchRunMetrics.distanceText(metrics.distanceMeters, metric: metric),
                    unit: WatchRunMetrics.distanceUnit(metric: metric)
                )
                metricRow(
                    WatchRunMetrics.paceText(secondsPerKm: metrics.currentPaceSecondsPerKm, metric: metric),
                    unit: WatchRunMetrics.paceUnit(metric: metric)
                )
                heartRateRow(metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: timeline.date) { _, date in recorder.refresh(at: date) }
        }
        .accessibilityElement(children: .combine)
    }

    private func metricRow(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            Text(verbatim: unit)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func heartRateRow(_ metrics: WatchRunMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            if let bpm = metrics.heartRateBPM {
                Text(verbatim: "\(Int(bpm.rounded()))")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            } else {
                Text(verbatim: "--")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            if let zone = metrics.zone(maxHeartRateBPM: recorder.runSession?.maxHeartRateBPM) {
                Text(verbatim: zone.shortName)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Controls

private struct WatchRunControls: View {
    @Environment(WatchRunRecorder.self) private var recorder

    var body: some View {
        VStack(spacing: 8) {
            if recorder.state == .paused {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(Color.strideBrand)
            } else {
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            Button(role: .destructive) {
                Task { await recorder.end() }
            } label: {
                Label("End", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Summary

private struct WatchRunSummary: View {
    @Environment(WatchRunRecorder.self) private var recorder
    let metrics: WatchRunMetrics

    var body: some View {
        let metric = recorder.usesMetricUnits
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run saved")
                    .font(.headline)
                let distance = WatchRunMetrics.distanceText(metrics.distanceMeters, metric: metric)
                Text(verbatim: "\(distance) \(WatchRunMetrics.distanceUnit(metric: metric))")
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.strideBrand)
                Text(verbatim: WatchRunMetrics.elapsedText(metrics.elapsedSeconds))
                    .font(.headline.monospacedDigit())
                let pace = WatchRunMetrics.paceText(secondsPerKm: metrics.averagePaceSecondsPerKm, metric: metric)
                Text("\(pace)\(WatchRunMetrics.paceUnit(metric: metric)) avg")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("It's in Apple Health. Open Stride on your iPhone to see it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button("Done") { recorder.dismiss() }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Failure

private struct WatchRunFailure: View {
    @Environment(WatchRunRecorder.self) private var recorder
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.strideBrand)
            Text(verbatim: message)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("OK") { recorder.dismiss() }
        }
        .padding()
    }
}
