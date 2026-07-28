#if DEBUG
import CoreData
import Foundation
import SwiftData

/// Uploads the current SwiftData schema to the CloudKit **development** environment,
/// so every record type and field exists on the server before anyone deploys it to
/// production.
///
/// Why this is not optional. Left to itself, `NSPersistentCloudKitContainer` creates a
/// record type the first time a record of that type is written, so the development
/// schema only ever contains what someone happened to exercise on a development device.
/// A field nobody used — a lap on a run nobody lapped, a `DeletedWorkout` on a device
/// where nobody deleted a HealthKit workout — simply is not on the server, and cannot be
/// part of the schema that gets deployed. Apple: "You manually initialize your app's
/// CloudKit schema during development … but you need to promote that schema to
/// production before releasing your app." Initializing writes a temporary instance of
/// *every* record type and then removes it, which is what makes the deployed schema
/// complete rather than incidental (F2).
///
/// **App Store builds can only see the production environment.** That is what makes the
/// gap invisible: sync works for every developer and TestFlight tester on the
/// development environment and then does nothing once the app ships. Deploying is a
/// manual step in CloudKit Console and is additive-only — see the release gate in
/// `docs/CLOUDKIT_VALIDATION.md`.
///
/// Run on demand rather than on every launch: this uploads records and takes real time,
/// and the schema only changes when `StrideSchema.models` or a `@Model`'s stored
/// properties do.
///
/// ```
/// xcodebuild ... -destination 'platform=iOS,name=<device>' \
///   # then launch with the argument below, e.g. via the scheme's Arguments Passed On Launch
/// ```
///
/// The whole type is `#if DEBUG`, per Apple's instruction to keep schema initialization
/// out of production builds.
enum CloudKitSchemaInitializer {

    /// Launch argument that requests a schema upload. Set it in the Xcode scheme's
    /// *Arguments Passed On Launch*, run once on a device signed into iCloud, then
    /// unset it.
    static let launchArgument = "--init-cloudkit-schema"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Uploads the schema if the launch argument is present. Must be called *before*
    /// the app's `ModelContainer` is created — the store is loaded and then explicitly
    /// removed here, because Apple warns that leaving it loaded means "both frameworks
    /// attempting to sync data to CloudKit".
    static func runIfRequested() {
        guard isRequested else { return }

        #if targetEnvironment(simulator)
        AppLogger.log(
            "Schema initialization skipped: run it on a device signed into iCloud, not the simulator",
            label: "CloudKit",
            level: .warning
        )
        #else
        do {
            try initializeSchema()
            AppLogger.log(
                "Development schema uploaded. Verify the record types in CloudKit Console, then Deploy Schema Changes before shipping.",
                label: "CloudKit",
                level: .notice
            )
        } catch {
            // Never fatal: a failed upload must not stop the app from launching, and
            // the next launch with the argument set can try again.
            for line in CloudKitDiagnostics.errorDiagnosticLines(error, path: "schemaInit") {
                AppLogger.log(line, label: "CloudKit", level: .error)
            }
        }
        #endif
    }

    private static func initializeSchema() throws {
        // Autoreleasepool so the Core Data stack is torn down before the SwiftData one
        // is built, which is the shape Apple's sample uses.
        try autoreleasepool {
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: StrideSchema.models) else {
                throw NSError(
                    domain: "CloudKitSchemaInitializer",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not build a managed object model from StrideSchema.models."
                    ]
                )
            }

            let description = NSPersistentStoreDescription(url: StrideSchema.storeURL)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: StrideSchema.cloudKitContainerID
            )
            // Synchronously, so the load finishes before the schema call below.
            description.shouldAddStoreAsynchronously = false

            let container = NSPersistentCloudKitContainer(name: "Stride", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]

            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }

            try container.initializeCloudKitSchema()

            // Unload before returning: the app is about to open the same file through
            // SwiftData, and two mirroring stacks over one store is the arrangement
            // this whole dance exists to avoid.
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
}
#endif
