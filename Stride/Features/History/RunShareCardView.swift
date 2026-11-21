import SwiftUI
import UIKit

/// A fixed-size, deterministic run card rendered to an image for sharing (B5).
///
/// It sits on `ink` with the `onInk` text colours, which have the same value in light and
/// dark, so the exported PNG looks identical no matter the device's appearance. Each
/// ``ShareCardFormat`` is designed at a third of its export size and rendered at ×3.
///
/// Every format carries the Stride mark and the landing page address: a card on someone's
/// Strava activity or Instagram story is how most people will first hear of the app.
struct RunShareCardView: View {
    let model: ShareCardModel
    /// Pre-rendered map snapshot (tiles + route baked in) shown behind the route. Supplied by the
    /// caller because `MKMapSnapshotter` is async; `nil` for indoor runs or when the snapshot
    /// failed (offline), in which case the panel falls back to a drawn polyline.
    var routeMapImage: UIImage?
    var format: ShareCardFormat = .portrait

    /// The original 4:5 card's design size in points, rendered at ×3 → 1080×1350 px.
    static let size = ShareCardFormat.portrait.size

    /// The 4:5 card's route panel. Other formats use `ShareCardFormat.routePanelSize`.
    static let routePanelSize = ShareCardFormat.portrait.routePanelSize

    private let accent = Color.brand
    private let primaryText = Color.onInk
    private let secondaryText = Color.onInkMuted

    var body: some View {
        Group {
            switch format {
            case .sticker: sticker
            case .square:  squareCard
            case .story, .portrait: tallCard
            }
        }
        .frame(width: format.size.width, height: format.size.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Formats

    /// Story and post: everything, the story with a larger map and more air.
    private var tallCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            routePanel
                .frame(height: format.routePanelSize.height)
                .padding(.top, AppSpacing.md)
            distanceHeadline
                .padding(.top, format == .story ? AppSpacing.xxl : AppSpacing.lg)
            primaryStats
                .padding(.top, AppSpacing.md)
            secondaryChips
                .padding(.top, 10)
            if format.showsSplits, !model.splitBars.isEmpty {
                splitsStrip
                    .padding(.top, format == .story ? AppSpacing.xxl : AppSpacing.lg)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(AppSpacing.xl)
        .background { inkBackground }
    }

    /// Square: for a Strava activity photo. Map, distance, time and pace, nothing else.
    private var squareCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            routePanel
                .frame(height: format.routePanelSize.height)
                .padding(.top, AppSpacing.md)
            distanceHeadline
                .padding(.top, AppSpacing.md)
            primaryStats
                .padding(.top, AppSpacing.sm)
            Spacer(minLength: 0)
            footer
        }
        .padding(AppSpacing.xl)
        .background { inkBackground }
    }

    /// No background: the route line, the numbers and the mark, each with a dark halo so
    /// they read on a bright photo as well as a dark one.
    private var sticker: some View {
        VStack(spacing: AppSpacing.sm) {
            if model.hasRoute {
                RoutePolylineShape(segments: model.routeSegments)
                    .stroke(
                        Color.onInk,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: format.routePanelSize.width, height: format.routePanelSize.height)
                    .padding(.bottom, AppSpacing.xs)
            }
            Text(model.distance)
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("\(model.duration)  ·  \(model.pace)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                StrideAppMark(size: 18)
                Text(model.planContext ?? model.sessionName)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.top, AppSpacing.xxs)
            Text(StrideLinks.landingPageDisplay)
                .font(.system(size: 10, weight: .semibold))
                .opacity(0.85)
        }
        .foregroundStyle(primaryText)
        .appGlow(.strong, color: .black)
        .padding(AppSpacing.md)
    }

    /// The night map of the Route Loop icon, so a shared run is recognisably Stride's.
    private var inkBackground: some View {
        ZStack {
            Rectangle().fill(.inkGround)
            MapGridPattern(pitch: 30, onInk: true)
        }
    }

    // MARK: Sections

    /// The mark on the left, what the run was on the right.
    private var header: some View {
        HStack(alignment: .center) {
            wordmark
            Spacer(minLength: AppSpacing.sm)
            Text(model.sessionName.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(accent)
                .lineLimit(1)
        }
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            StrideAppMark(size: 22)
            Text("STRIDE")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(primaryText)
        }
    }

    private var routePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(Color.onInk.opacity(0.05))
            if let routeMapImage {
                // Map tiles + route already baked into the snapshot; just present it.
                Image(uiImage: routeMapImage)
                    .resizable()
                    .scaledToFill()
            } else if model.hasRoute {
                // Snapshot unavailable (offline): fall back to the self-drawn polyline.
                RoutePolylineShape(segments: model.routeSegments)
                    .stroke(
                        .route,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .padding(AppSpacing.lg)
            } else if model.isRouteHidden {
                // Route privacy hid all of it; say so rather than call it indoors.
                VStack(spacing: 8) {
                    StrideIcon(name: .lock, size: 34, color: secondaryText, strokeWeight: 2.2)
                    Text("Route kept private")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
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
                    chip(icon: .heart, text: heartRate)
                }
                if let elevation = model.elevation {
                    chip(icon: .mountain, text: elevation)
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
                        .fill(bar.isFastest ? accent : Color.onInk.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, CGFloat(bar.height) * 44))
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
    }

    /// Where the run sat in the plan, and where to get the app. A run with no plan says
    /// it was trained with Stride instead.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text((model.planContext ?? String(localized: "Trained with Stride", comment: "Share card footer")).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text(StrideLinks.landingPageDisplay)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(.top, AppSpacing.md)
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

    private func chip(icon: StrideIconName, text: String) -> some View {
        HStack(spacing: 5) {
            StrideIcon(name: icon, size: 12, color: accent, strokeWeight: 2.2)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.onInk.opacity(0.08), in: Capsule())
    }
}

/// Draws a normalized `[0,1]` polyline into a rect without distorting its shape: the unit square
/// is fit as a centered square inside the (possibly non-square) rect, so the route keeps the true
/// proportions `ShareCardModel.normalizedRoute` already established.
struct RoutePolylineShape: Shape {
    /// One polyline per visible piece of the route (see ``RoutePrivacy``); no line joins
    /// one piece to the next.
    let segments: [[CGPoint]]

    init(segments: [[CGPoint]]) {
        self.segments = segments
    }

    init(points: [CGPoint]) {
        self.segments = [points]
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: originX + point.x * side, y: originY + point.y * side)
        }

        for points in segments {
            guard let first = points.first else { continue }
            path.move(to: place(first))
            for point in points.dropFirst() {
                path.addLine(to: place(point))
            }
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

/// A file the app just wrote for the runner to send on — today the GPX export (B6).
///
/// Same shape and same reason as `ShareCardImage`: the file is produced by the tap, so
/// having one *is* the signal to present the share sheet.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet for something the app has already produced — a rendered card, or a
/// GPX file written to a temporary URL (B6).
///
/// `ShareLink` needs its item up front, which is what forced the card to be rendered
/// before anyone asked to share it. Presenting `UIActivityViewController` directly keeps
/// the work on the tap that needs it while still being one tap for the user.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    init(image: UIImage) {
        self.init(items: [image])
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
