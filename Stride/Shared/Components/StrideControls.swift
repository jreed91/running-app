import SwiftUI

// MARK: - Route Loop controls
//
// The everyday controls in the Route Loop identity: buttons, the segmented control,
// progress bars, text fields, list and sheet grounds, and empty states. They follow the
// same rules as the heroes and cards in `RouteLoop.swift`:
//
// - the route gradient means *progress or go*: the primary button, a selected segment,
//   the filled part of a bar;
// - everything else sits on the page's own ground (`surfacePrimary`) as a card
//   (`surfaceSecondary` with a `cardStroke` hairline), in light and dark alike;
// - text on the route is `onFill`, never white (white on orange is 2.8:1).

// MARK: Buttons

/// How loud a `StrideButtonStyle` button is.
enum StrideButtonProminence {
    /// The screen's one main action: the route, with `onFill` text.
    case primary
    /// A supporting action: a brand tint with `brandText`.
    case secondary
    /// A neutral action: a card with a hairline and primary text.
    case quiet
    /// An action that removes something: a destructive tint with destructive text.
    case destructive
}

/// The app's button. Replaces `.borderedProminent` / `.bordered` and the hand-rolled
/// brand-filled labels, so every button has the same shape, height and press.
///
/// The style sets the font, padding and ground; labels bring only their text and icon.
/// A label's own `.font` still wins, for the few buttons that need a different size.
struct StrideButtonStyle: ButtonStyle {
    var prominence: StrideButtonProminence = .primary
    /// A smaller button for rows and card footers.
    var compact = false
    /// Whether the button fills the width it is offered.
    var fullWidth = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? AppRadius.md : AppRadius.lg, style: .continuous)
        configuration.label
            .font(compact ? .dsFootnote.weight(.semibold) : .bodyStrong)
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .padding(.vertical, compact ? AppSpacing.sm : AppSpacing.md)
            .padding(.horizontal, compact ? AppSpacing.md : AppSpacing.xl)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: compact ? 36 : 50)
            .background { ground(shape) }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(reduceMotion ? nil : AppAnimation.snappy, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch prominence {
        case .primary:     return .onFill
        case .secondary:   return .brandText
        case .quiet:       return .primary
        case .destructive: return .destructive
        }
    }

    @ViewBuilder
    private func ground(_ shape: RoundedRectangle) -> some View {
        switch prominence {
        case .primary:
            shape.fill(.route)
        case .secondary:
            shape.fill(Color.brand.opacity(0.12))
                .overlay(shape.strokeBorder(Color.brand.opacity(0.22), lineWidth: 1))
        case .quiet:
            shape.fill(.surfaceSecondary)
                .overlay(shape.strokeBorder(.cardStroke, lineWidth: 1))
        case .destructive:
            shape.fill(Color.destructive.opacity(0.12))
        }
    }
}

extension ButtonStyle where Self == StrideButtonStyle {
    /// `.buttonStyle(.strideButton())` for the primary action,
    /// `.buttonStyle(.strideButton(.secondary, compact: true))` for a row action.
    static func strideButton(
        _ prominence: StrideButtonProminence = .primary,
        compact: Bool = false,
        fullWidth: Bool = true
    ) -> StrideButtonStyle {
        StrideButtonStyle(prominence: prominence, compact: compact, fullWidth: fullWidth)
    }
}

// MARK: Chips

