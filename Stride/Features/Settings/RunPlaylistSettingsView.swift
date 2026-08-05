import SwiftUI
import MusicKit

/// Apple Music access and the per-tier playlist overrides (N40).
///
/// Nothing here is required to use the feature: with no setup at all, every tier is filled
/// from `MusicEnergyPolicy`'s genre table. This screen exists for the runner who disagrees
/// with that table — which is the likelier case for music than for any of Stride's other
/// policies, because the others are evidence and this one is taste.
struct RunPlaylistSettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppSettings.self) private var appSettings

    @State private var libraryPlaylists: [Playlist] = []
    @State private var isLoadingLibrary = false

    private var service: RunPlaylistService { container.runPlaylistService }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                accessSection
                if service.isAuthorized {
                    tierSection
                }
            }
            .padding(AppSpacing.lg)
        }
        .navigationTitle("Run Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.refreshAvailability()
            await loadLibraryPlaylists()
        }
    }

    // MARK: - Access

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPLE MUSIC")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(accessStatusTitle)
                        .font(.bodyStrong)
                    Spacer()
                    if service.isAuthorized {
                        StrideIcon(name: .check, size: 16, color: .green, strokeWeight: 2)
                    }
                }

                Text(accessStatusDetail)
                    .font(.dsFootnote)
                    .foregroundStyle(.secondary)

                if service.authorizationStatus == .notDetermined {
                    Button {
                        Task {
                            await service.requestAuthorization()
                            await loadLibraryPlaylists()
                        }
                    } label: {
                        Text("Allow Apple Music")
                            .font(.dsFootnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var accessStatusTitle: String {
        switch service.authorizationStatus {
        case .authorized:
            return String(localized: "Connected", comment: "Apple Music authorization state")
        case .denied:
            return String(localized: "Access denied", comment: "Apple Music authorization state")
        case .restricted:
            return String(localized: "Restricted", comment: "Apple Music authorization state")
        case .notDetermined:
            return String(localized: "Not connected", comment: "Apple Music authorization state")
        @unknown default:
            return String(localized: "Not connected", comment: "Apple Music authorization state")
        }
    }

    private var accessStatusDetail: String {
        switch service.authorizationStatus {
        case .authorized where service.canPlayCatalogContent:
            return String(
                localized: "Playlists are built from the Apple Music catalogue and saved to your library.",
                comment: "Apple Music state detail for a subscriber"
            )
        case .authorized:
            return String(
                localized: "Playlists are built from the music already in your library.",
                comment: "Apple Music state detail without a subscription"
            )
        case .denied:
            return String(
                localized: "Turn Stride on in iOS Settings → Privacy & Security → Media & Apple Music.",
                comment: "How to restore Apple Music access after denying it"
            )
        case .restricted:
            return String(
                localized: "Apple Music access is restricted on this device.",
                comment: "Apple Music state detail when restricted by device policy"
            )
        default:
            return String(
                localized: "Stride saves each playlist to your Apple Music library. It never plays music itself.",
                comment: "What granting Apple Music access lets Stride do"
            )
        }
    }

    // MARK: - Tiers

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT EACH PART SOUNDS LIKE")
                .font(.sectionHeader)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(RunPlaylistEnergy.allCases.enumerated()), id: \.element) { index, energy in
                    tierRow(for: energy)
                    if index < RunPlaylistEnergy.allCases.count - 1 {
                        Divider().padding(.leading, AppSpacing.lg)
                    }
                }
            }
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.md))

            Text("By default Stride picks by genre. Point a tier at one of your own playlists and it uses that instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)

            // Said plainly, because the alternative is a runner wondering why the interval
            // section is not at their cadence. Apple publishes no tempo for a song, so
            // nothing in Stride can match one.
            Text("Apple Music doesn't publish a tempo for its songs, so Stride matches the feel of each part of a run rather than its beats per minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.xs)
        }
    }

    private func tierRow(for energy: RunPlaylistEnergy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(energy.localizedName)
                        .font(.bodyStrong)
                    Text(energy.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                sourcePicker(for: energy)
            }
        }
        .padding()
    }

    private func sourcePicker(for energy: RunPlaylistEnergy) -> some View {
        Picker(
            selection: Binding(
                get: { appSettings.playlistSourceID(for: energy) },
                set: { appSettings.setPlaylistSourceID($0, for: energy) }
            )
        ) {
            Text("By genre").tag("")
            ForEach(libraryPlaylists, id: \.id) { playlist in
                Text(playlist.name).tag(playlist.id.rawValue)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(isLoadingLibrary)
    }

    // MARK: - Library

    /// The runner's own playlists, used to populate the per-tier pickers.
    ///
    /// A failure here is deliberately silent: an empty list leaves every tier on "By genre",
    /// which is the working default. There is nothing for the runner to do about a library
    /// read that failed, so there is nothing worth telling them.
    private func loadLibraryPlaylists() async {
        guard service.isAuthorized else {
            libraryPlaylists = []
            return
        }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let response = try await MusicLibraryRequest<Playlist>().response()
            libraryPlaylists = Array(response.items)
        } catch {
            libraryPlaylists = []
        }
    }
}
