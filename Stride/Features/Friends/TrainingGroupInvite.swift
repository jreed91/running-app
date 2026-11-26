import CloudKit
import SwiftUI
import UIKit

// MARK: - TrainingGroupInvite

/// A training-group invite link a friend sent, as iOS hands it to the app.
///
/// Group links are iCloud share links (`https://www.icloud.com/share/…`), not
/// runwithstride.app links, so they need no Associated Domains: with
/// `CKSharingSupported` in the Info.plist, tapping one opens Stride and the system passes
/// the share's metadata to the scene delegate. An iPhone without Stride gets iCloud's own
/// page with an App Store link.
struct TrainingGroupInvite: Identifiable, @unchecked Sendable {
    // `@unchecked`: `CKShare.Metadata` is an immutable snapshot the system delivers once;
    // nothing mutates it after that, so passing it to the service's actor is safe.
    let metadata: CKShare.Metadata

    var id: String { metadata.share.recordID.zoneID.zoneName + "/" + metadata.share.recordID.zoneID.ownerName }

    /// The group's name as its owner set it.
    var title: String {
        TrainingGroup.tidiedTitle(metadata.share[CKShare.SystemFieldKey.title] as? String ?? "")
    }

    /// Who started the group, from their iCloud identity, when iCloud shares it.
    var ownerName: String? {
        guard let components = metadata.ownerIdentity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .short)
        return name.isEmpty ? nil : name
    }
}

// MARK: - TrainingGroupInviteInbox

/// Where the scene delegate leaves an invite for the tabs to pick up.
///
/// The scene delegate is made by UIKit, not by `StrideApp`, so it cannot reach
/// `AppContainer`; this one shared box is the hand-off. `MainTabView` shows the join sheet
/// while ``pending`` is set and clears it. An invite opened before onboarding is finished
/// waits here until the tabs appear.
@MainActor
@Observable
final class TrainingGroupInviteInbox {
    static let shared = TrainingGroupInviteInbox()

    var pending: TrainingGroupInvite?

    func receive(_ metadata: CKShare.Metadata) {
        // Only training groups: the container shares nothing else today, but a share of
        // some other zone should not open a join sheet for it.
        guard TrainingGroupNames.isGroupZone(metadata.share.recordID.zoneID.zoneName) else {
            AppLogger.log("Ignored a share that isn't a training group", label: "friends", level: .warning)
            return
        }
        pending = TrainingGroupInvite(metadata: metadata)
    }
}

// MARK: - StrideSceneDelegate

/// Receives accepted iCloud share links. SwiftUI's own scene delegate doesn't forward
/// `userDidAcceptCloudKitShareWith`, so `StrideAppDelegate` names this class for every
/// scene it configures. It makes no window: SwiftUI still owns the scene's window and
/// content, this only listens.
@MainActor
final class StrideSceneDelegate: NSObject, UIWindowSceneDelegate {

    /// A cold launch from a link: the metadata arrives with the connection, not through
    /// the callback below.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            TrainingGroupInviteInbox.shared.receive(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        TrainingGroupInviteInbox.shared.receive(cloudKitShareMetadata)
    }
}
