import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - RunShareStudioView

/// Where a run card is made: pick a format, see the exact card, then share or copy it.
///
/// The preview is the view that gets rendered, scaled to fit, so what is shared is what
/// was shown. Map snapshots are made per format on first view (their panels differ in
/// size) and kept while the sheet is open. Route privacy is applied to the line and the
/// map alike (``RoutePrivacy``).
struct RunShareStudioView: View {
    let workout: RunWorkout

    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss

    /// The last format used, so a runner who always posts stories starts on Story.
    @AppStorage("shareCard.format") private var format: ShareCardFormat = .story
    @State private var privacy = RoutePrivacy.load()
    @State private var mapImages: [ShareCardFormat: UIImage] = [:]
    @State private var loadingMaps: Set<ShareCardFormat> = []
    @State private var shareItem: SharedCard?
    @State private var copied = false

    private var model: ShareCardModel {
        ShareCardModel.make(from: workout, unit: appSettings.unitPreference, privacy: privacy)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.lg) {
                Picker("Format", selection: $format) {
                    ForEach(ShareCardFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("shareStudio.format")

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(format.hint)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                actions
            }
            .padding(AppSpacing.lg)
            .background(Color.surfacePrimary)
            .navigationTitle("Share run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: format) { await loadMap(for: format) }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.payload])
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { proxy in
            let size = format.size
            let scale = min(proxy.size.width / size.width, proxy.size.height / size.height)
            ZStack {
                if format.isTransparent {
                    // A stand-in photo, so the sticker's transparency and halo show.
                    LinearGradient(
                        colors: [Color.brand.opacity(0.55), Color.surfaceSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: size.width * scale, height: size.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                card(for: format)
                    .scaleEffect(scale)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                if format.showsMap, loadingMaps.contains(format) {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .appShadow(.e2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the \(format.title) card"))
    }

    private func card(for format: ShareCardFormat) -> RunShareCardView {
        RunShareCardView(
            model: model,
            routeMapImage: format.showsMap ? mapImages[format] : nil,
            format: format
        )
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: AppSpacing.sm) {
            Button {
                share()
            } label: {
                Label("Share", strideIcon: .export, size: 18, color: .onFill)
            }
            .buttonStyle(.strideButton(.primary))
            .accessibilityIdentifier("shareStudio.share")

            if format == .sticker {
                Button {
                    copySticker()
                } label: {
                    Text(copied ? "Copied. Paste it in your story." : "Copy sticker")
                }
                .buttonStyle(.strideButton(.secondary))
                .accessibilityIdentifier("shareStudio.copySticker")
            }
        }
    }

    /// The card at full size: 1080 px wide, transparent for the sticker.
    private func render(_ format: ShareCardFormat) -> UIImage? {
        let renderer = ImageRenderer(content: card(for: format))
        renderer.scale = ShareCardFormat.renderScale
        renderer.isOpaque = !format.isTransparent
        return renderer.uiImage
    }

    private func share() {
        guard let image = render(format) else {
            AppLogger.log("Share card render produced no image", label: "Share", level: .error)
            return
        }
        if format.isTransparent, let png = image.pngData() {
            // A file, so the transparency survives: a bare UIImage can be flattened to
            // JPEG on the way to some apps.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Stride-run-sticker.png")
            do {
                try png.write(to: url, options: .atomic)
                shareItem = SharedCard(payload: url)
                return
            } catch {
                AppLogger.log("Sticker write failed: \(error.localizedDescription)", label: "Share", level: .error)
            }
        }
        shareItem = SharedCard(payload: image)
    }

    /// Puts the sticker on the clipboard as a PNG; Instagram's story editor pastes an
    /// image from the clipboard as a sticker.
    private func copySticker() {
        guard let png = render(.sticker)?.pngData() else { return }
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        copied = true
        UIAccessibility.post(notification: .announcement, argument: "Sticker copied")
    }

    // MARK: Map

    private func loadMap(for format: ShareCardFormat) async {
        copied = false
        guard format.showsMap, mapImages[format] == nil, !loadingMaps.contains(format) else { return }
        let segments = privacy.visibleSegments(of: workout.routeCoordinates)
        guard !segments.isEmpty else { return }
        loadingMaps.insert(format)
        defer { loadingMaps.remove(format) }
        let image = await RouteSnapshotService.routeSnapshot(
            segments: segments,
            size: format.routePanelSize,
            scale: ShareCardFormat.renderScale,
            lineColor: UIColor(.brand),
            lineWidth: 3
        )
        if let image { mapImages[format] = image }
    }
}

/// What the share sheet is handed: an image, or a PNG file for the sticker.
private struct SharedCard: Identifiable {
    let id = UUID()
    let payload: Any
}
