import SwiftUI

// MARK: - NextUpCardView

/// The dashboard's "Up next" card: the plan's next session, with the prescription a
/// runner needs to decide whether they can fit it in today.
///
/// Content-only — the caller wraps it in the `NavigationLink` that opens the session's
/// detail. Everything it renders comes from ``NextUpBriefing``, so the decisions about
/// what to show and how to word it are testable and none of them live here.
struct NextUpCardView: View {
    let briefing: NextUpBriefing
    let workoutType: WorkoutType
    /// False when the race countdown is on the screen: it is the hero then (rule 2).
    var isHero = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !metrics.isEmpty {
                metricRow
            }
            if let note = briefing.note {
                Text(note)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        // The screen's hero (daylight paper in light, raised ink in dark), unless the race
        // countdown is showing.
        .strideSurface(isHero: isHero)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens the workout's details")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                StrideIcon(name: workoutType.strideIcon, size: 20, color: tint, strokeWeight: 2.2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("UP NEXT")
                    .font(.dsCaption2.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Text(briefing.title)
                    .font(.bodyStrong)
                // Verbatim: both halves are already localized, and a "%@ · %@" key in
                // the catalog is a translation nobody can act on.
                Text(verbatim: "\(briefing.dayPhrase) · \(briefing.dateText)")
                    .font(.caption)
                    .foregroundStyle(briefing.isToday ? Color.brand : Color.secondary)
            }
            Spacer(minLength: 0)
            StrideIcon(name: .chevronRight, size: 14, color: .secondary, strokeWeight: 2)
        }
    }

    // MARK: Metrics

    /// One cell of the prescription. `label` is a resolved `String` rather than a
    /// `LocalizedStringKey` so the same text can be both drawn and spoken — the
    /// accessibility summary below needs it as a value, and a key cannot be read back.
    private struct Metric: Identifiable {
        let id: String
        let label: String
        let value: String
    }

    /// The prescription, in the order a runner reads it: how far, how fast, how long.
    /// Absent values are dropped rather than shown as a dash — a plan that sets no pace
    /// band has not prescribed "--:--".
    private var metrics: [Metric] {
        var items: [Metric] = []
        if let distance = briefing.distanceText {
            items.append(Metric(
                id: "distance",
                label: String(localized: "Distance", comment: "Up-next card metric label"),
                value: distance
            ))
        }
        if let pace = briefing.paceText {
            items.append(Metric(
                id: "pace",
                label: String(localized: "Target pace", comment: "Up-next card metric label"),
                value: pace
            ))
        }
        if let duration = briefing.durationText {
            items.append(Metric(
                id: "duration",
                label: String(localized: "Est. time", comment: "Up-next card metric label"),
                value: duration
            ))
        }
        return items
    }

    private var metricRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.xl) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.value)
                        .font(.dsSubhead.weight(.semibold))
                        .monospacedDigit()
                    Text(verbatim: metric.label)
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Styling

    private var tint: Color { workoutType.color }


    /// Spoken as one sentence. Combining the children alone reads the metric values and
    /// their labels as separate fragments in visual order — "8.0 km", "Distance" — which
    /// is the wrong way round for every one of them.
    private var accessibilityDescription: String {
        var parts = [
            String(
                localized: "Up next: \(briefing.title), \(briefing.dayPhrase), \(briefing.dateText)",
                comment: "VoiceOver summary of the dashboard's up-next card"
            )
        ]
        for metric in metrics {
            // Label first: the card draws the value above its label, which is the wrong
            // way round to hear.
            parts.append("\(metric.label): \(metric.value)")
        }
        if let note = briefing.note { parts.append(note) }
        return parts.joined(separator: ". ")
    }
}

#Preview {
    VStack(spacing: 16) {
        NextUpCardView(
            briefing: NextUpBriefing(
                title: "Long Run",
                dayPhrase: "Tomorrow",
                dateText: "Sun 3 Aug",
                distanceText: "18.0 km",
                paceText: "6:10–6:40 /km",
                durationText: "~1 h 55 min",
                note: "Keep it easy and practise your fuelling",
                isToday: false
            ),
            workoutType: .longRun
        )
        NextUpCardView(
            briefing: NextUpBriefing(
                title: "Tempo",
                dayPhrase: "Today",
                dateText: "Wed 30 Jul",
                distanceText: "10.0 km",
                paceText: "4:45 /km",
                durationText: "~48 min",
                note: nil,
                isToday: true
            ),
            workoutType: .tempo
        )
    }
    .padding()
}
