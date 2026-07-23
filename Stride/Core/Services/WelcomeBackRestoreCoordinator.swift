import CloudKit
import Foundation

struct WelcomeBackRestoreCoordinator {

    struct ICloudStatusPresentation: Equatable {
        var issueMessage: String?
        var shouldAutoTransition: Bool
    }

    /// How the initial-sync wait concluded. Only `imported`/`noRemoteData` are
    /// definitive; `timedOut` means we never heard back and must not be treated as
    /// "sync finished, store is empty → new user".
    enum InitialSyncOutcome: Equatable {
        /// No CloudKit data will ever arrive (sync toggle off, or account unusable).
        case noRemoteData
        /// CloudKit signalled that its initial import completed.
        case imported
        /// The import never signalled completion before the fallback timeout.
        case timedOut
    }

    typealias ImportWaiter = @Sendable (UInt64) async -> Bool
    typealias Sleeper = @Sendable (UInt64) async -> Void

    private let sleep: Sleeper

    init(
        sleep: @escaping Sleeper = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    func presentation(for status: CKAccountStatus) -> ICloudStatusPresentation {
        switch status {
        case .available:
            .init(issueMessage: nil, shouldAutoTransition: false)
        case .noAccount:
            .init(
                issueMessage: "iCloud is not signed in on this device. Your previous plans are stored in iCloud.",
                shouldAutoTransition: true
            )
        case .restricted:
            .init(
                issueMessage: "iCloud access is restricted on this device, so previous plans can't be restored yet.",
                shouldAutoTransition: true
            )
        case .couldNotDetermine:
            .init(
                issueMessage: "iCloud status couldn't be verified right now. Check your network and iCloud settings.",
                shouldAutoTransition: true
            )
        case .temporarilyUnavailable:
            .init(
                issueMessage: "iCloud is temporarily unavailable. Please keep this screen open and try again in a moment.",
                shouldAutoTransition: false
            )
        @unknown default:
            .init(
                issueMessage: "Unable to verify iCloud status. Check iCloud settings and network, then try again.",
                shouldAutoTransition: true
            )
        }
    }

    func waitBeforeAutoTransition() async {
        await sleep(6_000_000_000)
    }

    @discardableResult
    func waitForInitialSync(
        iCloudSyncEnabled: Bool,
        waitForImport: ImportWaiter
    ) async -> InitialSyncOutcome {
        guard iCloudSyncEnabled else {
            await sleep(1_500_000_000)
            return .noRemoteData
        }

        let imported = await waitForImport(60_000_000_000)
        await sleep(1_000_000_000)
        return imported ? .imported : .timedOut
    }

    /// Whether an empty store should send the user into fresh onboarding. A
    /// timeout is inconclusive — a returning user's records may still be arriving
    /// — so we keep them on the restore screen (which still offers a manual
    /// "Start fresh") rather than stranding them in new-user onboarding.
    func shouldStartFresh(outcome: InitialSyncOutcome, hasData: Bool) -> Bool {
        switch outcome {
        case .timedOut:
            return false
        case .noRemoteData, .imported:
            return !hasData
        }
    }
}
