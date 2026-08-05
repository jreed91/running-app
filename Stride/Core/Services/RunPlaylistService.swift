import Foundation
import MusicKit

/// Builds a playlist for a scheduled session in the runner's Apple Music library.
///
/// This type holds only the *plumbing* — authorization, subscription state, where the tracks
/// come from, and the write into the library. Every judgement about what a session should
/// sound like lives in ``RunPlaylistPlanner`` and ``MusicEnergyPolicy``, which are pure and
/// tested; the same split `HeatAdvisoryService` keeps with `HeatAdaptationPolicy`, and for
/// the same reason: none of the interesting half should need a device to exercise.
///
/// Two design rules this feature rests on, both of which a change here has to keep:
///
/// - **Stride writes a playlist; it never plays one.** The result is a real playlist in the
///   runner's library, so it syncs to their Watch, opens in the Music app, and outlives
///   Stride. The app does not become a music player, and it never touches the audio session —
///   which `RunVoiceCoach` owns, and which exists to *duck* whatever the runner chose to
///   listen to rather than to replace it.
/// - **No claim is made about tempo.** Apple's catalogue publishes no BPM, so neither does
///   Stride. See ``MusicEnergyPolicy``.
@Observable
@MainActor
final class RunPlaylistService {

    // MARK: - Errors

