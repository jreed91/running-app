import SwiftUI
import WidgetKit

// MARK: - CoachTipWidget

/// The one thing the coach would say right now, on the Home Screen and the Lock Screen.
///
/// The selection behind it is the app's — `SmartCoachCards` reads scheduled workouts,
/// logged runs, weather and the profile, and this process can reach none of them. The app
/// runs it and publishes the winning card into ``WidgetSnapshot/coachTip``, so this widget
/// and the dashboard's Coach Tips strip are answering from one set of thresholds rather
/// than two that happen to agree.
struct CoachTipWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StrideWidgetKind.coachTip, provider: StrideSnapshotProvider()) { entry in
            CoachTipWidgetView(entry: entry)
                .widgetURL(StrideWidgetDeepLink.home)
        }
        // `Text`, not a bare string literal: the `StringProtocol` overload of these
        // modifiers does *not* localize, and picks itself silently.
        .configurationDisplayName(Text("Coach Tip"))
        .description(Text("What to do about your next run, and what to eat before it."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - View

struct CoachTipWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrideWidgetEntry

    /// The tip, if there is one that is still true.
    ///
    /// Expiry is resolved against the *entry's* date rather than `Date()`: the timeline
    /// pre-renders several days of entries, so a refuelling tip written this morning has
    /// to disappear from tomorrow's entry without the app running to withdraw it. Same
    /// reason `NextWorkout.dayLabel(asOf:)` takes the entry date.
    private var tip: WidgetSnapshot.CoachTip? {
        guard entry.source != .unavailable, let tip = entry.snapshot.coachTip else { return nil }
        return tip.isValid(asOf: entry.date) ? tip : nil
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
        VStack(alignment: .leading, spacing: 5) {
            if let tip {
                WidgetCardHeader(
                    title: Text(verbatim: tip.categoryLabel),
                    symbolName: tip.symbolName,
                    tint: tip.tint.color
                )
                Text(verbatim: tip.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(verbatim: tip.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            } else {
                WidgetEmptyState(title: "Coach")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Medium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tip {
                WidgetCardHeader(
                    title: Text(verbatim: tip.categoryLabel),
                    symbolName: tip.symbolName,
                    tint: tip.tint.color
                )
                Text(verbatim: tip.title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: tip.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                // The session the advice is about, so the card stands on its own rather
                // than assuming the runner remembers what is next.
                if let workout = entry.snapshot.nextWorkout, !workout.isRest {
                    nextUpLine(workout)
                }
            } else {
                WidgetEmptyState(title: "Coach")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private func nextUpLine(_ workout: WidgetSnapshot.NextWorkout) -> some View {
        HStack(spacing: 4) {
            Image(systemName: workout.symbolName)
                .imageScale(.small)
                .foregroundStyle(workout.tint.color)
            Text(verbatim: workout.dayLabel(asOf: entry.date))
            Text(verbatim: "·")
            Text(verbatim: workout.title)
            if let detail = workout.detail {
                Text(verbatim: "·")
                Text(verbatim: detail)
            }
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: Accessory

    /// Lock Screen. No colour and very little room, so the category overline goes and the
    /// title carries the tint's job.
    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let tip {
                Text(verbatim: tip.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: tip.message)
                    .font(.caption2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text("Coach")
                    .font(.headline)
                Text("Open Stride to sync")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Spoken

    /// The card as one sentence. The overline is a category marker rather than prose, and
    /// the symbol says nothing at all, so combining the children alone would read "FUEL"
    /// before the advice.
    private var spokenLabel: Text {
        guard let tip else {
            return Text("Coach tip. Open Stride to sync.")
        }
        return Text(verbatim: "\(tip.title). \(tip.message)")
    }
}
