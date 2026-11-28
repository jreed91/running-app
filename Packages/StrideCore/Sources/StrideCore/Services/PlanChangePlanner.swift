import Foundation

// MARK: - PlanChangeRequest

/// One change to the plan, as a runner asks the coach for it in the chat: "add an
/// interval run this week", "make Thursday a tempo", "I need Friday off".
///
/// Only the *shape* of the change comes from the model: what to do, which day and which
/// kind of run. Every number in the session that ends up in the plan (paces, reps,
/// warm-up, distance when none was asked for) is the app's own, built by
/// ``PlanChangeApplier`` with the same rules the plan was generated with. The model is
/// good at reading "something for my cardio midweek"; it is not the thing that should
/// decide how fast an interval is.
public struct PlanChangeRequest: Equatable, Sendable {

    public enum Action: String, Equatable, Sendable {
        /// Put a new run on a day that has none.
        case add
        /// Turn the run already on a day into a different kind of run.
        case changeType
        /// Take the run off a day, leaving it a rest day.
        case makeRest
    }

    public enum Day: Equatable, Sendable {
        /// Let the planner choose. For ``Action/add`` that is the free day in the next week
        /// furthest from the other runs; for the other actions, the soonest session it may
        /// change.
        case best
        case today
        case tomorrow
        /// A day of the week, as `Calendar` numbers them (1 = Sunday … 7 = Saturday): the
        /// next one from today, today included.
        case weekday(Int)
    }

    public let action: Action
    public let day: Day
    /// The kind of run to add or change to. Ignored by ``Action/makeRest``.
    public let type: WorkoutType?
    /// A distance the runner asked for. Optional: without one the planner picks a
    /// distance from the plan itself.
    public let distanceMeters: Double?

    public init(action: Action, day: Day, type: WorkoutType? = nil, distanceMeters: Double? = nil) {
        self.action = action
        self.day = day
        self.type = type
        self.distanceMeters = distanceMeters
    }
}

// MARK: - PlanChangePlanner

/// Decides whether a ``PlanChangeRequest`` can go into the plan, and exactly what it would
/// change, before anything is written. Pure: it reads plain copies of the plan's sessions,
/// so its rules are tested without SwiftData, and the chat can show the runner the change
/// it would make and only write it when they confirm.
///
/// The rules, all of them the plan's own:
///
/// - **Only a pace-based plan.** A Start Running or pregnancy plan prescribes by time and
///   effort; it is not the coach's to rewrite, the same rule as `AdaptableWorkoutSelector`.
/// - **Only the week ahead.** A change lands from today to six days on, inside the plan
///   and before race day. Further out than that, the plan is still going to move.
/// - **One run a day.** Adding to a day that already holds a run is refused, so the coach
///   can offer to change that run instead. A rest day or a strength day is free.
/// - **No hard day next to a hard day.** A tempo, intervals or a long run never lands the
///   day before or after another of those or the race, and no hard session lands in the
///   two days before the race. That is the same spacing the plan generator keeps.
/// - **Never the race, never the past.** A completed session, the race, or a day already
///   gone cannot be changed.
/// - **No added run longer than the week's long run.** A runner asking for "an extra
///   easy run" should not get one longer than the run the week is built around.
/// - **A distance on its own is a change.** "Make Saturday's long run 8 miles" is a
///   ``PlanChangeRequest/Action/changeType`` to the same type with a distance.
public enum PlanChangePlanner {

    /// A planned session as the planner reads it.
    public struct Session: Equatable, Sendable {
        public let id: UUID
        public let date: Date
        public let type: WorkoutType
        public let isCompleted: Bool
        public let targetDistanceMeters: Double?

        public init(id: UUID = UUID(), date: Date, type: WorkoutType, isCompleted: Bool = false, targetDistanceMeters: Double? = nil) {
            self.id = id
            self.date = date
            self.type = type
            self.isCompleted = isCompleted
            self.targetDistanceMeters = targetDistanceMeters
        }
    }

    /// The plan as the planner reads it.
    public struct Plan: Equatable, Sendable {
        public let sessions: [Session]
        public let startDate: Date
        /// The plan's last day.
        public let endDate: Date
        public let raceDate: Date?
        public let prescribesByTime: Bool
        /// The days of a live training break, its easing-back days included: no run is
        /// added there and no run made harder (``Refusal/duringTrainingBreak(_:)``).
        public let breakDays: ClosedRange<Date>?

