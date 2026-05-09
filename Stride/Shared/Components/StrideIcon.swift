import SwiftUI
import UIKit

/// Pixel-art icon set drawn on a 24x24 grid.
enum StrideIconName: String {
    // Workout types
    case run
    case walk
    case shoe
    case road
    case tempo
    case bolt
    case flame
    case tortoise
    case moon
    case trophy
    case medal
    case dumbbell
    case barbell

    // Navigation and places
    case home
    case calendar
    case play
    case history
    case chart
    case map
    case location
    case indoor
    case mountain
    case routeLoop
    case routeOutAndBack

    // UI
    case chevronRight
    case chevronLeft
    case chevronDown
    case arrowRight
    case arrowUp
    case arrowDown
    case check
    case plus
    case close
    case pause
    case stop
    case minus
    case lock
    case heart
    case timer
    case ruler
    case bell
    case flag
    case gear
    case sync
    case search
    case bookmark
    case trash
    case link
    case exclamation
    case sparkles
    case wand
    case humidity
    case wind
    case thumbsUp
    case thumbsDown
    case seal

    // Weather
    case sun
    case cloud
    case rain
    case snow

    init(weatherSymbol: String) {
        let value = weatherSymbol.lowercased()
        if value.contains("rain") || value.contains("drizzle") {
            self = .rain
        } else if value.contains("snow") || value.contains("sleet") {
            self = .snow
        } else if value.contains("cloud") || value.contains("fog") || value.contains("smoke") || value.contains("haze") {
            self = .cloud
        } else {
            self = .sun
        }
    }

