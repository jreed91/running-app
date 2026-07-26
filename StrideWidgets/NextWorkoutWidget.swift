import SwiftUI
import WidgetKit

// MARK: - NextWorkoutWidget

/// What the plan is asking for next, on the Home Screen and the Lock Screen (B1).
///
/// The most-asked question the app answers, and the one least worth unlocking a phone for.
struct NextWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StrideWidgetKind.nextWorkout, provider: StrideSnapshotProvider()) { entry in
            NextWorkoutWidgetView(entry: entry)
                .widgetURL(StrideWidgetDeepLink.plan)
        }
        // `Text`, not a bare string literal: the `StringProtocol` overload of these
        // modifiers does *not* localize, and picks itself silently (the same trap the
        // Live Activity's glyph documents).
        .configurationDisplayName(Text("Next Workout"))
        .description(Text("The next session on your training plan."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - View

struct NextWorkoutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrideWidgetEntry

    private var workout: WidgetSnapshot.NextWorkout? {
        entry.source == .unavailable ? nil : entry.snapshot.nextWorkout
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                accessory
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .strideWidgetBackground(family)
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let workout {
                WidgetCardHeader(
                    title: Text(verbatim: workout.dayLabel(asOf: entry.date)),
                    symbolName: workout.symbolName,
                    tint: workout.tint.color
                )
                Text(verbatim: workout.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let detail = workout.detail {
                    Text(verbatim: detail)
                        .font(.headline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let pace = workout.paceTarget {
                    Text(verbatim: pace)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if workout.isRest {
                    Text("Recovery is part of training")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                WidgetEmptyState(title: "Next Workout", message: emptyMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Medium

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            if let workout {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetCardHeader(
                        title: Text(verbatim: workout.dayLabel(asOf: entry.date)),
                        symbolName: workout.symbolName,
                        tint: workout.tint.color
                    )
                    Text(verbatim: workout.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let note = workout.note {
                        Text(verbatim: note)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else if workout.isRest {
                        Text("Recovery is part of training")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    if let detail = workout.detail {
                        WidgetMetric(label: "Distance", alignment: .trailing) {
                            Text(verbatim: detail)
                        }
                    }
                    if let pace = workout.paceTarget {
                        WidgetMetric(label: "Target pace", alignment: .trailing) {
                            Text(verbatim: pace)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                WidgetEmptyState(title: "Next Workout", message: emptyMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let workout {
                Text(verbatim: workout.dayLabel(asOf: entry.date).uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(1.1)
                    .widgetAccentable()
                Text(verbatim: workout.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail = workout.detail {
                    Text(verbatim: detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    private var emptyMessage: LocalizedStringKey {
        entry.source == .unavailable
            ? "Open Stride to sync"
            : "No plan yet — build one in Stride"
    }

    /// Spoken as one sentence rather than as four stacked fragments, and it says the day
    /// in words: "Today, Tempo" is what the card means, where VoiceOver reading the
    /// header, the title, and two numbers in sequence is not.
    private var spokenLabel: Text {
        guard let workout else {
            return Text("Next workout. Open Stride to sync.")
        }
        var parts = [workout.dayLabel(asOf: entry.date), workout.title]
        if let detail = workout.detail { parts.append(detail) }
        if let pace = workout.paceTarget { parts.append(pace) }
        return Text(parts.joined(separator: ", "))
    }
}
