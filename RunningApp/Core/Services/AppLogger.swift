import Foundation

#if canImport(Pulse)
import Pulse
#endif

enum AppLogger {

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

        print("[\(label)] \(text)")
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
