import Testing
@testable import Stride

// MARK: - RouteGeniusViewModel.distanceInputText tests
//
// The text Route Genius's distance field starts with when it opens from a planned workout.

@MainActor
struct RouteGeniusDistanceInputTests {

    @Test("Whole distances drop the decimal")
    func wholeDistance() {
        #expect(RouteGeniusViewModel.distanceInputText(meters: 5_000, unit: .metric) == "5")
        #expect(RouteGeniusViewModel.distanceInputText(meters: 8 * 1_609.344, unit: .imperial) == "8")
    }

    @Test("Other distances keep one decimal in the runner's unit")
    func oneDecimal() {
        #expect(RouteGeniusViewModel.distanceInputText(meters: 10_000, unit: .imperial) == "6.2")
        #expect(RouteGeniusViewModel.distanceInputText(meters: 12_345, unit: .metric) == "12.3")
    }

    @Test("Rounds up to a whole number without a trailing .0")
    func roundsToWhole() {
        #expect(RouteGeniusViewModel.distanceInputText(meters: 4_980, unit: .metric) == "5")
    }

    @Test("No distance leaves the field empty")
    func empty() {
        #expect(RouteGeniusViewModel.distanceInputText(meters: 0, unit: .metric).isEmpty)
        #expect(RouteGeniusViewModel.distanceInputText(meters: 20, unit: .metric).isEmpty)
        #expect(RouteGeniusViewModel.distanceInputText(meters: .nan, unit: .imperial).isEmpty)
    }

    @Test("The text parses back to about the same distance")
    func roundTrips() {
        let text = RouteGeniusViewModel.distanceInputText(meters: 16_093, unit: .imperial)
        let miles = Double(text) ?? 0
        #expect(abs(miles * 1_609.344 - 16_093) < 161)
    }
}
