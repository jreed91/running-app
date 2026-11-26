import Foundation
import Testing
@testable import Stride

/// Covers `FriendWeek`, the week a runner shares with a training group. It is read on a
/// friend's phone, maybe in another time zone and on another app version, so what goes
/// in, what stays out, and how it reads back are what matter.
struct FriendWeekTests {

    private func calendar(_ zone: String = "Europe/London") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ day: Int, hour: Int = 9, month: Int = 11, in zone: String = "Europe/London") -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// Thursday 26 November 2026; the week runs Monday 23 to Sunday 29.
    private var now: Date { date(26, hour: 18) }

    private func run(_ day: Int, _ type: WorkoutType = .easy, km: Double = 5, minutes: Double = 30,
                     hour: Int = 7, id: UUID = UUID()) -> FriendWeek.FinishedWorkout {
        FriendWeek.FinishedWorkout(id: id, date: date(day, hour: hour), type: type,
                                   meters: km * 1000, seconds: minutes * 60)
    }

    private func session(_ day: Int, _ type: WorkoutType = .easy, km: Double? = 5) -> FriendWeek.PlannedSession {
        FriendWeek.PlannedSession(date: date(day), type: type, targetMeters: km.map { $0 * 1000 })
    }

    private func make(
        name: String = "Sam",
        planned: [FriendWeek.PlannedSession] = [],
        done: [FriendWeek.FinishedWorkout] = [],
        race: RaceInvite? = nil,
        zone: String = "Europe/London"
    ) -> FriendWeek {
        FriendWeek.make(name: name, planned: planned, done: done, race: race, now: now, calendar: calendar(zone))
    }

    // MARK: Shape

    @Test func weekIsSevenDaysFromMonday() {
        let week = make()
        #expect(week.weekStart == "2026-11-23")
        #expect(week.days.map(\.date) == [
            "2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26",
            "2026-11-27", "2026-11-28", "2026-11-29",
        ])
        #expect(week.version == FriendWeek.currentVersion)
        #expect(week.updatedAt == now)
    }

    @Test func weekStartsMondayEvenWhereTheCalendarStartsSunday() {
        var sundayFirst = calendar("America/New_York")
        sundayFirst.firstWeekday = 1
        let sunday = sundayFirst.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 12))!
        let week = FriendWeek.make(name: "Sam", planned: [], done: [], race: nil, now: sunday, calendar: sundayFirst)
        #expect(week.weekStart == "2026-11-23")
        #expect(week.days.last?.date == "2026-11-29")
    }

    @Test func sessionsAndWorkoutsLandOnTheirDays() {
        let week = make(
            planned: [session(24, .tempo, km: 8), session(28, .longRun, km: 18)],
            done: [run(24, .tempo, km: 8.2, minutes: 40)]
        )
        #expect(week.days[1].planned == [FriendWeek.Planned(kind: .tempo, meters: 8000)])
        #expect(week.days[1].done.map(\.meters) == [8200])
        #expect(week.days[1].done.map(\.seconds) == [2400])
        #expect(week.days[5].planned == [FriendWeek.Planned(kind: .long, meters: 18000)])
        #expect(week.days[5].done.isEmpty)
    }

    @Test func outsideTheWeekIsIgnored() {
        let week = make(
            planned: [session(22), session(30)],
            done: [run(22), FriendWeek.FinishedWorkout(id: UUID(), date: date(30), type: .easy, meters: 5000, seconds: 1800)]
        )
        #expect(week.days.allSatisfy { $0.planned.isEmpty && $0.done.isEmpty })
    }

    @Test func restDaysAreLeftOut() {
        let week = make(planned: [session(23, .rest, km: nil)])
        #expect(week.days[0].planned.isEmpty)
        #expect(week.plannedCount == 0)
    }

    @Test func workoutsOnADayKeepTheirOrder() {
        let morning = UUID(), evening = UUID()
        let week = make(done: [run(25, hour: 19, id: evening), run(25, hour: 6, id: morning)])
        #expect(week.days[2].done.map(\.id) == [morning, evening])
    }

    @Test func aDayKeepsAtMostTheCap() {
        let many = (0..<10).map { run(25, hour: 6 + $0) }
        let week = make(done: many)
        #expect(week.days[2].done.count == FriendWeek.maxEntriesPerDay)
    }

    // MARK: Time zones

    @Test func daysAreTheRunnersCalendarDays() {
        // 23:30 on Tuesday in Los Angeles is already Wednesday in London. The friend sees
        // the run on Tuesday, the day the runner ran it.
        var la = calendar("America/Los_Angeles")
        la.firstWeekday = 2
        let late = la.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 23, minute: 30))!
        let week = FriendWeek.make(
            name: "Sam", planned: [],
            done: [FriendWeek.FinishedWorkout(id: UUID(), date: late, type: .easy, meters: 5000, seconds: 1800)],
            race: nil, now: la.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10))!, calendar: la
        )
        #expect(week.days[1].date == "2026-11-24")
        #expect(week.days[1].done.count == 1)
    }

    // MARK: What stays out

    @Test func strengthAndCrossTrainingCarryNoDistance() {
        let week = make(
            planned: [session(23, .strength, km: 3)],
            done: [run(23, .strength, km: 0.5, minutes: 45), run(23, .crossTraining, km: 30, minutes: 60)]
        )
        #expect(week.days[0].planned == [FriendWeek.Planned(kind: .strength, meters: nil)])
        #expect(week.days[0].done.map(\.meters) == [nil, nil])
        #expect(week.days[0].done.map(\.seconds) == [2700, 3600])
    }

    @Test func walksKeepDistanceButAreNotRunning() {
        let week = make(done: [run(23, .walk, km: 4, minutes: 50), run(24, km: 6)])
        #expect(week.days[0].done.first?.meters == 4000)
        #expect(week.runMeters == 6000)
        #expect(week.runCount == 1)
    }

    @Test func jsonCarriesNoTimeOfDay() throws {
        let week = make(done: [run(24, hour: 6)])
        let json = try #require(String(data: week.encoded(), encoding: .utf8))
        // The only instant is updatedAt; days are calendar days.
        #expect(!json.contains("T06:"))
        #expect(!json.contains("T05:"))
        #expect(json.components(separatedBy: "\"updatedAt\"").count == 2)
    }

    @Test func nonsenseNumbersAreTidied() {
        let week = make(done: [FriendWeek.FinishedWorkout(id: UUID(), date: date(23), type: .easy,
                                                           meters: .nan, seconds: -5)])
        #expect(week.days[0].done.first?.meters == 0)
        #expect(week.days[0].done.first?.seconds == 0)
    }

    // MARK: Name

    @Test func nameIsTidiedAndCut() {
        #expect(make(name: "  Sam\n  Runner ").name == "Sam Runner")
        #expect(make(name: String(repeating: "a", count: 50)).name.count == FriendWeek.maxNameLength)
        #expect(make(name: " \n\t").name == "Runner")
    }

    // MARK: Race

    @Test func raceTravelsAsAnInviteLink() throws {
        let race = try #require(RaceInvite(name: "Valencia", raceType: .marathon,
                                           raceDate: date(6, month: 12), calendar: calendar()))
        let week = make(race: race)
        #expect(week.raceLink == race.webURL.absoluteString)
        #expect(week.race == race)
    }

    @Test func aPassedRaceIsLeftOut() throws {
        let race = try #require(RaceInvite(name: "Parkrun", raceType: .fiveK,
                                           raceDate: date(21), calendar: calendar()))
        #expect(make(race: race).raceLink == nil)
    }

    // MARK: Totals

    @Test func totalsCountRunningOnly() {
        let week = make(
            planned: [session(23, km: 5), session(25, .interval, km: 8), session(26, .strength, km: nil),
                      session(28, .longRun, km: 16)],
            done: [run(23, km: 5.4), run(25, .interval, km: 7.6), run(26, .strength)]
        )
        #expect(week.plannedRunMeters == 29000)
        #expect(week.runMeters == 13000)
        #expect(week.runCount == 2)
        #expect(week.plannedCount == 4)
        #expect(week.plannedDoneCount == 3)
    }

    @Test func currentWeekIsTold() {
        let week = make()
        #expect(week.isCurrent(now: now, calendar: calendar()))
        #expect(!week.isCurrent(now: date(2, month: 12), calendar: calendar()))
    }

    // MARK: Wire

    @Test func roundTripsThroughJSON() throws {
        let race = RaceInvite(name: "Valencia", raceType: .marathon, raceDate: date(6, month: 12), calendar: calendar())
        let week = make(planned: [session(24, .tempo, km: 8)], done: [run(24, .tempo, km: 8)], race: race)
        let read = try #require(FriendWeek.decoded(from: week.encoded()))
        #expect(read == week)
    }

    @Test func unknownKindsAndFieldsFromANewerAppAreRead() throws {
        let json = """
        {"version":3,"name":"Ana","weekStart":"2026-11-23","updatedAt":"2026-11-26T10:00:00Z",
         "mood":"great",
         "days":[
          {"date":"2026-11-23","planned":[{"kind":"hill","meters":6000}],"done":[]},
          {"date":"2026-11-24","planned":[],"done":[]},
          {"date":"2026-11-25","planned":[],"done":[]},
          {"date":"2026-11-26","planned":[],"done":[]},
          {"date":"2026-11-27","planned":[],"done":[]},
          {"date":"2026-11-28","planned":[],"done":[]},
          {"date":"2026-11-29","planned":[],"done":[]}]}
        """
        let week = try #require(FriendWeek.decoded(from: Data(json.utf8)))
        #expect(week.version == 3)
        #expect(week.days[0].planned.first?.kind == .other)
        #expect(week.raceLink == nil)
    }

    @Test func notAWeekIsRefused() {
        #expect(FriendWeek.decoded(from: Data("nope".utf8)) == nil)
        let short = """
        {"version":1,"name":"Ana","weekStart":"2026-11-23","updatedAt":"2026-11-26T10:00:00Z","days":[]}
        """
        #expect(FriendWeek.decoded(from: Data(short.utf8)) == nil)
    }

    @Test func everyWorkoutTypeHasAKind() {
        for type in WorkoutType.allCases {
            _ = FriendWeek.Kind(type)
        }
        #expect(FriendWeek.Kind(.longRun) == .long)
        #expect(FriendWeek.Kind(.crossTraining) == .cross)
    }
}
