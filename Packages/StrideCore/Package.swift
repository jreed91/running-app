// swift-tools-version: 6.2
import PackageDescription

// StrideCore: the Foundation-only models and services the iPhone app, the widget
// extension and the Watch app all compile.
//
// Why a package. Every file in the `Stride` app target is visible to StrideTests through
// `@testable import Stride`, so a change to any app file's interface recompiles nearly the
// whole test bundle (in CI run 46091670703, 177 of the 212 files the test build compiled
// were tests). Code in here is a separate module: the app only recompiles against it when
// its *public* interface changes, and its own tests run with `swift test` on a Mac, with no
// simulator and no app build at all.
//
// Rules for code in here:
// - Foundation only. No SwiftUI, SwiftData, HealthKit, CoreLocation or app types: the
//   watch (watchOS 26) and the Linux toolchain both compile this package.
// - Anything the app, the widgets or the watch reads is `public`, and a public struct the
//   app builds needs an explicit `public init` (a memberwise init is internal).
// - Public types state `Sendable` explicitly; it is not inferred across modules.
//
// The app target re-exports this module (`Stride/App/StrideCoreExports.swift`), so app
// files and `@testable import Stride` tests see these types without an import of their own.
let package = Package(
    name: "StrideCore",
    platforms: [
        .iOS("27.0"),
        // The watch app's deployment target: see `StrideWatch` in project.yml.
        .watchOS("26.0"),
        // For `swift test` on a CI Mac, without a simulator.
        .macOS("15.0"),
    ],
    products: [
        .library(name: "StrideCore", targets: ["StrideCore"]),
    ],
    targets: [
        .target(
            name: "StrideCore",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "StrideCoreTests",
            dependencies: ["StrideCore"],
            swiftSettings: sharedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

// The behavioural half of the app's `SWIFT_APPROACHABLE_CONCURRENCY: YES` (project.yml),
// so a `nonisolated async` function means the same thing in here as it does in the app.
// The rest of that bundle is already on in the Swift 6 language mode.
var sharedSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
