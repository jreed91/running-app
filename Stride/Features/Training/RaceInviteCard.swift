import SwiftUI

// MARK: - RaceInviteCard

/// "Train with a friend": shares the goal race as a link.
///
/// The link carries the race's name, day and distance and nothing about the runner
/// (see ``RaceInvite``). A friend with Stride gets a plan to the same day at their own
/// paces; one without it gets the race and the App Store button on jacobreed.dev.
struct RaceInviteCard: View {

    let invite: RaceInvite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRAIN WITH A FRIEND")
                .strideEyebrow()
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    iconTile
                    Text("Send a friend a link to this race. Stride builds them a plan to the same day at their own paces.")
                        .font(.dsSubhead)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ShareLink(
                    item: invite.webURL,
                    subject: Text(verbatim: invite.name),
                    message: Text(verbatim: message)
                ) {
                    Text("Invite a friend")
                }
                .buttonStyle(.strideButton(.secondary, compact: true, fullWidth: false))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .strideCard()
        }
    }

    private var iconTile: some View {
        ZStack {
            Circle()
                .fill(Color.brand.opacity(0.12))
                .frame(width: 48, height: 48)
            StrideIcon(name: .person, size: 20, color: .brandText, strokeWeight: 2.2)
        }
        .accessibilityHidden(true)
    }

    /// The words that go with the link. The day is written out because the link's own
    /// `2027-10-10` is for the app, not the reader.
    private var message: String {
        let day = invite.raceDate()?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? ""
        return String(
            localized: "I'm training for \(invite.name) on \(day). Train for it with me on Stride:",
            comment: "Race hub: the message shared with a race invite link, followed by the link"
        )
    }
}
