import SwiftUI

/// Brand mark matching the Stride design system's `AppIconMark`.
///
/// A rounded square with the brand gradient fill and a single-stroke
/// stride motif drawn in white. Drawn on a 180-unit reference grid
/// and scaled to any size.
struct StrideAppMark: View {
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            // Base brand gradient — same stops as the design's iconBg.
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0, green: 0.627, blue: 0.337), location: 0),      // #FFA056
                            .init(color: Color(red: 1.0, green: 0.420, blue: 0.133), location: 0.55),   // #FF6B22
                            .init(color: Color(red: 0.824, green: 0.227, blue: 0.071), location: 1),    // #D23A12
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Top-left radial highlight for depth.
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.28), .clear],
                        center: .init(x: 0.25, y: 0.10),
                        startRadius: 0,
                        endRadius: size * 0.9
                    )
                )

            // Vertical sheen.
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.30), location: 0),
                            .init(color: .clear, location: 0.5),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            // Stride motif — single-stroke flowing shape (from design path
            // "M36 148 Q66 44 122 28 L140 28 Q86 46 60 150 Z" on 180 grid).
            StrideMotifShape()
                .fill(Color.white)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .appShadow(.e3)
    }
}

private struct StrideMotifShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Reference path is drawn on a 180×180 grid; scale to rect.
        let s = rect.width / 180
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }

        var path = Path()
        path.move(to: p(36, 148))
        path.addQuadCurve(to: p(122, 28), control: p(66, 44))
        path.addLine(to: p(140, 28))
        path.addQuadCurve(to: p(60, 150), control: p(86, 46))
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 24) {
        StrideAppMark(size: 120)
        StrideAppMark(size: 64)
        StrideAppMark(size: 28)
    }
    .padding()
}
