import SwiftUI

/// The race hub's "race plan": which goal to go for and how to pace it, written by Apple
/// Intelligence from what ``RaceDayPlan`` computed. See `RaceBriefing`.
///
/// Additive, so it has no plain fallback: every number it could quote is already on the
/// hub. With AI Coach off, on a device without Apple Intelligence, or when a draft fails
/// its number check, the card is not drawn at all. Display only: the hub owns the request
/// (`RaceDayHubView.refreshBriefing`), because a view that might draw nothing cannot be
/// relied on to run its own `.task`.
struct RaceBriefingCard: View {
    /// A wording already checked against the hub's current facts, or nil while writing.
    let wording: RaceBriefingWording?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RACE PLAN")
                .strideEyebrow()
                .foregroundStyle(.secondary)
            content
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strideCard()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if let current = wording {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(current.headline)
                    .font(.dsHeadline)
                Text(current.pacing)
                    .font(.dsBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.beforeTheRace)
                    .font(.dsCallout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }
        } else {
            HStack(spacing: AppSpacing.sm) {
                ProgressView()
                Text("Writing your race plan…")
                    .font(.dsCallout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Discloses who wrote the plan, as the run page's coach does.
    private var footer: some View {
        HStack(spacing: 4) {
            RunSummaryView.SparkleShape()
                .fill(Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text("Written by Apple Intelligence")
                .font(.dsCaption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, AppSpacing.xs)
    }
}
