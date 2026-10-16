import SwiftUI

/// The one control for choosing distance/pace units.
///
/// There used to be two, and they did not look like the same control: onboarding drew a
/// stock `.pickerStyle(.segmented)` showing only the format hint, while Settings drew a
/// custom brand-filled pill showing the unit's name *and* its format. Same setting, two
/// visual languages, and the stock segmented control was the only one of its kind in either
/// flow (S24). This is the Settings treatment, extracted so both sites share it.
struct UnitPreferencePicker: View {
    @Binding var selection: UnitPreference

    var body: some View {
        HStack(spacing: 4) {
            ForEach(UnitPreference.allCases, id: \.self) { unit in
                Button { selection = unit } label: {
                    VStack(spacing: 3) {
                        Text(unit.localizedName)
                            .font(.dsSubhead.weight(.semibold))
                        Text(unit == .metric ? "km · min/km" : "mi · min/mi")
                            .font(.dsCaption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background {
                        if selection == unit {
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous).fill(.route)
                        }
                    }
                    // `.onFill`, not `.white`: white on `Color.brand` is 2.84:1, below even
                    // the 3.0 large-text bar, which is why `onFill` exists (U3a). The
                    // Settings copy of this control was still using white.
                    .foregroundStyle(selection == unit ? Color.onFill : Color.secondary)
                    .animation(.easeInOut(duration: 0.15), value: selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(unit.localizedName)
                .accessibilityAddTraits(selection == unit ? [.isSelected] : [])
            }
        }
        .padding(AppSpacing.xs)
        .background(Color.surfaceTertiary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Distance and pace units")
    }
}
