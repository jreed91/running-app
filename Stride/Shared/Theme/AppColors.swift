import SwiftUI

extension Color {
    // MARK: Brand

    /// The route's orange — the end of the Route Loop gradient, and the app's accent.
    static let brand = Color("Brand")
    /// The route's amber — where the Route Loop gradient starts. Pair with `brand`
    /// through `LinearGradient.route`; on its own it is a highlight, never text on a
    /// light surface (1.9:1 on white).
    static let brandGlow = Color("BrandGlow")
    /// Orange for *text and small glyphs*: eyebrows, links, inline figures. `brand` is
    /// 3.1:1 on white, too light for text under 24pt; this is `#C2410C` in light (4.7:1
    /// on the page, 4.5:1 on a hero) and the brand orange itself in dark (7:1).
    static let brandText = Color("BrandText")
    /// A data colour for a second chart series (VO₂ max). Not part of the brand.
    static let brandSecondary = Color("BrandSecondary")

    // MARK: Ink — the night-map ground of the Route Loop identity

    /// The always-dark navy of the app icon: the app mark, the share card and the dark
    /// appearance's ground. In-app heroes use `heroGround`, which follows the appearance,
    /// so a light page never carries a dark card.
    static let ink = Color("Ink")
    /// The icon's darkest stop: the bottom of an ink gradient.
    static let inkDeep = Color("InkDeep")
    /// Primary text and glyphs on `ink` (14:1).
    static let onInk = Color("OnInk")
    /// Secondary text on `ink` (7:1).
    static let onInkMuted = Color("OnInkMuted")
    /// The faint map-grid line drawn by `MapGridPattern` on page surfaces. On `ink`
    /// use `MapGridPattern(onInk: true)`, which draws in white.
    static let mapGrid = Color("MapGrid")

    // MARK: Hero and card chrome — one ground per appearance

    /// The top of a hero card: a warm dawn tint in light, raised ink in dark. Paired with
    /// `heroBottom` by `LinearGradient.heroGround`; see `.heroCard()`.
    static let heroTop = Color("HeroTop")
    /// The bottom of a hero card: the card colour itself, so a hero reads as a card that
    /// catches the light rather than a different object on the page.
    static let heroBottom = Color("HeroBottom")
    /// The hairline around cards and heroes: ink 8% in light, white 8% in dark.
    static let cardStroke = Color("CardStroke")

    // MARK: Pace Zones

    static let zoneRecovery  = Color("ZoneRecovery")  // system blue
    static let zoneEasy      = Color("ZoneEasy")       // sky blue
    static let zoneMarathon  = Color("ZoneMarathon")   // teal
    static let zoneTempo     = Color("ZoneTempo")      // amber
    static let zoneInterval  = Color("ZoneInterval")   // red
    static let zoneMax       = Color("ZoneMax")        // deep red

    // MARK: Backgrounds

    static let surfacePrimary = Color("SurfacePrimary")
    static let surfaceSecondary = Color("SurfaceSecondary")
    static let surfaceTertiary = Color("SurfaceTertiary")

    // MARK: Semantic

    static let success = Color("Success")
    static let warning = Color("Warning")
    static let destructive = Color("Destructive")

    // MARK: On-fill foreground

    /// Foreground for text and glyphs that sit **on** one of the saturated light
    /// fills — `brand`, `success`, `warning`, `zoneTempo`, `zoneEasy`.
    ///
    /// Those fills are vivid rather than dark, so white on them lands at 2.0–2.8:1
    /// and fails WCAG AA even at the 3.0 large-text bar: the two primary CTAs sat
    /// at 2.84:1 (U3a). This near-black reads at 6.5–9:1 on the same fills, and
    /// goes to pure black under Increase Contrast.
    ///
    /// Not for `zoneMax`, `zoneInterval` or `zoneRecovery` — those are dark enough
    /// that white is the higher-contrast choice on them.
    static let onFill = Color("OnFill")
}

// Allows shorthand dot syntax when the expected type is `some ShapeStyle`,
// e.g. .background(.surfaceSecondary) or .fill(.brand).
extension ShapeStyle where Self == Color {
    static var brand: Color { Color("Brand") }
    static var brandGlow: Color { Color("BrandGlow") }
    static var brandText: Color { Color("BrandText") }
    static var heroTop: Color { Color("HeroTop") }
    static var heroBottom: Color { Color("HeroBottom") }
    static var cardStroke: Color { Color("CardStroke") }
    static var brandSecondary: Color { Color("BrandSecondary") }
    static var ink: Color { Color("Ink") }
    static var inkDeep: Color { Color("InkDeep") }
    static var onInk: Color { Color("OnInk") }
    static var onInkMuted: Color { Color("OnInkMuted") }
    static var mapGrid: Color { Color("MapGrid") }
    static var zoneRecovery: Color  { Color("ZoneRecovery") }
    static var zoneEasy: Color      { Color("ZoneEasy") }
    static var zoneMarathon: Color  { Color("ZoneMarathon") }
    static var zoneTempo: Color     { Color("ZoneTempo") }
    static var zoneInterval: Color  { Color("ZoneInterval") }
    static var zoneMax: Color       { Color("ZoneMax") }
    static var surfacePrimary: Color { Color("SurfacePrimary") }
    static var surfaceSecondary: Color { Color("SurfaceSecondary") }
    static var surfaceTertiary: Color { Color("SurfaceTertiary") }
    static var success: Color { Color("Success") }
    static var warning: Color { Color("Warning") }
    static var destructive: Color { Color("Destructive") }
    static var onFill: Color { Color("OnFill") }
}

// MARK: - Route Loop gradients

// Declared once, on `ShapeStyle where Self == LinearGradient`, so both
// `.fill(.route)` and `LinearGradient.route` resolve here. A second copy on
// `extension LinearGradient` would be the same lookup and recurse (see the note in
// StrideWidgets/WidgetTheme.swift).
extension ShapeStyle where Self == LinearGradient {
    /// The route line: amber where it starts, orange where it ends. The one gradient in
    /// the identity — progress, primary actions and drawn routes use it, nothing else.
    static var route: LinearGradient {
        LinearGradient(
            colors: [Color("BrandGlow"), Color("Brand")],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    /// A hero card's ground: `heroTop` to `heroBottom`. Warm paper in light, raised ink
    /// in dark — never a dark card on a light page.
    static var heroGround: LinearGradient {
        LinearGradient(
            colors: [Color("HeroTop"), Color("HeroBottom")],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }

    /// The night-map ground: `ink` at the top to `inkDeep` at the bottom, as on the icon.
    static var inkGround: LinearGradient {
        LinearGradient(
            colors: [Color("Ink"), Color("InkDeep")],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
