import SwiftUI

// MARK: - Colour

/// Stride's palette on the watch, resolved from the app's own asset catalog, which
/// `project.yml` compiles into this target the way it does into `StrideWidgets`. Asset
/// colours rather than RGB, so the watch and the phone are the same orange.
extension Color {
    static let strideBrand = Color("Brand")
    static let strideSuccess = Color("Success")
    static let strideZoneEasy = Color("ZoneEasy")
    static let strideZoneTempo = Color("ZoneTempo")
    static let strideZoneInterval = Color("ZoneInterval")
    /// The Route Loop's night-map ground, behind the week and race pages, so the orange
    /// ring and figures sit on it the way the loop sits on the icon.
    static let strideInk = Color("Ink")
}

extension ShapeStyle where Self == LinearGradient {
    /// The Route Loop gradient, amber start to orange end, as the phone draws progress.
    static var strideRoute: LinearGradient {
        LinearGradient(
            colors: [Color("BrandGlow"), Color("Brand")],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

extension WidgetSnapshot.Tint {
    /// The accent for a card. The same mapping as the widgets' `WidgetTheme.swift`, which
    /// lives in the extension's target and so cannot be shared from here.
    var color: Color {
        switch self {
        case .brand:    return .strideBrand
        case .easy:     return .strideZoneEasy
        case .tempo:    return .strideZoneTempo
        case .interval: return .strideZoneInterval
        case .success:  return .strideSuccess
        case .neutral:  return .secondary
        }
    }
}
