import Foundation

// MARK: - TrainingBreakRequest

/// What the runner told the plan: why, what they want it to do, and when.
public struct TrainingBreakRequest: Equatable, Sendable {
    public let reason: TrainingBreak.Reason
    public let mode: TrainingBreak.Mode
    /// The break's first day.
    public let startDate: Date
    /// How many days it lasts, the first day included.
    public let days: Int

    public init(
        reason: TrainingBreak.Reason,
        mode: TrainingBreak.Mode,
        startDate: Date,
        days: Int
    ) {
        self.reason = reason
        self.mode = mode
        self.startDate = startDate
        self.days = days
    }
}

// MARK: - TrainingBreakPlanner

/// Decides exactly what a break does to the plan before anything is written. Pure: it
/// reads the same plain copy of the plan as ``PlanChangePlanner`` (built by
/// `PlanChangeApplier.snapshot(of:)`), so the rules are tested without SwiftData and the
/// sheet shows the runner every change before they confirm.
///
/// The rules:
///
/// - **On the break's days**, "pause" turns every run into a rest day, and strength and
///   cross-training too unless the runner is injured
///   (``TrainingBreakPolicy/pauseKeepsNonRunning(for:)``). "Ease off" turns every run
///   into a short easy one (``TrainingBreakPolicy/easeOffFactor(for:)``) and leaves the
///   rest alone.
/// - **After it**, the easing-back days (``TrainingBreakPolicy/ramp(after:reason:mode:)``)
///   shorten every run, and turn tempo and interval days easy for the first half (the
///   whole ramp after an injury). Long runs stay long runs, only shorter.
/// - **Never the race.** A break that covers race day is refused, and the easing-back
///   days stop the day before it: the taper is already lighter.
/// - **Never the past or a completed session.**
/// - **Ease off only on a pace-based plan.** A Start Running or pregnancy plan prescribes
///   by minutes and effort; it can pause, but it has no easy-distance version of a
///   session to write, and no ramp: Start Running has "Repeat this week" for that.
public enum TrainingBreakPlanner {

    public typealias Plan = PlanChangePlanner.Plan
    public typealias Session = PlanChangePlanner.Session

    /// One session the break changes.
    public struct Edit: Equatable, Sendable, Identifiable {
        public enum Stage: Equatable, Sendable {
            case onBreak
            case easingBack
        }

        public enum Outcome: Equatable, Sendable {
            case rest
            /// A run of this type and distance. Nil distance only for intervals kept as
            /// intervals, whose distance is in the reps.
            case run(WorkoutType, distanceMeters: Double?)
        }

        public let sessionID: UUID
        public let date: Date
        public let stage: Stage
        public let fromType: WorkoutType
        public let fromDistanceMeters: Double?
        public let outcome: Outcome

        public var id: UUID { sessionID }

        public init(
            sessionID: UUID,
            date: Date,
            stage: Stage,
            fromType: WorkoutType,
            fromDistanceMeters: Double?,
            outcome: Outcome
        ) {
            self.sessionID = sessionID
            self.date = date
            self.stage = stage
            self.fromType = fromType
            self.fromDistanceMeters = fromDistanceMeters
            self.outcome = outcome
        }
    }

    /// What the break would do, for the sheet to show and the applier to write.
    public struct Proposal: Equatable, Sendable {
        public let request: TrainingBreakRequest
        /// The break's first and last day, at the start of the day.
        public let startDate: Date
        public let endDate: Date
        public let ramp: TrainingBreakPolicy.Ramp?
        /// The last easing-back day the plan actually reaches: the ramp's last day,
        /// brought in to the day before the race or the plan's end.
        public let rampEndDate: Date?
        /// Soonest first.
        public let edits: [Edit]

        public var suggestsRebuild: Bool {
            request.mode == .pause && request.days >= TrainingBreakPolicy.rebuildSuggestedAfterDays
        }

        public init(
            request: TrainingBreakRequest,
            startDate: Date,
            endDate: Date,
            ramp: TrainingBreakPolicy.Ramp?,
            rampEndDate: Date?,
            edits: [Edit]
        ) {
            self.request = request
            self.startDate = startDate
            self.endDate = endDate
            self.ramp = ramp
            self.rampEndDate = rampEndDate
            self.edits = edits
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case noPlan
        case easeOffNeedsPacePlan
        case startInPast
        case startTooFarAhead
        case lengthOutOfRange
        case startsAfterPlanEnds
        case raceDuringBreak(Date)
        /// Nothing on the plan in those days to change.
        case nothingToChange
    }

