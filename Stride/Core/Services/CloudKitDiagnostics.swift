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
            identifier: event.identifier,
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

    /// Flattens a CloudKit error — including every partial per-item error and the whole
    /// underlying chain — into loggable lines.
    ///
    /// CloudKit reports a failed batch as one error whose real causes sit in
    /// `CKPartialErrorsByItemIDKey`, so an unwalked `localizedDescription` says only
    /// that something went wrong with some records.
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
            lines.append("\(path): partialErrors.count=\(partialErrors.count)")
            for (itemID, value) in partialErrors.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                guard let nestedError = value as? NSError else {
                    lines.append("\(path): partial[\(itemID)]=\(String(describing: value))")
                    continue
                }
                lines.append(
                    contentsOf: errorDiagnosticLines(nestedError, path: "\(path).partial[\(itemID)]")
                )
            }
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(contentsOf: errorDiagnosticLines(underlying, path: "\(path).underlying"))
        }

        return lines
    }
}
