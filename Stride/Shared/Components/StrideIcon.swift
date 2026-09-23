import SwiftUI

/// Custom icon set matching the Stride Design System.
/// Paths are drawn on a 24×24 coordinate grid, same as the design spec.
enum StrideIconName: String {
    // Workout types
    case run
    case walk
    case tempo
    case bolt
    case flame
    case tortoise
    case moon
    case trophy
    case dumbbell
    case barbell
    // Nav
    case home
    case calendar
    case play
    case history
    case chart
    // UI
    case chevronRight
    case chevronLeft
    case chevronDown
    case check
    case plus
    case close
    case pause
    case stop
    case lock
    case heart
    case location
    case mountain
    case timer
    case ruler
    case bell
    case flag
    case gear
    case music

    /// The SF Symbol that stands in for the hand-drawn glyph, or nil to draw the path.
    ///
    /// The workout-type glyphs were 24 pt stick figures and outlines drawn with a fixed
    /// ~2 pt stroke, which clogged up at the 13–15 pt sizes the plan lists use and read
    /// as blobs: the rest-day "moon" was a closed circle, the runner and walker were
    /// hard to tell apart, the tortoise's legs were a point long. Apple's filled
    /// symbols are hinted for small sizes and are the shapes people already recognise.
    var systemSymbol: String? {
        switch self {
        case .run:      return "figure.run"
        case .walk:     return "figure.walk"
        case .tempo:    return "gauge.with.needle.fill"
        case .bolt:     return "bolt.fill"
        case .flame:    return "flame.fill"
        case .tortoise: return "tortoise.fill"
        case .moon:     return "moon.zzz.fill"
        case .trophy:   return "trophy.fill"
        case .dumbbell: return "dumbbell.fill"
        case .barbell:  return "figure.strengthtraining.traditional"
        default:        return nil
        }
    }
}

struct StrideIcon: View {
    let name: StrideIconName
    var size: CGFloat = 24
    var color: Color = .primary
    var strokeWeight: CGFloat = 1.8

    var body: some View {
        if let symbol = name.systemSymbol {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(symbolWeight)
                .frame(width: size, height: size)
                .foregroundStyle(color)
                // The Canvas glyphs were never exposed to VoiceOver; keep it that way
                // rather than have it start reading symbol names like "figure run".
                .accessibilityHidden(true)
        } else {
            Canvas { ctx, _ in
                draw(ctx)
            }
            .frame(width: size, height: size)
            .foregroundStyle(color)
        }
    }

    /// Call sites tune `strokeWeight` for the Canvas glyphs; carry the same intent over
    /// to the symbol's weight so a heavier-stroked icon stays heavier.
    private var symbolWeight: Font.Weight {
        switch strokeWeight {
        case ..<1.9: return .medium
        case ..<2.3: return .semibold
        default:     return .bold
        }
    }

    // MARK: - Drawing

