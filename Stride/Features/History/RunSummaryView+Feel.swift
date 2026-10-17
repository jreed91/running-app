import SwiftUI

// Part of `RunSummaryView` (D1).
// The "How did that feel?" card: the runner's own rating of the run (`RunFeel`), stored on
// the run and read by the coach and plan adaptation through `RunFeelSignal`.

extension RunSummaryView {

    /// Five choices, one tap. Sits right under the hero because this screen is what
    /// opens when a run finishes, and the question is only worth asking while the run is
    /// still in the runner's legs. It stays on every later open too, so a skipped answer
    /// can be given (or changed) afterwards; a second tap on the active choice clears it.
    var feelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The chosen answer shows on its own chip, so the header doesn't repeat it.
            sectionHeader(title: "How did that feel?")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(RunFeel.allCases) { feel in
                        feelButton(feel)
                    }
                }

                // Only when there is something to do about it. What the rating is for is
                // the buttons' hint, rather than a standing line under them on every open.
                if feelChangedSinceInsight, aiInsight != nil {
                    Text("Open the coach and tap Refresh to include this.")
                        .font(.dsCaption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strideCard()
            .sensoryFeedback(.selection, trigger: workout.feelRaw)
        }
    }

    private func feelButton(_ feel: RunFeel) -> some View {
        let isActive = workout.feel == feel
        return Button {
            withAnimation(AppAnimation.snappy) {
                workout.feel = isActive ? nil : feel
            }
            feelChangedSinceInsight = true
            context.saveOrLog("the run-feel rating")
        } label: {
            VStack(spacing: AppSpacing.xxs) {
                Text("\(feel.rawValue)")
                    .font(.dsHeadline.weight(.bold).monospacedDigit())
                Text(feel.localizedName)
                    .font(.dsCaption2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        // The chip sets the colours: the route when chosen, a card when not.
        .buttonStyle(.strideChip(selected: isActive))
        .accessibilityLabel(feel.localizedName)
        .accessibilityValue(
            String(localized: "\(feel.rawValue) of 5", comment: "Position of a run-feel choice on its scale")
        )
        .accessibilityHint(
            String(
                localized: "Your coach and plan adjustments use this alongside pace and heart rate.",
                comment: "Explains what the run-feel rating is used for"
            )
        )
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
