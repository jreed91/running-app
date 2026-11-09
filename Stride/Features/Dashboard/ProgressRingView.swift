import SwiftUI

// MARK: - ProgressRingView

/// The week's progress drawn as a route: the Route Loop gradient on a faint track.
struct ProgressRingView: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// False until the ring first appears, so the route fills in from zero rather than
    /// showing up already drawn — the same entrance as the app mark's loop. Under Reduce
    /// Motion it appears filled, as `StrideProgressBar` does.
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.surfaceTertiary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: hasAppeared || reduceMotion ? progress : 0)
                .stroke(.route, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .adaptiveAnimation(AppAnimation.gentle, value: progress)
                .adaptiveAnimation(AppAnimation.gentle, value: hasAppeared)
        }
        .frame(width: size, height: size)
        .onAppear { hasAppeared = true }
    }
}
