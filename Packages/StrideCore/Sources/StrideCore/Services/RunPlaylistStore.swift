import Foundation

/// Stride's note of which Apple Music playlist belongs to which scheduled session.
///
/// `UserDefaults`, keyed by workout ID. See ``RunPlaylistLink`` for why this is not a stored
/// property on `ScheduledWorkout`: the playlist itself already syncs through the runner's
/// Apple Music account, so the only thing that would have earned a CloudKit schema
/// deployment is the note, and a second device losing the note offers to build rather than
/// to open — which is a smaller cost than a release gated on a console deploy.
enum RunPlaylistStore {

    private static let keyPrefix = "runPlaylist."

    private static func key(for workoutID: UUID) -> String {
        keyPrefix + workoutID.uuidString
    }

    static func link(for workoutID: UUID, in defaults: UserDefaults = .standard) -> RunPlaylistLink? {
        guard let data = defaults.data(forKey: key(for: workoutID)) else { return nil }
        return try? JSONDecoder().decode(RunPlaylistLink.self, from: data)
    }

    static func save(_ link: RunPlaylistLink, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(link) else { return }
        defaults.set(data, forKey: key(for: link.workoutID))
    }

    static func remove(for workoutID: UUID, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: workoutID))
    }

    /// How long a link is kept. A playlist built for a session four months ago is not something
    /// anyone is going back to look at.
    static let retention: TimeInterval = 120 * 24 * 60 * 60

    /// Drops links older than ``retention``.
    ///
    /// Worth doing only because a link now carries its full track list — a name and an ID per
    /// session would have been negligible forever, but twenty tracks per session in
    /// `UserDefaults`, which is read into memory whole, is a number that should not grow without
    /// a bound. Called after each build, which is the only thing that adds one.
    ///
    /// Pruning a link does not touch the playlist: that is in the runner's Apple Music library
    /// and stays there. All they lose is Stride's offer to play it from the session.
    static func prune(now: Date = Date(), in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            guard let data = defaults.data(forKey: key),
                  let link = try? JSONDecoder().decode(RunPlaylistLink.self, from: data)
            else {
                // Undecodable under our own prefix: a format we no longer read. Drop it.
                defaults.removeObject(forKey: key)
                continue
            }
            if now.timeIntervalSince(link.builtAt) > retention {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Drops every stored link.
    ///
    /// Called from `AppContainer.resetAllData` for the same reason the widget snapshot is
    /// cleared there: after a reset, an offer to open the playlist for a session that no
    /// longer exists is the one place the deleted plan survives. The playlists themselves are
    /// deliberately left alone — they are in the runner's Apple Music library, not Stride's,
    /// and deleting a runner's music behind a "reset app data" button is not a thing this
    /// button gets to do.
    static func removeAll(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
