import Foundation
import Testing
@testable import Stride

/// Covers cheers between members of a training group: which workout a card offers, who
/// gets notified, and what the runner's own card says.
struct FriendCheerTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func done(_ kind: FriendWeek.Kind = .long, id: UUID = UUID()) -> FriendWeek.Done {
        FriendWeek.Done(id: id, kind: kind, meters: 16_000, seconds: 5_400)
    }

    private func cheer(_ workout: FriendWeek.Done, to: String = "me", from: String, name: String, minute: Int = 0) -> FriendCheer {
        FriendCheer(workout: workout, to: to, from: from, fromName: name, at: date(26, hour: 10).addingTimeInterval(Double(minute) * 60))
    }

    // MARK: Latest workout

    @Test func cardOffersTheLatestWorkoutThisWeek() {
        let early = UUID(), late = UUID()
        let week = FriendWeek.make(
            name: "Ana", planned: [],
            done: [
                .init(id: early, date: date(23), type: .easy, meters: 5000, seconds: 1800),
                .init(id: late, date: date(25, hour: 18), type: .tempo, meters: 8000, seconds: 2400),
            ],
            race: nil, now: date(26), calendar: calendar
        )
        #expect(FriendCheers.latestDone(in: week)?.id == late)
    }

    @Test func nothingToCheerBeforeTheFirstWorkout() {
        let week = FriendWeek.make(name: "Ana", planned: [], done: [], race: nil, now: date(26), calendar: calendar)
        #expect(FriendCheers.latestDone(in: week) == nil)
    }

    // MARK: Records

    @Test func oneRecordPerSenderPerWorkout() {
        let workout = done()
        let a = cheer(workout, from: "_ana", name: "Ana")
        let again = cheer(workout, from: "_ana", name: "Ana", minute: 5)
        let sam = cheer(workout, from: "_sam", name: "Sam")
        #expect(a.recordName == again.recordName)
        #expect(a.recordName != sam.recordName)
        #expect(a.recordName.hasPrefix(FriendCheer.recordPrefix))
    }

    @Test func roundTripsThroughJSON() throws {
        let original = cheer(done(.interval), from: "_ana", name: " Ana\n")
        #expect(original.fromName == "Ana")
        #expect(FriendCheer.decoded(from: try original.encoded()) == original)
        #expect(FriendCheer.decoded(from: Data("{}".utf8)) == nil)
    }

    @Test func hasCheeredIsPerSenderAndWorkout() {
        let workout = done()
        let cheers = [cheer(workout, to: "_ana", from: "me", name: "Me")]
        #expect(FriendCheers.hasCheered(cheers, from: "me", workoutID: workout.id))
        #expect(!FriendCheers.hasCheered(cheers, from: "_sam", workoutID: workout.id))
        #expect(!FriendCheers.hasCheered(cheers, from: "me", workoutID: UUID()))
    }

    // MARK: Notifications

    @Test func onlyNewCheersForMeNotify() {
        let workout = done()
        let ana = cheer(workout, from: "_ana", name: "Ana", minute: 2)
        let sam = cheer(workout, from: "_sam", name: "Sam", minute: 1)
        let forSomeoneElse = cheer(done(), to: "_ana", from: "_sam", name: "Sam")
        let fromMe = cheer(workout, from: "me", name: "Me")
        let unseen = FriendCheers.unseen([ana, sam, forSomeoneElse, fromMe], for: "me", seen: [ana.recordName])
        #expect(unseen == [sam])
    }

    @Test func notificationNamesTheSenderAndTheWorkout() {
        let text = FriendCheers.notificationText(cheer(done(.long), from: "_ana", name: "Ana"))
        #expect(text.contains("Ana"))
        #expect(text.contains("long run"))
    }

    // MARK: My card

    @Test func cheersForAWorkoutShareALine() {
        let longRun = done(.long), tempo = done(.tempo)
        let lines = FriendCheers.lines([
            cheer(tempo, from: "_ana", name: "Ana", minute: 1),
            cheer(longRun, from: "_ana", name: "Ana", minute: 10),
            cheer(longRun, from: "_sam", name: "Sam", minute: 20),
            cheer(done(), to: "_ana", from: "_sam", name: "Sam", minute: 30),
        ], for: "me")
        #expect(lines.count == 2)
        #expect(lines[0].contains("Ana") && lines[0].contains("Sam") && lines[0].contains("long run"))
        #expect(lines[1].contains("tempo run"))
    }

    @Test func everyKindHasAName() {
        for kind in FriendWeek.Kind.allCases {
            #expect(!FriendCheers.workoutName(kind).isEmpty)
        }
    }
}
