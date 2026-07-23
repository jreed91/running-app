import Foundation
import OSLog

#if canImport(Pulse)
import Pulse
#endif

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.running.stride"

    enum Level {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical
    }

    static func log(
        _ message: @autoclosure () -> String,
        label: String = "app",
        level: Level = .info
    ) {
        let text = message()

        #if canImport(Pulse)
        // Only persist to the on-disk Pulse store when diagnostics are enabled
        // (DEBUG or a TestFlight sandbox build). In App Store production the store
        // is never activated, so its 64 MB/7-day retention limits never apply —
        // persisting there would grow an unbounded, uncapped log of coordinates,
        // distances, and source bundle IDs (S2).
        if PulseIntegrationService.isDiagnosticsEnabled {
            LoggerStore.shared.storeMessage(
                label: label,
                level: map(level),
                message: text
            )
        }
        #endif

        // Keep payloads out of sysdiagnose/Console in shipping builds. Developers
        // attached to Xcode (DEBUG) still see full text; everywhere else the value
        // is redacted as `<private>` (S2).
        let logger = Logger(subsystem: subsystem, category: label)
        #if DEBUG
        logger.log(level: mapToOSLog(level), "\(text, privacy: .public)")
        #else
        logger.log(level: mapToOSLog(level), "\(text, privacy: .private)")
        #endif
    }

    private static func mapToOSLog(_ level: Level) -> OSLogType {
        switch level {
        case .trace, .debug:
            return .debug
        case .info:
            return .info
        case .notice, .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }

    #if canImport(Pulse)
    private static func map(_ level: Level) -> LoggerStore.Level {
        switch level {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }
    #endif
}
