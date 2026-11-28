// The models and services shared by the app, the widgets and the watch live in the StrideCore
// package (Packages/StrideCore). Re-exporting it here makes them visible to every file in
// this target without an import of their own, as they were before the move.
@_exported import StrideCore

// Also `@testable import Stride` tests: an exported import is part of the app module's
// interface, so they see StrideCore's public API through it.
