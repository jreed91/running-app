import SwiftUI

// Part of `RunSummaryView` (D1).
// The "How did that feel?" card: the runner's own rating of the run (`RunFeel`), stored on
// the run and read by the coach and plan adaptation through `RunFeelSignal`.

extension RunSummaryView {

    /// Five choices, one tap. Sits near the top of the screen because this screen is what
    /// opens when a run finishes, and the question is only worth asking while the run is
    /// still in the runner's legs. It stays on every later open too, so a skipped answer
    /// can be given (or changed) afterwards; a second tap on the active choice clears it.
    var feelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("How did that feel?")
                    .font(.dsSubhead.weight(.bold))
                Spacer()
                if let feel = workout.feel {
                    Text(feel.localizedName)
                        .font(.dsCaption.weight(.semibold))
                        .foregroundStyle(.brandText)
                }
            }

            HStack(spacing: 6) {
                ForEach(RunFeel.allCases) { feel in
                    feelButton(feel)
                }
            }

            Text(feelFootnote)
                .font(.dsCaption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strideCard(cornerRadius: AppRadius.md)
        .sensoryFeedback(.selection, trigger: workout.feelRaw)
    }

    private var feelFootnote: String {
        // A coach read cached before the rating was written against a run with no rating,
        // so it says nothing about it until it is regenerated.
        if feelChangedSinceInsight, aiInsight != nil {
            return String(
                localized: "Tap Refresh on the coach's analysis to include this.",
                comment: "Under the run-feel buttons, after the rating changed while a coach analysis was loaded"
            )
        }
        return String(
            localized: "Your coach and plan adjustments use this alongside pace and heart rate.",
            comment: "Explains what the run-feel rating is used for"
        )
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
            VStack(spacing: 6) {
                Text("\(feel.rawValue)")
                    .font(.dsHeadline.weight(.bold).monospacedDigit())
                Text(feel.localizedName)
                    .font(.dsCaption2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? Color.onFill : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding(.vertical, AppSpacing.xs)
            .background(
                isActive ? Color.brand : Color.surfacePrimary,
                in: RoundedRectangle(cornerRadius: AppRadius.sm)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feel.localizedName)
        .accessibilityValue(
            String(localized: "\(feel.rawValue) of 5", comment: "Position of a run-feel choice on its scale")
        )
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
