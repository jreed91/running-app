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
        LoggerStore.shared.storeMessage(
            label: label,
            level: map(level),
            message: text
        )
        #endif

        Logger(subsystem: subsystem, category: label)
            .log(level: mapToOSLog(level), "\(text, privacy: .public)")
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
