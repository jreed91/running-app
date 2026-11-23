import Foundation

// MARK: - TrainingBreak

/// A stretch of days the runner told the plan they can't train normally: they're ill,
/// injured or travelling. The plan eases off or pauses for those days, then brings them
/// back in gradually (the "easing back" days after it).
///
/// What a break *does* to the plan is written straight into the sessions, so Plan, Home,
/// the Watch and the widgets need to know nothing about it. This record exists for the
/// three things the sessions can't say on their own: the card that tells the runner what
/// is going on, "I'm back early", and "Undo". It keeps every changed session as it was
/// (``ChangedSession/original``) so an undo puts the plan back exactly.
///
/// Device-local in `UserDefaults` (``TrainingBreakStore``), like ``AdaptedSessions``: a
/// stored property on a `@Model` would mean a CloudKit schema deployment. A break made on
/// this phone shows its card on this phone; the changed sessions sync as usual.
struct TrainingBreak: Codable, Equatable, Sendable, Identifiable {

    /// Why the runner can't train normally.
    enum Reason: String, Codable, CaseIterable, Sendable {
        case ill
        case injured
        case travelling
    }

    /// What the plan does on the break's days.
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Keep running, but every run is a short easy one.
        case easeOff
        /// No running at all.
        case pause
    }

    /// Where the runner is in a break on a given day.
    enum Phase: Equatable, Sendable {
        /// The break starts on a later day (a holiday booked ahead).
        case upcoming
        case onBreak
        /// The break is over and the plan is still lighter than it was.
        case easingBack
        case finished
    }

    /// A planned session the break changed, as it was and as the break left it.
    struct ChangedSession: Codable, Equatable, Sendable {
        let sessionID: UUID
        let original: SessionContent
        /// What the break wrote. Undo only puts back a session that still looks like
        /// this, so a session the runner changed again since (Smart Adapt, the coach) is
        /// left as they made it.
        let appliedTypeRaw: String
        let appliedDistanceMeters: Double?
    }

    /// Everything a planned session prescribes, so it can be put back exactly.
    struct SessionContent: Codable, Equatable, Sendable {
        let workoutTypeRaw: String
        let targetDistanceMeters: Double?
        let targetPaceLowerBound: Double?
        let targetPaceUpperBound: Double?
        let notes: String?
        let intervalsData: Data?
        let structureData: Data?
        let strengthData: Data?
    }

    let id: UUID
    let planID: UUID
    let reason: Reason
    let mode: Mode
    /// The break's first day, at the start of the day.
    let startDate: Date
    /// The break's last day, at the start of the day.
    var endDate: Date
    /// The last easing-back day, or nil when the break was too short to need any.
    var rampEndDate: Date?
    let createdAt: Date
    var changes: [ChangedSession]

    init(
        id: UUID = UUID(),
        planID: UUID,
        reason: Reason,
        mode: Mode,
        startDate: Date,
        endDate: Date,
        rampEndDate: Date?,
        createdAt: Date = Date(),
        changes: [ChangedSession]
    ) {
        self.id = id
        self.planID = planID
        self.reason = reason
        self.mode = mode
        self.startDate = startDate
        self.endDate = endDate
        self.rampEndDate = rampEndDate
        self.createdAt = createdAt
        self.changes = changes
    }

    func phase(on now: Date, calendar: Calendar = .current) -> Phase {
        let today = calendar.startOfDay(for: now)
        if today < calendar.startOfDay(for: startDate) { return .upcoming }
        if today <= calendar.startOfDay(for: endDate) { return .onBreak }
        if let rampEndDate, today <= calendar.startOfDay(for: rampEndDate) { return .easingBack }
        return .finished
    }

    /// The number of days the break covers, first and last included.
    func length(calendar: Calendar = .current) -> Int {
        TrainingBreakPolicy.days(from: startDate, through: endDate, calendar: calendar)
    }
}

// MARK: - TrainingBreakPolicy

/// Every number a break uses, in one place.
///
/// These are conservative coaching rules of thumb, the kind return-to-run guidance gives
/// (come back below where you left off, easy running before quality, longer away means a
/// longer way back), not values from a study. `docs/TRAINING_BREAKS.md` says what each
/// one is for; change it there and here together.
enum TrainingBreakPolicy {

    /// The longest break the plan takes. Longer than this, the plan the runner comes back
    /// to is the wrong plan, and "Rebuild plan" is the better tool.
    static let maximumDays = 28
    /// How far ahead a break can start: a holiday booked for the week after next.
    static let maximumDaysAhead = 21
    /// After a pause this long the card suggests rebuilding the plan once they're back.
    static let rebuildSuggestedAfterDays = 15

    /// No run the break writes is shorter than this.
    static let minimumRunMeters: Double = 2_000
    /// A quality day turned easy with no distance of its own (intervals carry theirs in
    /// the reps) gets the plan's usual easy run, or this when it has none.
    static let fallbackEasyMeters: Double = 5_000

    /// How much of each run is left on an "ease off" day.
    static func easeOffFactor(for reason: TrainingBreak.Reason) -> Double {
        switch reason {
        case .ill, .injured: return 0.5
        case .travelling: return 0.7
        }
    }

    /// Whether a strength or cross-training session goes during a pause. An injured runner
    /// keeps them (cross-training is how an injured runner keeps fit, and the strength
    /// card already says to skip what hurts); an ill one rests completely, and a
    /// travelling one is away from the gym and the bike.
    static func pauseKeepsNonRunning(for reason: TrainingBreak.Reason) -> Bool {
        reason == .injured
    }

    /// How the plan brings the runner back after a break.
    struct Ramp: Equatable, Sendable {
        /// Easing-back days after the break.
        let days: Int
        /// The share of each run's distance kept in the first half of the ramp.
        let firstHalfFactor: Double
        /// The share kept in the second half.
        let secondHalfFactor: Double
        /// Tempo and interval days turn easy for the whole ramp rather than its first
        /// half.
        let easyOnlyThroughout: Bool

        /// The easing-back days that are in the first half.
        var firstHalfDays: Int { (days + 1) / 2 }
    }

    /// The ramp after a break of `days`, or nil when the break was short enough to pick
    /// the plan straight back up.
    ///
    /// An "ease off" break kept the runner running, so it counts as half its length.
    static func ramp(after days: Int, reason: TrainingBreak.Reason, mode: TrainingBreak.Mode) -> Ramp? {
        let daysOff = mode == .easeOff ? (days + 1) / 2 : days
        let easyOnly = reason == .injured
        switch daysOff {
        case ...2:
            return nil
        case 3...7:
            return Ramp(days: 7, firstHalfFactor: 0.7, secondHalfFactor: 0.85, easyOnlyThroughout: easyOnly)
        case 8...14:
            return Ramp(days: 14, firstHalfFactor: 0.6, secondHalfFactor: 0.8, easyOnlyThroughout: easyOnly)
        default:
            return Ramp(days: 14, firstHalfFactor: 0.5, secondHalfFactor: 0.75, easyOnlyThroughout: easyOnly)
        }
    }

    /// Distances are written rounded to 100 m.
    static func rounded(_ meters: Double) -> Double {
        (meters / 100).rounded() * 100
    }

    /// Days from `start` through `end`, both included; zero when `end` is before `start`.
    static func days(from start: Date, through end: Date, calendar: Calendar = .current) -> Int {
        let gap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
        return max(gap + 1, 0)
    }
}
