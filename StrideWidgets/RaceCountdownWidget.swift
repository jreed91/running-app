import SwiftUI
import WidgetKit

// MARK: - RaceCountdownWidget

/// Days to race day, with where the plan has got to (B1).
///
/// `raceDate` has been on `UserProfile` since the first plan was ever built and nothing
/// counted down to it. This is the smallest surface that closes that arc.
struct RaceCountdownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StrideWidgetKind.raceCountdown, provider: StrideSnapshotProvider()) { entry in
            RaceCountdownWidgetView(entry: entry)
                .widgetURL(StrideWidgetDeepLink.plan)
        }
        .configurationDisplayName(Text("Race Countdown"))
        .description(Text("Days until your goal race, and where your plan has got to."))
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - View

struct RaceCountdownWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StrideWidgetEntry

    /// The race, but only while it is still ahead. Checked against the *entry's* date
    /// rather than the snapshot's, so the card retires itself the morning after the race
    /// even if the app has not been opened since.
    private var race: WidgetSnapshot.RaceCountdown? {
        guard entry.source != .unavailable, let race = entry.snapshot.race else { return nil }
        return race.isUpcoming(asOf: entry.date) ? race : nil
    }

    private var daysRemaining: Int {
        race?.daysRemaining(asOf: entry.date) ?? 0
    }

    private var isRaceDay: Bool { race != nil && daysRemaining == 0 }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
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
        VStack(alignment: .leading, spacing: 2) {
            if let race {
                WidgetCardHeader(
                    // Two `Text`s rather than a ternary of two literals: a ternary of
                    // string literals infers `String` and picks the overload that does
                    // *not* localize (the trap `RunActivityGlyph` documents).
                    title: isRaceDay ? Text("Race Day") : Text("Race Countdown"),
                    symbolName: "flag.checkered",
                    tint: .strideBrand
                )
                Spacer(minLength: 0)
                if isRaceDay {
                    Text("Today")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.strideBrand)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text(daysRemaining, format: .number)
                        .font(.largeTitle.weight(.bold).monospacedDigit())
                        .foregroundStyle(.strideBrand)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(daysUnitLabel)
                        .font(.caption2.weight(.bold))
                        .kerning(1.1)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(verbatim: race.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if let phase = race.phaseLabel {
                    Text(phase)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else if let goal = race.goalTimeText {
                    Text(verbatim: goal)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                WidgetEmptyState(title: "Race Countdown", message: emptyMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — rectangular

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let race {
                Text(verbatim: race.name.uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(1.1)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(verbatim: headlineText)
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let phase = race.phaseLabel {
                    Text(phase)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("No race set")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Lock Screen — inline

    /// One line above the clock. It gets the race name *and* the count, because the
    /// inline slot is the one place a bare number has no card around it to explain it.
    private var inline: some View {
        Group {
            if let race {
                Text(verbatim: "\(race.name) · \(headlineText)")
            } else {
                Text("No race set")
            }
        }
        .accessibilityLabel(spokenLabel)
    }

    // MARK: Copy

    private var headlineText: String {
        isRaceDay
            ? String(localized: "Race day", comment: "Widget race countdown, on the day")
            : String(
                localized: "^[\(daysRemaining) day](inflect: true) to go",
                comment: "Widget race countdown"
            )
    }

    /// The unit beside the big number on the small card.
    ///
    /// Two keys rather than one `inflect:` phrase, because the number is drawn separately
    /// here — it is the subject of the card and wants to be four times the size of the
    /// word next to it — and automatic grammar agreement has no number to agree with once
    /// the two are split. A translator gets both forms and can leave them identical where
    /// the language does not distinguish them.
    private var daysUnitLabel: LocalizedStringKey {
        daysRemaining == 1 ? "DAY TO GO" : "DAYS TO GO"
    }

    private var emptyMessage: LocalizedStringKey {
        entry.source == .unavailable
            ? "Open Stride to sync"
            : "Set a goal race in Stride"
    }

    private var spokenLabel: Text {
        guard let race else {
            return Text("Race countdown. No race set.")
        }
        var parts = [race.name, headlineText]
        if let phase = race.phaseLabel { parts.append(phase) }
        if let goal = race.goalTimeText {
            parts.append(String(localized: "Goal \(goal)", comment: "Widget race goal time, spoken"))
        }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}
