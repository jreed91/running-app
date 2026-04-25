import CloudKit
import Foundation
import Testing
@testable import Stride

struct WelcomeBackRestoreCoordinatorTests {

    actor Recorder<Value: Sendable> {
        private var values: [Value] = []

        func append(_ value: Value) {
            values.append(value)
        }

        func snapshot() -> [Value] {
            values
        }
    }

    @Test("Available iCloud account shows no issue and does not auto-transition")
    func availableStatusPresentation() {
        let coordinator = WelcomeBackRestoreCoordinator()
        let presentation = coordinator.presentation(for: .available)

        #expect(presentation.issueMessage == nil)
        #expect(presentation.shouldAutoTransition == false)
    }

    @Test("Unavailable account statuses show an issue and auto-transition")
    func unavailableStatusesAutoTransition() {
        let coordinator = WelcomeBackRestoreCoordinator()
        let statuses: [CKAccountStatus] = [.noAccount, .restricted, .couldNotDetermine]

        for status in statuses {
            let presentation = coordinator.presentation(for: status)
            #expect(presentation.issueMessage != nil)
            #expect(presentation.shouldAutoTransition)
        }
    }

    @Test("Temporarily unavailable iCloud keeps the user on the restore screen")
    func temporarilyUnavailableDoesNotAutoTransition() {
        let coordinator = WelcomeBackRestoreCoordinator()
        let presentation = coordinator.presentation(for: .temporarilyUnavailable)

        #expect(presentation.issueMessage?.contains("temporarily unavailable") == true)
        #expect(presentation.shouldAutoTransition == false)
    }

    @Test("Disabled sync waits briefly and skips import polling")
    func disabledSyncShortCircuitsImportWait() async {
        let sleepCalls = Recorder<UInt64>()
        let importWaitCalls = Recorder<Int>()
        let coordinator = WelcomeBackRestoreCoordinator(
            sleep: { await sleepCalls.append($0) }
        )

        await coordinator.waitForInitialSync(iCloudSyncEnabled: false) { _ in
            await importWaitCalls.append(1)
            return false
        }

        #expect(await importWaitCalls.snapshot().isEmpty)
        #expect(await sleepCalls.snapshot() == [1_500_000_000])
    }

    @Test("Enabled sync waits for import and then gives SwiftData time to publish")
    func enabledSyncWaitsForImportAndPublishDelay() async {
        let sleepCalls = Recorder<UInt64>()
        let importTimeouts = Recorder<UInt64>()
        let coordinator = WelcomeBackRestoreCoordinator(
            sleep: { await sleepCalls.append($0) }
        )

        await coordinator.waitForInitialSync(iCloudSyncEnabled: true) { timeout in
            await importTimeouts.append(timeout)
            return true
        }

        #expect(await importTimeouts.snapshot() == [60_000_000_000])
        #expect(await sleepCalls.snapshot() == [1_000_000_000])
    }

    @Test("Start-fresh decision only triggers after sync finishes with no data")
    func startFreshDecision() {
        let coordinator = WelcomeBackRestoreCoordinator()

        #expect(coordinator.shouldStartFresh(initialSyncFinished: false, hasData: false) == false)
        #expect(coordinator.shouldStartFresh(initialSyncFinished: true, hasData: true) == false)
        #expect(coordinator.shouldStartFresh(initialSyncFinished: true, hasData: false))
    }
}
