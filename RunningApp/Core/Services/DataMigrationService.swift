import Foundation
import SwiftData

// MARK: - DataMigrationService

/// Wipes all SwiftData stores on TestFlight builds whenever a new version or build is detected.
///
/// This gives beta testers a clean slate on every new release without requiring them to
/// manually delete and reinstall the app. The migration is a no-op on App Store and
/// debug builds.
///
/// Usage: call `runIfNeeded(context:)` once during app launch, after the
/// `ModelContainer` is ready (see `AppContainer`).
@MainActor
final class DataMigrationService {

    // MARK: - UserDefaults keys

    private static let lastMigratedVersionKey = "DataMigration.lastMigratedVersion"
    private static let lastMigratedBuildKey   = "DataMigration.lastMigratedBuild"

    // MARK: - TestFlight detection

    /// `true` when the running binary was distributed via TestFlight.
    ///
    /// TestFlight builds carry a `sandboxReceipt` at the App Store receipt URL.
    /// App Store builds carry a plain `receipt`; debug / simulator builds have no
    /// receipt file at all.
    static var isTestFlight: Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return receiptURL.lastPathComponent == "sandboxReceipt"
    }

    // MARK: - Version helpers

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - Public API

    /// Runs a full data cleanup when on TestFlight and a new version or build is detected.
    ///
    /// The method is synchronous and safe to call from `AppContainer.init()` on the
    /// main actor, before any SwiftUI views are mounted.
    func runIfNeeded(context: ModelContext) {
        guard Self.isTestFlight else { return }

        let defaults       = UserDefaults.standard
        let lastVersion    = defaults.string(forKey: Self.lastMigratedVersionKey)
        let lastBuild      = defaults.string(forKey: Self.lastMigratedBuildKey)
        let currentVersion = Self.currentVersion
        let currentBuild   = Self.currentBuild

        guard lastVersion != currentVersion || lastBuild != currentBuild else { return }

        performCleanup(context: context)

        defaults.set(currentVersion, forKey: Self.lastMigratedVersionKey)
        defaults.set(currentBuild,   forKey: Self.lastMigratedBuildKey)
    }

    // MARK: - Cleanup

    private func performCleanup(context: ModelContext) {
        // Delete in dependency order so cascades don't cause constraint violations.
        // Each call is explicit because SwiftData's delete(model:) is generic and
        // cannot be dispatched through an existential.
        var failed = false

        func attempt<T: PersistentModel>(_ type: T.Type) {
            do { try context.delete(model: type) } catch {
                failed = true
                print("[DataMigrationService] Failed to delete \(type): \(error)")
            }
        }

        attempt(ScheduledWorkout.self)
        attempt(TrainingWeek.self)
        attempt(TrainingPlan.self)
        attempt(RunWorkout.self)
        attempt(SavedRoute.self)
        attempt(UserProfile.self)

        guard !failed else { return }

        do {
            try context.save()
        } catch {
            print("[DataMigrationService] Failed to save after cleanup: \(error)")
        }
    }
}
