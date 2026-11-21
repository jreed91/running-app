import SwiftUI

/// Plan Replay: a finished plan as a story of cards to swipe through and share, drawn by
/// the year recap's pager and card so the two look like one family.
struct PlanReplayView: View {
    let plan: TrainingPlan

    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        let cards = PlanReplayCards.make(
            from: PlanReplay.make(from: plan),
            unit: appSettings.unitPreference
        )

        RecapStoryPager(cards: cards, logLabel: "Plan replay") {
            StrideEmptyState(
                "Not enough runs to replay",
                systemImage: "figure.run",
                description: Text("A replay needs at least \(YearInRunning.minimumRunsForRecap) runs logged in the plan.")
            )
            .padding(AppSpacing.xl)
        }
    }
}

/// The way into a plan's replay: a card on the plan's detail screen once its last day
/// has passed.
struct PlanReplayEntryCard: View {
    let plan: TrainingPlan

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: AppSpacing.md) {
                StrideIcon(name: .trophy, size: 22, color: .brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replay this plan")
                        .font(.bodyStrong)
                        .foregroundStyle(.primary)
                    Text("Your training from week 1 to the end, as cards to share.")
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.dsFootnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(AppSpacing.lg)
            .strideCard(cornerRadius: AppRadius.md)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plan.replay")
        .fullScreenCover(isPresented: $isPresented) {
            PlanReplayView(plan: plan)
        }
    }
}
