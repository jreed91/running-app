import SwiftUI

// MARK: - Elevation
//
// Four shadow levels mirroring the Stride design system (tokens.jsx).
// iOS is mostly flat; reserve elevation for floating controls, popovers,
// and sheets. Each level is expressed as a pair of stacked shadows via
// the `.appShadow(_:)` view modifier.
//
// ## Why this scale had no call sites (U1)
//
// The app drew 26 inline `.shadow(...)` calls while this file sat unused, and the
// reason turned out to be a real gap rather than neglect: **19 of those 26 were
// brand-coloured glows, not elevation.** A glow says "this is the thing to tap";
// elevation says "this is above the page". A neutral scale cannot express the
// first, so every CTA hand-rolled its own. `AppGlow` below closes that gap.
//
// The remaining five were genuine elevation, and `e1`/`e2` have been retuned to
// the shadows those sites actually needed (both levels had zero call sites, so
// nothing moved): `e1` is now a soft card-rest shadow rather than a hairline, and
// `e2` a tooltip/popover lift. `e3` is unchanged.
//
// `.swiftlint.yml`'s `no_inline_shadow` keeps both scales adopted.

enum AppElevation {
    /// Flat on the page — draws nothing. Use as the "off" side of a conditional
    /// (`.appShadow(isSelected ? .e2 : .e0)`), which keeps one view identity and
    /// animates between the two states.
    case e0
    /// A card at rest on the page background.
    case e1
    /// Raised above the page: tooltips, popovers, a selected chip.
    case e2
    /// Floating free: the app mark, modal surfaces.
    case e3
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
            // Two clear layers rather than none, so `.e0` takes the same code path as
            // every other level — see `AppShadowModifier`.
            return [
                ShadowLayer(color: .clear, radius: 0, x: 0, y: 0),
                ShadowLayer(color: .clear, radius: 0, x: 0, y: 0),
            ]
        case .e1:
            return [
                ShadowLayer(color: .black.opacity(0.03), radius: 1, x: 0, y: 1),
                ShadowLayer(color: .black.opacity(0.04), radius: 6, x: 0, y: 2),
            ]
        case .e2:
            return [
                ShadowLayer(color: .black.opacity(0.10), radius: 4, x: 0, y: 2),
                ShadowLayer(color: .black.opacity(0.05), radius: 10, x: 0, y: 6),
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

    func body(content: Content) -> some View {
        // Every level draws both layers — `.e0`'s are clear — rather than branching on
        // the level. A `switch` here would put the raised and flat states in different
        // arms of a `ViewBuilder`, so a control that changes elevation with selection
        // would be torn down and rebuilt instead of animating between the two.
        let layers = level.layers
        return content
            .shadow(color: layers[0].color, radius: layers[0].radius, x: layers[0].x, y: layers[0].y)
            .shadow(color: layers[1].color, radius: layers[1].radius, x: layers[1].x, y: layers[1].y)
    }
}

// MARK: - Glow
//
// The tinted counterpart to elevation. A glow is the fill colour bleeding out
// from under a control, and it carries emphasis rather than height — so it is
// always drawn in the control's own colour, never in black.

enum AppGlow {
    /// A tight halo around a small marker: a progress capsule, a today dot.
    case halo
    /// A selected chip or a small tinted tile.
    case subtle
    /// A tinted control at rest: a coach avatar, a plan badge, a capsule button.
    case standard
    /// A primary CTA — the widest, warmest spread in the app.
    case strong
}

private extension AppGlow {
    var opacity: Double {
        switch self {
        case .halo:     return 0.55
        case .subtle:   return 0.35
        case .standard: return 0.35
        case .strong:   return 0.45
        }
    }

    var radius: CGFloat {
        switch self {
        case .halo:     return 6
        case .subtle:   return 8
        case .standard: return 10
        case .strong:   return 14
        }
    }

    var offsetY: CGFloat {
        switch self {
        case .halo:     return 0
        case .subtle:   return 3
        case .standard: return 4
        case .strong:   return 7
        }
    }
}

extension View {
    /// Applies stacked shadows from the design-system elevation scale.
    func appShadow(_ level: AppElevation) -> some View {
        modifier(AppShadowModifier(level: level))
    }

    /// Applies a coloured glow from the design-system emphasis scale.
    ///
    /// `isActive` fades the glow to `.clear` rather than removing the modifier,
    /// so a control that glows only when selected keeps one view identity and
    /// animates between the two states instead of snapping.
    func appGlow(_ level: AppGlow, color: Color, isActive: Bool = true) -> some View {
        shadow(
            color: isActive ? color.opacity(level.opacity) : .clear,
            radius: level.radius,
            y: level.offsetY
        )
    }
}
