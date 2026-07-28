import CloudKit
import Foundation
import Testing
@testable import Stride

/// Covers the CloudKit event/error flattening that backs the debug screen and the logs.
///
/// `NSPersistentCloudKitContainer.Event` cannot be constructed, so the value type it is
/// reduced to is the testable seam — which is most of why it exists.
struct CloudKitDiagnosticsTests {

    // MARK: - Event summaries

    @Test("A finished export reads as one line")
    func finishedExportLogLine() {
        let summary = CloudKitEventSummary(identifier: "abc", kind: .export, status: .finished)
        #expect(summary.logLine == "Event abc export finished")
    }

    @Test("A failure carries its reason into the line")
    func failedEventIncludesReason() {
        let summary = CloudKitEventSummary(
            identifier: "abc",
            kind: .import,
            status: .failed("Network unavailable")
        )
        #expect(summary.logLine == "Event abc import failed (Network unavailable)")
    }

    @Test("A started and a finished event for one operation are distinct rows")
    func startedAndFinishedHaveDifferentIDs() {
        // The debug screen replaces on `identifier` + `kind`, so these must not collide
        // as `Identifiable` while both are on screen.
        let started = CloudKitEventSummary(identifier: "abc", kind: .setup, status: .started)
        let finished = CloudKitEventSummary(identifier: "abc", kind: .setup, status: .finished)
        #expect(started.id != finished.id)
        #expect(started.identifier == finished.identifier)
    }

    // MARK: - Error flattening

    @Test("A plain error yields its domain, code, and description")
    func plainErrorLine() {
        let error = NSError(
            domain: "TestDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )
        let lines = CloudKitDiagnostics.errorDiagnosticLines(error, path: "event.error")
        #expect(lines.count == 1)
        #expect(lines[0].contains("domain=TestDomain"))
        #expect(lines[0].contains("code=42"))
        #expect(lines[0].contains("Something went wrong"))
    }

    @Test("An underlying error is walked, not swallowed")
    func underlyingErrorIsWalked() {
        let underlying = NSError(domain: "Inner", code: 7, userInfo: [:])
        let outer = NSError(
            domain: "Outer",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let lines = CloudKitDiagnostics.errorDiagnosticLines(outer, path: "event.error")
        #expect(lines.contains { $0.hasPrefix("event.error: ") && $0.contains("domain=Outer") })
        #expect(lines.contains { $0.hasPrefix("event.error.underlying: ") && $0.contains("domain=Inner") })
    }

    @Test("Partial per-item errors are expanded, which is where the real cause lives")
    func partialErrorsAreExpanded() {
        // CloudKit reports a failed batch as one error whose causes sit in
        // CKPartialErrorsByItemIDKey. Reading only `localizedDescription` says nothing
        // beyond "some records failed".
        let itemFailure = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.serverRecordChanged.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "record conflict"]
        )
        let batch = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["recordA": itemFailure]]
        )

        let lines = CloudKitDiagnostics.errorDiagnosticLines(batch, path: "event.error")
        #expect(lines.contains { $0.contains("partialErrors.count=1") })
        #expect(lines.contains { $0.contains("partial[recordA]") && $0.contains("record conflict") })
    }

    @Test("Partial errors are ordered so two runs of the same failure log identically")
    func partialErrorsAreSorted() {
        let makeError = { (message: String) in
            NSError(
                domain: CKError.errorDomain,
                code: CKError.Code.serverRecordChanged.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        let batch = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "recordB": makeError("second"),
                    "recordA": makeError("first")
                ]
            ]
        )

        let lines = CloudKitDiagnostics.errorDiagnosticLines(batch, path: "event.error")
        let indexA = lines.firstIndex { $0.contains("partial[recordA]") }
        let indexB = lines.firstIndex { $0.contains("partial[recordB]") }
        #expect(indexA != nil)
        #expect(indexB != nil)
        if let indexA, let indexB { #expect(indexA < indexB) }
    }

    @Test("A CloudKit error names its CKError code")
    func ckErrorCodeIsNamed() {
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.notAuthenticated.rawValue,
            userInfo: [:]
        )
        let lines = CloudKitDiagnostics.errorDiagnosticLines(error, path: "event.error")
        #expect(lines.contains { $0.contains("ckCode=") })
    }
}
