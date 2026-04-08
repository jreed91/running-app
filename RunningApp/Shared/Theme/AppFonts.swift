import SwiftUI

// MARK: - Type Scale

extension Font {
    // Metric / stat display (large numbers)
    static let metricLarge = Font.system(size: 56, weight: .bold, design: .rounded)
    static let metricMedium = Font.system(size: 36, weight: .bold, design: .rounded)
    static let metricSmall = Font.system(size: 24, weight: .semibold, design: .rounded)

    // Section & card headings
    static let sectionHeader = Font.system(size: 13, weight: .semibold).uppercaseSmallCaps()

    // Body
    static let bodyStrong = Font.system(size: 15, weight: .semibold)
    static let bodyRegular = Font.system(size: 15, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
}
