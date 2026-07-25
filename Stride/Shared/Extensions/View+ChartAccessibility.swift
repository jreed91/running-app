import SwiftUI

extension View {
    /// Collapses a chart into a single labelled accessibility element that speaks a
    /// summary of its data (N18).
    ///
    /// Left alone, a `Chart`'s marks are exposed as unlabelled sub-elements, so a
    /// VoiceOver user swiping through the Progress tab or a run's splits hears a series of
    /// bare numbers with nothing saying which chart they belong to — and a chart carrying
    /// a `chartXSelection` overlay often exposes nothing at all.
    ///
    /// Build `summary` with ``ChartAccessibility/summary(_:format:)`` so every chart in the
    /// app describes itself the same way.
    func chartAccessibility(_ label: String, _ summary: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(summary)
    }
}
