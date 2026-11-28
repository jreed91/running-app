import Foundation

// Linux only: swift-corelibs Foundation has `String(localized:)` but not its `comment:`
// overload, which every user-facing string in here passes for the translators. Lets the
// package build and test with the Linux toolchain. Apple platforms never compile this.
#if !canImport(Darwin)
extension String {
    init(localized key: String, comment: StaticString? = nil) {
        self = key
    }
}
#endif
