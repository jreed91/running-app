import SwiftUI

// MARK: - StrideWatchApp

/// Stride on Apple Watch (B3): today's session with a Start button, the week's goal and
/// streak, and the race countdown — everything the phone last sent. See
/// ``WatchGlanceModel`` for where it comes from and ``WatchContext`` for what it is.
@main
struct StrideWatchApp: App {
    @State private var model = WatchGlanceModel()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(model)
                .tint(Color.strideBrand)
                .task { model.activate() }
        }
    }
}