    public static func propose(
        _ request: TrainingBreakRequest,
        in plan: Plan?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Result<Proposal, Refusal> {
        guard let plan else { return .failure(.noPlan) }
        if request.mode == .easeOff && plan.prescribesByTime { return .failure(.easeOffNeedsPacePlan) }
        guard (1...TrainingBreakPolicy.maximumDays).contains(request.days) else { return .failure(.lengthOutOfRange) }

        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: request.startDate)
        guard start >= today else { return .failure(.startInPast) }
        guard let latestStart = calendar.date(byAdding: .day, value: TrainingBreakPolicy.maximumDaysAhead, to: today),
              start <= latestStart else { return .failure(.startTooFarAhead) }
        guard start <= calendar.startOfDay(for: plan.endDate) else { return .failure(.startsAfterPlanEnds) }
        guard let end = calendar.date(byAdding: .day, value: request.days - 1, to: start) else {
            return .failure(.lengthOutOfRange)
        }

        let raceDay = plan.raceDate.map(calendar.startOfDay(for:))
        if let raceDay, raceDay >= start, raceDay <= end { return .failure(.raceDuringBreak(raceDay)) }
        if let race = plan.sessions.first(where: { session in
            let day = calendar.startOfDay(for: session.date)
            return session.type == .race && day >= start && day <= end
        }) {
            return .failure(.raceDuringBreak(calendar.startOfDay(for: race.date)))
        }

        let context = Context(plan: plan, today: today, calendar: calendar)
        var edits = context.breakEdits(request, from: start, through: end)

        let ramp = plan.prescribesByTime
            ? nil
            : TrainingBreakPolicy.ramp(after: request.days, reason: request.reason, mode: request.mode)
        var rampEnd: Date?
        if let ramp, let firstRampDay = calendar.date(byAdding: .day, value: 1, to: end) {
            let ramped = context.rampEdits(ramp, reason: request.reason, from: firstRampDay)
            edits += ramped.edits
            rampEnd = ramped.lastDay
        }

        guard !edits.isEmpty else { return .failure(.nothingToChange) }
        return .success(Proposal(
            request: request,
            startDate: start,
            endDate: end,
            ramp: ramp,
            rampEndDate: rampEnd,
            edits: edits.sorted { $0.date < $1.date }
        ))
    }

    /// The ramp for a runner who's back before the break they asked for was over: the
    /// easing-back days for the days they actually had off, starting today.
    ///
    /// `plan` is the plan with the break's remaining days already put back (the applier
    /// restores them first), so the ramp is worked out from the sessions as planned.
    /// - Returns: nil when the days they had were too few to need a ramp, or the ramp
    ///   finds nothing to change.
    public static func rampForEarlyReturn(
        reason: TrainingBreak.Reason,
        mode: TrainingBreak.Mode,
        breakStart: Date,
        in plan: Plan,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (ramp: TrainingBreakPolicy.Ramp, edits: [Edit], lastDay: Date?)? {
        guard !plan.prescribesByTime else { return nil }
        let today = calendar.startOfDay(for: now)
        // Days off are the days before today: today is the first day back.
        let daysOff = TrainingBreakPolicy.days(from: breakStart, through: today, calendar: calendar) - 1
        guard daysOff > 0,
              let ramp = TrainingBreakPolicy.ramp(after: daysOff, reason: reason, mode: mode) else { return nil }
        let context = Context(plan: plan, today: today, calendar: calendar)
        let ramped = context.rampEdits(ramp, reason: reason, from: today)
        guard !ramped.edits.isEmpty else { return nil }
        return (ramp, ramped.edits, ramped.lastDay)
    }
}

// MARK: - Rules

private extension TrainingBreakPlanner {

    struct Context {
        let plan: Plan
        let today: Date
        let calendar: Calendar

        var raceDay: Date? {
            let fromSessions = plan.sessions.filter { $0.type == .race }.map { calendar.startOfDay(for: $0.date) }.min()
            return [plan.raceDate.map(calendar.startOfDay(for:)), fromSessions].compactMap { $0 }.min()
        }

        /// Sessions the break may change between two days, both included: not done, not
        /// the race, not in the past.
        func changeable(from first: Date, through last: Date) -> [Session] {
            plan.sessions.filter { session in
                let day = calendar.startOfDay(for: session.date)
                return day >= first && day <= last && day >= today
                    && !session.isCompleted && session.type != .race
            }
        }