        public init(
            sessions: [Session],
            startDate: Date,
            endDate: Date,
            raceDate: Date? = nil,
            prescribesByTime: Bool = false,
            breakDays: ClosedRange<Date>? = nil
        ) {
            self.sessions = sessions
            self.startDate = startDate
            self.endDate = endDate
            self.raceDate = raceDate
            self.prescribesByTime = prescribesByTime
            self.breakDays = breakDays
        }
    }

    /// The change the planner would make.
    public enum Change: Equatable, Sendable {
        /// A new run. `replacingRestID` is a stored rest day on that date, which becomes
        /// the run rather than sitting beside it.
        case add(date: Date, type: WorkoutType, distanceMeters: Double?, replacingRestID: UUID?)
        case changeType(sessionID: UUID, date: Date, from: WorkoutType, to: WorkoutType, distanceMeters: Double?)
        case makeRest(sessionID: UUID, date: Date, type: WorkoutType)

        public var date: Date {
            switch self {
            case .add(let date, _, _, _), .changeType(_, let date, _, _, _), .makeRest(_, let date, _):
                return date
            }
        }
    }

    /// Why a request can't go into the plan.
    public enum Refusal: Error, Equatable, Sendable {
        case noPlan
        case planPrescribesByTime
        /// Add or change without a run type, or with one the coach can't plan (race,
        /// strength, cross-training, rest).
        case unsupportedType
        case dayOutsideWindow(Date)
        case dayHasRun(Date, WorkoutType)
        case noSessionOnDay(Date)
        case sessionLocked(Date, WorkoutType)
        case sameType(Date, WorkoutType)
        case nextToHardDay(Date, neighbour: WorkoutType, neighbourDate: Date)
        case tooCloseToRace(Date)
        case noFreeDay(WorkoutType)
        case nothingToChange
        /// The runner told the plan they're ill, injured or away, or is easing back in
        /// after it: nothing is added, and nothing made harder, on those days.
        case duringTrainingBreak(Date)
    }

    /// How many days a change may reach, today included.
    public static let windowDays = 7

    /// The run types the coach may add or change a session to.
    public static let plannableTypes: Set<WorkoutType> = [.easy, .tempo, .interval, .longRun]

    /// The shortest run the planner will add.
    public static let minimumDistanceMeters: Double = 1_500
    /// The cap on a run when the week has no long run to measure against.
    public static let maximumDistanceMeters: Double = 32_000

    public static func plan(
        _ request: PlanChangeRequest,
        in plan: Plan?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Result<Change, Refusal> {
        guard let plan else { return .failure(.noPlan) }
        guard !plan.prescribesByTime else { return .failure(.planPrescribesByTime) }
        let context = Context(plan: plan, today: calendar.startOfDay(for: now), calendar: calendar)

        let result: Result<Change, Refusal>
        switch request.action {
        case .add:
            guard let type = request.type, plannableTypes.contains(type) else { return .failure(.unsupportedType) }
            result = context.add(type: type, on: request.day, distance: request.distanceMeters)
        case .changeType:
            guard let type = request.type, plannableTypes.contains(type) else { return .failure(.unsupportedType) }
            result = context.change(on: request.day, to: type, distance: request.distanceMeters)
        case .makeRest:
            return context.rest(on: request.day)
        }
        // A break is the runner's own call about their body: the coach can rest a day or
        // keep a run easy, never add running or make it harder.
        if case .success(let change) = result, let breakDays = plan.breakDays {
            let day = calendar.startOfDay(for: change.date)
            let inBreak = day >= calendar.startOfDay(for: breakDays.lowerBound)
                && day <= calendar.startOfDay(for: breakDays.upperBound)
            if inBreak {
                switch change {
                case .add:
                    return .failure(.duringTrainingBreak(day))
                case let .changeType(_, _, from, to, _):
                    // Easy is fine, but not a longer easy run than the break left.
                    if to != .easy || from == .easy { return .failure(.duringTrainingBreak(day)) }
                case .makeRest:
                    break
                }
            }
        }
        return result
    }

    /// Whether a type is a hard day for spacing: quality, the long run, the race.
    public static func isHard(_ type: WorkoutType) -> Bool {
        type.isQualitySession || type == .longRun
    }
}

// MARK: - Rules

private extension PlanChangePlanner {

