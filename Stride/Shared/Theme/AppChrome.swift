import UIKit

/// App-wide UIKit chrome that SwiftUI has no modifier for: navigation-bar titles in SF
/// Pro Rounded, the Route Loop display face, so every screen's title matches the
/// `dsLargeTitle` / `dsTitle*` type the screens use inside.
///
/// Only the title fonts are set on the bars. They keep the system's own (Liquid Glass)
/// background, so scroll-edge behaviour is unchanged.
///
/// The system segmented control (the `.segmented` pickers inside forms) takes the route's
/// orange for the chosen segment with `onFill` text, matching `StrideSegmentedControl`.
enum AppChrome {
    @MainActor
    static func apply() {
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: rounded(.largeTitle, weight: .bold)]
        bar.titleTextAttributes = [.font: rounded(.headline, weight: .semibold)]

        let segments = UISegmentedControl.appearance()
        segments.selectedSegmentTintColor = UIColor(named: "Brand")
        let label = UIFont.preferredFont(forTextStyle: .subheadline)
        segments.setTitleTextAttributes(
            [.font: UIFont.systemFont(ofSize: label.pointSize, weight: .medium)],
            for: .normal
        )
        segments.setTitleTextAttributes(
            [
                .font: UIFont.systemFont(ofSize: label.pointSize, weight: .semibold),
                .foregroundColor: UIColor(named: "OnFill") ?? .black
            ],
            for: .selected
        )
    }

    /// A Dynamic Type text style in the rounded design, so titles still scale.
    private static func rounded(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        // The style's size at the default content size; `scaledFont` then applies the
        // user's setting once. `preferredFont`'s size alone would already be scaled.
        let defaultSize = UITraitCollection(preferredContentSizeCategory: .large)
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: defaultSize)
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else {
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: base.pointSize))
    }
}
