import SwiftUI

/// A number you can either step or type.
///
/// Age and Max HR were stepper-only in both onboarding and Settings, so moving age from the
/// assumed 30 to 45 was fifteen taps with no way to just say "45" (S25). The stepper stays —
/// it is the right control for a nudge — and the value beside it is now a number-pad field.
///
/// Committing is deliberate rather than live: the text is parsed and clamped when the field
/// loses focus, not on every keystroke. Clamping per keystroke fights the typist, because
/// the first digit of "45" is "4", which is below the age floor and would be rewritten to 10
/// before the second digit arrives.
struct NumericStepperField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// How far one tap of the stepper moves the value. Defaults to 1, which is right for a
    /// value nudged a unit at a time (age, max HR); a value the runner thinks about in blocks
    /// — weekly running minutes — passes something coarser. The typed field still accepts any
    /// number in `range` either way.
    var step = 1
    /// Rendered after the number when the field is not being edited (e.g. "bpm").
    var suffix: String?
    /// Whether to draw `title` as a leading label. Settings rows draw their own titles and
    /// pass `false`; onboarding's card has no row chrome and passes the default. Either way
    /// `title` is the field's accessibility label.
    var showsLabel = true
    /// Called when the runner changes the value by either route, so callers can record that
    /// this was an explicit choice rather than a default they left alone.
    var onEdit: (() -> Void)?

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if showsLabel {
                Text(title)
                    .font(.dsSubhead.weight(.semibold))
                Spacer(minLength: AppSpacing.sm)
            }

            HStack(spacing: 4) {
                TextField(title, text: $text)
                    .font(.dsSubhead.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($isEditing)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(title)

                if let suffix, !isEditing {
                    Text(suffix)
                        .font(.dsSubhead.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(
                Color.secondary.opacity(isEditing ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: AppRadius.xs)
            )

            Stepper(title, value: stepperBinding, in: range, step: step)
                .labelsHidden()
        }
        .task(id: value) {
            // Only rewrite the buffer from outside while the runner is not mid-edit;
            // otherwise the stepper's own writes would fight their typing.
            if !isEditing { text = "\(value)" }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                text = "\(value)"
            } else {
                commit()
            }
        }
        .toolbar {
            if isEditing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
        }
    }

    private var stepperBinding: Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                guard newValue != value else { return }
                value = newValue
                text = "\(newValue)"
                onEdit?()
            }
        )
    }

    /// Parses, clamps, and writes back — or restores the last good value if what was typed
    /// is not a number at all, so an empty field can never persist as a zero.
    private func commit() {
        let digits = text.filter(\.isNumber)
        guard let parsed = Int(digits) else {
            text = "\(value)"
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        text = "\(clamped)"
        guard clamped != value else { return }
        value = clamped
        onEdit?()
    }
}
