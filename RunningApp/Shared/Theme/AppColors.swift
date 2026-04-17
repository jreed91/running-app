import SwiftUI

extension Color {
    // MARK: Brand

    static let brand = Color("Brand")          // primary orange/green accent
    static let brandSecondary = Color("BrandSecondary")

    // MARK: Pace Zones

    static let zoneRecovery  = Color("ZoneRecovery")  // sky blue-cyan
    static let zoneEasy      = Color("ZoneEasy")       // blue
    static let zoneMarathon  = Color("ZoneMarathon")   // teal
    static let zoneTempo     = Color("ZoneTempo")      // yellow-orange
    static let zoneInterval  = Color("ZoneInterval")   // red
    static let zoneMax       = Color("ZoneMax")        // pink-red

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
