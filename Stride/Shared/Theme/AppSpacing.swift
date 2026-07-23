import CoreGraphics

// MARK: - Spacing scale
//
// 4pt grid matching the Stride design system (tokens.jsx). Use `AppSpacing.md`
// (12) as the default card padding.

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 40
    static let hero: CGFloat = 56
}
