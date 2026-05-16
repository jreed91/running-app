import SwiftUI

// MARK: - Elevation
//
// Four shadow levels mirroring the Stride design system (tokens.jsx).
// iOS is mostly flat; reserve elevation for floating controls, popovers,
// and sheets. Each level is expressed as a pair of stacked shadows via
// the `.appShadow(_:)` view modifier.

enum AppElevation {
    case e0, e1, e2, e3
}

private struct ShadowLayer {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

private extension AppElevation {
    var layers: [ShadowLayer] {
        switch self {
        case .e0:
            return []
        case .e1:
            return [
                ShadowLayer(color: .black.opacity(0.04), radius: 1, x: 0, y: 1),
                ShadowLayer(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 1),
            ]
        case .e2:
            return [
                ShadowLayer(color: .black.opacity(0.06), radius: 3, x: 0, y: 2),
                ShadowLayer(color: .black.opacity(0.08), radius: 8, x: 0, y: 6),
            ]
        case .e3:
            return [
                ShadowLayer(color: .black.opacity(0.12), radius: 12, x: 0, y: 8),
                ShadowLayer(color: .black.opacity(0.10), radius: 20, x: 0, y: 16),
            ]
        }
    }
}

private struct AppShadowModifier: ViewModifier {
    let level: AppElevation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch level {
        case .e0:
            content
        case .e1, .e2, .e3:
            let layers = level.layers
            content
                .shadow(color: layers[0].color, radius: layers[0].radius, x: layers[0].x, y: layers[0].y)
                .shadow(color: layers[1].color, radius: layers[1].radius, x: layers[1].x, y: layers[1].y)
        }
    }
}

extension View {
    /// Applies stacked shadows from the design-system elevation scale.
    func appShadow(_ level: AppElevation) -> some View {
        modifier(AppShadowModifier(level: level))
    }
}