/// A pill that can be on or off: filters, suggestions, quick replies. On, it takes the
/// route; off, it is a card with a hairline. Turning on, the route fades in under the
/// label with a small press-and-settle, so the change is felt as well as seen.
struct StrideChipStyle: ButtonStyle {
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsFootnote.weight(.semibold))
            .foregroundStyle(isSelected ? Color.onFill : Color.primary)
            .padding(.vertical, AppSpacing.sm)
            .padding(.horizontal, AppSpacing.md)
            .background {
                if isSelected {
                    Capsule().fill(.route)
                } else {
                    Capsule().fill(.surfaceSecondary)
                        .overlay(Capsule().strokeBorder(.cardStroke, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : AppAnimation.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? AppAnimation.reduced : AppAnimation.bouncy, value: isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension ButtonStyle where Self == StrideChipStyle {
    static func strideChip(selected: Bool = false) -> StrideChipStyle {
        StrideChipStyle(isSelected: selected)
    }
}

// MARK: Segmented control

/// The app's segmented control: a card track with the route sliding under the chosen
/// segment. For pickers that sit in the page rather than in a `Form` (those keep the
/// system control, which `AppChrome` tints to match).
struct StrideSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    /// Kept for existing callers. Every segment now has tabular digits; this used to switch
    /// to SF Mono, a typewriter face no other control uses.
    var monospaced = false
    let title: (Value) -> Text
    /// An optional second line under each title, for choices that need a hint
    /// ("km · min/km"). Segments with one grow taller; the route still slides.
    var subtitle: ((Value) -> Text)?

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        selection: Binding<Value>,
        options: [Value],
        monospaced: Bool = false,
        title: @escaping (Value) -> Text,
        subtitle: ((Value) -> Text)? = nil
    ) {
        _selection = selection
        self.options = options
        self.monospaced = monospaced
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    // The route slides to the new segment; under Reduce Motion it moves
                    // there at once rather than travelling across the track.
                    withAnimation(reduceMotion ? nil : AppAnimation.bouncy) { selection = option }
                } label: {
                    VStack(spacing: 3) {
                        title(option)
                            .font(.dsSubhead.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let subtitle {
                            subtitle(option)
                                .font(.dsCaption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, subtitle == nil ? AppSpacing.sm : AppSpacing.md)
                    .foregroundStyle(isSelected ? Color.onFill : Color.secondary)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                .fill(.route)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(BouncyButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(AppSpacing.xs)
        .strideCard(cornerRadius: AppRadius.md)
    }
}

// MARK: Progress bar

/// A linear progress bar: the route filling a `surfaceTertiary` track, with round caps.
/// `tint` replaces the route for a bar that means something else (a met goal in
/// `success`, a worn shoe in `warning`).
///
/// The bar draws itself in from empty when it first appears, as the app mark's route and
/// the Home ring do, and slides to a new value when it changes. Under Reduce Motion it
/// appears already filled.
struct StrideProgressBar: View {
    let value: Double
    var tint: Color?
    var height: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        let fraction = min(max(value.isFinite ? value : 0, 0), 1)
        let shown = hasAppeared || reduceMotion ? fraction : 0
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.surfaceTertiary)
                Group {
                    if let tint {
                        Capsule().fill(tint)
                    } else {
                        Capsule().fill(.route)
                    }
                }
                // A sliver of a capsule draws as a dot rather than nothing, so a started
                // bar never looks empty.
                .frame(width: shown > 0 ? max(proxy.size.width * shown, height) : 0)
            }
        }
        .frame(height: height)
        .adaptiveAnimation(AppAnimation.gentle, value: shown)
        .onAppear { hasAppeared = true }
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: Tags

/// A small label that isn't a control: a duration, a weight, a muscle group. It reads as a
/// chip at rest, so it shares the chip's shape, but nothing presses or selects it.
struct StrideTag: View {
    enum Tone {
        /// A fact about the thing: the card ground with its hairline, secondary text.
        case neutral
        /// A category the brand picks out: brand at 12% with `brandText`.
        case brand
    }

    let text: String
    var systemImage: String?
    var tone: Tone = .neutral

    init(_ text: String, systemImage: String? = nil, tone: Tone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.dsCaption2)
            }
            Text(text)
                .font(.dsCaption.weight(.semibold))
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .foregroundStyle(tone == .brand ? AnyShapeStyle(Color.brandText) : AnyShapeStyle(.secondary))
        .background {
            switch tone {
            case .neutral:
                Capsule().fill(.surfaceSecondary)
                    .overlay(Capsule().strokeBorder(.cardStroke, lineWidth: 1))
            case .brand:
                Capsule().fill(Color.brand.opacity(0.12))
            }
        }
    }
}

// MARK: Tooltips and map labels

/// A chart's selected-point readout: a small card lifted off the chart (`e2`), so it reads
/// as the same material as every other card rather than system frosted glass.
struct StrideTooltip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.strideTooltip()
    }
}

extension View {
    /// See `StrideTooltip`.
    func strideTooltip() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        return padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 5)
            .background(.surfaceSecondary, in: shape)
            .overlay(shape.strokeBorder(.cardStroke, lineWidth: 1))
            .appShadow(.e2)
    }

    /// A label sitting on a map (the route's name): the tooltip's card, so a map label and
    /// a chart label look the same.
    func strideMapLabel() -> some View {
        font(.dsCaption2.weight(.semibold))
            .strideTooltip()
    }
}

// MARK: Text fields

/// A free-standing text field: a card with a hairline. Fields inside a `Form` keep the
/// form's own row and don't need it.
private struct StrideFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
        content
            .font(.dsBody)
            .padding(.vertical, AppSpacing.md)
            .padding(.horizontal, AppSpacing.lg)
            .background(.surfaceSecondary, in: shape)
            .overlay(shape.strokeBorder(.cardStroke, lineWidth: 1))
    }
}

// MARK: Page width

