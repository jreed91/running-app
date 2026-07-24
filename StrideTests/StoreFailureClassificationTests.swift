import Testing
import Foundation
@testable import Stride

/// Covers which store-open failures are allowed to move the user's database aside.
///
/// Getting this wrong in the permissive direction destroys the appearance of a
/// user's entire training history: a transient failure that would have cleared on
/// the next launch instead renames the file and the app starts up empty.
@MainActor
struct StoreFailureClassificationTests {

    private func cocoaError(_ code: Int, underlying: NSError? = nil) -> NSError {
        var userInfo: [String: Any] = [:]
        if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
    }

    @Test("Incompatible version hash is treated as a migration failure")
    func incompatibleVersionHashIsMigration() {
        #expect(AppContainer.isLikelyMigrationFailure(cocoaError(134_100)))
    }

    @Test("Every code in the Core Data migration range is recognised")
    func migrationRangeIsRecognised() {
        for code in [134_110, 134_130, 134_140, 134_170, 134_190, 134_199] {
            #expect(AppContainer.isLikelyMigrationFailure(cocoaError(code)), "code \(code)")
        }
    }

    @Test("Incompatible schema is treated as a migration failure")
    func incompatibleSchemaIsMigration() {
        #expect(AppContainer.isLikelyMigrationFailure(cocoaError(134_020)))
    }

    @Test("A migration cause wrapped in an outer error is still found")
    func nestedUnderlyingErrorIsFound() {
        let wrapped = cocoaError(134_060, underlying: cocoaError(134_100))
        #expect(AppContainer.isLikelyMigrationFailure(wrapped))
    }

    @Test("A file-protection failure is transient and must not move the store aside")
    func fileProtectionIsTransient() {
        // NSFileReadNoPermissionError — the device was locked with data protection on.
        #expect(!AppContainer.isLikelyMigrationFailure(cocoaError(257)))
    }

    @Test("A full disk is transient and must not move the store aside")
    func outOfSpaceIsTransient() {
        // NSFileWriteOutOfSpaceError.
        #expect(!AppContainer.isLikelyMigrationFailure(cocoaError(640)))
    }

    @Test("A CloudKit error is transient and must not move the store aside")
    func cloudKitErrorIsTransient() {
        let error = NSError(domain: "CKErrorDomain", code: 4, userInfo: [:])
        #expect(!AppContainer.isLikelyMigrationFailure(error))
    }

    @Test("An unrecognised error defaults to transient")
    func unknownErrorDefaultsToTransient() {
        let error = NSError(domain: "SomeOtherDomain", code: 134_100, userInfo: [:])
        #expect(!AppContainer.isLikelyMigrationFailure(error))
    }

    @Test("A cycle in the underlying-error chain terminates instead of hanging")
    func cyclicChainTerminates() {
        let inner = NSError(domain: "A", code: 1, userInfo: [:])
        let outer = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
        let looped = NSError(domain: "C", code: 3, userInfo: [NSUnderlyingErrorKey: outer])
        #expect(!AppContainer.isLikelyMigrationFailure(looped))
    }

    @Test("Only recovery-worthy modes produce a user-facing notice")
    func noticeIsRaisedOnlyWhereItHelps() {
        #expect(AppContainer.StoreRecoveryNotice(mode: .cloudKit, movedAsideStoreName: nil) == nil)
        #expect(AppContainer.StoreRecoveryNotice(mode: .localOnly, movedAsideStoreName: nil) == nil)
        #expect(AppContainer.StoreRecoveryNotice(mode: .inMemory, movedAsideStoreName: nil) == nil)
        // The file is intact and re-syncs on its own — nothing for the user to do.
        #expect(AppContainer.StoreRecoveryNotice(mode: .localFallback, movedAsideStoreName: nil) == nil)

        #expect(
            AppContainer.StoreRecoveryNotice(mode: .recreatedLocalFallback, movedAsideStoreName: "Stride.store.broken-1")
                == .storeMovedAside(backupName: "Stride.store.broken-1")
        )
        #expect(
            AppContainer.StoreRecoveryNotice(mode: .emergencyInMemory, movedAsideStoreName: nil) == .runningInMemory
        )
    }

    @Test("The moved-aside notice names the backup file so the data is findable")
    func noticeNamesTheBackup() {
        let notice = AppContainer.StoreRecoveryNotice.storeMovedAside(backupName: "Stride.store.broken-1700000000")
        #expect(notice.message.contains("Stride.store.broken-1700000000"))
        #expect(!notice.title.isEmpty)
    }
}
