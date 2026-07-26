import SwiftUI

extension Color {
    // MARK: Brand

    static let brand = Color("Brand")          // primary orange/green accent
    static let brandSecondary = Color("BrandSecondary")

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
    static var brandSecondary: Color { Color("BrandSecondary") }
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
