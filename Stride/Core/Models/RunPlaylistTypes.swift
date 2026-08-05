import Foundation

// MARK: - Energy

/// The energy a stretch of a session should be scored to.
///
/// Three tiers, deliberately, and deliberately *not* named after tempo. Apple Music's
/// catalogue exposes no BPM for a song — `Songs.Attributes` carries genre, duration and
/// artwork and nothing about the beat — so a tier here is an editorial claim about how a
/// stretch of music feels, never a claim about how fast it is. Anything in the UI that
/// implied "160 bpm for your intervals" would be inventing data Apple does not publish.
enum RunPlaylistEnergy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Warm-ups, cool-downs, and the walking bookends of a pregnancy session.
    case calm
    /// Steady running: easy days, long runs, and the recovery jogs inside a hard set.
    case steady
    /// The working part of a tempo, an interval session, or a race.
    case hard

    var id: String { rawValue }

    /// The canonical English form, for logs and stored keys. Never shown to a runner.
    var displayName: String {
        switch self {
        case .calm:   return "Calm"
        case .steady: return "Steady"
        case .hard:   return "Hard"
        }
    }

    var localizedName: String {
        switch self {
        case .calm:
            return String(localized: "Calm", comment: "Run-playlist energy tier: warm-ups and cool-downs")
        case .steady:
            return String(localized: "Steady", comment: "Run-playlist energy tier: easy and long running")
        case .hard:
            return String(localized: "Hard", comment: "Run-playlist energy tier: tempo and interval work")
        }
    }

    /// What this tier is for, in the runner's words. Used by the Settings picker, where
    /// the tier name alone does not say which part of a run it scores.
    var localizedDescription: String {
        switch self {
        case .calm:
            return String(
                localized: "Warm-ups, cool-downs and walking breaks.",
                comment: "Explains which part of a run the Calm playlist tier covers"
            )
        case .steady:
            return String(
                localized: "Easy days, long runs, and recovery jogs between reps.",
                comment: "Explains which part of a run the Steady playlist tier covers"
            )
        case .hard:
            return String(
                localized: "The working part of a tempo, an interval session or a race.",
                comment: "Explains which part of a run the Hard playlist tier covers"
            )
        }
    }
}

// MARK: - Plan

/// One contiguous stretch of a session that should be scored at a single energy.
struct RunPlaylistBlock: Codable, Hashable, Sendable {
    var energy: RunPlaylistEnergy
    /// How long this stretch of the session lasts, in seconds — before any buffer.
    var seconds: Double
}

/// The shape of a session, expressed as music rather than as pace.
///
/// Produced by ``RunPlaylistPlanner`` from a `ScheduledWorkout` and consumed by
/// ``RunPlaylistService``, which is the only half that needs MusicKit. Keeping the shape
/// in a value type is what lets every interesting decision in this feature be tested
/// without an Apple Music subscription, a network, or a device.
struct RunPlaylistPlan: Codable, Hashable, Sendable {
    /// Blocks in the order the runner will meet them.
    var blocks: [RunPlaylistBlock]
    /// The session's own estimated duration, before buffers.
    var sessionSeconds: Double

    /// Total music to gather, including each block's buffer.
    var targetSeconds: Double {
        blocks.reduce(0) { $0 + $1.seconds + MusicEnergyPolicy.bufferSeconds(forBlockOf: $1.seconds) }
    }
}

// MARK: - Tracks

/// One track in a built playlist, as Stride placed it.
///
/// Stored on the link rather than re-read from Apple Music when the runner wants to look at
/// the playlist, and the reason is the whole history of this feature: iOS will not open a
/// private library playlist, so this list is the *only* place the playlist can be seen. A
/// screen that needs authorization, a library round trip and a network to render is a screen
/// that can fail, and it is standing in for something that already failed three times. This
/// renders instantly, offline, and cannot error.
///
/// What it costs is that it shows the playlist **as Stride built it**. If the runner reorders
/// or deletes tracks in Apple Music, this does not follow — which is why the detail screen
/// says so rather than presenting itself as a live mirror.
struct RunPlaylistTrack: Codable, Hashable, Sendable, Identifiable {
    /// `MusicItemID.rawValue`. Also what makes a track unique within a playlist.
    var id: String
    var title: String
    var artist: String
    var seconds: Double
    /// The block this track was placed in — the reason a playlist is worth looking at rather
    /// than just playing, since it is what shows the shape actually landed.
    var energy: RunPlaylistEnergy
}

/// A run of consecutive tracks sharing an energy — one block of the playlist, as heard.
struct RunPlaylistTrackSection: Identifiable, Hashable, Sendable {
    var energy: RunPlaylistEnergy
    var tracks: [RunPlaylistTrack]

    /// Stable within a playlist: blocks never repeat an energy back-to-back (the planner
    /// coalesces them), so position plus energy identifies a section.
    var id: String { "\(index)-\(energy.rawValue)" }
    var index: Int

