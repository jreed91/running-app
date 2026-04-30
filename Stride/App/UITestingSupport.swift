import Foundation

enum UITestingSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }
}
