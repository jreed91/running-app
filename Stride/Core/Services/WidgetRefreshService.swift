import Foundation
import SwiftData
import WidgetKit

// MARK: - WidgetRefreshService

/// Keeps the Home Screen and Lock Screen widgets in step with the app's data (B1).
///
/// The widget extension cannot read the app's SwiftData store — it runs in its own
/// process, with its own container — so the app is the only thing that can tell it
/// anything. This is the one place that happens: read the store, build a
/// ``WidgetSnapshot``, write it to the shared App Group, and ask WidgetKit to redraw.
///
/// **A reload is only requested when the snapshot actually changed.** WidgetKit budgets
/// reloads per widget per day and quietly stops honouring them past that, so spending one
/// every time the app is foregrounded — the most common refresh trigger by far — would
/// mean the reload that matters, the one right after a run is saved, is the one that gets
/// dropped. `WidgetSnapshot` is `Equatable` for exactly this comparison.
@MainActor
enum WidgetRefreshService {

    /// Rebuilds the snapshot from `context` and reloads the widgets if it moved.
    ///
    /// Failure is silent and total: no App Group (entitlement missing, or the identifier
    /// not yet registered — see ``StrideAppGroup``), no store, no write. Nothing in the
    /// app depends on this succeeding, and the cost of it failing is a widget one refresh
    /// behind, which is not worth an alert or a crash.
    @discardableResult
    static func refresh(
        context: ModelContext,
        appSettings: AppSettings,
        now: Date = Date(),
        store: WidgetSnapshotStore = .shared,
        reload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) -> Bool {
        // UI tests run against an in-memory container seeded for a specific screen.
        // Publishing that to the real App Group would leave fixture data on the device's
        // Home Screen after the test process exits.
        guard !UITestingSupport.isEnabled else { return false }

        let snapshot = makeSnapshot(context: context, appSettings: appSettings, now: now)

        // `generatedAt` moves every time, so compare everything else.
        if let existing = store.load(), isEquivalent(existing, snapshot) {
            return false
        }

        guard store.save(snapshot) else { return false }
        reload()
        AppLogger.log("Widget snapshot refreshed.", label: "Widgets", level: .debug)
        return true
    }

    /// Drops the snapshot and blanks the widgets — for "reset all data", where leaving
    /// the last plan on the Home Screen would be the one place the deleted data survived.
    static func clear(reload: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        WidgetSnapshotStore.shared.clear()
        reload()
    }

    // MARK: - Snapshot

    static func makeSnapshot(
        context: ModelContext,
        appSettings: AppSettings,
        now: Date = Date()
    ) -> WidgetSnapshot {
        WidgetSnapshotBuilder.snapshot(
            plan: activePlan(in: context),
            runs: runs(in: context),
            profile: profile(in: context),
            weeklyGoalMeters: appSettings.weeklyGoalMeters,
            unit: appSettings.unitPreference,
            now: now
        )
    }

    /// Everything but `generatedAt`, which changes on every build and would defeat the
    /// comparison that keeps the reload budget intact.
    private static func isEquivalent(_ lhs: WidgetSnapshot, _ rhs: WidgetSnapshot) -> Bool {
        var normalized = rhs
        normalized.generatedAt = lhs.generatedAt
        return lhs == normalized
    }

    // MARK: - Fetches

    private static func activePlan(in context: ModelContext) -> TrainingPlan? {
        var descriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Duplicates are reconciled at launch by `ProfileRestoreDeduplicator`; newest
        // wins here for the same reason it does there.
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Every run, because the longest-streak figure is defined over all of them —
    /// the same read `AchievementsView` already makes with an unbounded `@Query`, and
    /// walks are excluded here for the same reason they are there (N38).
    private static func runs(in context: ModelContext) -> [RunWorkout] {
        (try? context.fetch(RunWorkout.runsOnlyDescriptor(
            sortBy: [SortDescriptor(\.date)]
        ))) ?? []
    }

    private static func profile(in context: ModelContext) -> UserProfile? {
        var descriptor = FetchDescriptor<UserProfile>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
