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
            // The chosen answer shows under the row, so the header doesn't repeat it.
            sectionHeader(title: "How did that feel?")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(RunFeel.allCases) { feel in
                        feelButton(feel)
                    }
                }
                feelCaption

                // Only when there is something to do about it. What the rating is for is
                // the buttons' hint, rather than a standing line under them on every open.
                if feelChangedSinceInsight, aiInsight != nil {
                    Text("Open the coach and tap Rewrite to include this.")
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

    /// The chosen answer in words, or the scale's two ends before anything is chosen.
    private var feelCaption: some View {
        Group {
            if let feel = workout.feel {
                Text(feel.localizedName)
                    .foregroundStyle(.primary)
            } else {
                HStack {
                    Text(RunFeel.veryEasy.localizedName)
                    Spacer()
                    Text(RunFeel.veryHard.localizedName)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.dsCaption.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: workout.feel == nil ? .leading : .center)
        .accessibilityHidden(true)
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
            // The number only: five words in five narrow buttons broke "Moder-ate" in
            // half. The words live in the caption under the row.
            Text("\(feel.rawValue)")
                .font(.dsHeadline.weight(.bold).monospacedDigit())
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
