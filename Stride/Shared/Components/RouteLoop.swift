import SwiftUI

// MARK: - Route Loop
//
// The pieces of the Route Loop identity, shared by the app mark, onboarding, the hero
// cards and the share card. The icon is a GPS loop with a start pin on a night map, so
// the app speaks in the same three things:
//
// - the **route**: one stroke, round caps, the amber → orange `LinearGradient.route`;
// - the **start pin**: a white disc with an orange centre, marking "you are here";
// - the **map**: `ink` ground with a faint square grid.
//
// The loop's geometry is the icon's own path on its 1024-unit canvas
// (`design/route-loop/icon-light.svg`), so the mark drawn here and the icon match.

/// The icon's loop, scaled to fit the rect it is drawn in.
struct RouteLoopShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 1024
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        var path = Path()
        path.move(to: point(300, 720))
        path.addCurve(to: point(420, 360), control1: point(200, 600), control2: point(260, 380))
        path.addCurve(to: point(640, 250), control1: point(520, 348), control2: point(540, 260))
        path.addCurve(to: point(740, 520), control1: point(780, 236), control2: point(820, 420))
        path.addCurve(to: point(620, 750), control1: point(680, 596), control2: point(700, 680))
        path.addCurve(to: point(300, 720), control1: point(540, 820), control2: point(380, 800))
        path.closeSubpath()
        return path
    }

    /// Where the start pin sits, as a fraction of the drawing square.
    static let pinAnchor = UnitPoint(x: 300.0 / 1024, y: 720.0 / 1024)
}

/// The start pin: a white disc with an orange centre.
///
/// Marks the runner's own position on anything map-like — today on the plan, the
/// current point on a chart, the start of a drawn route.
struct StartPin: View {
    var diameter: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            Circle()
                .fill(Color.brand)
                .frame(width: diameter * 0.45, height: diameter * 0.45)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The faint square grid of the night map.
///
/// Drawn with `Canvas`, so a full-screen grid is one layer, not hundreds of views.
/// `onInk: true` draws in white for an `ink` ground; otherwise it uses `mapGrid`,
/// which follows the appearance.
struct MapGridPattern: View {
    var pitch: CGFloat = 32
    var onInk = false

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var x: CGFloat = 0
            while x <= size.width {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += pitch
            }
            var y: CGFloat = 0
            while y <= size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += pitch
            }
            let color = onInk ? Color.white.opacity(0.05) : Color.mapGrid
            context.stroke(lines, with: .color(color), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Ink hero surface

private struct InkHeroBackground: ViewModifier {
    let cornerRadius: CGFloat
    let showsGrid: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.onInk)
            .environment(\.colorScheme, .dark)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.inkGround)
                    .overlay {
                        if showsGrid {
                            MapGridPattern(onInk: true)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }
    }
}

extension View {
    /// Puts the view on the Route Loop's night-map ground: an `ink` gradient card with
    /// the map grid, in the dark appearance whatever the app's, so `.primary` and
    /// `.secondary` text read on it in both.
    ///
    /// For the one or two hero cards on a screen — the next session, the race — not
    /// for every card: a screen of ink cards has no hero.
    func inkHero(cornerRadius: CGFloat = AppRadius.lg, showsGrid: Bool = true) -> some View {
        modifier(InkHeroBackground(cornerRadius: cornerRadius, showsGrid: showsGrid))
    }
}

#Preview("Route Loop pieces") {
    VStack(spacing: 24) {
        ZStack {
            RouteLoopShape()
                .stroke(.route, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            GeometryReader { geo in
                StartPin(diameter: 22)
                    .position(
                        x: geo.size.width * RouteLoopShape.pinAnchor.x,
                        y: geo.size.height * RouteLoopShape.pinAnchor.y
                    )
            }
        }
        .frame(width: 160, height: 160)
        .padding()
        .inkHero()

        Text("Tempo · 8 km")
            .font(.dsHeadline)
            .padding()
            .inkHero(cornerRadius: AppRadius.md)
    }
    .padding()
    .background(Color.surfacePrimary)
}

/// A full-screen night map: the `ink` ground, the grid, and a warm route glow from the
/// top. For the welcome screens. Pair it with `.environment(\.colorScheme, .dark)` on
/// the screen so its text reads on the ink in both appearances.
struct NightMapBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.inkGround)
            MapGridPattern(pitch: 36, onInk: true)
            EllipticalGradient(
                colors: [Color.brand.opacity(0.28), .clear],
                center: .top,
                startRadiusFraction: 0,
                endRadiusFraction: 0.85
            )
        }
        .accessibilityHidden(true)
    }
}
