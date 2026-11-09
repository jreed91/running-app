import Foundation
import Testing
@testable import Stride

/// The coach chat's plan-change tool hands its proposals to `CoachPlanChangeDesk`, which
/// keeps them for the confirm card and tells the model in words what happened.
struct CoachPlanChangeDeskTests {

    private let calendar = Calendar.current
    private let monday = Calendar.current.date(
        from: DateComponents(year: 2027, month: 3, day: 15, hour: 9)
    ) ?? .now

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: monday) ?? monday)
    }

    private var plan: PlanChangePlanner.Plan {
        PlanChangePlanner.Plan(
            sessions: [.init(date: day(5), type: .longRun, targetDistanceMeters: 13_000)],
            startDate: day(-7),
            endDate: day(60)
        )
    }

    @Test("A proposal is kept for the card, read once, and the model is told nothing changed yet")
    func proposalKeptOnce() {
        let desk = CoachPlanChangeDesk(plan: plan, unit: .imperial, now: monday)
        let answer = desk.propose(PlanChangeRequest(action: .add, day: .best, type: .interval))

        #expect(answer.hasPrefix("Proposed: add an interval session on"))
        #expect(answer.contains("Nothing has changed yet"))
        let proposal = desk.takeProposal()
        #expect(proposal == .add(date: day(1), type: .interval, distanceMeters: nil, replacingRestID: nil))
        #expect(desk.takeProposal() == nil)
    }

    @Test("A refusal keeps nothing and says why")
    func refusalKeepsNothing() {
        let desk = CoachPlanChangeDesk(plan: plan, unit: .metric, now: monday)
        let saturday = calendar.component(.weekday, from: day(5))
        let answer = desk.propose(PlanChangeRequest(action: .add, day: .weekday(saturday), type: .easy))

        #expect(answer.hasPrefix("Not proposed."))
        #expect(answer.contains("already has a long run"))
        #expect(desk.takeProposal() == nil)
    }

    @Test("The plan-change instructions come only with a desk")
    func instructionsOnlyWithDesk() {
        var lookup = CoachLookup(runs: [], sessions: [], unit: .metric, now: monday)
        #expect(!CoachLookup.instructions("Base.", withToolsFor: lookup, today: monday).contains("proposePlanChange"))

        lookup.planChanges = CoachPlanChangeDesk(plan: plan, unit: .metric, now: monday)
        let withDesk = CoachLookup.instructions("Base.", withToolsFor: lookup, today: monday)
        #expect(withDesk.contains("proposePlanChange"))
        #expect(withDesk.hasSuffix("The tools count days back from today."))
    }
}
