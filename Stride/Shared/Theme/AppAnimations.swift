import SwiftUI

// MARK: - Spring presets

enum AppAnimation {
    /// Fast bouncy spring — selection changes, navigation transitions.
    static let bouncy   = Animation.spring(response: 0.32, dampingFraction: 0.72)
    /// Snappier spring — quick toggles, button tap feedback.
    static let snappy   = Animation.spring(response: 0.22, dampingFraction: 0.78)
    /// Gentle spring — layout shifts, slow content changes.
    static let gentle   = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// Entrance spring — content appearing on screen.
    static let entrance = Animation.spring(response: 0.40, dampingFraction: 0.75)
}

// MARK: - adaptiveAnimation modifier

extension View {
    /// Spring animation that degrades to a simple easeInOut when Reduce Motion is on.
    func adaptiveAnimation<V: Equatable>(
        _ spring: Animation = AppAnimation.bouncy,
        reducedFallback: Animation = .easeInOut(duration: 0.2),
        value: V
    ) -> some View {
        modifier(AdaptiveAnimationModifier(spring: spring, reducedFallback: reducedFallback, value: value))
    }
}

private struct AdaptiveAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let spring: Animation
    let reducedFallback: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? reducedFallback : spring, value: value)
    }
}

// MARK: - BouncyButtonStyle

/// Button style that scales down slightly on press — communicates interactivity.
struct BouncyButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(AppAnimation.snappy, value: configuration.isPressed)
    }
}
