import SwiftUI

// What the screen shows while the coach writes. The motion table gives waiting on the
// coach one look: skeleton lines in the shape of the reply, or typing dots, both
// breathing with `AppAnimation.thinking`. Never the system spinner.

/// One line of a reply that isn't written yet. Size it with `.frame` to the text it stands
/// in for. Breathes with `thinking`, and holds still under Reduce Motion.
struct CoachSkeletonLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 0.12

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.micro)
            .fill(Color.secondary.opacity(reduceMotion ? 0.2 : opacity))
            .onAppear {
                // A steady placeholder under Reduce Motion; the pulse is motion.
                guard !reduceMotion else { return }
                withAnimation(AppAnimation.thinking) {
                    opacity = 0.28
                }
            }
            .accessibilityHidden(true)
    }
}

/// Three dots that breathe in turn while the coach is still writing. Decorative: the
/// view around them says what is happening to VoiceOver.
struct CoachTypingDots: View {
    var dotSize: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        HStack(spacing: dotSize) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: dotSize, height: dotSize)
                    .opacity(breathing || reduceMotion ? 1 : 0.3)
                    // A looping pulse is exactly what Reduce Motion asks to stop. Two
                    // stagger steps apart, so the three read as a wave, not one blink.
                    .animation(
                        reduceMotion
                            ? nil
                            : AppAnimation.thinking.delay(Double(index) * 2 * AppAnimation.stagger),
                        value: breathing
                    )
            }
        }
        .onAppear { breathing = true }
        .accessibilityHidden(true)
    }
}
