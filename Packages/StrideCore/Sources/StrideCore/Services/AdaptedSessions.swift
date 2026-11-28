import Foundation

/// The planned sessions the runner chose to change, and when, so the automatic pace
/// refresh leaves them alone for a week.
///
/// Three things change a session on purpose: Smart Adapt, the coach's "Update next
/// session", and the heat sheet. `TrainingPlanService.refreshPaces` rewrites every future
/// session after a run, and it used to rewrite these too: a heat-adapted session got its
/// fast paces back from a run the day before it, and a Smart Adapt answer lasted until the
/// next run (P1.1). An edit is now protected for ``protection``. That covers a heat edit,
/// which is for today or tomorrow, and the coach's near-term choices; after it the session
/// is re-paced from the runner's latest fitness as usual, so a Smart Adapt across a long
/// plan does not freeze its paces until race day.
///
/// Device-local in `UserDefaults`, like ``RunPlaylistStore``: a stored property on
/// `ScheduledWorkout` would mean a CloudKit schema deployment. The refresh runs on the
/// device that recorded or imported the run, which in practice is the phone the edit was
/// made on; an edit made on another device is not protected on this one.
public enum AdaptedSessions {

    public static let key = "adaptedSessions"

    /// How long an edit outlasts the automatic refresh.
    public static let protection: TimeInterval = 7 * 24 * 60 * 60

    /// Serializes ``record(_:at:in:)``. Swift Testing ran `CustomWorkoutSwapTests` alongside
    /// other tests recording into `.standard`, and a lost update failed it (run 46070097517).
    private static let lock = NSLock()

    /// Notes that `sessionID` was just changed on purpose. Edits older than
    /// ``protection`` are dropped on the way, so the dictionary stays the size of a week's
    /// edits.
    public static func record(_ sessionID: UUID, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        // Read-modify-write: two records at once could each drop the other's entry.
        lock.lock()
        defer { lock.unlock() }
        var edits = load(from: defaults).filter { isProtected(editedAt: $0.value, now: date) }
        edits[sessionID] = date
        defaults.set(
            Dictionary(uniqueKeysWithValues: edits.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }),
            forKey: key
        )
    }

    /// The sessions the refresh must leave alone at `now`.
    public static func protectedIDs(now: Date = Date(), in defaults: UserDefaults = .standard) -> Set<UUID> {
        Set(load(from: defaults).filter { isProtected(editedAt: $0.value, now: now) }.keys)
    }

    /// Called from `AppContainer.resetAllData`: the entries name sessions that are about to
    /// stop existing.
    public static func removeAll(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func isProtected(editedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(editedAt) < protection
    }

    private static func load(from defaults: UserDefaults) -> [UUID: Date] {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        var edits: [UUID: Date] = [:]
        for (id, seconds) in raw {
            if let uuid = UUID(uuidString: id) {
                edits[uuid] = Date(timeIntervalSince1970: seconds)
            }
        }
        return edits
    }
}
