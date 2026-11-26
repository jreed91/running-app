import Foundation
import Testing
@testable import Stride

// MARK: - Watch run metrics tests
//
// The Watch's live run screen draws only what `WatchRunMetrics` works out, and the watch
// target has no test bundle of its own, so its pace, zone and formatting rules are pinned
// here.

struct WatchRunMetricsTests {

    @Test("Current pace comes from speed, and standing still shows no pace")
    func currentPace() throws {
        let running = WatchRunMetrics(elapsedSeconds: 600, distanceMeters: 2_000, currentSpeedMetersPerSecond: 4)
        #expect(try #require(running.currentPaceSecondsPerKm) == 250)

        let standing = WatchRunMetrics(elapsedSeconds: 600, distanceMeters: 2_000, currentSpeedMetersPerSecond: 0.2)
        #expect(standing.currentPaceSecondsPerKm == nil)
        #expect(WatchRunMetrics.zero.currentPaceSecondsPerKm == nil)
    }

    @Test("Average pace waits for the first 50 m")
    func averagePace() throws {
        #expect(WatchRunMetrics(elapsedSeconds: 20, distanceMeters: 40).averagePaceSecondsPerKm == nil)
        let run = WatchRunMetrics(elapsedSeconds: 1_500, distanceMeters: 5_000)
        #expect(try #require(run.averagePaceSecondsPerKm) == 300)
    }

    @Test("Zone needs both a reading and a max heart rate")
    func zone() {
        let run = WatchRunMetrics(elapsedSeconds: 60, distanceMeters: 200, heartRateBPM: 160)
        #expect(run.zone(maxHeartRateBPM: 186) == HeartRateZoneService.zone(forBPM: 160, maxHR: 186))
        #expect(run.zone(maxHeartRateBPM: nil) == nil)
        #expect(run.zone(maxHeartRateBPM: 0) == nil)
        #expect(WatchRunMetrics(elapsedSeconds: 60, distanceMeters: 200).zone(maxHeartRateBPM: 186) == nil)
    }

    @Test("Elapsed time reads m:ss under an hour and h:mm:ss after")
    func elapsedText() {
        #expect(WatchRunMetrics.elapsedText(0) == "0:00")
        #expect(WatchRunMetrics.elapsedText(245.9) == "4:05")
        #expect(WatchRunMetrics.elapsedText(3_729) == "1:02:09")
        #expect(WatchRunMetrics.elapsedText(-5) == "0:00")
    }

    @Test("Distance reads in kilometres or miles")
    func distanceText() {
        #expect(WatchRunMetrics.distanceText(5_234, metric: true) == "5.23")
        #expect(WatchRunMetrics.distanceText(1_609.344, metric: false) == "1.00")
        #expect(WatchRunMetrics.distanceUnit(metric: false) == "mi")
    }

    @Test("Pace reads per kilometre or per mile, and no pace reads as dashes")
    func paceText() {
        #expect(WatchRunMetrics.paceText(secondsPerKm: 298, metric: true) == "4:58")
        #expect(WatchRunMetrics.paceText(secondsPerKm: 300, metric: false) == "8:03")
        #expect(WatchRunMetrics.paceText(secondsPerKm: nil, metric: true) == "--:--")
        #expect(WatchRunMetrics.paceText(secondsPerKm: 4_000, metric: true) == "--:--")
        #expect(WatchRunMetrics.paceUnit(metric: true) == "/km")
    }
}
