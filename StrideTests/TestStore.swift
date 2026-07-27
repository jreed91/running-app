import Foundation
import SwiftData
@testable import Stride

/// Builds SwiftData containers for tests, each backed by its own store file.
///
/// The obvious way to get a scratch context — `AppContainer.preview().modelContainer
/// .mainContext` — has two independent problems, and every suite that used it eventually
/// aborted the whole test host.
///
/// The first is lifetime: the container reached through in that expression is a temporary,
/// released at the end of the statement, leaving the context pointing at a store that is
/// being torn down.
///
/// The second is that `isStoredInMemoryOnly: true` does *not* give each container a store
/// of its own. Every in-memory `ModelConfiguration` resolves to the same store URL —
/// `/dev/null`, regardless of the `name:` argument, which was verified directly rather
/// than assumed — so containers built that way share one store and one SQLite connection
/// pool. That is invisible in the app, which builds a single container and keeps it for
/// the process lifetime, and fatal in tests, which build one per test case. The host dies
/// on a later save inside `-[NSSQLCore _obtainPermanentIDsForObjects:...]` with
/// `NSInternalInconsistencyException: No eligible connection available`.
///
/// Giving each container a real file URL fixes both: the stores are genuinely separate,
/// and nothing another test does can pull one out from under a context still using it.
/// This is the same fix that stopped `IntentDataProviderTests` aborting the host.
///
/// A crash here reports as a 0.000s failure on whichever tests had not finished, in *any*
/// suite sharing the host — which is why this looked for so long like a cross-suite
/// concurrency bug, and why the suites named in the failures were usually innocent.
@MainActor
enum TestStore {

    /// Containers are held for the process lifetime so nothing is ever released while a
    /// context handed out from it is still in use. Cheap: a probe built and saved through
    /// 400 containers with no growth in open file descriptors.
    private static var retained: [AppContainer] = []

    /// A fresh, empty container with a store file nothing else touches.
    ///
    /// Prefer this to `AppContainer.preview()` in tests. Binding `preview()` to a local is
    /// not enough on its own — it still shares `/dev/null` with every other in-memory
    /// container in the host.
    static func makeContainer() -> AppContainer {
        let container = AppContainer(
            inMemory: false,
            syncEnabledOverride: false,
            forceCloudKit: false,
            storeURLOverride: makeStoreURL()
        )
        retained.append(container)
        return container
    }

    /// The main context of a fresh, empty container.
    static func makeContext() -> ModelContext {
        makeContainer().modelContainer.mainContext
    }

    /// A unique store URL under the temporary directory. Left behind deliberately: the
    /// simulator's temporary directory is per-install and the files are small, so deleting
    /// them would mean tearing a store down mid-run, which is the problem this type exists
    /// to avoid.
    private static func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stride-tests-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("store")
    }
}
