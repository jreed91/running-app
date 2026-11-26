import CloudKit
import Foundation

// MARK: - TrainingGroupSyncing

/// What "Train with friends" asks of iCloud. A protocol so views and tests can run on a
/// fake; ``CloudKitTrainingGroupService`` is the real one.
protocol TrainingGroupSyncing: Sendable {
    /// Starts a group: a new zone in this runner's private database and a link that
    /// invites anyone who has it.
    func createGroup(title: String) async throws -> TrainingGroup
    /// The groups this runner started and the ones they joined.
    func groups() async throws -> [TrainingGroup]
    /// Writes this runner's week into each group, over their previous one.
    func publish(_ week: FriendWeek, to groups: [TrainingGroup]) async throws
    /// Every member's latest week in `group`.
    func weeks(in group: TrainingGroup) async throws -> [FriendsBoard.MemberWeek]
    /// This runner's member id, the one their week records are named after.
    func myMemberID() async throws -> String
    /// Ends the group for everyone when this runner started it, or leaves it when they
    /// joined it.
    func leave(_ group: TrainingGroup) async throws
    /// Joins the group behind an invite link the system handed the app.
    func accept(_ invite: TrainingGroupInvite) async throws -> TrainingGroup
}

// MARK: - CloudKitTrainingGroupService

/// ``TrainingGroupSyncing`` on the app's CloudKit container.
///
/// Groups live beside the SwiftData store, not in it: SwiftData syncs only its own zone
/// (`com.apple.coredata.cloudkit.zone`) in the private database and cannot share. A group
/// is a zone named ``TrainingGroupNames/zonePrefix``… with a zone-wide `CKShare` whose
/// public permission is read-write, so anyone with the link can join and write their own
/// week. The trade-off: a member could also overwrite someone else's record. For a group
/// of friends that is acceptable; the app only ever writes its own.
///
/// Reads go through zone changes rather than queries, so no field needs a queryable index
/// in the Production schema.
final class CloudKitTrainingGroupService: TrainingGroupSyncing {

    private let containerID: String

    init(containerID: String = StrideSchema.cloudKitContainerID) {
        self.containerID = containerID
    }

    // `CKContainer` is made on each call rather than stored, so the service stays
    // `Sendable` without leaning on CloudKit's own annotations.
    private var container: CKContainer { CKContainer(identifier: containerID) }

    // MARK: Groups

    func createGroup(title: String) async throws -> TrainingGroup {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: TrainingGroupNames.newZoneName())
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

        let tidiedTitle = TrainingGroup.tidiedTitle(title)
        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = tidiedTitle as CKRecordValue
        share.publicPermission = .readWrite

        let (saved, _) = try await database.modifyRecords(saving: [share], deleting: [])
        let savedShare = try saved[share.recordID]?.get() as? CKShare

        AppLogger.log("Created training group \(zone.zoneID.zoneName)", label: "friends")
        return TrainingGroup(
            zoneName: zone.zoneID.zoneName,
            ownerName: zone.zoneID.ownerName,
            title: tidiedTitle,
            isOwner: true,
            shareURL: savedShare?.url
        )
    }

    func groups() async throws -> [TrainingGroup] {
        let owned = try await groups(in: container.privateCloudDatabase, isOwner: true)
        let joined = try await groups(in: container.sharedCloudDatabase, isOwner: false)
        return owned + joined
    }

    private func groups(in database: CKDatabase, isOwner: Bool) async throws -> [TrainingGroup] {
        let zones = try await database.allRecordZones()
            .filter { TrainingGroupNames.isGroupZone($0.zoneID.zoneName) }

        var result: [TrainingGroup] = []
        for zone in zones {
            let share = try? await zoneShare(in: database, zoneID: zone.zoneID)
            let title = (share?[CKShare.SystemFieldKey.title] as? String).map(TrainingGroup.tidiedTitle)
            result.append(TrainingGroup(
                zoneName: zone.zoneID.zoneName,
                ownerName: zone.zoneID.ownerName,
                title: title ?? TrainingGroup.defaultTitle,
                isOwner: isOwner,
                shareURL: share?.url
            ))
        }
        return result
    }

    private func zoneShare(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try await database.record(for: id) as? CKShare
    }

    func leave(_ group: TrainingGroup) async throws {
        // Deleting the zone ends it for everyone in the owner's private database; in a
        // member's shared database it removes them from the share and leaves the group.
        _ = try await database(for: group).modifyRecordZones(saving: [], deleting: [zoneID(for: group)])
        AppLogger.log("Left training group \(group.zoneName) (owner: \(group.isOwner))", label: "friends")
    }

    func accept(_ invite: TrainingGroupInvite) async throws -> TrainingGroup {
        let share = try await container.accept(invite.metadata)
        let zoneID = share.recordID.zoneID
        AppLogger.log("Joined training group \(zoneID.zoneName)", label: "friends")
        return TrainingGroup(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            title: invite.title,
            isOwner: false,
            shareURL: share.url
        )
    }

    // MARK: Weeks

    func myMemberID() async throws -> String {
        try await container.userRecordID().recordName
    }

    func publish(_ week: FriendWeek, to groups: [TrainingGroup]) async throws {
        guard !groups.isEmpty else { return }
        let payload = try week.encoded()
        let recordName = TrainingGroupNames.weekRecordName(memberID: try await myMemberID())

        var firstError: Error?
        for group in groups {
            let record = CKRecord(
                recordType: TrainingGroupNames.weekRecordType,
                recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID(for: group))
            )
            record[TrainingGroupNames.payloadField] = payload as CKRecordValue
            record[TrainingGroupNames.weekStartField] = week.weekStart as CKRecordValue
            do {
                // `.allKeys` writes over the previous week without fetching it first:
                // only this phone writes this record, so there is nothing to merge.
                _ = try await database(for: group).modifyRecords(
                    saving: [record], deleting: [], savePolicy: .allKeys
                )
            } catch {
                AppLogger.log("Publishing week to \(group.zoneName) failed: \(error.localizedDescription)", label: "friends", level: .error)
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func weeks(in group: TrainingGroup) async throws -> [FriendsBoard.MemberWeek] {
        let database = database(for: group)
        let zoneID = zoneID(for: group)

        var result: [FriendsBoard.MemberWeek] = []
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, modification) in changes.modificationResultsByID {
                guard let memberID = TrainingGroupNames.memberID(fromRecordName: id.recordName),
                      let record = try? modification.get().record,
                      record.recordType == TrainingGroupNames.weekRecordType,
                      let payload = record[TrainingGroupNames.payloadField] as? Data,
                      let week = FriendWeek.decoded(from: payload)
                else { continue }
                result.append(FriendsBoard.MemberWeek(memberID: memberID, week: week))
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return result
    }

    // MARK: Helpers

    private func database(for group: TrainingGroup) -> CKDatabase {
        group.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(for group: TrainingGroup) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: group.zoneName, ownerName: group.ownerName)
    }
}
