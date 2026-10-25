import SwiftUI

// MARK: Two columns where there's room

/// A page's cards in two columns when the page is wide enough, and in one when it isn't.
///
/// Built for iPhone Duo's inner display, where a single column of phone-width cards wastes
/// half the screen in landscape (Apple: "avoid simply stretching the iPhone app"). It is
/// decided by the width the page actually has, not by device or size class: the inner
/// display is regular width in portrait too, but at about 670pt two columns would be two
/// cards narrower than any iPhone, so it keeps one there, and a Split View half does too.
///
/// One column is always `leading` followed by `trailing`, so splitting a page's stack into
/// the two keeps its order on every other iPhone exactly as it was.
///
/// When iPhone Duo has a fold running down the page, the gap between the columns is put on
/// it, so no card is creased. The fold is read with `.includeInactive`: fully open, the
/// fold is inactive but still has a frame, and keeping the gap there means the columns
/// don't jump when the phone is half-closed (Apple's advice on `ReservedRegion`).
struct StrideColumns<Leading: View, Trailing: View>: View {
    private let spacing: CGFloat
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    /// The fold's horizontal span in this view's coordinates, when one runs top to bottom.
    @State private var fold: ClosedRange<CGFloat>?

    init(
        spacing: CGFloat = AppSpacing.lg,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.spacing = spacing
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        StrideColumnsLayout(spacing: spacing, fold: fold) {
            VStack(alignment: .leading, spacing: spacing) { leading() }
            VStack(alignment: .leading, spacing: spacing) { trailing() }
        }
        .onGeometryChange(for: ClosedRange<CGFloat>?.self) { proxy in
            guard #available(iOS 27.1, *) else { return nil }
            // A division taller than it is wide is a fold held like a book. One held like
            // a laptop runs across the page, and a scrolling page doesn't need to avoid it.
            return proxy
                .reservedRegions(kind: .division, options: .includeInactive)
                .first { $0.frame.height > $0.frame.width }
                .map { $0.frame.minX...$0.frame.maxX }
        } action: { span in
            fold = span
        }
    }
}

/// The layout behind `StrideColumns`. Exactly two subviews: the leading and trailing stacks.
struct StrideColumnsLayout: Layout {
    var spacing: CGFloat
    var fold: ClosedRange<CGFloat>?

    /// The narrowest a column may be: a little narrower than the narrowest iPhone in
    /// portrait, which every card here is already laid out for.
    static let minimumColumnWidth: CGFloat = 340

    /// The widest two columns get, padding included. See `StrideLayout.readableWidth` for
    /// one column.
    static let maximumWidth: CGFloat = 1000

    private struct Columns {
        var leadingWidth: CGFloat
        var gap: CGFloat
        var trailingWidth: CGFloat
    }

    /// The two columns for a width, or nil when it only has room for one.
    private func columns(for width: CGFloat) -> Columns? {
        let minimum = Self.minimumColumnWidth
        guard width >= minimum * 2 + spacing else { return nil }
        if let fold, fold.lowerBound >= minimum, width - fold.upperBound >= minimum {
            return Columns(
                leadingWidth: fold.lowerBound,
                gap: fold.upperBound - fold.lowerBound,
                trailingWidth: width - fold.upperBound
            )
        }
        let column = (width - spacing) / 2
        return Columns(leadingWidth: column, gap: spacing, trailingWidth: column)
    }

    /// As `columns(for:)`, but one column when either side is empty (a chart with no data,
    /// a card that isn't shown today): half a row standing empty reads as a mistake, so the
    /// other side takes the whole width instead.
    private func columns(
        for width: CGFloat,
        leading: LayoutSubview,
        trailing: LayoutSubview
    ) -> Columns? {
        guard let columns = columns(for: width) else { return nil }
        let leadingHeight = leading.sizeThatFits(.init(width: columns.leadingWidth, height: nil)).height
        let trailingHeight = trailing.sizeThatFits(.init(width: columns.trailingWidth, height: nil)).height
        return leadingHeight > 0 && trailingHeight > 0 ? columns : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let leading = subviews[0], trailing = subviews[1]
        // A scroll view always proposes its width; an unspecified one only comes from a
        // caller asking for an ideal size, and one column is the honest answer there.
        let width = proposal.width ?? leading.sizeThatFits(.unspecified).width

        if let columns = columns(for: width, leading: leading, trailing: trailing) {
            let leadingHeight = leading.sizeThatFits(.init(width: columns.leadingWidth, height: nil)).height
            let trailingHeight = trailing.sizeThatFits(.init(width: columns.trailingWidth, height: nil)).height
            return CGSize(width: width, height: max(leadingHeight, trailingHeight))
        }
        let column = ProposedViewSize(width: width, height: nil)
        let leadingHeight = leading.sizeThatFits(column).height
        let trailingHeight = trailing.sizeThatFits(column).height
        // No gap under an empty stack, so one column reads exactly as the old single stack.
        let gap = leadingHeight > 0 && trailingHeight > 0 ? spacing : 0
        return CGSize(width: width, height: leadingHeight + gap + trailingHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let leading = subviews[0], trailing = subviews[1]

        if let columns = columns(for: bounds.width, leading: leading, trailing: trailing) {
            leading.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: .init(width: columns.leadingWidth, height: nil)
            )
            trailing.place(
                at: CGPoint(x: bounds.minX + columns.leadingWidth + columns.gap, y: bounds.minY),
                proposal: .init(width: columns.trailingWidth, height: nil)
            )
            return
        }
        let column = ProposedViewSize(width: bounds.width, height: nil)
        let leadingHeight = leading.sizeThatFits(column).height
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: column)
        let trailingHeight = trailing.sizeThatFits(column).height
        let gap = leadingHeight > 0 && trailingHeight > 0 ? spacing : 0
        trailing.place(at: CGPoint(x: bounds.minX, y: bounds.minY + leadingHeight + gap), proposal: column)
    }
}
