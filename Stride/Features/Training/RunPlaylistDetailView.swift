import SwiftUI

/// The built playlist's tracks, grouped into the blocks they were placed in (N40).
///
/// This screen exists because iOS will not open a private library playlist — not the playlist,
/// not even the library root. Stride is therefore the only place the playlist can actually be
/// read, which is why the list is rendered from the stored link rather than fetched: no
/// authorization, no round trip, no network, and so nothing that can fail on the one screen
/// standing in for something that already failed.
struct RunPlaylistDetailView: View {
    let link: RunPlaylistLink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                ForEach(link.sections) { section in
                    sectionView(section)
                }
                provenanceNote
            }
            .padding(AppSpacing.lg)
        }
        .background(Color.surfacePrimary)
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(link.name)
                .font(.dsTitle3.weight(.bold))
            Text(summary)
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        String(
            localized: "\(link.trackCount) tracks · \(link.totalSeconds.durationString)",
            comment: "Summary line on the playlist detail screen: track count and total duration"
        )
    }

    // MARK: - Sections

    private func sectionView(_ section: RunPlaylistTrackSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: section.energy))
                    .frame(width: 8, height: 8)
                Text(section.energy.localizedName.uppercased())
                    .strideEyebrow()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(section.seconds.durationString)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(section.energy.localizedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track)
                    if index < section.tracks.count - 1 {
                        Divider().padding(.leading, AppSpacing.lg)
                    }
                }
            }
            .strideCard(cornerRadius: AppRadius.md)
        }
    }

    private func trackRow(_ track: RunPlaylistTrack) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.dsBody)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.seconds.durationString)
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Provenance

    /// Says plainly that this is what Stride built, not a live mirror of the playlist.
    ///
    /// The list is stored at build time, so a runner who reorders or deletes tracks in Apple
    /// Music will not see that here. Better to say so in one line than to let the screen imply
    /// a freshness it does not have.
    private var provenanceNote: some View {
        Text("This is the playlist as Stride built it. Changes you make in Apple Music won't show here.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func color(for energy: RunPlaylistEnergy) -> Color {
        switch energy {
        case .calm:   return .zoneRecovery
        case .steady: return .zoneEasy
        case .hard:   return .zoneTempo
        }
    }
}
