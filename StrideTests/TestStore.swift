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
///
/// ## Two entry points, and why
///
/// `makeContext()` opens a bare `ModelContainer`; `makeContainer()` builds a whole
/// `AppContainer`. The split exists because `AppContainer.init` is not a store opener —
/// it is the app's composition root, and constructing one wires four repositories and
/// fourteen services, including an `AVSpeechSynthesizer` that configures the app's audio
/// session, `NotificationService.shared` (which installs the `UNUserNotificationCenter`
/// delegate), an instrumented `URLSession`, the CloudKit diagnostics observers, and a
/// long-lived `Task` reading the synced-run tap stream. Every one of those is retained for
/// the rest of the process by `retained` below.
///
/// Around ninety of those were being built per run, and the overwhelming majority of the
/// call sites only ever reached `container.modelContainer.mainContext` through them.
/// Reach for `makeContainer()` only when the test genuinely exercises a service or
/// repository the container owns; when a `ModelContext` is all that is wanted, which is
/// the usual case, `makeContext()` is the same fixture without the app attached.
@MainActor
enum TestStore {

    /// Built once rather than per container. `Schema.init` walks all eight `@Model` types
    /// and reflects over their properties, and the result is immutable and shareable —
    /// there is no reason for every store in the run to pay for its own copy.
    private static let schema = StrideSchema.make()

    /// Containers are held for the process lifetime so nothing is ever released while a
    /// context handed out from it is still in use. Cheap: a probe built and saved through
    /// 400 containers with no growth in open file descriptors.
    private static var retained: [Any] = []

    /// A fresh, empty `ModelContext` over a store file nothing else touches.
    ///
    /// This is the one to reach for by default. It gives the same isolation guarantee as
    /// `makeContainer()` — its own file URL, retained for the process lifetime — without
    /// constructing the app's service graph behind it.
    static func makeContext() -> ModelContext {
        // `.none`, and not by omission. The test host *is* the Stride app, so its
        // entitlements name a CloudKit container, and `cloudKitDatabase`'s default of
        // `.automatic` resolves from exactly those — every scratch store in the suite
        // was mirroring test fixtures into the team's real development container (F1).
        let config = ModelConfiguration(
            schema: schema,
            url: makeStoreURL(),
            cloudKitDatabase: .none
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Unrecoverable and never expected: the URL is freshly generated under the
            // temporary directory, so nothing is there to migrate or collide with. Trapping
            // here names the fixture; letting it propagate would surface as an unrelated
            // failure in whichever test asked for the context.
            fatalError("[TestStore] Could not open a scratch store at \(config.url): \(error)")
        }
        retained.append(container)
        return container.mainContext
    }

    /// A fresh, empty `AppContainer` with a store file nothing else touches.
    ///
    /// Only for tests that exercise something the container owns — a repository, a
    /// service, the wiring between them. For a plain `ModelContext`, use `makeContext()`.
    ///
    /// Prefer this to `AppContainer.preview()`. Binding `preview()` to a local is not
    /// enough on its own — it still shares `/dev/null` with every other in-memory
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
