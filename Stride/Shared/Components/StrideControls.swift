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
/// route; off, it is a card with a hairline.
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
    var monospaced = false
    let title: (Value) -> Text

    @Namespace private var namespace

    init(
        selection: Binding<Value>,
        options: [Value],
        monospaced: Bool = false,
        title: @escaping (Value) -> Text
    ) {
        _selection = selection
        self.options = options
        self.monospaced = monospaced
        self.title = title
    }

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(AppAnimation.bouncy) { selection = option }
                } label: {
                    title(option)
                        .font(monospaced ? .dsSubhead.weight(.semibold).monospaced() : .dsSubhead.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.sm)
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
struct StrideProgressBar: View {
    let value: Double
    var tint: Color?
    var height: CGFloat = 8

    var body: some View {
        let fraction = min(max(value.isFinite ? value : 0, 0), 1)
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
                .frame(width: fraction > 0 ? max(proxy.size.width * fraction, height) : 0)
            }
        }
        .frame(height: height)
        .adaptiveAnimation(AppAnimation.gentle, value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
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

// MARK: Empty states

/// An empty screen or section: what is missing, why, and the way forward.
///
/// Replaces `ContentUnavailableView` so empty states carry the identity: the symbol sits
/// on a small hero disc, the title is in the rounded display face, and the action is a
/// route button.
struct StrideEmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text?
    @ViewBuilder let actions: () -> Actions

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
            }
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)
            .padding(.bottom, AppSpacing.xs)

            Text(title)
                .font(.dsTitle3)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if let description {
                description
                    .font(.dsSubhead)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppSpacing.sm) {
                actions()
            }
            .buttonStyle(.strideButton(fullWidth: false))
            .padding(.top, AppSpacing.sm)
        }
        .padding(.horizontal, AppSpacing.xxxl)
        .padding(.vertical, AppSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension StrideEmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
