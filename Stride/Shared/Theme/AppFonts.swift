import SwiftUI

// MARK: - Type Scale
//
// Mirrors the Stride design system tokens (running-app/project/tokens.jsx).
// Metrics use `.monospaced` (tabular figures) so digits don't jitter during an
// active run. UI copy uses SF Pro Text / SF Pro Display.
//
// Two rules keep this file honest:
//
// 1. **Never re-declare one of SwiftUI's own `Font` statics.** A `static let
//    caption` here shadowed `Font.caption` at every one of the ~115
//    `.font(.caption)` call sites in the app, silently swapping a dynamic-type
//    token for a fixed 12pt font and disabling Dynamic Type app-wide (N19). UI
//    tokens are therefore `ds`-prefixed, and a SwiftLint `custom_rules` entry
//    (`no_builtin_font_shadowing`) fails the build if the pattern comes back.
// 2. **UI copy scales; HUD metrics don't.** The `ds*` tokens are built from text
//    styles, so they track the user's preferred content size while keeping the
//    design system's default-size values. The `metric*` tokens stay fixed on
//    purpose: they sit in tight fixed-height grids and a 120pt hero that has no
//    room to grow.

extension Font {
    // MARK: Metrics (tabular mono, deliberately non-scaling)

    /// 96pt — full-bleed Active Run HUD hero.
    static let metricXL     = Font.system(size: 96, weight: .semibold, design: .monospaced)
    /// 64pt — secondary hero (distance, split).
    static let metricL      = Font.system(size: 64, weight: .semibold, design: .monospaced)
    /// 40pt — card headline metric.
    static let metricM      = Font.system(size: 40, weight: .semibold, design: .monospaced)
    /// 24pt — inline metric row (HR, cadence).
    static let metricS      = Font.system(size: 24, weight: .semibold, design: .monospaced)
    /// 11pt bold — the caption under a HUD metric.
    ///
    /// Fixed like the rest of the `metric` scale (rule 2), but pinned to Apple's
    /// 11pt legibility floor. The run HUD labelled every cell at 9pt — under the
    /// floor, on the one screen read at arm's length, outdoors, in motion (U2).
    static let metricLabel  = Font.system(size: 11, weight: .bold)

    // MARK: Legacy metric aliases (kept for existing call sites)

    /// 120pt bold — Active Run HUD current-pace display, per design spec.
    static let metricHero   = Font.system(size: 120, weight: .bold, design: .monospaced)
    static let metricLarge  = Font.system(size: 56, weight: .bold,     design: .monospaced)
    static let metricMedium = Font.system(size: 36, weight: .bold,     design: .monospaced)
    static let metricSmall  = Font.metricS

    // MARK: UI (SF Pro) — design-system scale
    //
    // Each token is the text style whose default size matches the design token, so
    // the rendered size is unchanged at the default content size and scales from
    // there. Prefixed with `ds` to avoid shadowing SwiftUI's dynamic-type statics
    // (Font.body, Font.largeTitle, Font.headline, …) — see rule 1 above.

    /// 34pt bold at default size.
    static let dsLargeTitle = Font.system(.largeTitle, weight: .bold)
    /// 28pt bold at default size.
    static let dsTitle1     = Font.system(.title, weight: .bold)
    /// 22pt bold at default size.
    static let dsTitle2     = Font.system(.title2, weight: .bold)
    /// 20pt semibold at default size.
    static let dsTitle3     = Font.system(.title3, weight: .semibold)
    /// 17pt semibold at default size.
    static let dsHeadline   = Font.system(.headline, weight: .semibold)
    /// 17pt regular at default size.
    static let dsBody       = Font.system(.body)
    /// 16pt regular at default size.
    static let dsCallout    = Font.system(.callout)
    /// 15pt regular at default size.
    static let dsSubhead    = Font.system(.subheadline)
    /// 13pt regular at default size.
    static let dsFootnote   = Font.system(.footnote)
    /// 12pt regular at default size.
    static let dsCaption    = Font.system(.caption)
    /// 11pt regular at default size — and the floor of the scale.
    ///
    /// The app had 90 call sites at 9–11pt before the migration. They all land here:
    /// `caption2` is the smallest text style Apple ships, 11pt is its legibility
    /// floor, and it scales from there (U2).
    static let dsCaption2   = Font.system(.caption2)

    // MARK: Section header

    /// 11pt bold uppercase small caps — group headers inside cards.
    static let sectionHeader = Font.system(.caption2, weight: .bold).uppercaseSmallCaps()

    // MARK: Legacy body aliases (kept for existing call sites)
    //
    // `caption` used to live here too. It is gone: `.font(.caption)` now resolves to
    // SwiftUI's own token, which is 12pt regular at the default content size — the
    // same rendering as before, but scaling with Dynamic Type (N19).

    static let bodyStrong    = Font.system(.subheadline, weight: .semibold)
    static let bodyRegular   = Font.system(.subheadline)
    static let captionStrong = Font.system(.caption, weight: .semibold)
}
