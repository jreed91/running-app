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
                    .foregroundStyle(.red)
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
                    ProgressView().controlSize(.small)
                    Text("Building…")
                        .font(.bodyStrong)
                } else {
                    Image(systemName: "music.note.list")
                    Text("Build playlist")
                        .font(.bodyStrong)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBuilding)
    }

    private func builtState(link: RunPlaylistLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.sm))

            HStack(spacing: 10) {
                Button {
                    if let url = RunPlaylistService.openURL(for: link) { openURL(url) }
                } label: {
                    Text("Open in Music")
                        .font(.dsFootnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.sm)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await build() }
                } label: {
                    HStack(spacing: 6) {
                        if isBuilding { ProgressView().controlSize(.mini) }
                        Text("Rebuild")
                            .font(.dsFootnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm)
                }
                .buttonStyle(.bordered)
                .disabled(isBuilding)
            }
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
        case .calm:   return .teal
        case .steady: return .green
        case .hard:   return .orange
        }
    }
}
