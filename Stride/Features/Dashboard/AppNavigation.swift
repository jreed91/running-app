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
    case settings
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

    /// Sends the app to `tab`. Named rather than assigned at call sites so the deep-link
    /// handler reads as an instruction, and so there is one place to add anything a tab
    /// switch should also do (scroll to top, dismiss a sheet) if that ever becomes true.
    func select(_ tab: StrideTab) {
        selectedTab = tab
    }
}
