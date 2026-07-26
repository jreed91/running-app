import SwiftUI
import UIKit

/// A fixed-size, deterministic run card rendered to an image for sharing (B5).
///
/// It intentionally uses an explicit dark palette for its background and text rather than
/// theme-dependent asset colors, so the exported PNG looks identical no matter the device's
/// light/dark setting; only the brand accent comes from the app's asset catalog. The design
/// size is small (points) and the caller renders it at ×3 scale to export a ~1080×1350 image.
struct RunShareCardView: View {
    let model: ShareCardModel
    /// Pre-rendered map snapshot (tiles + route baked in) shown behind the route. Supplied by the
    /// caller because `MKMapSnapshotter` is async; `nil` for indoor runs or when the snapshot
    /// failed (offline), in which case the panel falls back to a drawn polyline.
    var routeMapImage: UIImage?

    /// Card design size in points. Rendered at ×3 → ~1080×1350 px (Instagram-portrait 4:5).
    static let size = CGSize(width: 360, height: 450)

    /// Size (points) of the route panel — the card is `size.width` wide with 20 pt padding each
    /// side. The caller requests a map snapshot at exactly this size so it maps 1:1 in the panel.
    static let routePanelSize = CGSize(width: size.width - 40, height: 150)

    private let accent = Color.brand
    private let backgroundTop = Color(red: 0.07, green: 0.08, blue: 0.10)
    private let backgroundBottom = Color(red: 0.11, green: 0.12, blue: 0.15)
    private let primaryText = Color.white
    private let secondaryText = Color.white.opacity(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
            routePanel
                .frame(height: Self.routePanelSize.height)
                .padding(.top, 14)
            distanceHeadline
                .padding(.top, 18)
            primaryStats
                .padding(.top, 14)
            secondaryChips
                .padding(.top, 10)
            if !model.splitBars.isEmpty {
                splitsStrip
                    .padding(.top, 16)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sections

    private var wordmark: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.run")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(accent)
            Text("STRIDE")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(primaryText)
        }
    }

    private var routePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.white.opacity(0.05))
            if let routeMapImage {
                // Map tiles + route already baked into the snapshot; just present it.
                Image(uiImage: routeMapImage)
                    .resizable()
                    .scaledToFill()
            } else if model.hasRoute {
                // Snapshot unavailable (offline): fall back to the self-drawn polyline.
                RoutePolylineShape(points: model.routePoints)
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .padding(18)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "figure.run.treadmill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(secondaryText)
                    Text("Indoor run")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private var distanceHeadline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DISTANCE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(secondaryText)
            Text(model.distance)
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var primaryStats: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(label: "TIME", value: model.duration)
            Spacer(minLength: 12)
            stat(label: "PACE", value: model.pace)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var secondaryChips: some View {
        if model.heartRate != nil || model.elevation != nil {
            HStack(spacing: 8) {
                if let heartRate = model.heartRate {
                    chip(icon: "heart.fill", text: heartRate)
                }
                if let elevation = model.elevation {
                    chip(icon: "mountain.2.fill", text: elevation)
                }
            }
        }
    }

    private var splitsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SPLITS · \(model.splitUnitLabel)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(secondaryText)
                Spacer()
                if let fastestSplit = model.fastestSplit {
                    Text(fastestSplit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(model.splitBars) { bar in
                    RoundedRectangle(cornerRadius: AppRadius.micro, style: .continuous)
                        .fill(bar.isFastest ? accent : Color.white.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, CGFloat(bar.height) * 44))
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
    }

    private var footer: some View {
        Text("RECORDED WITH STRIDE")
            .font(.system(size: 10, weight: .bold))
            .tracking(2)
            .foregroundStyle(secondaryText)
            .padding(.top, 12)
    }

    // MARK: Building blocks

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(secondaryText)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

/// Draws a normalized `[0,1]` polyline into a rect without distorting its shape: the unit square
/// is fit as a centered square inside the (possibly non-square) rect, so the route keeps the true
/// proportions `ShareCardModel.normalizedRoute` already established.
struct RoutePolylineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }

        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: originX + point.x * side, y: originY + point.y * side)
        }

        path.move(to: place(first))
        for point in points.dropFirst() {
            path.addLine(to: place(point))
        }
        return path
    }
}

// MARK: - Share presentation

/// The rendered card, wrapped so it can drive `.sheet(item:)`.
///
/// Rendering is on demand (N21), so the presence of a value *is* the signal to present
/// the share sheet — there is no pre-rendered image sitting around to share.
struct ShareCardImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// System share sheet for an already-rendered card.
///
/// `ShareLink` needs its item up front, which is what forced the card to be rendered
/// before anyone asked to share it. Presenting `UIActivityViewController` directly keeps
/// the render on the tap that needs it while still being one tap for the user.
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
