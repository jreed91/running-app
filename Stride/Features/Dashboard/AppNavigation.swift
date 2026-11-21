import Foundation

// MARK: - StrideTab

/// The tabs `MainTabView` shows, as values rather than positions.
///
/// `TabView` only gained a selection at all because something outside it now needs to
/// drive one: a widget tapped on the Home Screen should land on the surface it was
/// showing, not merely foreground the app onto whatever was open last (B1).
enum StrideTab: String, Hashable, Sendable, CaseIterable {
    case home
    case plan
    case history
    case progress
}

// MARK: - AppNavigation

/// Which tab is on screen.
///
/// Owned by `AppContainer` and read through the environment, for the same reason
/// `ActiveRunPresentation` is: the writer (`StrideApp`'s `onOpenURL`, at the scene root)
/// and the reader (`MainTabView`, several levels down) are different views, so `@State`
/// in either of them cannot be the source of truth.
@MainActor
@Observable
final class AppNavigation {

    var selectedTab: StrideTab = .home

    /// Settings, open over the tabs. It was a fifth tab; it is a sheet now, opened from
    /// the profile button on Home, because it is visited rarely and a tab is for places
    /// the runner goes every day.
    var isSettingsPresented = false

    /// A scheduled workout whose detail the Plan tab should push, set by a morning-reminder
    /// tap. The Plan tab resolves it against its store and clears it, so it is a request
    /// rather than state: reading it after that returns `nil`.
    var requestedScheduledWorkoutID: UUID?

    /// A race invite a friend sent (`RaceInvite`), waiting to become a plan: the new-plan
    /// flow opens on it once the tabs are up, and first-run onboarding fills its race in
    /// from it. Whichever takes it clears it.
    var pendingRaceInvite: RaceInvite?

    /// The name of an invited race that has already happened, for the "too late" alert.
    var pastRaceInviteName: String?

    /// Sends the app to `tab`. Named rather than assigned at call sites so the deep-link
    /// handler reads as an instruction, and so there is one place to add anything a tab
    /// switch should also do (scroll to top, dismiss a sheet) if that ever becomes true.
    func select(_ tab: StrideTab) {
        selectedTab = tab
    }

    /// Opens Settings over whatever tab is showing.
    func openSettings() {
        isSettingsPresented = true
    }

    /// Opens a friend's race invite: on the Plan tab with the new-plan flow filled in, or
    /// in onboarding for a runner who hasn't finished it yet. A race already run says so
    /// rather than building a plan to a day that has gone.
    func openRaceInvite(_ invite: RaceInvite, now: Date = Date()) {
        if invite.hasPassed(now: now) {
            pastRaceInviteName = invite.name
            return
        }
        select(.plan)
        pendingRaceInvite = invite
    }

    /// Sends the app to the Plan tab with `workoutID`'s detail pushed on it.
    func openScheduledWorkout(_ workoutID: UUID) {
        select(.plan)
        requestedScheduledWorkoutID = workoutID
    }
}