/// The widest a scrolling page's column of cards gets, padding included. Every iPhone
/// screen in portrait is narrower than this, so it changes nothing there. It exists for
/// iPhone Duo: the inner display is regular width in both orientations and about 950pt
/// across in landscape, where a full-width card turns a one-line headline into a long
/// thin strip and puts a card's leading label and trailing figure a hand-span apart.
/// 700 keeps the text column near UIKit's readable width at the default text size.
enum StrideLayout {
    static let readableWidth: CGFloat = 700
}

extension View {
    /// Caps a page's content column at `StrideLayout.readableWidth` and centres it, on
    /// the page's own ground. Apply it to the stack inside a `ScrollView`, after its
    /// padding, rather than to the `ScrollView`: the scroll view keeps the full width, so
    /// the page can still be dragged from its margins and the indicator stays at the edge.
    ///
    /// `hasColumns`: the page lays its cards out with `StrideColumns`, so it may grow to
    /// two columns' width. Below that it is one column, which is never wider than the
    /// one-column cap anyway.
    func strideReadableWidth(hasColumns: Bool = false) -> some View {
        frame(maxWidth: hasColumns ? StrideColumnsLayout.maximumWidth : StrideLayout.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Lists, forms and sheets

/// Puts a `List` or `Form` on the page's ground. Without it, a grouped list draws the
/// system's own grey and black, which is the mismatch the redesign removed: the rest of
/// the app is paper in light and ink in dark. Rows take `.strideListRow()`.
private struct StrideListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.surfacePrimary)
    }
}

extension View {
    /// See `StrideFieldModifier`.
    func strideField() -> some View {
        modifier(StrideFieldModifier())
    }

    /// See `StrideListModifier`.
    func strideList() -> some View {
        modifier(StrideListModifier())
    }

    /// A list row as a card: `surfaceSecondary`, matching `.strideCard()`. Apply to a
    /// `Section` and every row in it takes it.
    func strideListRow() -> some View {
        listRowBackground(Color.surfaceSecondary)
    }

    /// `.heroCard()` when this card is the screen's one hero, `.strideCard()` otherwise, for
    /// a card that is the hero only on some screens or in some states.
    @ViewBuilder
    func strideSurface(isHero: Bool, cornerRadius: CGFloat = AppRadius.lg) -> some View {
        if isHero {
            heroCard(cornerRadius: cornerRadius)
        } else {
            strideCard(cornerRadius: cornerRadius)
        }
    }

    /// A sheet on the page's ground, with the larger sheet radius. The system sheet is
    /// otherwise grey glass in light and black in dark.
    func strideSheet() -> some View {
        presentationBackground(Color.surfacePrimary)
            .presentationCornerRadius(AppRadius.xl)
    }
}

// MARK: Eyebrows

extension View {
    /// A section's eyebrow, the one header style in the app: 11pt bold capitals with
    /// open tracking. The caller picks the colour (`.secondary` on the page or a card,
    /// `brandText` on a hero) and where it sits; section headers go outside their card.
    func strideEyebrow() -> some View {
        font(.sectionHeader)
            .textCase(.uppercase)
            .tracking(1.4)
    }
}

// MARK: Empty states

/// An empty screen or section: what is missing, why, and the way forward.
///
/// Replaces `ContentUnavailableView` so empty states carry the identity: the symbol sits
/// on a small hero disc, the title is in the rounded display face, and the action is a
/// route button.
///
/// It arrives the way the start pin does: the disc lands with `pinDrop` and its symbol
/// bounces once, then the words and the action rise in behind it. Under Reduce Motion
/// it fades in whole.
struct StrideEmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text?
    @ViewBuilder let actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            ZStack {
                Circle().fill(.heroGround)
                Circle().strokeBorder(Color.brand.opacity(0.22), lineWidth: 1)
                Image(systemName: systemImage)
                    .font(.dsTitle1)
                    .foregroundStyle(.brandText)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: appeared && !reduceMotion)
            }
            .frame(width: 76, height: 76)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? AppAnimation.reduced : AppAnimation.pinDrop, value: appeared)
            .accessibilityHidden(true)
            .padding(.bottom, AppSpacing.xs)

            Text(title)
                .font(.dsTitle3)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .strideEntrance(appeared, delay: AppAnimation.stagger * 2, rise: 10)

            if let description {
                description
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .strideEntrance(appeared, delay: AppAnimation.stagger * 3, rise: 10)
            }

            VStack(spacing: AppSpacing.sm) {
                actions()
            }
            .buttonStyle(.strideButton(fullWidth: false))
            .padding(.top, AppSpacing.sm)
            .strideEntrance(appeared, delay: AppAnimation.stagger * 4, rise: 10)
        }
        .padding(.horizontal, AppSpacing.xxxl)
        .padding(.vertical, AppSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }
}

extension StrideEmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
