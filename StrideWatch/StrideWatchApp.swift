import SwiftUI
import WatchKit

// MARK: - StrideWatchApp

/// Stride on Apple Watch (B3): today's session with a Start button, the week's goal and
/// streak, and the race countdown — everything the phone last sent. See
/// ``WatchGlanceModel`` for where it comes from and ``WatchContext`` for what it is.
@main
struct StrideWatchApp: App {
    @WKApplicationDelegateAdaptor private var appDelegate: WatchAppDelegate
    @State private var model = WatchGlanceModel()

    private var recorder: WatchRunRecorder { appDelegate.recorder }

    var body: some Scene {
        WindowGroup {
            Group {
                // A run in progress (or its summary) replaces the home pages entirely, the
                // way Apple's Workout app does: nothing else on the wrist matters mid-run.
                if recorder.state == .idle {
                    WatchHomeView()
                } else {
                    WatchRunView()
                }
            }
                .environment(model)
                .environment(recorder)
                .tint(Color.strideBrand)
                .task { model.activate() }
        }
    }
}

// MARK: - WatchAppDelegate

/// Owns the run recorder, because the system relaunches the app after a crash or a
/// restart mid-run and asks its delegate to recover the workout (Watch runs, PR 6).
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let recorder = WatchRunRecorder()

    func handleActiveWorkoutRecovery() {
        Task { await recorder.recover() }
    }
}
