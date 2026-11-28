import Foundation
import Testing
@testable import StrideCore

/// Covers `RunAnalysis`, the shared timeline behind the run analysis page.
struct RunAnalysisTests {

    /// A reading every 10 m at a steady pace, climbing 1 m every 100 m.
    private func steady(_ meters: Double, secondsPerKm: Double) -> [RunAnalysis.Reading] {
        stride(from: 10.0, through: meters, by: 10).map {
            RunAnalysis.Reading(elapsedSeconds: $0 / 1_000 * secondsPerKm, meters: $0, altitudeMeters: $0 / 100)
        }
    }

    @Test func resamplesOntoEvenDistances() {
        let points = RunAnalysis.points(readings: steady(5_000, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 1_500)
        #expect(points.first?.meters == 0)
        #expect(points.last?.meters == 5_000)
        #expect(points.count <= RunAnalysis.targetPointCount + 2)
        let gaps = zip(points.dropFirst(), points).map { $0.meters - $1.meters }
        #expect(Set(gaps.dropLast().map { ($0 * 1_000).rounded() }).count == 1)
    }

    @Test func steadyPaceReadsSteady() {
        let points = RunAnalysis.points(readings: steady(5_000, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 1_500)
        let paces = points.compactMap(\.paceSecondsPerKm)
        #expect(!paces.isEmpty)
        #expect(paces.allSatisfy { abs($0 - 300) < 0.5 })
    }

    @Test func timeIsInterpolated() {
        let points = RunAnalysis.points(readings: steady(5_000, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 1_500)
        let middle = RunAnalysis.point(nearest: 2_500, in: points)
        #expect(abs((middle?.elapsedSeconds ?? 0) - 750) < 7)
    }

    @Test func altitudeFollowsTheSeries() {
        let points = RunAnalysis.points(readings: steady(2_000, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 600)
        #expect(abs((points.last?.altitudeMeters ?? 0) - 20) < 0.01)
    }

    @Test func noAltitudeForAnImportedSeries() {
        let readings = stride(from: 10.0, through: 1_000, by: 10).map {
            RunAnalysis.Reading(elapsedSeconds: $0 * 0.3, meters: $0, altitudeMeters: nil)
        }
        let points = RunAnalysis.points(readings: readings, heartRateSamples: [], durationSeconds: 300)
        #expect(points.allSatisfy { $0.altitudeMeters == nil })
    }

    @Test func heartRateIsSpreadAcrossTheRun() {
        let samples = Array(repeating: 120.0, count: 50) + Array(repeating: 170.0, count: 50)
        let points = RunAnalysis.points(readings: steady(4_000, secondsPerKm: 300), heartRateSamples: samples, durationSeconds: 1_200)
        #expect(points.first?.heartRate == 120)
        #expect(points.last?.heartRate == 170)
    }

    @Test func aStopHasNoPace() {
        // 1 km steady, ten minutes stood still, 1 km steady.
        var readings = steady(1_000, secondsPerKm: 300)
        readings += stride(from: 10.0, through: 1_000, by: 10).map {
            RunAnalysis.Reading(elapsedSeconds: 900 + $0 * 0.3, meters: 1_000 + $0, altitudeMeters: nil)
        }
        let points = RunAnalysis.points(readings: readings, heartRateSamples: [], durationSeconds: 1_200)
        let atStop = RunAnalysis.point(nearest: 1_000, in: points)
        #expect(atStop?.paceSecondsPerKm == nil)
    }

    @Test func tooShortToDraw() {
        #expect(RunAnalysis.points(readings: steady(150, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 45).isEmpty)
        #expect(RunAnalysis.points(readings: [], heartRateSamples: [], durationSeconds: 0).isEmpty)
    }

    @Test func routeIndexFollowsElapsedTime() {
        #expect(RunAnalysis.routeIndex(atElapsed: 0, duration: 100, coordinateCount: 11) == 0)
        #expect(RunAnalysis.routeIndex(atElapsed: 50, duration: 100, coordinateCount: 11) == 5)
        #expect(RunAnalysis.routeIndex(atElapsed: 500, duration: 100, coordinateCount: 11) == 10)
        #expect(RunAnalysis.routeIndex(atElapsed: 50, duration: 100, coordinateCount: 0) == nil)
    }

    @Test func nearestPointClampsToTheEnds() {
        let points = RunAnalysis.points(readings: steady(2_000, secondsPerKm: 300), heartRateSamples: [], durationSeconds: 600)
        #expect(RunAnalysis.point(nearest: -50, in: points)?.meters == 0)
        #expect(RunAnalysis.point(nearest: 9_999, in: points)?.meters == 2_000)
    }
}
