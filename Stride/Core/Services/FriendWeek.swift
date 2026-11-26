import Foundation

// MARK: - FriendWeek

/// One runner's training week as their friends see it: "Train with friends".
///
/// It is what a runner puts in a training group: for each of the seven days, the sessions
/// the plan asked for and the workouts actually done, with distances and times. It also
/// carries the name the runner chose to show and, when they have one, the race they train
/// for. Nothing else leaves the phone: no routes or locations, no heart rate, no time of
/// day, no notes, no feel. So the privacy zones that guard a shared map have nothing to do
/// here: there is no map.
///
/// The week travels as JSON in a single CloudKit field (``encoded()``, ``decoded(from:)``),
/// so a later version can add fields without a schema change, and an older app reads a
/// newer week by ignoring what it doesn't know.
///
/// Days are calendar days, `YYYY-MM-DD`, not instants. A long run on Saturday stays on
/// Saturday for a friend a few time zones away.
///
/// Pure and Foundation-only; ``make(name:planned:done:race:now:calendar:)`` takes plain
/// values, so every rule here is assertable without SwiftData or a screen.
struct FriendWeek: Codable, Equatable, Sendable {

    /// The format version this app writes. Readers accept any version: fields are only
    /// ever added, and an unknown ``Kind`` reads as `.other`.
    static let currentVersion = 1

    /// Longest display name a week carries. A name is a label on a small card.
    static let maxNameLength = 30

    /// Most entries kept for one day, planned or done. A real day has one or two; the cap
    /// keeps a hand-edited or runaway record from growing without end.
    static let maxEntriesPerDay = 6

    var version: Int
    /// The name the runner chose to show their friends. Never empty: ``make`` falls back
    /// to "Runner".
    var name: String
    /// The Monday this week starts on, `YYYY-MM-DD`.
    var weekStart: String
    /// Always seven, Monday first, each day's ``Day/date`` in order.
    var days: [Day]
    /// The runner's goal race as a race invite link (``RaceInvite/webURL``), so a friend
    /// can open it and train for the same race. Nil without a goal race, or once it has
    /// passed.
    var raceLink: String?
    /// When the runner's phone built this week.
    var updatedAt: Date

    // MARK: Parts

    struct Day: Codable, Equatable, Sendable {
        /// `YYYY-MM-DD`.
        var date: String
        /// What the plan asked for. Empty on a rest day or without a plan.
        var planned: [Planned]
        /// What was done, in the order it was done.
        var done: [Done]
    }

    struct Planned: Codable, Equatable, Sendable {
        var kind: Kind
        /// Whole metres, for runs with a target distance only.
        var meters: Int?
    }

    struct Done: Codable, Equatable, Sendable {
        /// The workout's id, so a friend can cheer this one. A random UUID made on the
        /// runner's phone; it says nothing about them.
        var id: UUID
        var kind: Kind
        /// Whole metres, for runs and walks. Nil for strength and cross training, whose
        /// distance (if any) is not a running distance.
        var meters: Int?
        /// Whole seconds.
        var seconds: Int
    }

    /// The kind of session, in a wire spelling of its own so renaming a ``WorkoutType``
    /// case or its raw value can never change what a friend's app reads.
    enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case easy
        case tempo
        case interval
        case long
        case race
        case cross
        case strength
        case walk
        /// Anything this app version doesn't know: a newer app's kind.
        case other

        init(_ type: WorkoutType) {
            switch type {
            case .easy: self = .easy
            case .tempo: self = .tempo
            case .interval: self = .interval
            case .longRun: self = .long
            case .race: self = .race
            case .crossTraining: self = .cross
            case .strength: self = .strength
            case .walk: self = .walk
            case .rest: self = .other
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }

        /// Whether this kind counts toward the week's running distance, the way
        /// `WorkoutType.countsAsRunning` does for the runner's own numbers.
        var isRunning: Bool {
            switch self {
            case .easy, .tempo, .interval, .long, .race: true
            case .cross, .strength, .walk, .other: false
            }
        }
    }

    // MARK: Inputs

    /// A session from the plan, as ``make`` reads it.
    struct PlannedSession: Equatable, Sendable {
        let date: Date
        let type: WorkoutType
        let targetMeters: Double?
    }

    /// A finished workout, as ``make`` reads it.
    struct FinishedWorkout: Equatable, Sendable {
        let id: UUID
        let date: Date
        let type: WorkoutType
        let meters: Double
        let seconds: Double
    }

    // MARK: Building

