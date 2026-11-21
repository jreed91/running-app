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

    // MARK: Race invites

    private func invite(on date: String) throws -> RaceInvite {
        let url = try #require(URL(string: "stride://race?name=City%2010K&date=\(date)&distance=10k"))
        return try #require(RaceInvite(url: url))
    }

    @Test func raceInviteOpensThePlanTabWithTheInvitePending() throws {
        let navigation = AppNavigation()
        let invite = try invite(on: "2099-06-01")

        navigation.openRaceInvite(invite)

        #expect(navigation.selectedTab == .plan)
        #expect(navigation.pendingRaceInvite == invite)
        #expect(navigation.pastRaceInviteName == nil)
    }

    @Test func pastRaceInviteSaysSoInsteadOfOpeningAPlan() throws {
        let navigation = AppNavigation()
        let invite = try invite(on: "2001-06-01")

        navigation.openRaceInvite(invite)

        #expect(navigation.pendingRaceInvite == nil)
        #expect(navigation.pastRaceInviteName == "City 10K")
        #expect(navigation.selectedTab == .home)
    }
}
