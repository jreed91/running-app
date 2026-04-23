import CoreGraphics

// MARK: - Corner radii
//
// Soft-rounded iOS geometry from the Stride design system (tokens.jsx).
// Never use 0 on interactive elements.

enum AppRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 26
    /// Fully-rounded pill — use on Capsules and circular chips.
    static let pill: CGFloat = 9_999
}
