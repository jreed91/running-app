import Foundation

/// Every judgement and every number behind run playlists, in one place.
///
/// This file is shaped like `HeatAdaptationPolicy` and `PregnancyRunningPolicy` — a wall of
/// constants with the reasoning attached, so the decisions can be argued with in one place
/// instead of being scattered through a generator. It differs from those two in one
/// important way, and the difference should not be papered over:
///
/// > **These numbers are editorial, not evidence.** A dew-point threshold is a published
/// > finding; "hip-hop is a hard-tier genre" is Stride's taste. The health policies cite
/// > sources because a prescription without one reads as authority it has not earned. This
/// > one carries no citations because there are none to carry, and inventing a
/// > scientific-sounding basis for a genre table would be the same failure in the opposite
/// > direction.
///
/// The one place a real constraint bites is tempo. The Apple Music catalogue publishes no
/// BPM for a song, so nothing here can match music to cadence, and nothing in the UI claims
/// to. Genre is the only signal Apple actually gives us, so genre is what the tiers are
/// built from — with the runner able to override any tier with a playlist of their own
/// when Stride's taste and theirs disagree.
enum MusicEnergyPolicy {

    // MARK: - Genres

    /// Apple Music genre names that suggest each tier.
    ///
    /// Matched case-insensitively as substrings against a song's `genreNames`, so a track
    /// tagged "Alternative Rap" or "Hard Rock" still lands under its parent. A song that
    /// matches more than one tier is claimed by the highest — the pool a hard block draws
    /// from should be the narrower one, because a hard block is the one a wrong pick spoils.
    static let genres: [RunPlaylistEnergy: [String]] = [
        .hard: [
            "Hip-Hop", "Rap", "Dance", "Electronic", "House", "Techno",
            "Drum & Bass", "Metal", "Punk", "Hard Rock"
        ],
        .steady: [
            "Rock", "Pop", "Alternative", "R&B/Soul", "Soul", "Funk",
            "Indie", "Reggae", "Latin", "Afrobeats"
        ],
        .calm: [
            "Ambient", "Classical", "Jazz", "Singer/Songwriter", "New Age",
            "Acoustic", "Folk", "Soundtrack", "Chill"
        ]
    ]

    /// The tier a song's genre list belongs to, or `nil` when none of them match.
    ///
    /// Checked hard → steady → calm so the narrower pool wins, per the note on ``genres``.
    static func energy(forGenreNames genreNames: [String]) -> RunPlaylistEnergy? {
        let haystack = genreNames.map { $0.lowercased() }
        for tier in [RunPlaylistEnergy.hard, .steady, .calm] {
            let needles = genres[tier] ?? []
            let matches = needles.contains { needle in
                haystack.contains { $0.contains(needle.lowercased()) }
            }
            if matches { return tier }
        }
        return nil
    }

    /// Search terms used to fill a tier from the Apple Music catalogue.
    ///
    /// Fewer than the full genre list: each one is a separate network round trip, and the
    /// results are filtered by ``energy(forGenreNames:)`` afterwards anyway, so breadth in
    /// the query buys less than it costs.
    static func catalogSearchTerms(for energy: RunPlaylistEnergy) -> [String] {
        Array((genres[energy] ?? []).prefix(4))
    }

    // MARK: - Block shaping

    /// The shortest stretch that gets its own block, in seconds.
    ///
    /// A block has to be worth at least a track and a bit, or the playlist changes character
    /// faster than it can play. This is what stops a 10 × 400 m session from producing twenty
    /// alternating blocks of ninety seconds each: the recovery jogs are shorter than this, so
    /// they are absorbed into the work around them and the whole set becomes one hard block.
    static let minimumBlockSeconds: Double = 5 * 60

    /// The most blocks a playlist is shaped into.
    ///
    /// Past about this many the shape stops being audible and starts being churn. Sessions
    /// that want more are merged down by ``RunPlaylistPlanner`` shortest-first.
    static let maximumBlockCount = 5

    /// How much music to gather beyond a block's own length.
    ///
    /// A run that goes long is far more common than a run that ends early — the runner adds
    /// a lap, waits at a crossing, or simply keeps going — and silence at minute 46 of a
    /// 45-minute session is the failure this exists to avoid. 15%, floored at two minutes so
    /// short blocks are not left with a buffer of seconds, and capped at five so a long run
    /// does not collect half an hour of music nobody hears.
    static func bufferSeconds(forBlockOf seconds: Double) -> Double {
        min(max(seconds * 0.15, 2 * 60), 5 * 60)
    }

    // MARK: - Track sourcing

    /// How many songs to pull per catalogue search before filtering.
    static let catalogSearchLimit = 25

    /// How many library songs to consider when filling from the runner's own library.
    ///
    /// The library request is unfiltered and sorted by nothing in particular, so this is a
    /// sample rather than a shortlist — big enough that a mixed library yields every tier,
    /// small enough not to page through ten thousand rows on the main actor.
    static let libraryFetchLimit = 500

    /// Assumed length of a track when Apple Music reports none, in seconds.
    ///
    /// `Song.duration` is optional. A missing one is rare and always a real song, so it is
    /// counted at roughly an average track rather than dropped or counted as zero — the
    /// latter would let a block fill with an unbounded number of unmeasured tracks.
    static let assumedTrackSeconds: Double = 3.5 * 60

    /// Longest a single track can be and still be used.
    ///
    /// Guards against a two-hour DJ set or an audiobook chapter swallowing a whole block.
    static let maximumTrackSeconds: Double = 12 * 60
}
