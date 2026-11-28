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
public struct TrainingBreak: Codable, Equatable, Sendable, Identifiable {

    /// Why the runner can't train normally.
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case ill
        case injured
        case travelling
    }

    /// What the plan does on the break's days.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Keep running, but every run is a short easy one.
        case easeOff
        /// No running at all.
        case pause
    }

    /// Where the runner is in a break on a given day.
    public enum Phase: Equatable, Sendable {
        /// The break starts on a later day (a holiday booked ahead).
        case upcoming
        case onBreak
        /// The break is over and the plan is still lighter than it was.
        case easingBack
        case finished
    }

    /// A planned session the break changed, as it was and as the break left it.
    public struct ChangedSession: Codable, Equatable, Sendable {
        public let sessionID: UUID
        public let original: SessionContent
        /// What the break wrote. Undo only puts back a session that still looks like
        /// this, so a session the runner changed again since (Smart Adapt, the coach) is
        /// left as they made it.
        public let appliedTypeRaw: String
        public let appliedDistanceMeters: Double?

        public init(
            sessionID: UUID,
            original: SessionContent,
            appliedTypeRaw: String,
            appliedDistanceMeters: Double?
        ) {
            self.sessionID = sessionID
            self.original = original
            self.appliedTypeRaw = appliedTypeRaw
            self.appliedDistanceMeters = appliedDistanceMeters
        }
    }

    /// Everything a planned session prescribes, so it can be put back exactly.
    public struct SessionContent: Codable, Equatable, Sendable {
        public let workoutTypeRaw: String
        public let targetDistanceMeters: Double?
        public let targetPaceLowerBound: Double?
        public let targetPaceUpperBound: Double?
        public let notes: String?
        public let intervalsData: Data?
        public let structureData: Data?
        public let strengthData: Data?

        public init(
            workoutTypeRaw: String,
            targetDistanceMeters: Double?,
            targetPaceLowerBound: Double?,
            targetPaceUpperBound: Double?,
            notes: String?,
            intervalsData: Data?,
            structureData: Data?,
            strengthData: Data?
        ) {
            self.workoutTypeRaw = workoutTypeRaw
            self.targetDistanceMeters = targetDistanceMeters
            self.targetPaceLowerBound = targetPaceLowerBound
            self.targetPaceUpperBound = targetPaceUpperBound
            self.notes = notes
            self.intervalsData = intervalsData
            self.structureData = structureData
            self.strengthData = strengthData
        }
    }

    public let id: UUID
    public let planID: UUID
    public let reason: Reason
    public let mode: Mode
    /// The break's first day, at the start of the day.
    public let startDate: Date
    /// The break's last day, at the start of the day.
    public var endDate: Date
    /// The last easing-back day, or nil when the break was too short to need any.
    public var rampEndDate: Date?
    public let createdAt: Date
    public var changes: [ChangedSession]

    public init(
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

    public func phase(on now: Date, calendar: Calendar = .current) -> Phase {
        let today = calendar.startOfDay(for: now)
        if today < calendar.startOfDay(for: startDate) { return .upcoming }
        if today <= calendar.startOfDay(for: endDate) { return .onBreak }
        if let rampEndDate, today <= calendar.startOfDay(for: rampEndDate) { return .easingBack }
        return .finished
    }

    /// The number of days the break covers, first and last included.
    public func length(calendar: Calendar = .current) -> Int {
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
public enum TrainingBreakPolicy {

    /// The longest break the plan takes. Longer than this, the plan the runner comes back
    /// to is the wrong plan, and "Rebuild plan" is the better tool.
    public static let maximumDays = 28
    /// How far ahead a break can start: a holiday booked for the week after next.
    public static let maximumDaysAhead = 21
    /// After a pause this long the card suggests rebuilding the plan once they're back.
    public static let rebuildSuggestedAfterDays = 15

    /// No run the break writes is shorter than this.
    public static let minimumRunMeters: Double = 2_000
    /// A quality day turned easy with no distance of its own (intervals carry theirs in
    /// the reps) gets the plan's usual easy run, or this when it has none.
    public static let fallbackEasyMeters: Double = 5_000

    /// How much of each run is left on an "ease off" day.
    public static func easeOffFactor(for reason: TrainingBreak.Reason) -> Double {
        switch reason {
        case .ill, .injured: return 0.5
        case .travelling: return 0.7
        }
    }

    /// Whether a strength or cross-training session goes during a pause. An injured runner
    /// keeps them (cross-training is how an injured runner keeps fit, and the strength
    /// card already says to skip what hurts); an ill one rests completely, and a
    /// travelling one is away from the gym and the bike.
    public static func pauseKeepsNonRunning(for reason: TrainingBreak.Reason) -> Bool {
        reason == .injured
    }

    /// How the plan brings the runner back after a break.
    public struct Ramp: Equatable, Sendable {
        /// Easing-back days after the break.
        public let days: Int
        /// The share of each run's distance kept in the first half of the ramp.
        public let firstHalfFactor: Double
        /// The share kept in the second half.
        public let secondHalfFactor: Double
        /// Tempo and interval days turn easy for the whole ramp rather than its first
        /// half.
        public let easyOnlyThroughout: Bool

        /// The easing-back days that are in the first half.
        public var firstHalfDays: Int { (days + 1) / 2 }

        public init(
            days: Int,
            firstHalfFactor: Double,
            secondHalfFactor: Double,
            easyOnlyThroughout: Bool
        ) {
            self.days = days
            self.firstHalfFactor = firstHalfFactor
            self.secondHalfFactor = secondHalfFactor
            self.easyOnlyThroughout = easyOnlyThroughout
        }
    }

    /// The ramp after a break of `days`, or nil when the break was short enough to pick
    /// the plan straight back up.
    ///
    /// An "ease off" break kept the runner running, so it counts as half its length.
    public static func ramp(after days: Int, reason: TrainingBreak.Reason, mode: TrainingBreak.Mode) -> Ramp? {
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
    public static func rounded(_ meters: Double) -> Double {
        (meters / 100).rounded() * 100
    }

    /// Days from `start` through `end`, both included; zero when `end` is before `start`.
    public static func days(from start: Date, through end: Date, calendar: Calendar = .current) -> Int {
        let gap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
        return max(gap + 1, 0)
    }
}

// MARK: - Coach

extension TrainingBreak {

    /// What the AI coach has to know about the break before it says anything about the
    /// plan or a run: the chat's plan context and the post-run read both carry it. Nil once
    /// the break is finished. Prompt text, so not localized, like the rest of the coach's
    /// context.
    public func coachNote(on now: Date, calendar: Calendar = .current) -> String? {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let end = endDate.formatted(style)
        let why: String
        switch reason {
        case .ill: why = "ill"
        case .injured: why = "injured"
        case .travelling: why = "travelling"
        }
        let what = mode == .pause
            ? "the plan is paused (rest days, no running)"
            : "the plan is eased off to short easy runs only"
        let ramp = rampEndDate.map {
            " After it, runs stay deliberately shorter and easier until \($0.formatted(style)) to ease them back in."
        } ?? ""

        switch phase(on: now, calendar: calendar) {
        case .upcoming:
            return "The runner has a break booked from \(startDate.formatted(style)) to \(end) "
                + "(\(why)): \(what).\(ramp) Plan around it; don't move training into those days."
        case .onBreak:
            var note = "The runner is on a break because they're \(why): \(what) through \(end).\(ramp) "
                + "Don't suggest tempo, intervals, long runs or extra running before then, and don't "
                + "treat skipped or shorter runs as missed. Ask how they feel rather than about pace. "
                + "If they're better, they can tap \"I'm back\" on the Plan tab to end the break early."
            switch reason {
            case .ill:
                note += " With a fever, chest symptoms or aching all over they should rest, not run, "
                    + "and see a doctor if they aren't improving."
            case .injured:
                note += " Never encourage running through pain; if it hurts to walk or changes how "
                    + "they run, suggest seeing a physio or doctor."
            case .travelling:
                break
            }
            return note
        case .easingBack:
            let rampEnd = (rampEndDate ?? endDate).formatted(style)
            return "The runner is easing back in after a break (\(why), \(length(calendar: calendar)) days) "
                + "until \(rampEnd): runs are deliberately shorter and easier than the plan was. Don't push "
                + "volume or pace up before then, and don't treat the shorter runs as missed targets."
        case .finished:
            return nil
        }
    }
}
