import SwiftUI

extension Color {
    // MARK: Brand

    static let brand = Color("Brand")          // primary orange/green accent
    static let brandSecondary = Color("BrandSecondary")

    /// Foreground for text and glyphs sitting on a **solid** `brand` fill.
    ///
    /// White on `Brand` measures 2.84:1 in light mode and 2.52:1 in dark — below
    /// even WCAG's 3.0:1 large-text bar, on the two most-tapped buttons in the app.
    /// The palette is vivid rather than dark, so every one of its fills clears AA
    /// comfortably with near-black instead (7.4–11.1:1). Use this anywhere a label
    /// sits directly on `Color.brand`; `.white` stays correct on the dark surfaces.
    static let onBrand = Color("OnBrand")

    // MARK: Pace Zones

    // The six zones are the app's core visual language — HUD background, calendar
    // dots, split charts, `PaceZoneIndicator` — so each needs its own light *and*
    // dark value. Dark mode used to render the six as four: ZoneEasy/ZoneMarathon
    // both resolved to #40C8E0 and ZoneInterval/ZoneMax both to #FF453A, so an easy
    // segment was indistinguishable from marathon pace, and an interval from a max
    // effort. Keep every dark variant distinct when editing these.
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
}

// Allows shorthand dot syntax when the expected type is `some ShapeStyle`,
// e.g. .background(.surfaceSecondary) or .fill(.brand).
extension ShapeStyle where Self == Color {
    static var brand: Color { Color("Brand") }
    static var brandSecondary: Color { Color("BrandSecondary") }
    static var onBrand: Color { Color("OnBrand") }
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
}
