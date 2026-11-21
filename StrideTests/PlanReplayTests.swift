import Testing
import Foundation
@testable import Stride

// MARK: - Plan Replay tests
//
// Which cards a finished plan gets, and what they say.

struct PlanReplayTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func replay(
        runCount: Int = 48,
        sessionsDone: Int = 52,
        sessionsPlanned: Int = 56,
        strength: Int = 10,
        race: PlanReplay.RaceResult? = nil,
        fitness: YearInRunning.FitnessChange? = nil
    ) -> PlanReplay {
        PlanReplay(
            title: "Half Marathon",
            weeks: 16,
            sessionsPlanned: sessionsPlanned,
            sessionsDone: sessionsDone,
            runCount: runCount,
            runMeters: 642_000,
            runSeconds: 230_000,
            strengthSessions: strength,
            longestRun: PlanReplay.LongestRun(
                date: Date(timeIntervalSince1970: 1_790_000_000),
                meters: 19_000,
                seconds: 6_300
            ),
            race: race,
            fitnessChange: fitness
        )
    }

    @Test("Too few runs makes no cards")
    func tooFewRuns() {
        #expect(PlanReplayCards.make(from: replay(runCount: 2), unit: .metric, calendar: calendar).isEmpty)
    }

    @Test("A plan without a race or a fitness rise gets cover, distance, sessions, longest run, outro")
    func baseCards() {
        let kinds = PlanReplayCards.make(from: replay(), unit: .metric, calendar: calendar).map(\.kind)
        #expect(kinds == [.cover, .distance, .consistency, .longestRun, .outro])
    }

    @Test("A race result comes straight after the cover")
    func raceCard() throws {
        let race = PlanReplay.RaceResult(date: Date(timeIntervalSince1970: 1_791_000_000), meters: 21_097.5, seconds: 6_734)
        let cards = PlanReplayCards.make(from: replay(race: race), unit: .metric, calendar: calendar)
        #expect(cards.map(\.kind).prefix(2) == [.cover, .race])
        let card = try #require(cards.first { $0.kind == .race })
        #expect(card.headline == 6_734.0.durationString)
    }

    @Test("Fitness appears only when it rose at least 1%")
    func fitnessCard() {
        let up = YearInRunning.FitnessChange(startVDOT: 40, endVDOT: 42)
        let flat = YearInRunning.FitnessChange(startVDOT: 40, endVDOT: 40.2)
        #expect(PlanReplayCards.make(from: replay(fitness: up), unit: .metric, calendar: calendar)
            .contains { $0.kind == .fitness && $0.headline == "+5%" })
        #expect(!PlanReplayCards.make(from: replay(fitness: flat), unit: .metric, calendar: calendar)
            .contains { $0.kind == .fitness })
    }

    @Test("Sessions card reads done of planned, and lists strength only when there was some")
    func sessionsCard() throws {
        let cards = PlanReplayCards.make(from: replay(), unit: .metric, calendar: calendar)
        let card = try #require(cards.first { $0.kind == .consistency })
        #expect(card.headline == "52 of 56")
        #expect(card.stats.map(\.label) == ["Weeks", "Strength"])

        let noStrength = PlanReplayCards.make(from: replay(strength: 0), unit: .metric, calendar: calendar)
        #expect(noStrength.first { $0.kind == .consistency }?.stats.map(\.label) == ["Weeks"])
    }

    @Test("The consistency line is kind at every level")
    func consistencyLines() {
        #expect(PlanReplayCards.consistencyLine(done: 56, planned: 56) == "Sessions done. Every single one.")
        #expect(PlanReplayCards.consistencyLine(done: 50, planned: 56) == "Sessions done. Nearly all of them.")
        #expect(PlanReplayCards.consistencyLine(done: 20, planned: 56) == "Sessions done, around everything else.")
    }

    @Test("The cover names the weeks and the plan; the outro names the site")
    func coverAndOutro() {
        let cards = PlanReplayCards.make(from: replay(), unit: .metric, calendar: calendar)
        #expect(cards.first?.headline == "16 weeks")
        #expect(cards.first?.caption == "My Half Marathon plan, start to finish")
        #expect(cards.last?.caption.contains(StrideLinks.landingPageDisplay) == true)
    }

    @Test("Replay opens once the plan's last day has passed, never for a pregnancy plan")
    func availability() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PlanReplay.isAvailable(endDate: now.addingTimeInterval(-1), isPregnancyPlan: false, now: now))
        #expect(!PlanReplay.isAvailable(endDate: now.addingTimeInterval(86_400), isPregnancyPlan: false, now: now))
        #expect(!PlanReplay.isAvailable(endDate: now.addingTimeInterval(-1), isPregnancyPlan: true, now: now))
    }
}
