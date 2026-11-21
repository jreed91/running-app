import CoreGraphics
import Foundation

// MARK: - RouteReplay

/// A run's route drawn on over a few seconds, as a short video to post to a story or a
/// Strava activity: the line grows from the start to the finish while the distance and
/// time count up, then holds on the whole route.
///
/// This is the timing and geometry only, so it can be tested without rendering:
/// ``progress(frame:)`` says how much of the route a frame shows, and
/// ``trail(progress:)`` / ``head(progress:)`` say which part of the line that is. The
/// route is the share card's normalized one (``ShareCardModel/routeSegments``), so route
/// privacy has already cut it, and the line never crosses from one visible piece to the
/// next.
struct RouteReplay: Equatable, Sendable {

    static let framesPerSecond = 30
    /// How long the line takes to draw.
    static let drawSeconds = 4.0
    /// How long the finished route holds before the video ends, long enough to read.
    static let holdSeconds = 2.0

    static var drawFrames: Int { Int(drawSeconds * Double(framesPerSecond)) }
    static var frameCount: Int { Int((drawSeconds + holdSeconds) * Double(framesPerSecond)) }

    /// The visible pieces of the route, in the order they were run.
    let segments: [[CGPoint]]
    /// The summed length of every piece, in the normalized square's units.
    let totalLength: Double

    init(segments: [[CGPoint]]) {
        let pieces = segments.filter { $0.count >= 2 }
        self.segments = pieces
        self.totalLength = pieces.reduce(0) { $0 + Self.length(of: $1) }
    }

    /// A replay needs a line to draw.
    var isPlayable: Bool { totalLength > 0 }

    /// How much of the route `frame` shows, from 0 to 1: eased in and out across the
    /// draw, then 1 for the hold.
    static func progress(frame: Int) -> Double {
        guard drawFrames > 1 else { return 1 }
        let linear = min(max(Double(frame) / Double(drawFrames - 1), 0), 1)
        return easeInOut(linear)
    }

    /// The part of the route drawn at `progress`: whole pieces up to the one being run,
    /// then that piece cut at the exact point reached.
    func trail(progress: Double) -> [[CGPoint]] {
        guard isPlayable else { return [] }
        var remaining = min(max(progress, 0), 1) * totalLength
        var drawn: [[CGPoint]] = []
        for piece in segments {
            guard remaining > 0 else { break }
            let pieceLength = Self.length(of: piece)
            if remaining >= pieceLength {
                drawn.append(piece)
                remaining -= pieceLength
                continue
            }
            var partial = [piece[0]]
            for (from, to) in zip(piece, piece.dropFirst()) {
                let step = Self.distance(from, to)
                if remaining >= step {
                    partial.append(to)
                    remaining -= step
                } else {
                    let fraction = step > 0 ? remaining / step : 0
                    partial.append(CGPoint(
                        x: from.x + (to.x - from.x) * fraction,
                        y: from.y + (to.y - from.y) * fraction
                    ))
                    remaining = 0
                    break
                }
            }
            if partial.count >= 2 { drawn.append(partial) }
            break
        }
        return drawn
    }

    /// Where the runner is at `progress`: the end of the drawn trail, or the start before
    /// anything is drawn.
    func head(progress: Double) -> CGPoint? {
        guard isPlayable else { return nil }
        return trail(progress: progress).last?.last ?? segments.first?.first
    }

    // MARK: Helpers

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func length(of piece: [CGPoint]) -> Double {
        zip(piece, piece.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(b.x - a.x, b.y - a.y))
    }
}
