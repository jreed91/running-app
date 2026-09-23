import SwiftUI

// The run's Strava entry in the share menu, and the alert for an upload that failed.
// Everything it shows is read from `StravaService`, so a run that went up automatically
// when it was saved reads the same as one sent from here.
extension RunSummaryView {

    var stravaService: StravaService { container.stravaService }

    /// Absent unless Strava is connected and this is a run; nothing to explain otherwise,
    /// and Settings is where connecting lives.
    @ViewBuilder
    var stravaMenuItems: some View {
        if stravaService.isConnected, StravaService.canUpload(workout) {
            switch stravaService.state(for: workout) {
            case .uploading:
                Button {} label: {
                    Label("Uploading to Strava…", systemImage: "arrow.up.circle")
                }
                .disabled(true)
            case .uploaded(let activityID?):
                Link(destination: StravaAPI.activityURL(id: activityID)) {
                    Label("View on Strava", systemImage: "arrow.up.forward.app")
                }
            case .uploaded(nil):
                Button {} label: {
                    Label("Already on Strava", systemImage: "checkmark.circle")
                }
                .disabled(true)
            case .processing:
                // Asking again resolves it: Strava answers a second copy of the same run
                // with the activity it already made.
                Button {
                    Task { await stravaService.upload(workout) }
                } label: {
                    Label("Check Strava upload", systemImage: "arrow.clockwise")
                }
            case .failed, nil:
                Button {
                    Task { await stravaService.upload(workout) }
                } label: {
                    Label("Upload to Strava", systemImage: "arrow.up.circle")
                }
            }
        }
    }

    var stravaFailureMessage: String? {
        if case .failed(let message) = stravaService.state(for: workout) { return message }
        return nil
    }

    var isShowingStravaFailure: Binding<Bool> {
        Binding(
            get: { stravaFailureMessage != nil },
            set: { if !$0 { stravaService.clearFailure(for: workout) } }
        )
    }
}