    struct Context {
        let plan: Plan
        let today: Date
        let calendar: Calendar

        var raceDay: Date? { plan.raceDate.map(calendar.startOfDay(for:)) }

        // MARK: Days

        /// The days a change may land on: today through six days on, inside the plan and
        /// before race day.
        var window: [Date] {
            let first = max(today, calendar.startOfDay(for: plan.startDate))
            let planEnd = calendar.startOfDay(for: plan.endDate)
            return (0..<PlanChangePlanner.windowDays).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
                guard day >= first, day <= planEnd else { return nil }
                if let raceDay, day >= raceDay { return nil }
                return day
            }
        }

        func resolve(_ day: PlanChangeRequest.Day) -> Date? {
            switch day {
            case .best:
                return nil
            case .today:
                return today
            case .tomorrow:
                return calendar.date(byAdding: .day, value: 1, to: today)
            case .weekday(let weekday):
                return (0..<7).lazy
                    .compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
                    .first { calendar.component(.weekday, from: $0) == weekday }
            }
        }

        func sessions(on day: Date) -> [Session] {
            plan.sessions.filter { calendar.isDate($0.date, inSameDayAs: day) }
        }

        func runs(on day: Date) -> [Session] {
            sessions(on: day).filter { $0.type.isRunType }
        }

        // MARK: Spacing

        /// The first reason a hard session can't go on `day`, if any. `ignoring` is the
        /// session being changed, which is not its own neighbour.
        func spacingRefusal(on day: Date, ignoring: UUID? = nil) -> Refusal? {
            if let raceDay,
               let daysToRace = calendar.dateComponents([.day], from: day, to: raceDay).day,
               (0...2).contains(daysToRace) {
                return .tooCloseToRace(day)
            }
            for offset in [-1, 1] {
                guard let neighbourDay = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
                if let hard = runs(on: neighbourDay).first(where: { $0.id != ignoring && PlanChangePlanner.isHard($0.type) }) {
                    return .nextToHardDay(day, neighbour: hard.type, neighbourDate: hard.date)
                }
            }
            return nil
        }

        // MARK: Add

        func add(type: WorkoutType, on requested: PlanChangeRequest.Day, distance: Double?) -> Result<Change, Refusal> {
            let day: Date
            if let resolved = resolve(requested) {
                guard window.contains(resolved) else { return .failure(.dayOutsideWindow(resolved)) }
                if let run = runs(on: resolved).first { return .failure(.dayHasRun(resolved, run.type)) }
                if PlanChangePlanner.isHard(type), let refusal = spacingRefusal(on: resolved) {
                    return .failure(refusal)
                }
                day = resolved
            } else {
                guard let best = bestFreeDay(for: type) else { return .failure(.noFreeDay(type)) }
                day = best
            }
            let rest = sessions(on: day).first { $0.type == .rest && !$0.isCompleted }
            return .success(.add(
                date: day,
                type: type,
                distanceMeters: distanceFor(type, on: day, asked: distance, current: nil),
                replacingRestID: rest?.id
            ))
        }

        /// The free day furthest from the week's other runs, earliest on a tie, and a day
        /// without a strength session over one with. Never today: "add a run" asked during
        /// the day is not a run the runner can still fit in before they read the plan.
        func bestFreeDay(for type: WorkoutType) -> Date? {
            let candidates = window.filter { day in
                day > today
                    && runs(on: day).isEmpty
                    && (!PlanChangePlanner.isHard(type) || spacingRefusal(on: day) == nil)
            }
            let runDays = plan.sessions.filter { $0.type.isRunType }.map { calendar.startOfDay(for: $0.date) }

            func gap(_ day: Date) -> Int {
                runDays.compactMap { calendar.dateComponents([.day], from: day, to: $0).day.map(abs) }.min() ?? 7
            }
            func hasStrength(_ day: Date) -> Bool {
                sessions(on: day).contains { $0.type == .strength }
            }

            return candidates.max { lhs, rhs in
                let left = (gap(lhs), hasStrength(lhs) ? 0 : 1)
                let right = (gap(rhs), hasStrength(rhs) ? 0 : 1)
                if left != right { return left < right }
                // `max` keeps the later of equals; flip so the earlier day wins.
                return lhs > rhs
            }
        }

        // MARK: Change and rest

