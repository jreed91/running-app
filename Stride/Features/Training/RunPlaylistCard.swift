import SwiftUI
import MusicKit

/// The run-playlist section of `WorkoutDetailView` (N40).
///
/// Shows the shape the session would take as music, and builds it into the runner's Apple
/// Music library on request. Nothing here plays anything — see `RunPlaylistService` for why
/// that boundary matters.
struct RunPlaylistCard: View {
    let workout: ScheduledWorkout
    let plan: RunPlaylistPlan

    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.openURL) private var openURL

    @State private var link: RunPlaylistLink?
    @State private var errorMessage: String?

    private var service: RunPlaylistService { container.runPlaylistService }

    /// Read off the service rather than held here: the service is the thing that knows a
    /// build is in flight, and a second copy of that flag is a second thing to get wrong.
    private var isBuilding: Bool { service.isBuilding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RUN PLAYLIST")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            energyBar
            energyLegend

            if let link {
                builtState(link: link)
            } else {
                buildButton
            }

            if service.authorizationStatus == .denied {
                Text("Apple Music access is off for Stride. Turn it on in iOS Settings → Privacy & Security → Media & Apple Music.")
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.dsFootnote)
                    .foregroundStyle(.destructive)
            }
        }
        .task {
            link = service.link(for: workout)
            await service.refreshAvailability()
        }
    }

    // MARK: - Shape

    /// The session's energy blocks, drawn to scale.
    ///
    /// This is the whole explanation of what "custom" means here, and it is deliberately a
    /// picture rather than a sentence: the runner can see that their interval session is
    /// bookended by calm and hard in the middle, which is a claim Stride can actually keep.
    private var energyBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(plan.blocks.enumerated()), id: \.offset) { _, block in
                    RoundedRectangle(cornerRadius: AppRadius.micro)
                        .fill(color(for: block.energy))
                        .frame(width: max(6, proxy.size.width * (block.seconds / max(plan.sessionSeconds, 1))))
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityShape))
    }

    private var energyLegend: some View {
        HStack(spacing: 14) {
            ForEach(orderedEnergiesInPlan, id: \.self) { energy in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: energy))
                        .frame(width: 7, height: 7)
                    Text(energy.localizedName)
                        .font(.dsFootnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(plan.sessionSeconds.durationString)
                .font(.dsFootnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Energies present in the plan, in tier order rather than in the order they appear —
    /// a legend that reorders itself between an easy day and an interval day reads as noise.
    private var orderedEnergiesInPlan: [RunPlaylistEnergy] {
        let present = Set(plan.blocks.map(\.energy))
        return RunPlaylistEnergy.allCases.filter { present.contains($0) }
    }

    private var accessibilityShape: String {
        let parts = plan.blocks.map { block in
            String(
                localized: "\(block.energy.localizedName) for \(Int((block.seconds / 60).rounded())) minutes",
                comment: "One block of the run-playlist shape, read out by VoiceOver"
            )
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private var buildButton: some View {
        Button {
            Task { await build() }
        } label: {
            // Two `Text`s rather than one with a ternary: a ternary of literals resolves to
            // `Text(_ content: some StringProtocol)`, which is *not* localized, so both
            // strings would quietly fall out of `Localizable.xcstrings`.
            HStack(spacing: 8) {
                if isBuilding {
                    ProgressView().controlSize(.small).tint(.onFill)
                    Text("Building…")
                } else {
                    Image(systemName: "music.note.list")
                    Text("Build playlist")
                }
            }
        }
        .buttonStyle(.strideButton())
        .disabled(isBuilding)
    }

    private func playlistRow(link: RunPlaylistLink, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name)
                    .font(.bodyStrong)
                    .lineLimit(1)
                Text(summary(for: link))
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsChevron {
                StrideIcon(name: .chevronRight, size: 12,
                           color: Color.secondary.opacity(0.5), strokeWeight: 2)
            }
        }
        .padding()
        .strideCard(cornerRadius: AppRadius.sm)
    }

    private func builtState(link: RunPlaylistLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tapping through to the track list is how a runner sees what they are about to
            // run to, and Stride is the only place they can: iOS opens neither the playlist
            // nor the library. A link written before tracks were stored has none, so it stays
            // a plain row rather than pushing an empty screen.
            if link.tracks.isEmpty {
                playlistRow(link: link, showsChevron: false)
            } else {
                NavigationLink {
                    RunPlaylistDetailView(link: link)
                } label: {
                    playlistRow(link: link, showsChevron: true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }

            // Play, rather than a link to the playlist: iOS has no deep link to a private
            // library playlist — not to the playlist and not even to the library root, both of
            // which make Music open and then show an error. The handoff is a queue on the
            // system music player, and the button below only launches Music.
            HStack(spacing: 10) {
                Button {
                    Task { await play(link) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                }
                .buttonStyle(.strideButton(compact: true))

                Button {
                    Task { await build() }
                } label: {
                    HStack(spacing: 6) {
                        if isBuilding { ProgressView().controlSize(.mini) }
                        Text("Rebuild")
                    }
                }
                .buttonStyle(.strideButton(.secondary, compact: true))
                .disabled(isBuilding)
            }

            // "Open Apple Music", not "Open in Music": it launches the app and cannot land on
            // the playlist, and a label promising otherwise is what made this read as broken.
            // The playlist's name is above, which is what to look for once Music is open.
            Button {
                if let url = RunPlaylistService.musicAppURL { openURL(url) }
            } label: {
                Text("Open Apple Music")
                    .font(.dsFootnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private func play(_ link: RunPlaylistLink) async {
        errorMessage = nil
        do {
            try await service.play(link)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The one place the subscription state is mentioned, and only after the fact: a
    /// non-subscriber gets a playlist built from their own library and is told that is what
    /// happened, rather than being shown an upsell instead of a playlist.
    private func summary(for link: RunPlaylistLink) -> String {
        let base = String(
            localized: "\(link.trackCount) tracks · \(link.totalSeconds.durationString)",
            comment: "Summary of a built run playlist: track count and total duration"
        )
        guard !link.usedCatalog else { return base }
        return base + " · " + String(
            localized: "from your library",
            comment: "Notes that a playlist was built without an Apple Music subscription"
        )
    }

    private func build() async {
        errorMessage = nil
        do {
            link = try await service.buildPlaylist(for: workout, sources: appSettings.playlistSources)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Colour

    private func color(for energy: RunPlaylistEnergy) -> Color {
        switch energy {
        case .calm:   return .zoneRecovery
        case .steady: return .zoneEasy
        case .hard:   return .zoneTempo
        }
    }
}
