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

    init(
        workoutID: UUID,
        playlistID: String,
        name: String,
        trackCount: Int,
        totalSeconds: Double,
        builtAt: Date,
        usedCatalog: Bool,
        playParametersData: Data? = nil
    ) {
        self.workoutID = workoutID
        self.playlistID = playlistID
        self.name = name
        self.trackCount = trackCount
        self.totalSeconds = totalSeconds
        self.builtAt = builtAt
        self.usedCatalog = usedCatalog
        self.playParametersData = playParametersData
    }
}