    /// The week containing `now`, Monday first, in `calendar`'s time zone.
    ///
    /// - Parameters:
    ///   - name: what the runner typed to show; tidied to one line of at most
    ///     ``maxNameLength`` characters.
    ///   - planned: plan sessions; any outside the week are ignored, rest days are dropped.
    ///   - done: finished workouts; any outside the week are ignored.
    ///   - race: the goal race. Left out once its day is before today.
    static func make(
        name: String,
        planned: [PlannedSession],
        done: [FinishedWorkout],
        race: RaceInvite?,
        now: Date,
        calendar baseCalendar: Calendar
    ) -> FriendWeek {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let dayStarts = (0..<7).map { offset in
            calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        }

        func index(of date: Date) -> Int? {
            let start = calendar.startOfDay(for: date)
            return dayStarts.firstIndex(of: start)
        }

        var plannedByDay = Array(repeating: [Planned](), count: 7)
        for session in planned.sorted(by: { $0.date < $1.date }) where session.type != .rest {
            guard let i = index(of: session.date), plannedByDay[i].count < maxEntriesPerDay else { continue }
            let kind = Kind(session.type)
            let meters = kind.isRunning ? wholeMeters(session.targetMeters) : nil
            plannedByDay[i].append(Planned(kind: kind, meters: meters))
        }

        var doneByDay = Array(repeating: [Done](), count: 7)
        for workout in done.sorted(by: { $0.date < $1.date }) where workout.type != .rest {
            guard let i = index(of: workout.date), doneByDay[i].count < maxEntriesPerDay else { continue }
            let kind = Kind(workout.type)
            let carriesDistance = kind.isRunning || kind == .walk
            doneByDay[i].append(Done(
                id: workout.id,
                kind: kind,
                meters: carriesDistance ? wholeMeters(workout.meters) ?? 0 : nil,
                seconds: wholeSeconds(workout.seconds)
            ))
        }

        let days = dayStarts.enumerated().map { i, start in
            Day(date: dayText(start, calendar: calendar), planned: plannedByDay[i], done: doneByDay[i])
        }

        let link = race.flatMap { $0.hasPassed(now: now, calendar: calendar) ? nil : $0.webURL.absoluteString }

        return FriendWeek(
            version: currentVersion,
            name: tidiedName(name),
            weekStart: dayText(weekStart, calendar: calendar),
            days: days,
            raceLink: link,
            updatedAt: now
        )
    }

    // MARK: Reading

    /// Metres run this week: running kinds only, the way the runner's own weekly total
    /// counts.
    var runMeters: Int {
        days.flatMap(\.done).filter(\.kind.isRunning).reduce(0) { $0 + ($1.meters ?? 0) }
    }

    /// Metres the plan asked for this week, running kinds only.
    var plannedRunMeters: Int {
        days.flatMap(\.planned).filter(\.kind.isRunning).reduce(0) { $0 + ($1.meters ?? 0) }
    }

    /// Runs done this week.
    var runCount: Int {
        days.flatMap(\.done).filter(\.kind.isRunning).count
    }

    /// Plan sessions this week, of any kind.
    var plannedCount: Int {
        days.reduce(0) { $0 + $1.planned.count }
    }

    /// Plan sessions on days that have something done. A day's sessions count as done
    /// when anything was done that day: a friend's card shows the week's shape, not a
    /// session-by-session audit.
    var plannedDoneCount: Int {
        days.reduce(0) { $0 + ($1.done.isEmpty ? 0 : $1.planned.count) }
    }

    /// The race this runner trains for, read back from ``raceLink``.
    var race: RaceInvite? {
        raceLink.flatMap(URL.init(string:)).flatMap(RaceInvite.init(url:))
    }

    /// Whether this week is the one containing `now` in `calendar`: a friend's week from
    /// last week is stale, not "no runs yet".
    func isCurrent(now: Date, calendar baseCalendar: Calendar) -> Bool {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return false }
        return weekStart == Self.dayText(start, calendar: calendar)
    }

    // MARK: Days on a card

    /// How a day of a friend's week is drawn.
    enum DayState: Equatable, Sendable {
        /// Something was done: a run, strength, a walk.
        case done
        /// The plan asked for something, the day is over, and nothing was done.
        case missed
        /// The plan asks for something today or later.
        case planned
        /// Nothing planned, nothing done, and the day is over or today.
        case rest
        /// Nothing planned and the day hasn't come yet.
        case upcoming
    }

    /// The seven days' states, as seen on `today` (`YYYY-MM-DD` in the viewer's calendar).
    ///
    /// Days compare as text, which orders `YYYY-MM-DD` correctly. The viewer's today is a
    /// fair stand-in for the friend's: a friend a few time zones away is at most a day
    /// apart, and only for a few hours.
    func dayStates(today: String) -> [DayState] {
        days.map { day in
            if !day.done.isEmpty { return .done }
            if !day.planned.isEmpty { return day.date < today ? .missed : .planned }
            return day.date > today ? .upcoming : .rest
        }
    }

    /// `date` as ``Day/date`` spells it, in `calendar`'s time zone.
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        dayText(date, calendar: calendar)
    }

    // MARK: Wire

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Nil for anything that is not a week: a corrupt record shows as nothing rather than
    /// as a broken card. A week without seven days is refused too.
    static func decoded(from data: Data) -> FriendWeek? {
        guard let week = try? decoder.decode(FriendWeek.self, from: data), week.days.count == 7 else { return nil }
        return week
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Helpers

    /// One line, at most ``maxNameLength`` characters, "Runner" when nothing is left.
    static func tidiedName(_ raw: String) -> String {
        let line = RaceInvite.tidiedName(raw)
        let cut = String(line.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "Runner" : cut
    }

    private static func wholeMeters(_ meters: Double?) -> Int? {
        guard let meters, meters.isFinite, meters > 0 else { return nil }
        return Int(min(meters, 1_000_000).rounded())
    }

    private static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 7 * 86_400).rounded())
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
