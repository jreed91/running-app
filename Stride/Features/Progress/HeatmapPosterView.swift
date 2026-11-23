import SwiftUI

/// The heatmap as a story-sized poster: every street run in the period on the night
/// ground, coloured by how often, with what they add up to.
///
/// The heat is a picture drawn from cells (``HeatDots/preview(size:background:pixelScale:)``),
/// not a map snapshot, so it needs no network and carries no street names, and the
/// runner's ``RoutePrivacy`` has already been applied to every run before a cell reaches
/// it. Like the recap cards it uses the `onInk` colours, so the PNG looks the same from
/// any device. Rendered at ×3 it is 1080×1920.
struct HeatmapPosterView: View {
    let heatmap: RouteHeatmap.Heatmap
    let heatImage: UIImage?
    /// "2025", "Last 90 days".
    let title: String
    /// The run type when it isn't all runs.
    let subtitle: String?
    let unit: UnitPreference

    /// Design size in points. ×3 → 1080×1920 (9:16).
    static let size = CGSize(width: 360, height: 640)
    /// The heat picture's size in points, between the title and the figures.
    static let heatSize = CGSize(width: 360, height: 430)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StrideAppMark(size: 22)
                Text("STRIDE")
                    .font(.dsHeadline.weight(.heavy))
                    .tracking(3)
                    .foregroundStyle(Color.onInk)
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, AppSpacing.xxl)

            VStack(alignment: .leading, spacing: 2) {
                Text("My running heatmap")
                    .font(.dsTitle2)
                    .foregroundStyle(Color.onInk)
                Text([title, subtitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.dsSubhead.weight(.semibold))
                    .foregroundStyle(Color.onInkMuted)
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, AppSpacing.md)

            Group {
                if let heatImage {
                    Image(uiImage: heatImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.heatSize.width, height: Self.heatSize.height)
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: AppSpacing.xl) {
                figure("\(heatmap.runCount)", heatmap.runCount == 1 ? "run" : "runs")
                figure(heatmap.uniqueMeters.distanceString(unit: unit), "of ground")
                figure("\(heatmap.maxRuns)×", "busiest street")
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.bottom, AppSpacing.xxl)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.inkDeep)
        .environment(\.colorScheme, .dark)
        // A fixed-size image: the type sizes stay put whatever the phone's text size.
        .environment(\.dynamicTypeSize, .large)
    }

    private func figure(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.dsTitle3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.onInk)
            Text(label)
                .font(.dsCaption2.weight(.medium))
                .foregroundStyle(Color.onInkMuted)
        }
    }
}
