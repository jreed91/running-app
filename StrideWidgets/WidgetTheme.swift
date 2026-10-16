import SwiftUI
import WidgetKit

// MARK: - Container background

extension WidgetFamily {
    /// The Lock Screen and Smart Stack families. They are drawn over the wallpaper and
    /// tinted by the system, so they must not paint a background of their own.
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return true
        default:
            return false
        }
    }
}

extension View {
    /// Every Stride widget's container background, in one place.
    ///
    /// `containerBackground(for: .widget)` is not optional on iOS 17 and later — a widget
    /// without one is letterboxed inside its own slot — so the accessory families get a
    /// deliberate clear one rather than none at all.
    func strideWidgetBackground(_ family: WidgetFamily) -> some View {
        containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
    }
}

// MARK: - Colour

/// Stride's palette, resolved from this extension's own copy of the app's asset catalog —
/// a widget bundle cannot read the app's. `project.yml` lists `Assets.xcassets` in both
/// targets' sources for exactly this, so a widget and the screen it mirrors cannot drift
/// to two different oranges, and light/dark/increase-contrast keep working because these
/// are still asset colours rather than baked-in RGB.
extension Color {
    static let strideBrand = Color("Brand")
    static let strideSuccess = Color("Success")
    static let strideZoneEasy = Color("ZoneEasy")
    static let strideZoneTempo = Color("ZoneTempo")
    static let strideZoneInterval = Color("ZoneInterval")
}

/// The dot-syntax shorthand, so `.foregroundStyle(.strideBrand)` resolves where the
/// expected type is `some ShapeStyle` rather than `Color`. Same two-part shape as the
/// app's `AppColors.swift`, and the reason `.strideBrand` works in `RunLiveActivity`.
/// Each name is spelled out again rather than delegating to the `Color` statics above:
/// with `Self == Color` the two sets are the same lookup, so `{ .strideBrand }` here
/// would resolve to this property rather than that one and recurse. `AppColors.swift`
/// repeats itself for the same reason.
extension ShapeStyle where Self == Color {
    static var strideBrand: Color { Color("Brand") }
    static var strideSuccess: Color { Color("Success") }
    static var strideZoneEasy: Color { Color("ZoneEasy") }
    static var strideZoneTempo: Color { Color("ZoneTempo") }
    static var strideZoneInterval: Color { Color("ZoneInterval") }
}

extension ShapeStyle where Self == LinearGradient {
    /// The Route Loop gradient, amber start to orange end — the app's `LinearGradient.route`
    /// rebuilt from this target's copy of the asset catalog.
    static var strideRoute: LinearGradient {
        LinearGradient(
            colors: [Color("BrandGlow"), Color("Brand")],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

extension WidgetSnapshot.Tint {
    /// The accent the app would use for the same thing. Mirrors `WorkoutType.color`,
    /// via the name the snapshot carries.
    var color: Color {
        switch self {
        case .brand:    return .strideBrand
        case .easy:     return .strideZoneEasy
        case .tempo:    return .strideZoneTempo
        case .interval: return .strideZoneInterval
        case .success:  return .strideSuccess
        case .neutral:  return .secondary
        }
    }
}

// MARK: - WidgetCardHeader

/// The kerned, tinted, all-caps line every Stride card starts with — the same one the
/// Live Activity uses, so a widget and the Lock Screen read as the same product.
struct WidgetCardHeader: View {
    /// A `Text`, not a `LocalizedStringKey`: some headers are literals the compiler
    /// should extract ("Weekly Goal"), and others are strings the *app* already localized
    /// and shipped in the snapshot ("Today"). Passing the latter as a key would send an
    /// already-translated string back through lookup as if it were one.
    let title: Text
    var symbolName: String?
    var tint: Color = .strideBrand

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .imageScale(.small)
            }
            title
                .kerning(1.2)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
    }
}

// MARK: - WidgetMetric

/// One labelled figure, laid out like the run HUD's metric cells and the Live Activity's.
struct WidgetMetric<Value: View>: View {
    let label: LocalizedStringKey
    var alignment: HorizontalAlignment = .leading
    let value: Value

    init(
        label: LocalizedStringKey,
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder value: () -> Value
    ) {
        self.label = label
        self.alignment = alignment
        self.value = value()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            value
                .font(.headline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - WidgetProgressRing

/// A goal ring. Hand-drawn rather than a `Gauge` because the system gauge styles are
/// sized for the accessory families — at `systemSmall` this needs to be the card's
/// subject, not a 20pt dial.
struct WidgetProgressRing<Label: View>: View {
    let fraction: Double
    var tint: Color = .strideBrand
    var lineWidth: CGFloat = 9
    let label: Label

    init(
        fraction: Double,
        tint: Color = .strideBrand,
        lineWidth: CGFloat = 9,
        @ViewBuilder label: () -> Label
    ) {
        self.fraction = fraction
        self.tint = tint
        self.lineWidth = lineWidth
        self.label = label()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(progressStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
        // The ring is decoration; the figures inside it are the content, and they are
        // already spoken. Without this VoiceOver reads two empty `Circle`s first.
        .accessibilityHidden(true)
    }

    /// A brand ring is the route, as in the app; any other tint (a met goal, a zone)
    /// stays flat so it still reads as that state.
    private var progressStyle: AnyShapeStyle {
        tint == .strideBrand ? AnyShapeStyle(.strideRoute) : AnyShapeStyle(tint)
    }
}

// MARK: - WidgetEmptyState

/// What every widget shows when there is nothing behind it: a fresh install whose app has
/// not been opened since the widget was added, a snapshot that has gone stale, or a
/// missing App Group. All three mean the same thing to the runner — open Stride — so they
/// all render the same card rather than three different apologies.
struct WidgetEmptyState: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey = "Open Stride to sync"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetCardHeader(title: Text(title), symbolName: "figure.run")
            Spacer(minLength: 0)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