    // One case per icon, each a short run of literal path commands on the 24 pt design
    // grid. It reads as a table, and splitting it into per-icon helpers would spread
    // that table across the file without making any single icon clearer. This is the
    // one function in the app over the length limit, and it was failing the lint job
    // at error level (N31).
    // swiftlint:disable:next function_body_length
    private func draw(_ ctx: GraphicsContext) {
        // Scale from the 24pt design grid to the requested size
        var ctx = ctx
        let scale = size / 24
        ctx.scaleBy(x: scale, y: scale)

        let stroke = StrokeStyle(lineWidth: strokeWeight / scale, lineCap: .round, lineJoin: .round)

        switch name {
        case .run, .walk, .tempo, .bolt, .flame, .tortoise, .moon, .trophy, .dumbbell, .barbell:
            // Drawn as SF Symbols in `body`; see `systemSymbol`.
            break

        case .home:
            var p = Path()
            p.move(to: CGPoint(x: 3, y: 11))
            p.addLine(to: CGPoint(x: 12, y: 4))
            p.addLine(to: CGPoint(x: 21, y: 11))
            p.addLine(to: CGPoint(x: 21, y: 20))
            p.addCurve(to: CGPoint(x: 20, y: 21),
                       control1: CGPoint(x: 21, y: 20.6),
                       control2: CGPoint(x: 20.6, y: 21))
            p.addLine(to: CGPoint(x: 15, y: 21))
            p.addLine(to: CGPoint(x: 15, y: 15))
            p.addLine(to: CGPoint(x: 9, y: 15))
            p.addLine(to: CGPoint(x: 9, y: 21))
            p.addLine(to: CGPoint(x: 4, y: 21))
            p.addCurve(to: CGPoint(x: 3, y: 20),
                       control1: CGPoint(x: 3.4, y: 21),
                       control2: CGPoint(x: 3, y: 20.6))
            p.closeSubpath()
            ctx.stroke(p, with: .foreground, style: stroke)

        case .calendar:
            var rect = Path(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 16), cornerRadius: 2)
            ctx.stroke(rect, with: .foreground, style: stroke)
            var lines = Path()
            lines.move(to: CGPoint(x: 3, y: 9)); lines.addLine(to: CGPoint(x: 21, y: 9))
            lines.move(to: CGPoint(x: 8, y: 3)); lines.addLine(to: CGPoint(x: 8, y: 7))
            lines.move(to: CGPoint(x: 16, y: 3)); lines.addLine(to: CGPoint(x: 16, y: 7))
            ctx.stroke(lines, with: .foreground, style: stroke)

        case .play:
            var p = Path()
            p.move(to: CGPoint(x: 7, y: 4))
            p.addLine(to: CGPoint(x: 20, y: 12))
            p.addLine(to: CGPoint(x: 7, y: 20))
            p.closeSubpath()
            ctx.fill(p, with: .foreground)

        case .history:
            var circle = Path(ellipseIn: CGRect(x: 3, y: 3, width: 18, height: 18))
            ctx.stroke(circle, with: .foreground, style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 7)); hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 15, y: 14))
            ctx.stroke(hands, with: .foreground, style: stroke)

        case .chart:
            var axes = Path()
            axes.move(to: CGPoint(x: 4, y: 20)); axes.addLine(to: CGPoint(x: 4, y: 4))
            axes.move(to: CGPoint(x: 4, y: 20)); axes.addLine(to: CGPoint(x: 20, y: 20))
            ctx.stroke(axes, with: .foreground, style: stroke)
            var line = Path()
            line.move(to: CGPoint(x: 7, y: 16))
            line.addLine(to: CGPoint(x: 11, y: 11))
            line.addLine(to: CGPoint(x: 14, y: 13))
            line.addLine(to: CGPoint(x: 19, y: 6))
            ctx.stroke(line, with: .foreground, style: stroke)

        case .chevronRight:
            var p = Path()
            p.move(to: CGPoint(x: 9, y: 4)); p.addLine(to: CGPoint(x: 17, y: 12)); p.addLine(to: CGPoint(x: 9, y: 20))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .chevronLeft:
            var p = Path()
            p.move(to: CGPoint(x: 15, y: 4)); p.addLine(to: CGPoint(x: 7, y: 12)); p.addLine(to: CGPoint(x: 15, y: 20))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .chevronDown:
            var p = Path()
            p.move(to: CGPoint(x: 4, y: 9)); p.addLine(to: CGPoint(x: 12, y: 17)); p.addLine(to: CGPoint(x: 20, y: 9))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .check:
            var p = Path()
            p.move(to: CGPoint(x: 4, y: 12)); p.addLine(to: CGPoint(x: 9, y: 17)); p.addLine(to: CGPoint(x: 20, y: 4))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .plus:
            var p = Path()
            p.move(to: CGPoint(x: 12, y: 4)); p.addLine(to: CGPoint(x: 12, y: 20))
            p.move(to: CGPoint(x: 4, y: 12)); p.addLine(to: CGPoint(x: 20, y: 12))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .close:
            var p = Path()
            p.move(to: CGPoint(x: 5, y: 5)); p.addLine(to: CGPoint(x: 19, y: 19))
            p.move(to: CGPoint(x: 19, y: 5)); p.addLine(to: CGPoint(x: 5, y: 19))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .pause:
            var p = Path(roundedRect: CGRect(x: 6, y: 4, width: 4, height: 16), cornerRadius: 1)
            ctx.fill(p, with: .foreground)
            var p2 = Path(roundedRect: CGRect(x: 14, y: 4, width: 4, height: 16), cornerRadius: 1)
            ctx.fill(p2, with: .foreground)

        case .stop:
            var p = Path(roundedRect: CGRect(x: 5, y: 5, width: 14, height: 14), cornerRadius: 2)
            ctx.fill(p, with: .foreground)

        case .lock:
            var body = Path(roundedRect: CGRect(x: 5, y: 11, width: 14, height: 10), cornerRadius: 2)
            ctx.stroke(body, with: .foreground, style: stroke)
            var shackle = Path()
            shackle.move(to: CGPoint(x: 8, y: 11))
            shackle.addLine(to: CGPoint(x: 8, y: 8))
            shackle.addCurve(to: CGPoint(x: 16, y: 8),
                             control1: CGPoint(x: 8, y: 4),
                             control2: CGPoint(x: 16, y: 4))
            shackle.addLine(to: CGPoint(x: 16, y: 11))
            ctx.stroke(shackle, with: .foreground, style: stroke)

        case .heart:
            var p = Path()
            p.move(to: CGPoint(x: 12, y: 20))
            p.addCurve(to: CGPoint(x: 5, y: 10),
                       control1: CGPoint(x: 5, y: 20),
                       control2: CGPoint(x: 5, y: 14.5))
            p.addCurve(to: CGPoint(x: 12, y: 7.5),
                       control1: CGPoint(x: 5, y: 7),
                       control2: CGPoint(x: 8.5, y: 7.5))
            p.addCurve(to: CGPoint(x: 19, y: 10),
                       control1: CGPoint(x: 15.5, y: 7.5),
                       control2: CGPoint(x: 19, y: 7))
            p.addCurve(to: CGPoint(x: 12, y: 20),
                       control1: CGPoint(x: 19, y: 14.5),
                       control2: CGPoint(x: 19, y: 20))
            p.closeSubpath()
            ctx.stroke(p, with: .foreground, style: stroke)

        case .location:
            var pin = Path()
            pin.move(to: CGPoint(x: 12, y: 22))
            pin.addCurve(to: CGPoint(x: 5, y: 10),
                         control1: CGPoint(x: 5, y: 19),
                         control2: CGPoint(x: 5, y: 14))
            pin.addCurve(to: CGPoint(x: 19, y: 10),
                         control1: CGPoint(x: 5, y: 3),
                         control2: CGPoint(x: 19, y: 3))
            pin.addCurve(to: CGPoint(x: 12, y: 22),
                         control1: CGPoint(x: 19, y: 14),
                         control2: CGPoint(x: 19, y: 19))
            ctx.stroke(pin, with: .foreground, style: stroke)
            var dot = Path(ellipseIn: CGRect(x: 9.5, y: 7.5, width: 5, height: 5))
            ctx.stroke(dot, with: .foreground, style: stroke)

        case .mountain:
            var p = Path()
            p.move(to: CGPoint(x: 3, y: 20))
            p.addLine(to: CGPoint(x: 9, y: 9))
            p.addLine(to: CGPoint(x: 13, y: 15))
            p.addLine(to: CGPoint(x: 16, y: 11))
            p.addLine(to: CGPoint(x: 21, y: 20))
            p.closeSubpath()
            ctx.stroke(p, with: .foreground, style: stroke)

        case .timer:
            var circle = Path(ellipseIn: CGRect(x: 4, y: 5, width: 16, height: 16))
            ctx.stroke(circle, with: .foreground, style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 13)); hands.addLine(to: CGPoint(x: 12, y: 9))
            hands.move(to: CGPoint(x: 9, y: 3)); hands.addLine(to: CGPoint(x: 15, y: 3))
            ctx.stroke(hands, with: .foreground, style: stroke)

        case .ruler:
            // Angled ruler
            var rect = Path(roundedRect: CGRect(x: 3, y: 8, width: 18, height: 8), cornerRadius: 1)
            var t = CGAffineTransform(translationX: 12, y: 12)
                .rotated(by: -.pi / 15)
                .translatedBy(x: -12, y: -12)
            ctx.stroke(rect.applying(t), with: .foreground, style: stroke)

        case .bell:
            var body = Path()
            body.move(to: CGPoint(x: 6, y: 16))
            body.addLine(to: CGPoint(x: 6, y: 11))
            body.addCurve(to: CGPoint(x: 18, y: 11),
                          control1: CGPoint(x: 6, y: 5),
                          control2: CGPoint(x: 18, y: 5))
            body.addLine(to: CGPoint(x: 18, y: 16))
            body.addLine(to: CGPoint(x: 20, y: 18))
            body.addLine(to: CGPoint(x: 4, y: 18))
            body.closeSubpath()
            ctx.stroke(body, with: .foreground, style: stroke)
            var clapper = Path()
            clapper.move(to: CGPoint(x: 10, y: 20))
            clapper.addCurve(to: CGPoint(x: 14, y: 20),
                             control1: CGPoint(x: 10, y: 22),
                             control2: CGPoint(x: 14, y: 22))
            ctx.stroke(clapper, with: .foreground, style: stroke)

        case .flag:
            var p = Path()
            p.move(to: CGPoint(x: 5, y: 3))
            p.addLine(to: CGPoint(x: 5, y: 21))
            p.move(to: CGPoint(x: 5, y: 3))
            p.addLine(to: CGPoint(x: 19, y: 3))
            p.addLine(to: CGPoint(x: 19, y: 12))
            p.addLine(to: CGPoint(x: 5, y: 12))
            ctx.stroke(p, with: .foreground, style: stroke)

        case .gear:
            var outer = Path(ellipseIn: CGRect(x: 9, y: 9, width: 6, height: 6))
            ctx.stroke(outer, with: .foreground, style: stroke)
            // Gear teeth via outer ring
            var ring = Path(ellipseIn: CGRect(x: 3, y: 3, width: 18, height: 18))
            var thinStroke = StrokeStyle(lineWidth: (strokeWeight / scale) * 0.5, lineCap: .round, lineJoin: .round)
            ctx.stroke(ring, with: .foreground, style: thinStroke)
            // 8 spokes for teeth suggestion
            let spokes: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 12, y: 2), CGPoint(x: 12, y: 4)),
                (CGPoint(x: 12, y: 20), CGPoint(x: 12, y: 22)),
                (CGPoint(x: 2, y: 12), CGPoint(x: 4, y: 12)),
                (CGPoint(x: 20, y: 12), CGPoint(x: 22, y: 12)),
                (CGPoint(x: 4.9, y: 4.9), CGPoint(x: 6.3, y: 6.3)),
                (CGPoint(x: 17.7, y: 17.7), CGPoint(x: 19.1, y: 19.1)),
                (CGPoint(x: 4.9, y: 19.1), CGPoint(x: 6.3, y: 17.7)),
                (CGPoint(x: 17.7, y: 6.3), CGPoint(x: 19.1, y: 4.9)),
            ]
            for (a, b) in spokes {
                var sp = Path(); sp.move(to: a); sp.addLine(to: b)
                ctx.stroke(sp, with: .foreground, style: stroke)
            }

        case .music:
            // Beamed pair of eighth notes: two note heads, two stems, one beam.
            ctx.fill(Path(ellipseIn: CGRect(x: 4, y: 15.2, width: 5, height: 4)), with: .foreground)
            ctx.fill(Path(ellipseIn: CGRect(x: 14.5, y: 13.2, width: 5, height: 4)), with: .foreground)
            var stems = Path()
            stems.move(to: CGPoint(x: 9, y: 17.2))
            stems.addLine(to: CGPoint(x: 9, y: 6))
            stems.move(to: CGPoint(x: 19.5, y: 15.2))
            stems.addLine(to: CGPoint(x: 19.5, y: 4))
            ctx.stroke(stems, with: .foreground, style: stroke)
            var beam = Path()
            beam.move(to: CGPoint(x: 9, y: 6))
            beam.addLine(to: CGPoint(x: 19.5, y: 4))
            ctx.stroke(beam, with: .foreground, style: stroke)
        }
    }
}

// MARK: - Convenience label init

extension Label where Title == Text, Icon == StrideIcon {
    init(_ title: String, strideIcon: StrideIconName, size: CGFloat = 20, color: Color = .primary) {
        self.init(title: { Text(title) }, icon: { StrideIcon(name: strideIcon, size: size, color: color) })
    }
}

// MARK: - Preview

#Preview {
    let all: [(String, StrideIconName)] = [
        ("run", .run), ("walk", .walk), ("tempo", .tempo), ("bolt", .bolt),
        ("flame", .flame), ("tortoise", .tortoise), ("moon", .moon), ("trophy", .trophy),
        ("dumbbell", .dumbbell), ("barbell", .barbell), ("home", .home), ("calendar", .calendar),
        ("play", .play), ("history", .history), ("chart", .chart),
        ("chevronR", .chevronRight), ("check", .check), ("pause", .pause),
        ("stop", .stop), ("lock", .lock), ("timer", .timer), ("flag", .flag), ("gear", .gear),
    ]
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
        ForEach(all, id: \.0) { name, icon in
            VStack(spacing: 4) {
                StrideIcon(name: icon, size: 28, color: .primary)
                Text(name).font(.system(size: 9))
            }
        }
    }
    .padding()
}
