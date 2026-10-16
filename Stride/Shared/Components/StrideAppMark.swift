import SwiftUI

/// The app mark: the Route Loop icon drawn live.
///
/// An `ink` rounded square with the map grid, the loop stroked in the route gradient,
/// and the start pin where the loop begins. Same geometry as the App Store icon
/// (`design/route-loop/icon-light.svg`, 1024-unit canvas), scaled to any size.
///
/// `drawsOn: true` plays the Route Loop entrance once: the loop strokes itself in from
/// the start pin's position (`AppAnimation.routeDraw`), then the pin drops onto it
/// (`AppAnimation.pinDrop`). Under Reduce Motion the mark appears whole.
struct StrideAppMark: View {
    var size: CGFloat = 120
    var drawsOn = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private var isDrawn: Bool { !drawsOn || reduceMotion || drawn }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
        ZStack {
            shape.fill(.inkGround)
            if size >= 48 {
                // 128 units on the icon's 1024 grid. Below 48pt the lines would sit
                // closer than 6pt and read as noise rather than a map.
                MapGridPattern(pitch: size * 0.125, onInk: true)
                    .clipShape(shape)
            }
            RouteLoopShape()
                .trim(from: 0, to: isDrawn ? 1 : 0)
                .stroke(
                    .route,
                    style: StrokeStyle(lineWidth: size * 0.0625, lineCap: .round, lineJoin: .round)
                )
                .animation(AppAnimation.routeDraw, value: drawn)
            StartPin(diameter: size * 0.113)
                .scaleEffect(isDrawn ? 1 : 0.01)
                .animation(AppAnimation.pinDrop.delay(0.85), value: drawn)
                .position(x: size * RouteLoopShape.pinAnchor.x, y: size * RouteLoopShape.pinAnchor.y)
        }
        .frame(width: size, height: size)
        .appShadow(.e3)
        .accessibilityHidden(true)
        .onAppear { drawn = true }
    }
}

#Preview {
    VStack(spacing: 24) {
        StrideAppMark(size: 120, drawsOn: true)
        StrideAppMark(size: 64)
        StrideAppMark(size: 28)
    }
    .padding()
}
