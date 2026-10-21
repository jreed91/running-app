import Testing
import Foundation
@testable import Stride

// MARK: - Opening a scheduled workout from a notification
//
// Tapping the morning reminder used to land on the Plan tab and stop there. It now asks
// the Plan tab to push the session the banner named; these pin the request's shape.

@MainActor
struct AppNavigationTests {

    @Test func openScheduledWorkoutSelectsPlanAndRequestsTheWorkout() {
        let navigation = AppNavigation()
        let id = UUID()

        navigation.openScheduledWorkout(id)

        #expect(navigation.selectedTab == .plan)
        #expect(navigation.requestedScheduledWorkoutID == id)
    }

    @Test func plainTabSelectionMakesNoWorkoutRequest() {
        let navigation = AppNavigation()

        navigation.select(.plan)

        #expect(navigation.requestedScheduledWorkoutID == nil)
    }
}
