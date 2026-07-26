import CoreGraphics

// MARK: - Spacing scale
//
// 4pt grid matching the Stride design system (tokens.jsx). Use `AppSpacing.md`
// (12) as the default card padding.
//
// Adoption (U1): this scale had 18 call sites against 353 numeric `.padding()`
// literals, and it is the one token scale that was *not* migrated by snapping every
// literal to its nearest token — the way `AppRadius` was. A corner radius moving 2pt is
// decorative; padding moving 2pt is a density change on every card in the app at once.
//
// So the rule here is exact matches only. Every literal that already *was* a token value
// now names the token (207 of them), which is a provably zero-pixel change. The 146 that
// sit off the 4pt grid — 3, 5, 6, 7, 9, 10, 11, 14, 18, 21, 22, 26, 28, 38, 44, 48, 62,
// 120 — stay as literals, deliberately: 14 and 18 alone account for 56 of them, and
// deciding whether each is a 12, a 16 or a genuine one-off is a design pass with a device
// in hand, not a refactor.
//
// Consequences worth knowing before changing a value below: because adoption is partial,
// re-pointing `lg` at 18 would move the 90 sites that say `AppSpacing.lg` and leave the
// 15 that say `18` where they are. There is deliberately no SwiftLint rule guarding this
// scale (unlike `no_fixed_font_size` and `no_raw_corner_radius`) for the same reason — a
// raw padding is still a legitimate thing to write.

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