        /// The session a change or rest request is about: the run on the named day, or the
        /// soonest one it may change when no day was named.
        func target(on requested: PlanChangeRequest.Day) -> Result<Session, Refusal> {
            if let day = resolve(requested) {
                let dayRuns = runs(on: day)
                // Race day sits outside the window on purpose; say it is the race rather
                // than that it is too far away.
                if let race = dayRuns.first(where: { $0.type == .race }) {
                    return .failure(.sessionLocked(day, race.type))
                }
                guard window.contains(day) else { return .failure(.dayOutsideWindow(day)) }
                guard !dayRuns.isEmpty else { return .failure(.noSessionOnDay(day)) }
                guard let open = dayRuns.first(where: { !$0.isCompleted }) else {
                    return .failure(.sessionLocked(day, dayRuns[0].type))
                }
                return .success(open)
            }
            let soonest = window
                .flatMap(runs(on:))
                .filter { !$0.isCompleted && $0.type != .race }
                .min { $0.date < $1.date }
            guard let soonest else { return .failure(.nothingToChange) }
            return .success(soonest)
        }

        func change(on requested: PlanChangeRequest.Day, to type: WorkoutType, distance: Double?) -> Result<Change, Refusal> {
            let session: Session
            switch target(on: requested) {
            case .success(let found): session = found
            case .failure(let refusal): return .failure(refusal)
            }
            let day = calendar.startOfDay(for: session.date)
            guard session.type != type || distance != nil else { return .failure(.sameType(day, type)) }
            if PlanChangePlanner.isHard(type), let refusal = spacingRefusal(on: day, ignoring: session.id) {
                return .failure(refusal)
            }
            return .success(.changeType(
                sessionID: session.id,
                date: session.date,
                from: session.type,
                to: type,
                distanceMeters: distanceFor(type, on: day, asked: distance, current: session)
            ))
        }

        func rest(on requested: PlanChangeRequest.Day) -> Result<Change, Refusal> {
            switch target(on: requested) {
            case .success(let session):
                return .success(.makeRest(sessionID: session.id, date: session.date, type: session.type))
            case .failure(let refusal):
                return .failure(refusal)
            }
        }

        // MARK: Distance

        /// The distance a new or changed run gets. Intervals carry their distance in the
        /// reps, so none. Otherwise the runner's ask, or the session's own distance when
        /// the type is unchanged, or the plan's usual for that type; clamped so it is
        /// never longer than the week's long run.
        func distanceFor(_ type: WorkoutType, on day: Date, asked: Double?, current: Session?) -> Double? {
            guard type != .interval else { return nil }
            let base = asked
                ?? (current?.type == type ? current?.targetDistanceMeters : nil)
                ?? usualDistance(for: type)
                ?? defaultDistance(for: type)
            return min(max(base, PlanChangePlanner.minimumDistanceMeters), cap(for: type, on: day, ignoring: current?.id))
        }

        /// The median planned distance of this type from today on.
        func usualDistance(for type: WorkoutType) -> Double? {
            let distances = plan.sessions
                .filter { $0.type == type && calendar.startOfDay(for: $0.date) >= today }
                .compactMap(\.targetDistanceMeters)
                .filter { $0 > 0 }
                .sorted()
            guard !distances.isEmpty else { return nil }
            let mid = distances.count / 2
            return distances.count.isMultiple(of: 2) ? (distances[mid - 1] + distances[mid]) / 2 : distances[mid]
        }

        func defaultDistance(for type: WorkoutType) -> Double {
            switch type {
            case .longRun: return 12_000
            case .tempo: return 6_000
            default: return 5_000
            }
        }

        /// No run longer than the longest planned run within three days either side, or
        /// the global cap when there is none. A long run is the week's longest by
        /// definition, so it only meets the global cap: "make Saturday's long run 8 miles"
        /// is how a runner fixes a long run that grew too fast.
        func cap(for type: WorkoutType, on day: Date, ignoring: UUID?) -> Double {
            guard type != .longRun else { return PlanChangePlanner.maximumDistanceMeters }
            let nearby = plan.sessions.filter { session in
                guard session.id != ignoring, session.type.isRunType, session.type != .race else { return false }
                guard let gap = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: session.date)).day else { return false }
                return abs(gap) <= 3
            }
            let longest = nearby.compactMap(\.targetDistanceMeters).max()
            return max(longest ?? PlanChangePlanner.maximumDistanceMeters, PlanChangePlanner.minimumDistanceMeters)
        }
    }
}
