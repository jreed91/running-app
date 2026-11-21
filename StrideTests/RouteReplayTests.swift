import Testing
import CoreGraphics
import Foundation
@testable import Stride

// MARK: - Route replay tests
//
// The timing and geometry of the route replay video: how much of the line each frame
// draws, and which part of it.

struct RouteReplayTests {

    /// Two pieces of length 1 each (a gap where route privacy cut the middle).
    private let twoPieces: [[CGPoint]] = [
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
        [CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1)],
    ]

    @Test("Six seconds at 30 fps: four drawing, two holding")
    func frameCounts() {
        #expect(RouteReplay.frameCount == 180)
        #expect(RouteReplay.drawFrames == 120)
    }

    @Test("Progress starts at 0, reaches 1 on the last draw frame, and holds")
    func progressCurve() {
        #expect(RouteReplay.progress(frame: 0) == 0)
        #expect(RouteReplay.progress(frame: RouteReplay.drawFrames - 1) == 1)
        #expect(RouteReplay.progress(frame: RouteReplay.frameCount - 1) == 1)
        let middle = RouteReplay.progress(frame: (RouteReplay.drawFrames - 1) / 2)
        #expect(abs(middle - 0.5) < 0.05)
    }

    @Test("Progress never goes backwards")
    func progressIsMonotonic() {
        let values = (0..<RouteReplay.frameCount).map(RouteReplay.progress(frame:))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Length sums every piece, ignoring single points")
    func totalLength() {
        let replay = RouteReplay(segments: twoPieces + [[CGPoint(x: 5, y: 5)]])
        #expect(abs(replay.totalLength - 2) < 1e-9)
        #expect(replay.segments.count == 2)
    }

    @Test("Halfway draws the first piece whole and nothing of the second")
    func halfway() {
        let trail = RouteReplay(segments: twoPieces).trail(progress: 0.5)
        #expect(trail.count == 1)
        #expect(trail.first == twoPieces[0])
    }

    @Test("Three quarters cuts the second piece at its middle point")
    func threeQuarters() throws {
        let replay = RouteReplay(segments: twoPieces)
        let trail = replay.trail(progress: 0.75)
        #expect(trail.count == 2)
        let last = try #require(trail.last?.last)
        #expect(abs(last.x - 0.5) < 1e-9 && abs(last.y - 1) < 1e-9)
        #expect(replay.head(progress: 0.75) == last)
    }

    @Test("A point inside a step is interpolated")
    func interpolates() throws {
        let replay = RouteReplay(segments: [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]])
        let head = try #require(replay.head(progress: 0.25))
        #expect(abs(head.x - 0.25) < 1e-9)
    }

    @Test("All of it at the end, the start before anything is drawn")
    func ends() {
        let replay = RouteReplay(segments: twoPieces)
        #expect(replay.trail(progress: 1) == twoPieces)
        #expect(replay.trail(progress: 0).isEmpty)
        #expect(replay.head(progress: 0) == CGPoint(x: 0, y: 0))
    }

    @Test("No route, no replay")
    func empty() {
        let replay = RouteReplay(segments: [])
        #expect(!replay.isPlayable)
        #expect(replay.trail(progress: 1).isEmpty)
        #expect(replay.head(progress: 1) == nil)
    }
}
