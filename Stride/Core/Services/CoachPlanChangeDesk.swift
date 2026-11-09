import Foundation
import Synchronization

// MARK: - CoachPlanChangeDesk

/// Where the coach chat's `proposePlanChange` tool leaves the change it proposed, for the
/// chat to show the runner as a card they confirm.
///
/// The tool never writes to the plan. It runs ``PlanChangePlanner`` on a plain copy of
/// the plan taken before the request, keeps the change it would make, and answers the
/// model in words: either "proposed, the runner will confirm it" or why it can't be done,
/// so the reply explains a refusal instead of promising a change that never happens.
/// Writing happens on the runner's tap, through ``PlanChangeApplier``.
///
/// A class so the tool and the chat share one; `Sendable` through its mutex, as Apple's
/// `Tool` requires. Nothing here imports `FoundationModels`, so it is tested on its own.
final class CoachPlanChangeDesk: Sendable {

    private let plan: PlanChangePlanner.Plan?
    private let unit: UnitPreference
    private let now: Date
    private let proposal = Mutex<PlanChangePlanner.Change?>(nil)

    init(plan: PlanChangePlanner.Plan?, unit: UnitPreference, now: Date = Date()) {
        self.plan = plan
        self.unit = unit
        self.now = now
    }

    /// Plans `request` and keeps the change when it can be made. The newest proposal of
    /// a reply wins: one reply proposes one change.
    ///
    /// - Returns: what the tool tells the model.
    func propose(_ request: PlanChangeRequest) -> String {
        switch PlanChangePlanner.plan(request, in: plan, now: now) {
        case .success(let change):
            proposal.withLock { $0 = change }
            return Self.proposedAnswer(for: change, unit: unit)
        case .failure(let refusal):
            return Self.refusalAnswer(for: refusal)
        }
    }

    /// The change proposed during this reply, if any. Cleared once read, so a later reply
    /// that proposes nothing shows no card.
    func takeProposal() -> PlanChangePlanner.Change? {
        proposal.withLock { current in
            defer { current = nil }
            return current
        }
    }

    // MARK: Answers to the model

    /// English, like every coach prompt.
    static func proposedAnswer(for change: PlanChangePlanner.Change, unit: UnitPreference) -> String {
        let what: String
        switch change {
        case let .add(date, type, distance, _):
            what = "add \(withArticle(type))\(distancePhrase(distance, type: type, unit: unit)) on \(CoachLookup.dayLabel(date))"
        case let .changeType(_, date, from, to, distance) where from == to:
            what = "make the \(spoken(from)) on \(CoachLookup.dayLabel(date))\(distancePhrase(distance, type: to, unit: unit))"
        case let .changeType(_, date, from, to, distance):
            what = "change the \(spoken(from)) on \(CoachLookup.dayLabel(date)) into \(withArticle(to))\(distancePhrase(distance, type: to, unit: unit))"
        case let .makeRest(_, date, type):
            what = "make \(CoachLookup.dayLabel(date)) a rest day instead of the \(spoken(type))"
        }
        return """
        Proposed: \(what). The app sets the paces and reps from the runner's plan. \
        Nothing has changed yet: the runner sees a card under your reply and confirms it \
        there. Say what you proposed and why in a sentence or two, and that they can \
        confirm it below. Never say the plan is already updated.
        """
    }

    static func refusalAnswer(for refusal: PlanChangePlanner.Refusal) -> String {
        let reason: String
        switch refusal {
        case .noPlan:
            reason = "The runner has no active training plan. Suggest they set one up on the Plan tab."
        case .planPrescribesByTime:
            reason = "This plan is a time-based programme the coach cannot change. Explain that its steps are built in on purpose and suggest following it as written."
        case .unsupportedType:
            reason = "Only an easy run, a tempo run, intervals or a long run can be planned."
        case .dayOutsideWindow(let day):
            reason = "\(CoachLookup.dayLabel(day)) is outside the coming week of the plan, or after race day. Only today and the next six days can change."
        case let .dayHasRun(day, type):
            reason = "\(CoachLookup.dayLabel(day)) already has \(withArticle(type)). Offer to change that run instead, or pick a free day."
        case .noSessionOnDay(let day):
            reason = "\(CoachLookup.dayLabel(day)) has no planned run to change."
        case let .sessionLocked(day, type):
            reason = "The \(spoken(type)) on \(CoachLookup.dayLabel(day)) is the race or already done, so it can't change."
        case let .sameType(day, type):
            reason = "\(CoachLookup.dayLabel(day)) is already \(withArticle(type))."
        case let .nextToHardDay(day, neighbour, neighbourDay):
            reason = "A hard session on \(CoachLookup.dayLabel(day)) would sit right next to the \(spoken(neighbour)) on \(CoachLookup.dayLabel(neighbourDay)). Suggest an easy run there, or a day further away."
        case .tooCloseToRace(let day):
            reason = "\(CoachLookup.dayLabel(day)) is within two days of the race, where only easy running fits."
        case .noFreeDay(let type):
            reason = "No free day in the coming week fits \(withArticle(type)) without sitting next to another hard day. Suggest changing an easy run into it instead."
        case .nothingToChange:
            reason = "There is no upcoming run in the coming week to change."
        }
        return "Not proposed. \(reason) Nothing changed, so don't say it did."
    }

    /// "easy run", "interval session": what the model reads, never the bare type name
    /// ("an easy").
    static func spoken(_ type: WorkoutType) -> String {
        switch type {
        case .easy: return "easy run"
        case .tempo: return "tempo run"
        case .interval: return "interval session"
        default: return type.displayName.lowercased()
        }
    }

    private static func withArticle(_ type: WorkoutType) -> String {
        let name = spoken(type)
        let article = name.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "\(article) \(name)"
    }

    private static func distancePhrase(_ distance: Double?, type: WorkoutType, unit: UnitPreference) -> String {
        guard let distance, type != .interval else { return "" }
        return " of \(distance.distanceString(unit: unit))"
    }
}

extension CoachPlanChangeDesk: Equatable {
    /// One desk per chat request, so identity is the only sameness there is. Lets
    /// `CoachLookup`, which carries it, stay `Equatable`.
    static func == (lhs: CoachPlanChangeDesk, rhs: CoachPlanChangeDesk) -> Bool {
        lhs === rhs
    }
}
