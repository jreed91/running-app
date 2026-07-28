import SwiftUI
import WidgetKit

// MARK: - StrideWidgetKind

/// The `kind` string each widget is registered under.
///
/// Named constants because a kind is **persistent identity**: it is what iOS keys an
/// already-placed widget to, so changing one of these silently orphans every instance of
/// that widget on every Home Screen it is on. Keep them stable, and never reuse a retired
/// one for something that renders differently.
enum StrideWidgetKind {
    static let nextWorkout = "StrideNextWorkoutWidget"
    static let weeklyGoal = "StrideWeeklyGoalWidget"
    static let raceCountdown = "StrideRaceCountdownWidget"
    static let streak = "StrideStreakWidget"
    static let coachTip = "StrideCoachTipWidget"
}

// MARK: - StrideWidgetsBundle

/// Stride's widget extension.
///
/// It started as the home for the run's Live Activity (U5b) — an `ActivityConfiguration`
/// can only be declared by a widget extension, not by the app — and now also carries the
/// Home Screen and Lock Screen widgets (B1). All five of the latter are `StaticConfiguration`s
/// over the same ``StrideSnapshotProvider``: the extension cannot reach the app's SwiftData
/// store, so everything they draw comes from the one snapshot the app publishes into the
/// shared App Group. See ``WidgetSnapshot``.
@main
struct StrideWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
        NextWorkoutWidget()
        WeeklyGoalWidget()
        RaceCountdownWidget()
        StreakWidget()
        CoachTipWidget()
    }
}
