import Foundation
import SwiftData

/// Single source of truth for the SwiftData schema and store location.
///
/// `AppContainer` and `IntentDataProvider` open the SAME on-disk store; if their
/// model lists drift, the intents open the store against a mismatched schema —
/// best case every intent throws, worst case a lightweight migration to the
/// subset model drops tables. Every store open must go through this type.
enum StrideSchema {
    static let models: [any PersistentModel.Type] = [
        UserProfile.self,
        RunWorkout.self,
        StrengthWorkout.self,
        TrainingPlan.self,
        TrainingWeek.self,
        ScheduledWorkout.self,
        SavedRoute.self,
        DeletedWorkout.self
    ]

    static func make() -> Schema { Schema(models) }

    /// Shared on-disk store URL used by both the app and App Intents.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "Stride.store")
    }

    /// The one CloudKit container this app mirrors into, named here so no caller
    /// has to spell it out. It must match `com.apple.developer.icloud-container-identifiers`
    /// in `project.yml`; a store opened against a different identifier silently
    /// syncs somewhere else.
    static let cloudKitContainerID = "iCloud.com.running.stride"
}
