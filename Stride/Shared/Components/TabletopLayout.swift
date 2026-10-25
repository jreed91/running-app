import SwiftUI

// MARK: Propped up like a laptop

/// A workout screen's layout for iPhone Duo propped half-open on a surface, with the fold
/// running across the display: `top` above the fold, `bottom` below it. Otherwise `flat`,
/// unchanged.
///
/// It exists for the two screens a phone is set down in front of: the run HUD on a
/// treadmill console and a strength session on the gym floor. Apple's guidance for the
/// pose is the split used here: the upper half is read from a distance, the lower half is
/// touched, on the part resting on the surface, so a tap doesn't rock the phone. Both
/// halves together must carry every control the flat layout has.
///
/// Only an *active* division counts. Fully open, the fold is inactive and the flat layout
/// is right; held like a book the fold runs top to bottom and isn't this pose.
struct TabletopLayout<Flat: View, Top: View, Bottom: View>: View {
    private let isEnabled: Bool
    private let flat: () -> Flat
    private let top: () -> Top
    private let bottom: () -> Bottom

    /// - Parameter isEnabled: false keeps `flat` whatever the pose, for the states that
    ///   have nothing to split (a finished or empty session).
    init(
        isEnabled: Bool = true,
        @ViewBuilder flat: @escaping () -> Flat,
        @ViewBuilder top: @escaping () -> Top,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) {
        self.isEnabled = isEnabled
        self.flat = flat
        self.top = top
        self.bottom = bottom
    }

    var body: some View {
        GeometryReader { proxy in
            if isEnabled, let fold = Self.acrossFold(in: proxy) {
                VStack(spacing: 0) {
                    top()
                        .frame(maxWidth: .infinity)
                        .frame(height: max(0, fold.minY))
                    // The fold itself, margins included: nothing is placed in the crease.
                    Color.clear
                        .frame(height: fold.height)
                    bottom()
                        .frame(maxWidth: .infinity)
                        .frame(height: max(0, proxy.size.height - fold.maxY))
                }
            } else {
                flat()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    /// The active fold, when it runs side to side across this view.
    private static func acrossFold(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return proxy
            .reservedRegions(kind: .division)
            .first { $0.frame.width > $0.frame.height }?
            .frame
    }
}
