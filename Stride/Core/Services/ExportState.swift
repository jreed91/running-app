import Foundation

// MARK: - ExportState

/// One "make a file, then share it" action: idle, working, ready to share, or failed.
///
/// Three screens spelled this as a busy `Bool`, an optional result that drives
/// `.sheet(item:)`, and an optional error string that drives an alert:
/// `SettingsView`'s full-data export (`isExportingData` + `dataExportFile` +
/// `dataExportErrorMessage`), and `RunSummaryView`'s share card (`isRenderingShareCard` +
/// `shareCard`) and GPX export (`gpxFile` + `exportErrorMessage`). A sheet and an alert
/// at once, or a spinner over a ready file, were writable; here one case is current.
///
/// ```
///          begin()              succeed(output)             dismiss()
///   idle ──────────▶ working ──────────────────▶ ready(output) ──────────▶ idle
///    ▲                  │  fail(message)                                    ▲
///    │                  └───────────────▶ failed(message) ──── dismiss() ───┘
///    └──────────────── abandon() (nothing to show, e.g. a render that came back empty)
/// ```
enum ExportState<Output> {
    case idle
    case working
    case ready(Output)
    case failed(String)

    // MARK: Reading

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// What the share sheet presents; nil when it should not show.
    var output: Output? {
        guard case .ready(let output) = self else { return nil }
        return output
    }

    /// What the error alert says; nil when it should not show.
    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }

    // MARK: Transitions

    mutating func begin() {
        self = .working
    }

    mutating func succeed(_ output: Output) {
        self = .ready(output)
    }

    mutating func fail(_ message: String) {
        self = .failed(message)
    }

    /// The work ended with nothing to show and nothing to say (logged instead).
    mutating func abandon() {
        guard isWorking else { return }
        self = .idle
    }

    /// The share sheet or the alert went away. A run still working is left alone.
    mutating func dismiss() {
        guard !isWorking else { return }
        self = .idle
    }
}

extension ExportState: Equatable where Output: Equatable {}