    // swiftlint:disable function_body_length
    var pixels: [PixelBlock] {
        switch self {
        case .run:
            return [
                .init(13, 2, 4, 4), .init(11, 7, 5, 3), .init(9, 10, 4, 3),
                .init(15, 9, 5, 3), .init(7, 13, 5, 3), .init(5, 16, 4, 3),
                .init(3, 19, 6, 2), .init(12, 13, 5, 3), .init(16, 16, 3, 4),
                .init(15, 20, 6, 2), .init(8, 7, 4, 2)
            ]
        case .walk:
            return [
                .init(12, 2, 4, 4), .init(11, 7, 4, 6), .init(8, 9, 3, 3),
                .init(15, 10, 4, 3), .init(9, 13, 4, 4), .init(7, 17, 3, 5),
                .init(13, 13, 4, 4), .init(16, 17, 4, 5)
            ]
        case .shoe:
            return [
                .init(4, 13, 3, 4), .init(7, 15, 5, 3), .init(12, 16, 5, 3),
                .init(17, 15, 3, 4), .init(3, 18, 18, 3), .init(8, 12, 4, 2),
                .init(12, 13, 3, 2)
            ]
        case .road:
            return [
                .init(10, 3, 4, 5), .init(9, 8, 6, 5), .init(7, 13, 10, 5),
                .init(5, 18, 14, 4), .init(11, 5, 2, 2), .init(11, 10, 2, 2),
                .init(11, 15, 2, 2), .init(11, 20, 2, 2)
            ]
        case .tempo, .flame:
            return [
                .init(11, 2, 3, 3), .init(10, 5, 5, 3), .init(8, 8, 8, 4),
                .init(7, 12, 10, 5), .init(8, 17, 8, 3), .init(10, 20, 4, 2),
                .init(6, 10, 3, 4), .init(14, 7, 3, 4)
            ]
        case .bolt:
            return [
                .init(12, 2, 5, 3), .init(10, 5, 5, 3), .init(8, 8, 5, 4),
                .init(6, 12, 7, 3), .init(11, 13, 5, 3), .init(10, 16, 4, 3),
                .init(9, 19, 3, 3)
            ]
        case .tortoise:
            return [
                .init(6, 10, 11, 6), .init(8, 8, 7, 3), .init(17, 11, 4, 3),
                .init(4, 12, 3, 3), .init(7, 16, 3, 3), .init(14, 16, 3, 3)
            ]
        case .moon:
            return [
                .init(11, 3, 5, 2), .init(8, 5, 5, 3), .init(6, 8, 5, 5),
                .init(6, 13, 5, 4), .init(8, 17, 6, 3), .init(13, 19, 4, 2),
                .init(13, 8, 3, 3), .init(16, 11, 2, 4)
            ]
        case .trophy:
            return [
                .init(7, 3, 10, 3), .init(7, 6, 10, 5), .init(9, 11, 6, 3),
                .init(11, 14, 2, 3), .init(8, 17, 8, 2), .init(6, 19, 12, 2),
                .init(4, 6, 3, 3), .init(5, 9, 3, 3), .init(17, 6, 3, 3),
                .init(16, 9, 3, 3)
            ]
        case .medal:
            return [
                .init(7, 2, 4, 7), .init(13, 2, 4, 7), .init(10, 7, 4, 4),
                .init(7, 11, 10, 10), .init(5, 13, 2, 6), .init(17, 13, 2, 6),
                .init(9, 15, 6, 3)
            ]
        case .dumbbell:
            return [
                .init(2, 8, 3, 8), .init(5, 10, 3, 4), .init(8, 11, 8, 2),
                .init(16, 10, 3, 4), .init(19, 8, 3, 8)
            ]
        case .barbell:
            return [
                .init(1, 11, 22, 2), .init(3, 7, 2, 10), .init(6, 8, 2, 8),
                .init(16, 8, 2, 8), .init(19, 7, 2, 10)
            ]
        case .home:
            return [
                .init(11, 3, 2, 2), .init(9, 5, 6, 2), .init(7, 7, 10, 2),
                .init(5, 9, 14, 2), .init(6, 11, 12, 10), .init(10, 15, 4, 6),
                .init(8, 13, 2, 2), .init(14, 13, 2, 2)
            ]
        case .calendar:
            return [
                .init(5, 4, 3, 3), .init(16, 4, 3, 3), .init(3, 7, 18, 3),
                .init(3, 10, 3, 11), .init(18, 10, 3, 11), .init(6, 18, 12, 3),
                .init(7, 12, 3, 3), .init(12, 12, 3, 3), .init(7, 16, 3, 2),
                .init(12, 16, 3, 2)
            ]
        case .play:
            return [.init(7, 4, 4, 16), .init(11, 7, 4, 10), .init(15, 10, 4, 4)]
        case .history:
            return [
                .init(8, 3, 8, 3), .init(5, 6, 3, 3), .init(16, 6, 3, 3),
                .init(3, 9, 3, 6), .init(18, 9, 3, 6), .init(5, 15, 3, 3),
                .init(16, 15, 3, 3), .init(8, 18, 8, 3), .init(11, 7, 2, 6),
                .init(12, 12, 5, 2)
            ]
        case .chart:
            return [
                .init(4, 4, 2, 17), .init(4, 19, 17, 2), .init(8, 15, 3, 4),
                .init(12, 11, 3, 8), .init(16, 7, 3, 12), .init(8, 12, 5, 2),
                .init(13, 9, 5, 2)
            ]
        case .map:
            return [
                .init(3, 5, 5, 15), .init(9, 4, 6, 15), .init(16, 5, 5, 15),
                .init(8, 6, 1, 13), .init(15, 5, 1, 13), .init(11, 8, 2, 2),
                .init(12, 10, 2, 2), .init(13, 12, 2, 2)
            ]
        case .location:
            return [
                .init(9, 3, 6, 2), .init(7, 5, 10, 4), .init(6, 9, 12, 4),
                .init(8, 13, 8, 3), .init(10, 16, 4, 3), .init(11, 19, 2, 3),
                .init(10, 8, 4, 4)
            ]
        case .indoor:
            return [
                .init(6, 10, 12, 11), .init(8, 8, 8, 2), .init(10, 6, 4, 2),
                .init(4, 12, 2, 9), .init(18, 12, 2, 9), .init(10, 15, 4, 6)
            ]
        case .mountain:
            return [
                .init(10, 5, 4, 3), .init(8, 8, 8, 3), .init(6, 11, 12, 4),
                .init(4, 15, 16, 4), .init(2, 19, 20, 2), .init(12, 10, 3, 2)
            ]
        case .routeLoop:
            return [
                .init(8, 3, 8, 2), .init(16, 5, 3, 3), .init(19, 8, 2, 7),
                .init(16, 15, 3, 3), .init(8, 18, 8, 2), .init(5, 15, 3, 3),
                .init(3, 8, 2, 7), .init(5, 5, 3, 3), .init(14, 3, 4, 4),
                .init(15, 1, 2, 6)
            ]
        case .routeOutAndBack:
            return [
                .init(5, 7, 14, 3), .init(3, 10, 3, 3), .init(5, 13, 14, 3),
                .init(18, 10, 3, 3), .init(4, 6, 3, 5), .init(17, 13, 3, 5)
            ]
        case .chevronRight:
            return [.init(8, 5, 4, 4), .init(12, 9, 4, 3), .init(8, 12, 4, 4), .init(6, 16, 4, 3)]
        case .chevronLeft:
            return [.init(12, 5, 4, 4), .init(8, 9, 4, 3), .init(12, 12, 4, 4), .init(14, 16, 4, 3)]
        case .chevronDown:
            return [.init(5, 8, 4, 4), .init(9, 12, 3, 4), .init(12, 12, 3, 4), .init(15, 8, 4, 4)]
        case .arrowRight:
            return [.init(4, 10, 12, 4), .init(14, 6, 4, 4), .init(18, 10, 3, 4), .init(14, 14, 4, 4)]
        case .arrowUp:
            return [.init(10, 4, 4, 14), .init(6, 8, 4, 4), .init(14, 8, 4, 4), .init(8, 6, 8, 2)]
        case .arrowDown:
            return [.init(10, 6, 4, 14), .init(6, 14, 4, 4), .init(14, 14, 4, 4), .init(8, 18, 8, 2)]
        case .check:
            return [.init(4, 12, 4, 4), .init(8, 16, 4, 3), .init(12, 12, 3, 4), .init(15, 8, 3, 4), .init(18, 5, 3, 3)]
        case .plus:
            return [.init(10, 4, 4, 16), .init(4, 10, 16, 4)]
        case .close:
            return [
                .init(5, 5, 4, 4), .init(9, 9, 3, 3), .init(12, 12, 3, 3),
                .init(15, 15, 4, 4), .init(15, 5, 4, 4), .init(12, 9, 3, 3),
                .init(9, 12, 3, 3), .init(5, 15, 4, 4)
            ]
        case .pause:
            return [.init(6, 4, 5, 16), .init(13, 4, 5, 16)]
        case .stop:
            return [.init(5, 5, 14, 14)]
        case .minus:
            return [.init(5, 10, 14, 4)]
        case .lock:
            return [
                .init(7, 10, 10, 11), .init(6, 12, 12, 8), .init(8, 6, 3, 5),
                .init(13, 6, 3, 5), .init(10, 4, 4, 3), .init(11, 14, 2, 4)
            ]
        case .heart:
            return [
                .init(6, 6, 5, 3), .init(13, 6, 5, 3), .init(4, 9, 16, 5),
                .init(6, 14, 12, 3), .init(8, 17, 8, 3), .init(11, 20, 2, 2)
            ]
        case .timer:
            return [
                .init(9, 2, 6, 2), .init(11, 4, 2, 2), .init(7, 6, 10, 3),
                .init(5, 9, 14, 8), .init(7, 17, 10, 3), .init(11, 9, 2, 5),
                .init(13, 13, 3, 2)
            ]
        case .ruler:
            return [
                .init(3, 9, 18, 6), .init(5, 8, 3, 2), .init(10, 8, 2, 2),
                .init(14, 8, 2, 2), .init(18, 8, 2, 2), .init(6, 15, 2, 2),
                .init(12, 15, 2, 2), .init(17, 15, 2, 2)
            ]
        case .bell:
            return [
                .init(10, 3, 4, 2), .init(7, 5, 10, 4), .init(6, 9, 12, 7),
                .init(4, 16, 16, 3), .init(10, 19, 4, 2)
            ]
        case .flag:
            return [
                .init(5, 3, 3, 18), .init(8, 4, 10, 3), .init(8, 7, 8, 3),
                .init(8, 10, 10, 3)
            ]
        case .gear:
            return [
                .init(10, 2, 4, 4), .init(10, 18, 4, 4), .init(2, 10, 4, 4),
                .init(18, 10, 4, 4), .init(6, 6, 4, 4), .init(14, 6, 4, 4),
                .init(6, 14, 4, 4), .init(14, 14, 4, 4), .init(9, 9, 6, 6)
            ]
        case .sync:
            return [
                .init(8, 3, 8, 2), .init(16, 5, 3, 3), .init(18, 8, 2, 5),
                .init(15, 11, 5, 2), .init(17, 9, 4, 4), .init(8, 19, 8, 2),
                .init(5, 16, 3, 3), .init(4, 11, 2, 5), .init(4, 11, 5, 2),
                .init(3, 11, 4, 4)
            ]
        case .search:
            return [
                .init(6, 4, 8, 3), .init(4, 7, 3, 7), .init(13, 7, 3, 7),
                .init(6, 14, 8, 3), .init(14, 15, 3, 3), .init(17, 18, 4, 4)
            ]
        case .bookmark:
            return [
                .init(6, 3, 12, 17), .init(8, 20, 3, 2), .init(13, 20, 3, 2),
                .init(10, 18, 4, 3)
            ]
        case .trash:
            return [
                .init(7, 5, 10, 2), .init(9, 3, 6, 2), .init(6, 8, 12, 2),
                .init(7, 10, 10, 11), .init(9, 12, 2, 7), .init(13, 12, 2, 7)
            ]
        case .link:
            return [
                .init(5, 8, 8, 3), .init(3, 11, 3, 5), .init(6, 16, 8, 3),
                .init(11, 13, 3, 3), .init(11, 5, 8, 3), .init(18, 8, 3, 5),
                .init(10, 13, 8, 3)
            ]
        case .exclamation:
            return [.init(10, 3, 4, 12), .init(10, 18, 4, 4)]
        case .sparkles:
            return [
                .init(11, 2, 2, 6), .init(9, 4, 6, 2), .init(11, 8, 2, 2),
                .init(5, 13, 2, 4), .init(3, 15, 6, 2), .init(17, 14, 2, 5),
                .init(15, 16, 6, 2)
            ]
        case .wand:
            return [
                .init(5, 16, 3, 3), .init(8, 13, 3, 3), .init(11, 10, 3, 3),
                .init(14, 7, 3, 3), .init(17, 4, 3, 3), .init(5, 5, 2, 4),
                .init(3, 7, 6, 2), .init(16, 16, 2, 4), .init(14, 18, 6, 2)
            ]
        case .humidity:
            return [
                .init(11, 3, 2, 3), .init(9, 6, 6, 4), .init(7, 10, 10, 5),
                .init(8, 15, 8, 4), .init(10, 19, 4, 2)
            ]
        case .wind:
            return [
                .init(3, 7, 13, 3), .init(16, 6, 4, 4), .init(6, 12, 13, 3),
                .init(3, 17, 10, 3), .init(13, 16, 4, 4)
            ]
        case .thumbsUp:
            return [
                .init(4, 11, 4, 8), .init(8, 9, 7, 10), .init(11, 5, 4, 5),
                .init(15, 10, 5, 3), .init(15, 14, 4, 2), .init(15, 17, 3, 2)
            ]
        case .thumbsDown:
            return [
                .init(4, 5, 4, 8), .init(8, 5, 7, 10), .init(11, 14, 4, 5),
                .init(15, 11, 5, 3), .init(15, 8, 4, 2), .init(15, 5, 3, 2)
            ]
        case .seal:
            return [
                .init(8, 3, 8, 3), .init(5, 6, 14, 5), .init(4, 11, 16, 5),
                .init(7, 16, 10, 5), .init(8, 11, 3, 3), .init(11, 14, 2, 2),
                .init(13, 9, 3, 3)
            ]
        case .sun:
            return [
                .init(10, 2, 4, 3), .init(10, 19, 4, 3), .init(2, 10, 3, 4),
                .init(19, 10, 3, 4), .init(7, 7, 10, 10), .init(5, 5, 3, 3),
                .init(16, 5, 3, 3), .init(5, 16, 3, 3), .init(16, 16, 3, 3)
            ]
        case .cloud:
            return [
                .init(8, 7, 8, 3), .init(5, 10, 14, 4), .init(3, 13, 18, 5),
                .init(6, 18, 12, 2)
            ]
        case .rain:
            return [
                .init(8, 5, 8, 3), .init(5, 8, 14, 4), .init(3, 11, 18, 4),
                .init(6, 17, 2, 4), .init(11, 18, 2, 4), .init(16, 17, 2, 4)
            ]
        case .snow:
            return [
                .init(11, 4, 2, 16), .init(4, 11, 16, 2), .init(7, 7, 3, 3),
                .init(14, 7, 3, 3), .init(7, 14, 3, 3), .init(14, 14, 3, 3)
            ]
        }
    }
    // swiftlint:enable function_body_length

