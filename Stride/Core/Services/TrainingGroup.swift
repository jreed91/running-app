import Foundation

// MARK: - TrainingGroup

/// A training group: friends who see each other's weeks. "Train with friends".
///
/// A group is a CloudKit record zone in the private database of the runner who started
/// it, shared with a zone-wide `CKShare` link. Everyone in it, the owner included, keeps
/// one record there: their ``FriendWeek``. Joining is accepting the link, so there are no
/// accounts and no server; iCloud is the only thing in between.
///
/// This file is the pure part: names, record layout and how the members' weeks are put in
/// order. `CloudKitTrainingGroupService` does the CloudKit calls.
struct TrainingGroup: Equatable, Hashable, Sendable, Identifiable {

    /// The zone's name, ``TrainingGroupNames/zonePrefix`` plus a UUID.
    let zoneName: String
    /// The zone owner's user record name; `CKCurrentUserDefaultName` for a group this
    /// runner started.
    let ownerName: String
    /// What the group is called: the share's title, or "Training group".
    let title: String
    /// Whether this runner started the group. The owner's zone is in their private
    /// database; a member reaches it through the shared database.
    let isOwner: Bool
    /// The link that invites someone, once CloudKit has given the share one.
    let shareURL: URL?

    var id: String { ownerName + "/" + zoneName }

    static let defaultTitle = "Training group"
    static let maxTitleLength = 40

    /// One line, at most ``maxTitleLength`` characters, ``defaultTitle`` when empty.
    static func tidiedTitle(_ raw: String) -> String {
        let line = RaceInvite.tidiedName(raw)
        let cut = String(line.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? defaultTitle : cut
    }
}

// MARK: - TrainingGroupNames

/// The CloudKit names a group uses. They are a wire format: a friend's phone on another
/// version reads them, so they never change.
enum TrainingGroupNames {

    /// Every group zone's name starts with this, so the group list can tell group zones
    /// from the zone SwiftData syncs in (`com.apple.coredata.cloudkit.zone`).
    static let zonePrefix = "TrainingGroup-"

    /// The record type of a member's week. Listed in `cloudkit/Stride.ckdb`.
    static let weekRecordType = "FriendWeek"
    /// `BYTES`: the ``FriendWeek`` JSON.
    static let payloadField = "payload"
    /// `STRING`: ``FriendWeek/weekStart``, readable in CloudKit Console without decoding.
    static let weekStartField = "weekStart"

    static let weekRecordPrefix = "week-"

    /// A new group's zone name.
    static func newZoneName(id: UUID = UUID()) -> String {
        zonePrefix + id.uuidString
    }

    static func isGroupZone(_ zoneName: String) -> Bool {
        zoneName.hasPrefix(zonePrefix) && zoneName.count > zonePrefix.count
    }

    /// The record name of `memberID`'s week. One record per member per group, written
    /// over each time, so a group holds as many weeks as it has members.
    static func weekRecordName(memberID: String) -> String {
        weekRecordPrefix + memberID
    }

    /// The member a week record belongs to, or nil for a record that isn't a week.
    static func memberID(fromRecordName recordName: String) -> String? {
        guard recordName.hasPrefix(weekRecordPrefix) else { return nil }
        let id = String(recordName.dropFirst(weekRecordPrefix.count))
        return id.isEmpty ? nil : id
    }
}

// MARK: - FriendsBoard

/// The members of a group as the friends screen lists them.
enum FriendsBoard {

    /// A member's week as read from the group.
    struct MemberWeek: Equatable, Sendable {
        /// The member's user record name in this container.
        let memberID: String
        let week: FriendWeek
    }

    struct Row: Equatable, Sendable, Identifiable {
        let memberID: String
        let name: String
        let isMe: Bool
        /// Nil when the member's latest week is not this week: they haven't opened Stride
        /// since Monday, which reads differently from "no runs yet".
        let week: FriendWeek?
        /// When the member's phone last wrote a week, current or not.
        let updatedAt: Date

        var id: String { memberID }
    }

    /// One row per member: this runner first, then friends by name. A member with more
    /// than one record (it shouldn't happen, but a hand-made one could) shows their
    /// newest.
    static func rows(
        _ weeks: [MemberWeek],
        myMemberID: String?,
        now: Date,
        calendar: Calendar
    ) -> [Row] {
        var newest: [String: MemberWeek] = [:]
        for entry in weeks {
            if let kept = newest[entry.memberID], kept.week.updatedAt >= entry.week.updatedAt { continue }
            newest[entry.memberID] = entry
        }

        let rows = newest.values.map { entry in
            Row(
                memberID: entry.memberID,
                name: entry.week.name,
                isMe: entry.memberID == myMemberID,
                week: entry.week.isCurrent(now: now, calendar: calendar) ? entry.week : nil,
                updatedAt: entry.week.updatedAt
            )
        }

        return rows.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.memberID < b.memberID
        }
    }
}
