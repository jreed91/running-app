import Testing
import Foundation
@testable import Stride

// MARK: - WeatherService.fetchStrategy tests
//
// Covers H7: historical HealthKit imports must not be stamped with today's
// weather. Recent runs stay on the live forecast; older runs route to the
// historical hourly range around the workout.

struct WeatherServiceStrategyTests {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("A run finished minutes ago uses the current forecast")
    func recentUsesCurrent() {
        let date = now.addingTimeInterval(-5 * 60)
        #expect(WeatherService.fetchStrategy(for: date, now: now) == .current)
    }

    @Test("A run just under the threshold still uses current")
    func justUnderThresholdUsesCurrent() {
        let date = now.addingTimeInterval(-(WeatherService.historicalThreshold - 60))
        #expect(WeatherService.fetchStrategy(for: date, now: now) == .current)
    }

    @Test("A six-week-old imported run uses the historical range around the workout")
    func oldRunUsesHistorical() {
        let date = now.addingTimeInterval(-42 * 24 * 3600)
        let strategy = WeatherService.fetchStrategy(for: date, now: now)
        guard case let .historical(start, end) = strategy else {
            Issue.record("Expected historical, got \(strategy)")
            return
        }
        // Window brackets the workout time by ±1 h.
        #expect(start == date.addingTimeInterval(-3600))
        #expect(end == date.addingTimeInterval(3600))
        #expect(start < date && date < end)
    }
}