    var seconds: Double { tracks.reduce(0) { $0 + $1.seconds } }

    /// Groups an ordered track list back into the blocks it was built from.
    ///
    /// Consecutive tracks of one energy are one section. That reproduces the plan's blocks
    /// exactly, because `RunPlaylistPlanner` guarantees no two neighbouring blocks share an
    /// energy — so a change of energy in this list is always a block boundary and never a
    /// split within one.
    static func sections(from tracks: [RunPlaylistTrack]) -> [RunPlaylistTrackSection] {
        var sections: [RunPlaylistTrackSection] = []
        for track in tracks {
            if var last = sections.last, last.energy == track.energy {
                last.tracks.append(track)
                sections[sections.count - 1] = last
            } else {
                sections.append(
                    RunPlaylistTrackSection(energy: track.energy, tracks: [track], index: sections.count)
                )
            }
        }
        return sections
    }
}

// MARK: - Link

/// The record that a playlist was built for a session, and which playlist it is.
///
/// Lives in `UserDefaults` (see ``RunPlaylistStore``) rather than as a stored property on
/// `ScheduledWorkout`, and that is a deliberate trade rather than an oversight. A new
/// stored property on a `@Model` means a `--init-cloudkit-schema` run on a device and a
/// **Deploy Schema Changes** in CloudKit Console before the build can ship (see
/// `docs/CLOUDKIT_VALIDATION.md`); this feature does not need that gate, because the thing
/// worth syncing — the playlist itself — already syncs through the runner's Apple Music
/// account. What stays local is only Stride's note of which playlist belongs to which
/// session, and the cost of that being device-local is that a second device offers to
/// build the playlist again rather than offering to open it.
struct RunPlaylistLink: Codable, Hashable, Sendable {
    /// The `ScheduledWorkout` this playlist was built for.
    var workoutID: UUID
    /// `MusicItemID.rawValue` of the created library playlist.
    var playlistID: String
    /// The name the playlist was given, so the UI can name it without a MusicKit round trip.
    var name: String
    var trackCount: Int
    var totalSeconds: Double
    var builtAt: Date
    /// False when the runner has no Apple Music subscription and the playlist was filled
    /// from their own library. Drives nothing but the wording of the confirmation.
    var usedCatalog: Bool

    /// JSON-encoded MusicKit `PlayParameters` for the created playlist, which is what lets
    /// the Play button work.
    ///
    /// Captured at build time because **iOS has no deep link to a private library playlist**.
    /// `music://music.apple.com/library` opens the library, but every deeper path — including
    /// one carrying a playlist's own ID — fails with "item not available", and that is Apple's
    /// documented behaviour rather than a URL waiting to be spelled correctly. Play parameters
    /// are the supported handle on a library playlist, so they are stored rather than a URL
    /// being constructed. Optional so links written before this existed still decode; those
    /// fall back to re-reading the playlist from the library.
    var playParametersData: Data?

    /// The playlist's tracks in order. Empty for links written before they were stored, which
    /// is what the detail screen checks before offering to show them.
    var tracks: [RunPlaylistTrack]

    /// The tracks grouped back into the blocks they were built from.
    var sections: [RunPlaylistTrackSection] { RunPlaylistTrackSection.sections(from: tracks) }

    init(
        workoutID: UUID,
        playlistID: String,
        name: String,
        trackCount: Int,
        totalSeconds: Double,
        builtAt: Date,
        usedCatalog: Bool,
        playParametersData: Data? = nil,
        tracks: [RunPlaylistTrack] = []
    ) {
        self.workoutID = workoutID
        self.playlistID = playlistID
        self.name = name
        self.trackCount = trackCount
        self.totalSeconds = totalSeconds
        self.builtAt = builtAt
        self.usedCatalog = usedCatalog
        self.playParametersData = playParametersData
        self.tracks = tracks
    }

    /// Decodes `tracks` as empty when absent, so a link written by an earlier build still
    /// decodes instead of taking the whole stored link down with it.
    enum CodingKeys: String, CodingKey {
        case workoutID, playlistID, name, trackCount, totalSeconds, builtAt, usedCatalog
        case playParametersData, tracks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workoutID = try container.decode(UUID.self, forKey: .workoutID)
        playlistID = try container.decode(String.self, forKey: .playlistID)
        name = try container.decode(String.self, forKey: .name)
        trackCount = try container.decode(Int.self, forKey: .trackCount)
        totalSeconds = try container.decode(Double.self, forKey: .totalSeconds)
        builtAt = try container.decode(Date.self, forKey: .builtAt)
        usedCatalog = try container.decode(Bool.self, forKey: .usedCatalog)
        playParametersData = try container.decodeIfPresent(Data.self, forKey: .playParametersData)
        tracks = try container.decodeIfPresent([RunPlaylistTrack].self, forKey: .tracks) ?? []
    }
}
