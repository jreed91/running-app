import SwiftUI
import Testing
import UIKit
@testable import Stride

/// Guards the two palette properties the app's visual language depends on, both of
/// which had silently broken in the asset catalog:
///
///   1. The six pace zones must stay tellable apart in *both* appearances. Dark mode
///      used to render them as four — `ZoneEasy`/`ZoneMarathon` both resolved to
///      #40C8E0 and `ZoneInterval`/`ZoneMax` both to #FF453A — so an easy segment and
///      a marathon-pace segment were the same colour on the HUD, the calendar dots,
///      the split charts and `PaceZoneIndicator`.
///   2. Text sitting on a solid `Brand` fill must clear WCAG AA. White on `Brand`
///      measures 2.84:1 in light and 2.52:1 in dark — below even the 3.0:1 large-text
///      bar — which is why `Color.onBrand` exists.
///
/// Both are checked against the *resolved* colours rather than the JSON, so a change
/// to either appearance of any of these colorsets is covered.
@MainActor
struct PaletteContrastTests {

    // MARK: - Colour maths

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        /// WCAG relative luminance (sRGB → linear, then the standard weighting).
        var relativeLuminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.03928
                    ? channel / 12.92
                    : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// Straight-line distance in sRGB. Crude next to a perceptual metric, but it
        /// is the right shape of guard here: the failure being prevented is two zones
        /// sitting on or near the same point.
        func distance(to other: RGB) -> Double {
            let dr = red - other.red
            let dg = green - other.green
            let db = blue - other.blue
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
    }

    private func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> RGB {
        let resolved = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: Double(red), green: Double(green), blue: Double(blue))
    }

    private func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let a = first.relativeLuminance
        let b = second.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private let zones: [(name: String, color: Color)] = [
        ("ZoneRecovery", .zoneRecovery),
        ("ZoneEasy", .zoneEasy),
        ("ZoneMarathon", .zoneMarathon),
        ("ZoneTempo", .zoneTempo),
        ("ZoneInterval", .zoneInterval),
        ("ZoneMax", .zoneMax)
    ]

    private let styles: [(name: String, style: UIUserInterfaceStyle)] = [
        ("light", .light),
        ("dark", .dark)
    ]

    // MARK: - Tests

    /// The separation floor. The closest surviving pair is `ZoneInterval`/`ZoneMax` in
    /// dark at ~0.24; anything at or under 0.20 is the collision this test exists for.
    private let minimumZoneSeparation = 0.20

    @Test("Every pace zone is a distinct colour in both light and dark")
    func zonesAreDistinctInBothAppearances() {
        for (styleName, style) in styles {
            let resolved = zones.map { (name: $0.name, rgb: resolve($0.color, style)) }
            for first in resolved.indices {
                for second in resolved.indices where second > first {
                    let separation = resolved[first].rgb.distance(to: resolved[second].rgb)
                    #expect(
                        separation > minimumZoneSeparation,
                        """
                        \(resolved[first].name) and \(resolved[second].name) are \
                        \(String(format: "%.3f", separation)) apart in \(styleName) — \
                        too close to read as different training zones.
                        """
                    )
                }
            }
        }
    }

    @Test("Text on a solid Brand fill clears WCAG AA")
    func onBrandClearsAAOverBrand() {
        for (styleName, style) in styles {
            let ratio = contrastRatio(resolve(.brand, style), resolve(.onBrand, style))
            #expect(
                ratio >= 4.5,
                "onBrand over brand is \(String(format: "%.2f", ratio)):1 in \(styleName), below AA's 4.5:1."
            )
        }
    }

    /// The reason `onBrand` is not simply `.white`. Kept as an assertion rather than a
    /// comment so that lightening `Brand` far enough to make white legible would show
    /// up here as a prompt to revisit the token, not as a silent contradiction.
    @Test("White on Brand still fails AA, which is why onBrand exists")
    func whiteOverBrandFailsAA() {
        for (_, style) in styles {
            let ratio = contrastRatio(resolve(.brand, style), RGB(red: 1, green: 1, blue: 1))
            #expect(ratio < 4.5)
        }
    }
}
