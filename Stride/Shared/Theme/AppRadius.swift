import CoreGraphics

// MARK: - Corner radii
//
// Soft-rounded iOS geometry from the Stride design system (tokens.jsx).
// Never use 0 on interactive elements.
//
// ## Adopting the scale (U1)
//
// The scale was defined and then not used: the app drew 208 hardcoded
// `cornerRadius:` literals across 13 distinct values while these six sat at four
// call sites. Snapping 13 values onto 6 is a design decision, not a script, so
// here is the one that was made:
//
// **Adopt this scale as it stands rather than redesign it around the literals.**
// The alternative — re-pointing the tokens at the two most common literals (18
// and 22) — would have silently changed the four existing `AppRadius` call sites
// and discarded the values the design system actually shipped. Instead every
// literal snapped to its nearest token:
//
// | Was | Sites | Now | Delta |
// | --- | --- | --- | --- |
// | 1, 2, 3, 4 | 17 | `micro` (3) | ≤2 |
// | 8 | 14 | `xs` (6) | −2 |
// | 10 | 20 | `sm` (10) | — |
// | 12, 14, 16 | 104 | `md` (14) | ≤2 |
// | 18, 20 | 46 | `lg` (20) | ≤2 |
// | 22 | 4 | `xl` (26) | +4 |
//
// Nothing moves by more than 2pt except the four 22pt surfaces — the Active Run
// pace meter and the guided-workout banner — which are large floating cards where
// 26 is the intended reading. The two dominant card radii (14 → `md` for inner
// tiles, 18/20 → `lg` for cards) land exactly where `AchievementsView` already
// used the tokens by hand, so the app's existing rhythm is preserved.
//
// `.swiftlint.yml`'s `no_raw_corner_radius` keeps it adopted.

enum AppRadius {
    /// Chart bars, sparkline caps, legend swatches — anything under ~8pt on its
    /// short side, where a larger radius would round the element away entirely.
    static let micro: CGFloat = 3
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    /// The default radius for an inner tile inside a card.
    static let md: CGFloat = 14
    /// The default radius for a card.
    static let lg: CGFloat = 20
    /// Large floating surfaces: sheets, banners, the run pace meter.
    static let xl: CGFloat = 26
    /// Fully-rounded pill — use on Capsules and circular chips.
    static let pill: CGFloat = 9_999
}
