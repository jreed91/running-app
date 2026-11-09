import SwiftUI

/// One card of the year-in-running recap, drawn at a fixed story size.
///
/// The same view is shown in the recap pager and rendered to the shared image, so what the
/// runner sees is what they send. Like `RunShareCardView` it sits on the night map (`ink`
/// with the map grid, which Route Loop allows on the share card) and uses the `onInk`
/// colours, which don't change with appearance, so the exported PNG looks the same from
/// any device. Rendered at ×3 it is 1080×1920, the size Instagram and TikTok stories use.
struct YearRecapCardView: View {
    let card: YearRecapCard

    /// Design size in points. ×3 → 1080×1920 (9:16).
    static let size = CGSize(width: 360, height: 640)

    private let primaryText = Color.onInk
    private let secondaryText = Color.onInkMuted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            Spacer(minLength: AppSpacing.xl)
            if card.kind == .cover {
                cover
            } else {
                content
            }
            Spacer(minLength: AppSpacing.xl)
            footer
        }
        .padding(AppSpacing.xxl)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(.inkGround)
                MapGridPattern(pitch: 30, onInk: true)
                // The route's light in the top corner, as on a hero card. Static.
                EllipticalGradient(
                    colors: [Color.brand.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.8
                )
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sections

    private var wordmark: some View {
        HStack(spacing: 6) {
            StrideAppMark(size: 22)
            Text("STRIDE")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(primaryText)
        }
    }

    /// The first card: the year, huge, over the app mark's loop.
    private var cover: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            StrideAppMark(size: 96)
                .padding(.bottom, AppSpacing.lg)
            Text(card.headline)
                .font(.system(size: 110, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(primaryText)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(card.caption)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
            routeRule
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Text(card.headline)
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(primaryText)
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .padding(.top, AppSpacing.sm)
            Text(card.caption)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppSpacing.sm)
            routeRule
                .padding(.top, AppSpacing.xl)

            if !card.months.isEmpty {
                monthBars
                    .padding(.top, AppSpacing.xxl)
            } else if !card.efforts.isEmpty {
                effortRows
                    .padding(.top, AppSpacing.xl)
            } else if !card.stats.isEmpty {
                statRow
                    .padding(.top, AppSpacing.xl)
            }
        }
    }

    private var eyebrow: some View {
        Text(card.eyebrow)
            .font(.system(size: 13, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(Color.brandGlow)
    }

    /// A short route stroke with the start pin: the Route Loop signature under the figure.
    private var routeRule: some View {
        HStack(spacing: 0) {
            StartPin(diameter: 14)
            Capsule()
                .fill(.route)
                .frame(width: 72, height: 5)
        }
    }

    private var statRow: some View {
        HStack(alignment: .top, spacing: AppSpacing.xxl) {
            ForEach(card.stats, id: \.label) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(secondaryText)
                    Text(stat.value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primaryText)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
        }
    }

    private var monthBars: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(card.months) { bar in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: AppRadius.micro, style: .continuous)
                        .fill(bar.isBiggest ? AnyShapeStyle(LinearGradient.routeBar) : AnyShapeStyle(Color.onInk.opacity(0.24)))
                        .frame(height: max(3, CGFloat(bar.height) * 150))
                    Text(bar.label)
                        .font(.system(size: 11, weight: bar.isBiggest ? .bold : .semibold))
                        .foregroundStyle(bar.isBiggest ? primaryText : secondaryText)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 172, alignment: .bottom)
    }

    private var effortRows: some View {
        VStack(spacing: AppSpacing.md) {
            ForEach(card.efforts) { effort in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(effort.distance)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(primaryText)
                        Text(effort.date)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    if effort.isPersonalBest {
                        Text("PB")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(Color.onFill)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.route, in: Capsule())
                    }
                    Text(effort.time)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primaryText)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 10)
                .background(Color.onInk.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
        }
    }

    private var footer: some View {
        Text("RECORDED WITH STRIDE")
            .font(.system(size: 10, weight: .bold))
            .tracking(2)
            .foregroundStyle(secondaryText)
    }
}

#Preview("Distance") {
    YearRecapCardView(card: YearRecapCard(
        kind: .distance,
        eyebrow: "2026 SO FAR",
        headline: "1,204 km",
        caption: "18% further than 2025.",
        stats: [
            .init(label: "Runs", value: "182"),
            .init(label: "Time", value: "112 hours"),
            .init(label: "Climb", value: "8,420 m"),
        ]
    ))
}

#Preview("Months") {
    YearRecapCardView(card: YearRecapCard(
        kind: .months,
        eyebrow: "2026",
        headline: "October",
        caption: "My biggest month: 162 km.",
        months: (1...12).map {
            .init(month: $0, label: "JFMAMJJASOND".map(String.init)[$0 - 1], height: Double($0) / 12, isBiggest: $0 == 10)
        }
    ))
}