    func uiImage(size: CGFloat = 24) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { _ in
            UIColor.label.setFill()
            let unit = size / 24
            for block in pixels {
                UIBezierPath(rect: CGRect(
                    x: block.x * unit,
                    y: block.y * unit,
                    width: block.width * unit,
                    height: block.height * unit
                )).fill()
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

private struct PixelBlock {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PixelIcon: View {
    let name: StrideIconName
    var size: CGFloat = 24
    var color: Color = .primary

    var body: some View {
        Canvas(opaque: false, colorMode: .linear) { context, _ in
            let unit = size / 24
            for block in name.pixels {
                let rect = CGRect(
                    x: block.x * unit,
                    y: block.y * unit,
                    width: block.width * unit,
                    height: block.height * unit
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StrideIcon: View {
    let name: StrideIconName
    var size: CGFloat = 24
    var color: Color = .primary
    var strokeWeight: CGFloat = 1.8

    var body: some View {
        PixelIcon(name: name, size: size, color: color)
    }
}

extension Label where Title == Text, Icon == StrideIcon {
    init(_ title: String, strideIcon: StrideIconName, size: CGFloat = 20, color: Color = .primary) {
        self.init(title: { Text(title) }, icon: { StrideIcon(name: strideIcon, size: size, color: color) })
    }
}

#Preview {
    let all: [(String, StrideIconName)] = [
        ("run", .run), ("shoe", .shoe), ("road", .road), ("flame", .flame),
        ("bolt", .bolt), ("moon", .moon), ("flag", .flag), ("dumbbell", .dumbbell),
        ("home", .home), ("calendar", .calendar), ("history", .history), ("chart", .chart),
        ("gear", .gear), ("map", .map), ("search", .search), ("heart", .heart),
        ("medal", .medal), ("sun", .sun), ("cloud", .cloud), ("rain", .rain)
    ]
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
        ForEach(all, id: \.0) { name, icon in
            VStack(spacing: 4) {
                PixelIcon(name: icon, size: 28, color: .primary)
                Text(name).font(.system(size: 9))
            }
        }
    }
    .padding()
}
