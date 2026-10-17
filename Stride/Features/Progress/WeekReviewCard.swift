import SwiftUI
import SwiftData

/// The Progress tab's "this week" card: the week's runs and distance in a plain sentence,
/// and — with AI Coach on — a short coach's read of the week by Apple Intelligence.
///
/// The plain copy is always the first thing drawn and stays whenever the model is off,
/// unavailable, still writing, or wrote something `WeekReview` would not accept, so the
/// card never waits on a model to say something true. See `WeekReview`.
struct WeekReviewCard: View {
    /// The runner's runs, as the Progress tab already fetched them (a year, runs only).
    let runs: [RunWorkout]

    @Query(filter: #Predicate<TrainingPlan> { $0.isActive == true })
    private var activePlans: [TrainingPlan]

    @Environment(AppSettings.self) private var appSettings
    @Environment(AppContainer.self) private var container

    /// The checked wording for the current facts, if any. Seeded from the last one saved,
    /// so reopening the tab on an unchanged week shows it at once and asks for nothing.
    @State private var wording: WeekReviewWording? = WeekReviewStore.load()

    private var unit: UnitPreference { appSettings.unitPreference }

    private var facts: WeekReviewFacts? {
        let scheduled = (activePlans.first?.weeks ?? []).flatMap { $0.workouts ?? [] }
        return WeekReview.facts(runs: runs, scheduled: scheduled)
    }

    var body: some View {
        if let facts {
            card(for: facts)
                .task(id: requestKey(for: facts)) { await refresh(for: facts) }
        }
    }

    private func card(for facts: WeekReviewFacts) -> some View {
        let shown = currentWording(for: facts)
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(facts.isCurrentWeek ? "THIS WEEK" : "LAST WEEK")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text(shown?.headline ?? WeekReview.plainHeadline(for: facts, unit: unit))
                    .font(.dsHeadline)
                Text(shown?.summary ?? WeekReview.plainSummary(for: facts, unit: unit))
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let shown {
                    Text(shown.nextFocus)
                        .font(.dsCallout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    footer
                }
            }
            .padding(AppSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
            .adaptiveAnimation(AppAnimation.gentle, value: shown)
        }
        .accessibilityElement(children: .combine)
    }

    /// Discloses who wrote the read, as the run page's coach does.
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

    /// The wording, when it was written from exactly these facts in this unit.
    private func currentWording(for facts: WeekReviewFacts) -> WeekReviewWording? {
        guard appSettings.aiInsightsEnabled,
              let wording,
              wording.source == WeekReview.prompt(for: facts, unit: unit) else { return nil }
        return wording
    }

    /// Moves with the facts, the unit, the AI Coach switch and the model choice, and with
    /// nothing else, so a re-render of an unchanged week never asks the model again.
    private func requestKey(for facts: WeekReviewFacts) -> String {
        [
            WeekReview.prompt(for: facts, unit: unit),
            appSettings.aiInsightsEnabled ? "on" : "off",
            appSettings.aiProvider.rawValue,
        ].joined(separator: "\n")
    }

    /// Asks the runner's model for a review of `facts` unless one is already in hand.
    /// Held back with AI Coach off, and in UI tests and unit-test hosting, where the card
    /// has to show its deterministic copy.
    private func refresh(for facts: WeekReviewFacts) async {
        guard appSettings.aiInsightsEnabled,
              !UITestingSupport.isEnabled, !UITestingSupport.isHostingUnitTests,
              currentWording(for: facts) == nil else { return }
        let fresh = await container.aiCoachService.writeWeekReview(
            for: facts,
            unit: unit,
            provider: appSettings.aiProvider
        )
        // A newer week (or setting) has already started its own request.
        guard !Task.isCancelled, let fresh else { return }
        wording = fresh
        WeekReviewStore.save(fresh)
    }
}

// MARK: - WeekReviewStore

/// The last accepted week review, kept on this device so the Progress tab does not spend
/// a Private Cloud Compute request every time it opens on the same week.
///
/// Local `UserDefaults`, never iCloud: it is a cache of model output for facts this
/// device can recompute, and it holds only the one wording, keyed by those facts.
enum WeekReviewStore {
    private static let key = "progress.weekReview.lastWording"

    static func load(from defaults: UserDefaults = .standard) -> WeekReviewWording? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WeekReviewWording.self, from: data)
    }

    static func save(_ wording: WeekReviewWording, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(wording) else { return }
        defaults.set(data, forKey: key)
    }
}