    enum PlaylistError: LocalizedError, Equatable {
        case notAuthorized
        case notARunSession
        case noTracksFound
        case libraryWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return String(
                    localized: "Stride needs permission to use Apple Music.",
                    comment: "Error when building a run playlist without Apple Music authorization"
                )
            case .notARunSession:
                return String(
                    localized: "This session isn't a run, so there's nothing to build a playlist for.",
                    comment: "Error when building a run playlist for a rest or strength day"
                )
            case .noTracksFound:
                return String(
                    localized: "Couldn't find enough music to fill this run.",
                    comment: "Error when no songs matched any energy tier"
                )
            case .libraryWriteFailed(let reason):
                return String(
                    localized: "Couldn't save the playlist to Apple Music. \(reason)",
                    comment: "Error when writing a playlist to the Apple Music library fails"
                )
            }
        }
    }

    // MARK: - State

    private(set) var authorizationStatus: MusicAuthorization.Status

    /// Whether the runner can play Apple Music's full catalogue.
    ///
    /// False for anyone without an active subscription, which is a supported case rather than
    /// a blocked one: the build falls back to their own library and says nothing about
    /// subscriptions. A feature that answers "build me a playlist" with an upsell is not
    /// answering the question.
    private(set) var canPlayCatalogContent = false

    private(set) var isBuilding = false

    @ObservationIgnored private let defaults: UserDefaults

    /// One build's worth of the runner's library, so a three-tier playlist costs one fetch
    /// rather than three. Cleared at the end of each build — a library changes, and a cache
    /// that outlives the reason for it is a stale-results bug waiting to happen.
    @ObservationIgnored private var librarySongCache: [Song]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.authorizationStatus = MusicAuthorization.currentStatus
    }

    // MARK: - Authorization

    var isAuthorized: Bool { authorizationStatus == .authorized }

    /// Asks for Apple Music access, or re-reads the answer if it has already been given.
    @discardableResult
    func requestAuthorization() async -> MusicAuthorization.Status {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        await refreshSubscriptionState()
        return status
    }

    /// Re-reads authorization and subscription without prompting.
    func refreshAvailability() async {
        authorizationStatus = MusicAuthorization.currentStatus
        await refreshSubscriptionState()
    }

    private func refreshSubscriptionState() async {
        guard authorizationStatus == .authorized else {
            canPlayCatalogContent = false
            return
        }
        do {
            let subscription = try await MusicSubscription.current
            canPlayCatalogContent = subscription.canPlayCatalogContent
        } catch {
            // A subscription lookup that fails is not a reason to fail the build — it just
            // means the library path is used, which is the same path a non-subscriber takes.
            canPlayCatalogContent = false
        }
    }

    // MARK: - Links

    func link(for workout: ScheduledWorkout) -> RunPlaylistLink? {
        RunPlaylistStore.link(for: workout.id, in: defaults)
    }

    /// The URL that opens a built playlist in Apple Music.
    static func openURL(for link: RunPlaylistLink) -> URL? {
        URL(string: "music://music.apple.com/library/playlist/\(link.playlistID)")
    }

    // MARK: - Building

    /// Builds — or rebuilds — the playlist for a session.
    ///
    /// Rebuilding replaces the contents of the same playlist rather than making a second one,
    /// so a runner who rebuilds three times ends up with one playlist and not three. That
    /// only works for a playlist Stride created: `MusicLibrary.edit` throws when another app
    /// owns the playlist, and the runner may simply have deleted it, so both cases fall back
    /// to creating a fresh one and re-pointing the stored link.
    ///
    /// - Parameters:
    ///   - workout: The session to score.
    ///   - sources: Per-tier overrides — a library playlist ID the runner chose for that tier,
    ///     which wins over ``MusicEnergyPolicy``'s genre table.
    func buildPlaylist(
        for workout: ScheduledWorkout,
        sources: [RunPlaylistEnergy: String] = [:]
    ) async throws -> RunPlaylistLink {
        guard let plan = RunPlaylistPlanner.plan(for: .init(workout: workout)) else {
            throw PlaylistError.notARunSession
        }

        if authorizationStatus != .authorized {
            _ = await requestAuthorization()
        }
        guard authorizationStatus == .authorized else { throw PlaylistError.notAuthorized }

        isBuilding = true
        defer {
            isBuilding = false
            librarySongCache = nil
        }

        await refreshSubscriptionState()

        let usedCatalog = canPlayCatalogContent
        let pools = await trackPools(for: plan, sources: sources)
        let songs = fill(plan: plan, from: pools)
        guard !songs.isEmpty else { throw PlaylistError.noTracksFound }

        let name = RunPlaylistPlanner.playlistName(for: workout.workoutType, date: workout.scheduledDate)
        let description = RunPlaylistPlanner.playlistDescription(for: plan)
        let existing = RunPlaylistStore.link(for: workout.id, in: defaults)
        let playlist = try await writePlaylist(
            named: name,
            description: description,
            songs: songs,
            replacing: existing?.playlistID
        )

        let link = RunPlaylistLink(
            workoutID: workout.id,
            playlistID: playlist.id.rawValue,
            name: name,
            trackCount: songs.count,
            totalSeconds: songs.reduce(0) { $0 + duration(of: $1) },
            builtAt: Date(),
            usedCatalog: usedCatalog
        )
        RunPlaylistStore.save(link, in: defaults)
        return link
    }

    /// Forgets a playlist without deleting it.
    ///
    /// Stride created the playlist but the runner owns it, so "remove" here means the app
    /// stops claiming it — deleting music out of somebody's library on their behalf is not
    /// something this button gets to do.
    func forgetPlaylist(for workout: ScheduledWorkout) {
        RunPlaylistStore.remove(for: workout.id, in: defaults)
    }

    // MARK: - Library write

    private func writePlaylist(
        named name: String,
        description: String,
        songs: [Song],
        replacing playlistID: String?
    ) async throws -> Playlist {
        if let playlistID, let existing = await libraryPlaylist(withID: playlistID) {
            do {
                return try await MusicLibrary.shared.edit(
                    existing,
                    name: name,
                    description: description,
                    items: songs
                )
            } catch {
                // Thrown when the playlist was created by another app — or has been edited
                // into one MusicKit will not touch. Creating a fresh one is a better answer
                // than failing the build.
                AppLogger.log(
                    "Editing the existing run playlist failed: \(error.localizedDescription)",
                    label: "RunPlaylist",
                    level: .error
                )
            }
        }

        do {
            return try await MusicLibrary.shared.createPlaylist(
                name: name,
                description: description,
                items: songs
            )
        } catch {
            throw PlaylistError.libraryWriteFailed(error.localizedDescription)
        }
    }

    private func libraryPlaylist(withID id: String) async -> Playlist? {
        do {
            // Fetched and matched by hand rather than filtered in the request: the set of
            // library playlists is small, and `MusicLibraryRequest`'s filter key paths are a
            // narrower surface than the one property we actually need to match on.
            let response = try await MusicLibraryRequest<Playlist>().response()
            return response.items.first { $0.id.rawValue == id }
        } catch {
            AppLogger.log(
                "Looking up the existing run playlist failed: \(error.localizedDescription)",
                label: "RunPlaylist",
                level: .error
            )
            return nil
        }
    }

    // MARK: - Track sourcing

    /// A shuffled pool of candidate songs for each energy the plan actually uses.
    ///
    /// A tier with no candidates of its own borrows from the others rather than failing the
    /// whole build. A playlist that is slightly off-genre in one stretch is a better outcome
    /// than no playlist, and the runner who cares can point that tier at a playlist of their
    /// own in Settings — which is what the `sources` overrides are for.
    private func trackPools(
        for plan: RunPlaylistPlan,
        sources: [RunPlaylistEnergy: String]
    ) async -> [RunPlaylistEnergy: [Song]] {
        var pools: [RunPlaylistEnergy: [Song]] = [:]

        for energy in Set(plan.blocks.map(\.energy)) {
            if let playlistID = sources[energy], !playlistID.isEmpty {
                // The runner named this playlist for this tier, so it is taken as given and
                // not filtered by genre afterwards.
                pools[energy] = await songs(inLibraryPlaylist: playlistID).shuffled()
                if pools[energy]?.isEmpty == false { continue }
            }

            var candidates: [Song] = []
            if canPlayCatalogContent {
                candidates = await catalogSongs(for: energy)
            }
            if candidates.isEmpty {
                candidates = await librarySongs().filter {
                    MusicEnergyPolicy.energy(forGenreNames: $0.genreNames) == energy
                }
            }
            pools[energy] = candidates.shuffled()
        }

        let fallback = pools.values.flatMap { $0 }.shuffled()
        for (energy, pool) in pools where pool.isEmpty {
            pools[energy] = fallback
        }
        return pools
    }

    private func catalogSongs(for energy: RunPlaylistEnergy) async -> [Song] {
        var collected: [Song] = []
        for term in MusicEnergyPolicy.catalogSearchTerms(for: energy) {
            do {
                var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
                request.limit = MusicEnergyPolicy.catalogSearchLimit
                let response = try await request.response()
                collected.append(contentsOf: response.songs)
            } catch {
                AppLogger.log(
                    "Apple Music search for \(term) failed: \(error.localizedDescription)",
                    label: "RunPlaylist",
                    level: .error
                )
            }
        }
        return collected.filter { song in
            isUsable(song) && MusicEnergyPolicy.energy(forGenreNames: song.genreNames) == energy
        }
    }

    private func librarySongs() async -> [Song] {
        if let cached = librarySongCache { return cached }
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = MusicEnergyPolicy.libraryFetchLimit
            let response = try await request.response()
            let songs = response.items.filter(isUsable)
            librarySongCache = songs
            return songs
        } catch {
            AppLogger.log(
                "Reading the music library failed: \(error.localizedDescription)",
                label: "RunPlaylist",
                level: .error
            )
            librarySongCache = []
            return []
        }
    }

    private func songs(inLibraryPlaylist id: String) async -> [Song] {
        guard let playlist = await libraryPlaylist(withID: id) else { return [] }
        do {
            // `with(.tracks)` returns at most 100 entries, which is far more than any block
            // needs and is why no paging is done here.
            let detailed = try await playlist.with(.tracks)
            let tracks = detailed.tracks ?? []
            return tracks.compactMap { track in
                guard case .song(let song) = track, isUsable(song) else { return nil }
                return song
            }
        } catch {
            AppLogger.log(
                "Reading the source playlist's tracks failed: \(error.localizedDescription)",
                label: "RunPlaylist",
                level: .error
            )
            return []
        }
    }

    private func isUsable(_ song: Song) -> Bool {
        duration(of: song) <= MusicEnergyPolicy.maximumTrackSeconds
    }

    private func duration(of song: Song) -> Double {
        song.duration ?? MusicEnergyPolicy.assumedTrackSeconds
    }

    // MARK: - Filling

    /// Walks the plan in order, filling each block to its length plus its buffer.
    ///
    /// A song is used once across the whole playlist: hearing the same track in the warm-up
    /// and again in the last interval is the sort of thing that makes a generated playlist
    /// feel generated. A block whose pool runs dry simply ends short rather than repeating.
    private func fill(plan: RunPlaylistPlan, from pools: [RunPlaylistEnergy: [Song]]) -> [Song] {
        var ordered: [Song] = []
        var used = Set<String>()

        for block in plan.blocks {
            let target = block.seconds + MusicEnergyPolicy.bufferSeconds(forBlockOf: block.seconds)
            var accumulated: Double = 0

            for song in pools[block.energy] ?? [] {
                if accumulated >= target { break }
                let id = song.id.rawValue
                guard !used.contains(id) else { continue }
                used.insert(id)
                ordered.append(song)
                accumulated += duration(of: song)
            }
        }

        return ordered
    }
}
