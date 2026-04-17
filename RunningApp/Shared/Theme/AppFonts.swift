import SwiftUI

// MARK: - Type Scale

extension Font {
    // Metric / stat display — monospaced tabular digits (sporty/technical per design)
    static let metricLarge  = Font.system(size: 56, weight: .bold,     design: .monospaced)
    static let metricMedium = Font.system(size: 36, weight: .bold,     design: .monospaced)
    static let metricSmall  = Font.system(size: 24, weight: .semibold, design: .monospaced)
    // Hero size used in the Active Run full-bleed HUD
    static let metricHero   = Font.system(size: 96, weight: .bold,     design: .monospaced)

    // Section & card headings
    static let sectionHeader = Font.system(size: 11, weight: .bold).uppercaseSmallCaps()

    // Body
    static let bodyStrong   = Font.system(size: 15, weight: .semibold)
    static let bodyRegular  = Font.system(size: 15, weight: .regular)
    static let caption      = Font.system(size: 12, weight: .regular)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
}