        // MARK: Break days

        func breakEdits(_ request: TrainingBreakRequest, from start: Date, through end: Date) -> [Edit] {
            changeable(from: start, through: end).compactMap { session in
                let outcome: Edit.Outcome?
                switch request.mode {
                case .pause:
                    if session.type == .rest {
                        outcome = nil
                    } else if session.type.isRunType {
                        outcome = .rest
                    } else {
                        outcome = TrainingBreakPolicy.pauseKeepsNonRunning(for: request.reason) ? nil : .rest
                    }
                case .easeOff:
                    if session.type.isRunType {
                        let factor = TrainingBreakPolicy.easeOffFactor(for: request.reason)
                        outcome = .run(.easy, distanceMeters: scaled(baseDistance(of: session), by: factor))
                    } else {
                        outcome = nil
                    }
                }
                guard let outcome else { return nil }
                return Edit(
                    sessionID: session.id,
                    date: session.date,
                    stage: .onBreak,
                    fromType: session.type,
                    fromDistanceMeters: session.targetDistanceMeters,
                    outcome: outcome
                )
            }
        }

        // MARK: Easing back

        /// The ramp's edits from `firstDay`, and the last day it reaches: the ramp's own
        /// last day, the day before the race, or the plan's last day, whichever is first.
        func rampEdits(_ ramp: TrainingBreakPolicy.Ramp, reason: TrainingBreak.Reason, from firstDay: Date) -> (edits: [Edit], lastDay: Date?) {
            guard var last = calendar.date(byAdding: .day, value: ramp.days - 1, to: firstDay) else { return ([], nil) }
            if let raceDay, let dayBefore = calendar.date(byAdding: .day, value: -1, to: raceDay) {
                last = min(last, dayBefore)
            }
            last = min(last, calendar.startOfDay(for: plan.endDate))
            guard last >= firstDay else { return ([], nil) }

            let edits: [Edit] = changeable(from: firstDay, through: last).compactMap { session in
                guard session.type.isRunType else { return nil }
                let dayIndex = (calendar.dateComponents([.day], from: firstDay, to: calendar.startOfDay(for: session.date)).day ?? 0)
                let firstHalf = dayIndex < ramp.firstHalfDays
                let factor = firstHalf ? ramp.firstHalfFactor : ramp.secondHalfFactor
                let easyOnly = firstHalf || ramp.easyOnlyThroughout

                let outcome: Edit.Outcome
                if session.type.isQualitySession && easyOnly {
                    outcome = .run(.easy, distanceMeters: scaled(baseDistance(of: session), by: factor))
                } else if session.type == .interval {
                    // Kept as intervals in the second half: the reps are the session, and
                    // the plan's own rep count is what they come back to.
                    return nil
                } else {
                    guard let distance = session.targetDistanceMeters, distance > 0 else { return nil }
                    outcome = .run(session.type, distanceMeters: scaled(distance, by: factor))
                }
                return Edit(
                    sessionID: session.id,
                    date: session.date,
                    stage: .easingBack,
                    fromType: session.type,
                    fromDistanceMeters: session.targetDistanceMeters,
                    outcome: outcome
                )
            }
            return (edits, last)
        }

        // MARK: Distance

        /// The distance a run is scaled from: its own, or for intervals (which carry it
        /// in the reps) the plan's usual easy run.
        func baseDistance(of session: Session) -> Double {
            if let distance = session.targetDistanceMeters, distance > 0, session.type != .interval {
                return distance
            }
            return usualEasyDistance ?? TrainingBreakPolicy.fallbackEasyMeters
        }

        /// The median planned easy run from today on.
        var usualEasyDistance: Double? {
            let distances = plan.sessions
                .filter { $0.type == .easy && calendar.startOfDay(for: $0.date) >= today }
                .compactMap(\.targetDistanceMeters)
                .filter { $0 > 0 }
                .sorted()
            guard !distances.isEmpty else { return nil }
            let mid = distances.count / 2
            return distances.count.isMultiple(of: 2) ? (distances[mid - 1] + distances[mid]) / 2 : distances[mid]
        }

        /// `distance` times `factor`, rounded, never under the shortest run the break
        /// writes and never longer than the run it came from.
        func scaled(_ distance: Double, by factor: Double) -> Double {
            min(max(TrainingBreakPolicy.rounded(distance * factor), TrainingBreakPolicy.minimumRunMeters), distance)
        }
    }
}
