import CloudKit
import CoreData
import Foundation

// MARK: - CloudKitEventSummary

/// One `NSPersistentCloudKitContainer` lifecycle event, reduced to something the app
/// can hold onto and render.
///
/// The events themselves arrive on an arbitrary thread, are not `Sendable`, and cannot
/// be constructed in a test. Flattening each one at the notification boundary gives the
/// CloudKit debug screen something to show and gives the formatting a testable shape
/// (`CloudKitDiagnosticsTests`).
struct CloudKitEventSummary: Identifiable, Equatable, Sendable {

    enum Kind: String, Sendable {
        case setup
        case `import`
        case export
        case unknown

        /// Matches the wording `docs/CLOUDKIT_VALIDATION.md` tells a tester to look for.
        var displayName: String { rawValue }
    }

    enum Status: Equatable, Sendable {
        /// The event has begun and has no `endDate` yet.
        case started
        case finished
        case failed(String)

        var displayName: String {
            switch self {
            case .started: "started"
            case .finished: "finished"
            case .failed(let reason): "failed (\(reason))"
            }
        }
    }

    /// The event's own identifier. Setup, import, and export events for one operation
    /// share it, so a "started" row and its "finished" row collapse onto each other.
    let identifier: String
    let kind: Kind
    let status: Status
    /// When this summary was taken, not when the event began — used only for display
    /// ordering on the debug screen.
    let observedAt: Date

    var id: String { "\(identifier)-\(kind.rawValue)-\(status.displayName)" }

    /// The single line that goes to the log, and the one the debug screen shows.
    var logLine: String {
        "Event \(identifier) \(kind.displayName) \(status.displayName)"
    }

    init(identifier: String, kind: Kind, status: Status, observedAt: Date = Date()) {
        self.identifier = identifier
        self.kind = kind
        self.status = status
        self.observedAt = observedAt
    }

    init(event: NSPersistentCloudKitContainer.Event, observedAt: Date = Date()) {
        let kind: Kind = switch event.type {
        case .setup: .setup
        case .import: .import
        case .export: .export
        @unknown default: .unknown
        }

        let status: Status
        if event.endDate == nil {
            status = .started
        } else if let error = event.error {
            status = .failed(error.localizedDescription)
        } else {
            status = .finished
        }

        self.init(
            identifier: event.identifier.uuidString,
            kind: kind,
            status: status,
            observedAt: observedAt
        )
    }
}

// MARK: - CloudKitDiagnostics

enum CloudKitDiagnostics {

    /// How many summaries to keep for the debug screen. A tail, not a log — Pulse still
    /// holds the full history.
    static let eventHistoryLimit = 25

    /// How many non-atomic per-record errors one batch expands into log lines.
    static let partialErrorExpansionLimit = 10

    /// True for a per-record error that only says its batch failed: `batchRequestFailed`,
    /// or the internal "Atomic failure" (code 2024) that CloudKit sometimes reports directly.
    static func isAtomicFailure(_ error: NSError) -> Bool {
        if error.domain == CKError.errorDomain, error.code == CKError.Code.batchRequestFailed.rawValue {
            return true
        }
        return error.domain == "CKInternalErrorDomain" && error.code == 2024
    }

    /// Flattens a CloudKit error — including every partial per-item error and the whole
    /// underlying chain — into loggable lines.
    ///
    /// CloudKit reports a failed batch as one error whose real causes sit in
    /// `CKPartialErrorsByItemIDKey`, so an unwalked `localizedDescription` says only
    /// that something went wrong with some records.
    ///
    /// Stride's zone saves each batch atomically, so one bad record fails every other
    /// record in it with `batchRequestFailed` ("Atomic failure"). Those are counted, not
    /// expanded: a 400-record batch otherwise logged 800 lines that hid the one real cause,
    /// and logged them again on every retry. The real causes are expanded up to
    /// ``partialErrorExpansionLimit``.
    static func errorDiagnosticLines(_ error: Error, path: String) -> [String] {
        let nsError = error as NSError
        var lines = [
            "\(path): domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
        ]

        if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
            lines.append("\(path): failureReason=\(failureReason)")
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
            lines.append("\(path): recoverySuggestion=\(recoverySuggestion)")
        }

        if nsError.domain == CKError.errorDomain {
            if let ckCode = CKError.Code(rawValue: nsError.code) {
                lines.append("\(path): ckCode=\(ckCode)")
            }
            if let requestUUIDEntry = nsError.userInfo.first(where: { entry in
                String(describing: entry.key).localizedCaseInsensitiveContains("uuid")
            }), let requestID = requestUUIDEntry.value as? String {
                lines.append("\(path): \(requestUUIDEntry.key)=\(requestID)")
            }
        }

        if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any], !partialErrors.isEmpty {
            lines.append(contentsOf: partialErrorLines(partialErrors, path: path))
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(contentsOf: errorDiagnosticLines(underlying, path: "\(path).underlying"))
        }

        return lines
    }

    /// The per-record errors of one failed batch: real causes expanded (up to the limit),
    /// atomic failures counted.
    private static func partialErrorLines(_ partialErrors: [AnyHashable: Any], path: String) -> [String] {
        var lines = ["\(path): partialErrors.count=\(partialErrors.count)"]
        var atomicFailures = 0
        var expanded = 0
        var notExpanded = 0
        for (itemID, value) in partialErrors.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            guard let nestedError = value as? NSError else {
                lines.append("\(path): partial[\(itemID)]=\(String(describing: value))")
                continue
            }
            if isAtomicFailure(nestedError) {
                atomicFailures += 1
            } else if expanded < partialErrorExpansionLimit {
                expanded += 1
                lines.append(
                    contentsOf: errorDiagnosticLines(nestedError, path: "\(path).partial[\(itemID)]")
                )
            } else {
                notExpanded += 1
            }
        }
        if atomicFailures > 0 {
            lines.append(
                "\(path): atomicFailures=\(atomicFailures) (rejected only because another record in the batch failed)"
            )
        }
        if notExpanded > 0 {
            lines.append("\(path): partialErrors.notExpanded=\(notExpanded)")
        }
        return lines
    }
}
