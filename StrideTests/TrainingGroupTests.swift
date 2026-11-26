import Foundation
import Testing
@testable import Stride

/// Covers the pure part of training groups: the CloudKit names (a wire format friends'
/// phones read) and the order the friends screen lists members in.
struct TrainingGroupTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    /// Thursday 26 November 2026.
    private var now: Date { date(26, hour: 18) }

    private func week(_ name: String, updated: Date) -> FriendWeek {
        FriendWeek.make(name: name, planned: [], done: [], race: nil, now: updated, calendar: calendar)
    }

    // MARK: Names

    @Test func zoneNamesCarryThePrefix() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(TrainingGroupNames.newZoneName(id: id) == "TrainingGroup-6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(TrainingGroupNames.isGroupZone(TrainingGroupNames.newZoneName()))
    }

    @Test func otherZonesAreNotGroups() {
        #expect(!TrainingGroupNames.isGroupZone("com.apple.coredata.cloudkit.zone"))
        #expect(!TrainingGroupNames.isGroupZone("_defaultZone"))
        #expect(!TrainingGroupNames.isGroupZone("TrainingGroup-"))
    }

    @Test func weekRecordNamesRoundTrip() {
        let name = TrainingGroupNames.weekRecordName(memberID: "_a1b2c3")
        #expect(name == "week-_a1b2c3")
        #expect(TrainingGroupNames.memberID(fromRecordName: name) == "_a1b2c3")
    }

    @Test func otherRecordsHaveNoMember() {
        #expect(TrainingGroupNames.memberID(fromRecordName: "cloudkit.zoneshare") == nil)
        #expect(TrainingGroupNames.memberID(fromRecordName: "week-") == nil)
        #expect(TrainingGroupNames.memberID(fromRecordName: "cheer-x") == nil)
    }

    @Test func wireNamesNeverChange() {
        #expect(TrainingGroupNames.zonePrefix == "TrainingGroup-")
        #expect(TrainingGroupNames.weekRecordType == "FriendWeek")
        #expect(TrainingGroupNames.payloadField == "payload")
        #expect(TrainingGroupNames.weekStartField == "weekStart")
    }

    @Test func titlesAreTidied() {
        #expect(TrainingGroup.tidiedTitle("  Tuesday\nclub ") == "Tuesday club")
        #expect(TrainingGroup.tidiedTitle("") == TrainingGroup.defaultTitle)
        #expect(TrainingGroup.tidiedTitle(String(repeating: "x", count: 99)).count == TrainingGroup.maxTitleLength)
    }

    @Test func groupIDsDifferByOwner() {
        let a = TrainingGroup(zoneName: "TrainingGroup-1", ownerName: "_alice", title: "A", isOwner: false, shareURL: nil)
        let b = TrainingGroup(zoneName: "TrainingGroup-1", ownerName: "_bob", title: "A", isOwner: false, shareURL: nil)
        #expect(a.id != b.id)
    }

    // MARK: Board

    @Test func meFirstThenFriendsByName() {
        let rows = FriendsBoard.rows([
            .init(memberID: "z", week: week("zoe", updated: date(25))),
            .init(memberID: "m", week: week("Mo", updated: date(24))),
            .init(memberID: "a", week: week("Ana", updated: date(26))),
            .init(memberID: "b", week: week("ben", updated: date(23))),
        ], myMemberID: "m", now: now, calendar: calendar)
        #expect(rows.map(\.name) == ["Mo", "Ana", "ben", "zoe"])
        #expect(rows.map(\.isMe) == [true, false, false, false])
    }

    @Test func lastWeeksWeekShowsAsNoUpdate() {
        let stale = week("Ana", updated: date(20))
        let rows = FriendsBoard.rows([.init(memberID: "a", week: stale)],
                                     myMemberID: nil, now: now, calendar: calendar)
        #expect(rows.first?.week == nil)
        #expect(rows.first?.updatedAt == date(20))
        #expect(rows.first?.name == "Ana")
    }

    @Test func aMemberShowsOnceWithTheirNewestWeek() {
        let older = week("Ana", updated: date(23))
        let newer = week("Ana R", updated: date(25))
        let rows = FriendsBoard.rows([.init(memberID: "a", week: newer), .init(memberID: "a", week: older)],
                                     myMemberID: nil, now: now, calendar: calendar)
        #expect(rows.count == 1)
        #expect(rows.first?.name == "Ana R")
    }

    @Test func sameNamesKeepAStableOrder() {
        let rows = FriendsBoard.rows([
            .init(memberID: "2", week: week("Sam", updated: date(25))),
            .init(memberID: "1", week: week("Sam", updated: date(25))),
        ], myMemberID: nil, now: now, calendar: calendar)
        #expect(rows.map(\.memberID) == ["1", "2"])
    }
}
