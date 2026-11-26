import SwiftUI
import UIKit

// MARK: - TrainingGroupInviteImage

/// The picture a training group's invite carries: the Stride app mark.
///
/// CloudKit keeps it on the group's `CKShare` (`SystemFieldKey.thumbnailImageData`), and
/// iOS shows it with the group's name where the invite link is previewed, in Messages
/// and on the iCloud join page, in place of a generic iCloud picture.
@MainActor
enum TrainingGroupInviteImage {

    /// Side of the rendered image, in points; rendered at 2x.
    static let size: CGFloat = 256

    /// PNG data, or nil if rendering fails (the invite then goes without a picture).
    static func pngData() -> Data? {
        let renderer = ImageRenderer(
            content: StrideAppMark(size: size)
                .padding(size * 0.08)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else {
            AppLogger.log("Invite image render produced no image", label: "friends", level: .warning)
            return nil
        }
        return data
    }
}
