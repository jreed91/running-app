import CoreGraphics
import Foundation

// MARK: - ShareCardFormat

/// The shapes a run card is made in, one per place runners post them.
///
/// Every format is designed at a third of its export size and rendered at ×3, the same
/// rule the original 4:5 card used, so text and strokes stay crisp at full size.
enum ShareCardFormat: String, CaseIterable, Identifiable, Sendable {
    /// 9:16, 1080×1920: an Instagram or Strava story.
    case story
    /// 4:5, 1080×1350: an Instagram feed post. The card Stride always made.
    case portrait
    /// 1:1, 1080×1080: a photo on a Strava activity, which crops to a square in the feed.
    case square
    /// Stats and route with no background, to lay over a photo. Shared as a PNG with
    /// transparency, or copied to paste as a sticker in an Instagram story.
    case sticker

    var id: String { rawValue }

    /// Render scale every format uses.
    static let renderScale: CGFloat = 3

    /// Design size in points; ×3 gives the exported pixel size.
    var size: CGSize {
        switch self {
        case .story:    return CGSize(width: 360, height: 640)
        case .portrait: return CGSize(width: 360, height: 450)
        case .square:   return CGSize(width: 360, height: 360)
        case .sticker:  return CGSize(width: 300, height: 300)
        }
    }

    /// Exported size in pixels.
    var pixelSize: CGSize {
        CGSize(width: size.width * Self.renderScale, height: size.height * Self.renderScale)
    }

    /// Size of the route panel in points, which is also the map snapshot's size so the
    /// tiles map 1:1. The card is `size.width` wide with 20 pt padding each side. The
    /// sticker has no map, only the drawn line, so its panel is the line's box.
    var routePanelSize: CGSize {
        let width = size.width - 40
        switch self {
        case .story:    return CGSize(width: width, height: 300)
        case .portrait: return CGSize(width: width, height: 150)
        case .square:   return CGSize(width: width, height: 110)
        case .sticker:  return CGSize(width: 120, height: 120)
        }
    }

    /// Whether the card has a map behind the route. The sticker draws the line alone,
    /// so the photo under it shows through.
    var showsMap: Bool { self != .sticker }

    /// Whether the card has room for the split bars.
    var showsSplits: Bool { self == .story || self == .portrait }

    /// Whether the exported image keeps transparency.
    var isTransparent: Bool { self == .sticker }

    /// Name on the format picker.
    var title: String {
        switch self {
        case .story:    return String(localized: "Story", comment: "Share card format")
        case .portrait: return String(localized: "Post", comment: "Share card format")
        case .square:   return String(localized: "Square", comment: "Share card format")
        case .sticker:  return String(localized: "Sticker", comment: "Share card format")
        }
    }

    /// One line under the picker on where the format fits.
    var hint: String {
        switch self {
        case .story:
            return String(localized: "For an Instagram or Strava story.", comment: "Share card format hint")
        case .portrait:
            return String(localized: "For an Instagram post.", comment: "Share card format hint")
        case .square:
            return String(localized: "Add it as a photo on your Strava activity.", comment: "Share card format hint")
        case .sticker:
            return String(localized: "No background. Copy it and paste it onto a photo in your Instagram story.", comment: "Share card format hint")
        }
    }
}

// MARK: - StrideLinks

/// Where a shared card sends people who want the app.
enum StrideLinks {
    /// The landing page, short enough to read off a card and type.
    static let landingPageDisplay = "jacobreed.dev/stride"
    /// The landing page itself. `www` because the bare domain redirects there.
    static let landingPage = URL(string: "https://www.jacobreed.dev/stride")
    /// The App Store listing (id 6763807505).
    static let appStore = URL(string: "https://apps.apple.com/app/id6763807505")
}
