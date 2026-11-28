import Foundation

/// The runner's training breaks (``TrainingBreak``), kept on this device.
///
/// `UserDefaults`, like ``AdaptedSessions`` and ``RunPlaylistStore``: a new `@Model` or a
/// stored property on one would need a CloudKit schema deployment. Finished breaks are
/// dropped as the store is read, so it holds at most one live break per plan.
enum TrainingBreakStore {

    static let key = "trainingBreaks"

    /// The break the plan is in, about to start, or easing back from; nil once it is
    /// finished.
    static func current(
        forPlan planID: UUID,
        now: Date = Date(),
        calendar: Calendar = .current,
        in defaults: UserDefaults = .standard
    ) -> TrainingBreak? {
        live(now: now, calendar: calendar, in: defaults)
            .filter { $0.planID == planID }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Saves `trainingBreak`, replacing any stored break with its id.
    static func save(_ trainingBreak: TrainingBreak, now: Date = Date(), in defaults: UserDefaults = .standard) {
        var breaks = live(now: now, in: defaults).filter { $0.id != trainingBreak.id }
        breaks.append(trainingBreak)
        write(breaks, to: defaults)
    }

    static func remove(id: UUID, in defaults: UserDefaults = .standard) {
        write(load(from: defaults).filter { $0.id != id }, to: defaults)
    }

    /// The sessions the automatic pace refresh must leave alone: everything a live break
    /// changed. The refresh keeps a session's type and distance, but it rewrites the note
    /// that says why the session is shorter, and a break outlasts the week
    /// ``AdaptedSessions`` protects an edit for.
    static func protectedIDs(now: Date = Date(), in defaults: UserDefaults = .standard) -> Set<UUID> {
        Set(live(now: now, in: defaults).flatMap { $0.changes.map(\.sessionID) })
    }

    /// Called from `AppContainer.resetAllData`.
    static func removeAll(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    // MARK: Storage

    private static func live(now: Date, calendar: Calendar = .current, in defaults: UserDefaults) -> [TrainingBreak] {
        load(from: defaults).filter { $0.phase(on: now, calendar: calendar) != .finished }
    }

    private static func load(from defaults: UserDefaults) -> [TrainingBreak] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TrainingBreak].self, from: data)) ?? []
    }

    private static func write(_ breaks: [TrainingBreak], to defaults: UserDefaults) {
        guard !breaks.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(breaks) {
            defaults.set(data, forKey: key)
        }
    }
}
