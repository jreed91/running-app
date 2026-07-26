import SwiftUI
import WidgetKit

// MARK: - WeeklyGoalWidget

/// Distance run this week against the weekly goal (B1).
///
/// The retention half of the Achievements surface (B4), on the surface people actually
/// look at: a ring that is visibly short on a Friday is the thing that gets someone out
/// of the door on a Saturday.
struct WeeklyGoalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StrideWidgetKind.weeklyGoal, provider: StrideSnapshotProvider()) { entry in
            WeeklyGoalWidgetView(entry: entry)
                .widgetURL(StrideWidgetDeepLink.progress)
        }
        .configurationDisplayName(Text("Weekly Goal"))
        .description(Text("How far you've run this week against your goal."))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - View

struct WeeklyGoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrideWidgetEntry

    private var weekly: WidgetSnapshot.WeeklyGoal? {
        entry.source == .unavailable ? nil : entry.snapshot.weekly
    }

    private var tint: Color {
        (weekly?.isMet ?? false) ? .strideSuccess : .strideBrand
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                accessory
            default:
                small
            }
        }
        .strideWidgetBackground(family)
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let weekly {
                WidgetCardHeader(title: Text("This Week"), symbolName: "figure.run", tint: tint)
                HStack {
                    Spacer(minLength: 0)
                    WidgetProgressRing(fraction: weekly.fraction, tint: tint) {
                        VStack(spacing: 0) {
                            Text(verbatim: weekly.completedText)
                                .font(.callout.weight(.bold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(verbatim: weekly.goalText)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: .infinity)
                    Spacer(minLength: 0)
                }
                Text(verbatim: weekly.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(weekly.isMet ? tint : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                WidgetEmptyState(title: "This Week")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — circular

    /// The system gauge rather than ``WidgetProgressRing``: at accessory size the complication
    /// styles are what match the rest of the Lock Screen, and they are what the Smart Stack
    /// and the always-on display know how to dim.
    private var circular: some View {
        Gauge(value: weekly?.fraction ?? 0) {
            Image(systemName: "figure.run")
        } currentValueLabel: {
            Text(verbatim: weekly?.completedText ?? "—")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — rectangular

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("THIS WEEK")
                .font(.caption2.weight(.bold))
                .kerning(1.1)
                .widgetAccentable()
            if let weekly {
                Text(verbatim: "\(weekly.completedText) / \(weekly.goalText)")
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: weekly.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Open Stride to sync")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Copy

    /// Spoken as a sentence. A ring read as "46 percent" says nothing a runner wants;
    /// "18.4 km of 40 km, 3 runs" is the same glance in words.
    private var spokenLabel: Text {
        guard let weekly, weekly.hasGoal else {
            return Text("This week. Open Stride to sync.")
        }
        // `inflect:` rather than a hand-written plural — otherwise a single run is
        // spoken as "1 runs".
        let runs = String(
            localized: "^[\(weekly.runCount) run](inflect: true)",
            comment: "Widget weekly run count, spoken"
        )
        return Text(verbatim: "\(weekly.completedText) / \(weekly.goalText), \(runs). \(weekly.statusText)")
    }
}
