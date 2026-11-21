import AVFoundation
import CoreVideo
import SwiftUI
import UIKit

// MARK: - RouteReplayFrameView

/// One frame of the route replay video, at the story card's design size (360×640 pt,
/// rendered at ×3 to 1080×1920 px).
///
/// The same night map, mark and footer as the run card (``RunShareCardView``), so a video
/// on someone's story reads as Stride's like the card does. The whole route sits faintly
/// behind the line being drawn; distance and time count up with it.
struct RouteReplayFrameView: View {
    let model: ShareCardModel
    let replay: RouteReplay
    let distanceMeters: Double
    let durationSeconds: Double
    let unit: UnitPreference
    /// How much of the route is drawn, 0 to 1 (``RouteReplay/progress(frame:)``).
    let progress: Double

    static let size = ShareCardFormat.story.size
    private static let routeSide: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            route
                .frame(width: Self.routeSide, height: Self.routeSide)
                .padding(.top, AppSpacing.xxl)
            Spacer(minLength: 0)
            counters
            footer
        }
        .padding(AppSpacing.xl)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                Rectangle().fill(.inkGround)
                MapGridPattern(pitch: 30, onInk: true)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                StrideAppMark(size: 22)
                Text("STRIDE")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Color.onInk)
            }
            Spacer(minLength: AppSpacing.sm)
            Text(model.sessionName.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.brand)
                .lineLimit(1)
        }
    }

    private var route: some View {
        let side = Self.routeSide
        return ZStack(alignment: .topLeading) {
            RoutePolylineShape(segments: replay.segments)
                .stroke(
                    Color.onInk.opacity(0.14),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            RoutePolylineShape(segments: replay.trail(progress: progress))
                .stroke(
                    .route,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            if let head = replay.head(progress: progress) {
                Circle()
                    .fill(Color.onInk)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.brand, lineWidth: 4))
                    .appGlow(.halo, color: .brand)
                    .position(x: head.x * side, y: head.y * side)
            }
        }
    }

    private var counters: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                label("DISTANCE")
                Text((distanceMeters * progress).distanceString(unit: unit))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.onInk)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: AppSpacing.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    label("TIME")
                    value((durationSeconds * progress).durationString)
                }
                VStack(alignment: .leading, spacing: 2) {
                    label("PACE")
                    value(model.pace)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
            Text((model.planContext ?? String(localized: "Trained with Stride", comment: "Route replay footer")).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.onInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text(StrideLinks.landingPageDisplay)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.onInkMuted)
                .lineLimit(1)
        }
        .padding(.top, AppSpacing.xl)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Color.onInkMuted)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.onInk)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

// MARK: - RouteReplayVideo

/// Renders a route replay to a 1080×1920 H.264 file, frame by frame, on the tap.
///
/// Each frame is ``RouteReplayFrameView`` drawn by `ImageRenderer`, the same way the run
/// card is, then appended to an `AVAssetWriter`. 180 frames take a few seconds; the
/// caller shows `onProgress` and can cancel the task.
@MainActor
enum RouteReplayVideo {

    enum RenderError: Error {
        case notPlayable
        case writerSetup
        case frame(Int)
        case finish
    }

    static let pixelWidth = 1_080
    static let pixelHeight = 1_920

    static func render(
        model: ShareCardModel,
        distanceMeters: Double,
        durationSeconds: Double,
        unit: UnitPreference,
        onProgress: (Double) -> Void
    ) async throws -> URL {
        let replay = RouteReplay(segments: model.routeSegments)
        guard replay.isPlayable else { throw RenderError.notPlayable }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stride-route-replay.mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight,
            ]
        )
        guard writer.canAdd(input) else { throw RenderError.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.writerSetup }
        writer.startSession(atSourceTime: .zero)

        do {
            for frame in 0..<RouteReplay.frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let view = RouteReplayFrameView(
                    model: model,
                    replay: replay,
                    distanceMeters: distanceMeters,
                    durationSeconds: durationSeconds,
                    unit: unit,
                    progress: RouteReplay.progress(frame: frame)
                )
                let renderer = ImageRenderer(content: view)
                renderer.scale = ShareCardFormat.renderScale
                renderer.isOpaque = true
                guard let image = renderer.cgImage,
                      let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool)
                else { throw RenderError.frame(frame) }
                let time = CMTime(
                    value: CMTimeValue(frame),
                    timescale: CMTimeScale(RouteReplay.framesPerSecond)
                )
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw RenderError.frame(frame)
                }
                onProgress(Double(frame + 1) / Double(RouteReplay.frameCount))
                // Lets the progress bar draw between frames.
                await Task.yield()
            }
        } catch {
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { @Sendable in continuation.resume() }
        }
        guard writer.status == .completed else { throw RenderError.finish }
        return url
    }

    /// Draws `image` into a buffer from the writer's pool, filling the frame.
    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return buffer
    }
}
