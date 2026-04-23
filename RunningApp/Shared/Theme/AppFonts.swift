import SwiftUI

// MARK: - Type Scale
//
// Mirrors the Stride design system tokens (running-app/project/tokens.jsx).
// Metrics use `.monospaced` (tabular figures) so digits don't jitter during an
// active run. UI copy uses SF Pro Text / SF Pro Display.
// Names are prefixed to avoid clashing with SwiftUI's built-in Font statics.

extension Font {
    // MARK: Metrics (tabular mono)

    /// 96pt — full-bleed Active Run HUD hero.
    static let metricXL     = Font.system(size: 96, weight: .semibold, design: .monospaced)
    /// 64pt — secondary hero (distance, split).
    static let metricL      = Font.system(size: 64, weight: .semibold, design: .monospaced)
    /// 40pt — card headline metric.
    static let metricM      = Font.system(size: 40, weight: .semibold, design: .monospaced)
    /// 24pt — inline metric row (HR, cadence).
    static let metricS      = Font.system(size: 24, weight: .semibold, design: .monospaced)

    // MARK: Legacy metric aliases (kept for existing call sites)

    /// 120pt bold — Active Run HUD current-pace display, per design spec.
    static let metricHero   = Font.system(size: 120, weight: .bold, design: .monospaced)
    static let metricLarge  = Font.system(size: 56, weight: .bold,     design: .monospaced)
    static let metricMedium = Font.system(size: 36, weight: .bold,     design: .monospaced)
    static let metricSmall  = Font.metricS

    // MARK: UI (SF Pro) — design-system scale
    // Prefixed with `ds` to avoid shadowing SwiftUI's dynamic-type statics
    // (Font.body, Font.largeTitle, Font.headline, …).

    static let dsLargeTitle = Font.system(size: 34, weight: .bold)
    static let dsTitle1     = Font.system(size: 28, weight: .bold)
    static let dsTitle2     = Font.system(size: 22, weight: .bold)
    static let dsTitle3     = Font.system(size: 20, weight: .semibold)
    static let dsHeadline   = Font.system(size: 17, weight: .semibold)
    static let dsBody       = Font.system(size: 17, weight: .regular)
    static let dsCallout    = Font.system(size: 16, weight: .regular)
    static let dsSubhead    = Font.system(size: 15, weight: .regular)
    static let dsFootnote   = Font.system(size: 13, weight: .regular)
    static let dsCaption    = Font.system(size: 12, weight: .regular)

    // MARK: Section header

    /// 11pt bold uppercase small caps — group headers inside cards.
    static let sectionHeader = Font.system(size: 11, weight: .bold).uppercaseSmallCaps()

    // MARK: Legacy body aliases (kept for existing call sites)

    static let bodyStrong    = Font.system(size: 15, weight: .semibold)
    static let bodyRegular   = Font.system(size: 15, weight: .regular)
    static let caption       = Font.system(size: 12, weight: .regular)
    static let captionStrong = Font.system(size: 12, weight: .semibold)
}
