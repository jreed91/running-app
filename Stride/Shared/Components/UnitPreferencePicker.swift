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
        // A `StrideSegmentedControl` with a hint line, so it is the same control as every
        // other segmented choice: the route slides between the two.
        StrideSegmentedControl(
            selection: $selection,
            options: UnitPreference.allCases,
            title: { Text($0.localizedName) },
            subtitle: { Text($0 == .metric ? "km · min/km" : "mi · min/mi") }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Distance and pace units")
    }
}
