import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - RunLiveActivity

/// A run in progress, on the Lock Screen and in the Dynamic Island (U5b).
///
/// The elapsed clock is a `Text(timerInterval:)` in every presentation, which means the
/// system counts it and the app pushes nothing for it — a locked phone in a pocket is
/// exactly the case this exists for, and it is also the case where update budget matters
/// most. `pauseTime` freezes the same view when the run is holding, so pausing costs one
/// push rather than a stream of them.
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunActivityLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RunActivityMetric(label: "Distance") {
                        Text(context.state.distance)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunActivityMetric(label: context.state.isPaused ? "Paused" : "Time") {
                        RunActivityClock(state: context.state)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(context.attributes.workoutName.uppercased())
                            .font(.caption2.weight(.bold))
                            .kerning(1.2)
                            .foregroundStyle(.strideBrand)
                        Spacer(minLength: 0)
                        if let pace = context.state.pace {
                            Text(pace)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                RunActivityGlyph(isPaused: context.state.isPaused)
            } compactTrailing: {
                RunActivityClock(state: context.state)
                    .font(.caption2.monospacedDigit())
                    // A ticking clock changes width as it goes; without a bound the island
                    // resizes on every tick.
                    .frame(maxWidth: 54)
            } minimal: {
                RunActivityGlyph(isPaused: context.state.isPaused)
            }
        }
    }
}

// MARK: - Lock Screen

struct RunActivityLockScreenView: View {
    let attributes: RunActivityAttributes
    let state: RunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                RunActivityGlyph(isPaused: state.isPaused)
                Text(attributes.workoutName.uppercased())
                    .kerning(1.4)
                Spacer(minLength: 0)
                // Said in words, not carried by the paused glyph alone — the same rule the
                // in-app accessory follows (U3d).
                if state.isPaused {
                    Text("PAUSED")
                        .kerning(1.4)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.strideBrand)

            HStack(alignment: .top, spacing: 22) {
                RunActivityMetric(label: "Time") {
                    RunActivityClock(state: state)
                }
                RunActivityMetric(label: "Distance") {
                    Text(state.distance)
                }
                if let pace = state.pace {
                    RunActivityMetric(label: "Pace") {
                        Text(pace)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        // Tapping the card reopens the run HUD rather than dropping the runner wherever the
        // app happened to be — which, since U7, may be any tab with the run minimised.
        .widgetURL(RunActivityDeepLink.activeRun)
    }
}

// MARK: - Pieces

/// The elapsed clock, counted by the system rather than pushed by the app.
struct RunActivityClock: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        Text(
            timerInterval: state.elapsed,
            pauseTime: state.pausedAt,
            countsDown: false,
            showsHours: true
        )
    }
}

/// One labelled figure, laid out like the run HUD's metric cells.
struct RunActivityMetric<Value: View>: View {
    let label: LocalizedStringKey
    let value: Value

    init(label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            value
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
    }
}

struct RunActivityGlyph: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.fill" : "figure.run")
            .foregroundStyle(.strideBrand)
            // Spelled as `Text`, not as a bare ternary: a ternary of two string literals
            // infers `String` and picks the overload that does *not* localize.
            .accessibilityLabel(isPaused ? Text("Run paused") : Text("Run in progress"))
    }
}

// MARK: - Colour

private extension ShapeStyle where Self == Color {
    /// Stride's brand colour, resolved from this extension's own copy of the app's asset
    /// catalog — a widget bundle cannot read the app's. `project.yml` lists
    /// `Assets.xcassets` in both targets' sources for exactly this, so the Lock Screen and
    /// the app cannot drift to two different oranges.
    static var strideBrand: Color { Color("Brand") }
}
