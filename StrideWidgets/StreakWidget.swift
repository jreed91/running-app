import SwiftUI
import WidgetKit

// MARK: - StreakWidget

/// The run streak, and whether today's run is already in (B1).
///
/// The streak's whole value is the moment before it breaks, which is the moment the app
/// is not open — so of everything the Achievements surface (B4) tracks, this is the piece
/// that most wants to be on the Lock Screen.
struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StrideWidgetKind.streak, provider: StrideSnapshotProvider()) { entry in
            StreakWidgetView(entry: entry)
                .widgetURL(StrideWidgetDeepLink.progress)
        }
        .configurationDisplayName(Text("Run Streak"))
        .description(Text("Consecutive days you've run, and whether today's is in."))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - View

struct StreakWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrideWidgetEntry

    private var streak: WidgetSnapshot.Streak? {
        entry.source == .unavailable ? nil : entry.snapshot.streak
    }

    /// Neutral while today is still outstanding, brand once it is done. The one bit of
    /// state worth encoding in colour here — but never *only* in colour: the glyph and
    /// the caption both change with it (U3d). Not the tempo zone's amber: zone colours
    /// are training data, and the route's amber fails as text on a light widget.
    private var tint: Color {
        guard let streak, streak.current > 0 else { return .secondary }
        return streak.isActiveToday ? .strideBrand : .primary
    }

    private var symbolName: String {
        (streak?.isActiveToday ?? false) ? "flame.fill" : "flame"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryInline:
                inline
            default:
                small
            }
        }
        .strideWidgetBackground(family)
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let streak {
                WidgetCardHeader(title: Text("Run Streak"), symbolName: symbolName, tint: tint)
                Spacer(minLength: 0)
                Text(streak.current, format: .number)
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(daysUnitLabel)
                    .font(.caption2.weight(.bold))
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                WidgetEmptyState(title: "Run Streak")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — circular

    /// A ring that fills as the week's seven days go by, with the streak count in the
    /// middle. It is a progress *reading*, not a goal — which is why the ring tops out at
    /// a week and the number keeps going.
    private var circular: some View {
        Gauge(value: min(Double(streak?.current ?? 0) / 7, 1)) {
            Image(systemName: symbolName)
        } currentValueLabel: {
            Text(streak?.current ?? 0, format: .number)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — inline

    private var inline: some View {
        Group {
            if let streak {
                Label {
                    Text(verbatim: streakPhrase)
                } icon: {
                    Image(systemName: symbolName)
                }
            } else {
                Text("Run streak unavailable")
            }
        }
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Copy

    /// Split from the number for the same reason the race countdown's is: the count is
    /// drawn several times larger than the word beside it, so there is no number left for
    /// automatic grammar agreement to agree with.
    private var daysUnitLabel: LocalizedStringKey {
        (streak?.current ?? 0) == 1 ? "DAY" : "DAYS"
    }

    private var streakPhrase: String {
        String(
            localized: "^[\(streak?.current ?? 0) day](inflect: true) streak",
            comment: "Widget run streak, inline"
        )
    }

    private var statusText: LocalizedStringKey {
        guard let streak, streak.current > 0 else {
            return "Run today to start one"
        }
        if streak.isActiveToday {
            return streak.current >= streak.longest ? "Your best yet" : "Today's run is in"
        }
        return "Run today to keep it"
    }

    private var spokenLabel: Text {
        guard let streak else {
            return Text("Run streak. Open Stride to sync.")
        }
        let state = streak.isActiveToday
            ? String(localized: "Today's run is in", comment: "Widget streak state, spoken")
            : String(localized: "Today's run is still to do", comment: "Widget streak state, spoken")
        return Text(verbatim: "\(streakPhrase). \(state).")
    }
}
