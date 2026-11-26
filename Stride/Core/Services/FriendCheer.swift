import Foundation

// MARK: - FriendCheer

/// A cheer one member of a training group sends for another's finished workout.
///
/// It lives in the group's zone beside the weeks, one record per sender per workout
/// (``recordName``), so cheering twice is the same record written twice. Like a week, it
/// travels as JSON in one field; it names the workout by the id its ``FriendWeek`` already
/// shares and says nothing else about either runner.
///
/// Cheers reach the runner when their phone next publishes its week (on a foreground or
/// background): new ones become one local notification each, and the runner's own card
/// lists them. There is no push from a server, so a cheer can take until the friend next
/// opens or leaves Stride to arrive.
struct FriendCheer: Codable, Equatable, Sendable {
    var version: Int
    /// The workout cheered, ``FriendWeek/Done/id``.
    var workoutID: UUID
    var kind: FriendWeek.Kind
    /// The member who did the workout.
    var toMemberID: String
    /// The member who cheered, and the name they show.
    var fromMemberID: String
    var fromName: String
    var sentAt: Date

    static let currentVersion = 1
    static let recordType = "Cheer"
    static let recordPrefix = "cheer-"

    init(workout: FriendWeek.Done, to toMemberID: String, from fromMemberID: String, fromName: String, at sentAt: Date) {
        self.version = Self.currentVersion
        self.workoutID = workout.id
        self.kind = workout.kind
        self.toMemberID = toMemberID
        self.fromMemberID = fromMemberID
        self.fromName = FriendWeek.tidiedName(fromName)
        self.sentAt = sentAt
    }

    /// One record per sender per workout.
    var recordName: String {
        Self.recordPrefix + fromMemberID + "-" + workoutID.uuidString
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) -> FriendCheer? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FriendCheer.self, from: data)
    }
}

// MARK: - FriendCheers

/// What the friends screen and the notifications make of a group's cheers.
enum FriendCheers {

    /// The workout a friend's card offers to cheer: their latest one this week. Nil when
    /// they haven't done anything yet.
    static func latestDone(in week: FriendWeek) -> FriendWeek.Done? {
        week.days.last(where: { !$0.done.isEmpty })?.done.last
    }

    /// Whether `memberID` has already cheered `workoutID`.
    static func hasCheered(_ cheers: [FriendCheer], from memberID: String, workoutID: UUID) -> Bool {
        cheers.contains { $0.fromMemberID == memberID && $0.workoutID == workoutID }
    }

    /// Cheers for `myMemberID` that haven't been notified yet, oldest first. A runner's
    /// own cheers never notify them, even if a hand-made record says so.
    static func unseen(_ cheers: [FriendCheer], for myMemberID: String, seen: Set<String>) -> [FriendCheer] {
        cheers
            .filter { $0.toMemberID == myMemberID && $0.fromMemberID != myMemberID && !seen.contains($0.recordName) }
            .sorted { $0.sentAt < $1.sentAt }
    }

    /// Lines for the runner's own card, newest workout first: "Ana and Sam cheered your
    /// long run".
    static func lines(_ cheers: [FriendCheer], for myMemberID: String) -> [String] {
        let mine = cheers.filter { $0.toMemberID == myMemberID && $0.fromMemberID != myMemberID }
        let byWorkout = Dictionary(grouping: mine, by: \.workoutID)
        return byWorkout.values
            .sorted { ($0.map(\.sentAt).max() ?? .distantPast) > ($1.map(\.sentAt).max() ?? .distantPast) }
            .compactMap { group in
                guard let first = group.first else { return nil }
                let names = group.sorted { $0.sentAt < $1.sentAt }.map(\.fromName)
                return sentence(names: names, kind: first.kind)
            }
    }

    /// "Ana cheered your long run", the notification's text.
    static func notificationText(_ cheer: FriendCheer) -> String {
        sentence(names: [cheer.fromName], kind: cheer.kind)
    }

    private static func sentence(names: [String], kind: FriendWeek.Kind) -> String {
        let who = names.formatted(.list(type: .and))
        let what = workoutName(kind)
        return String(localized: "\(who) cheered your \(what)",
                      comment: "Train with friends: who cheered which workout, e.g. 'Ana and Sam cheered your long run'")
    }

    static func workoutName(_ kind: FriendWeek.Kind) -> String {
        switch kind {
        case .easy: String(localized: "easy run", comment: "Train with friends: cheered workout name")
        case .tempo: String(localized: "tempo run", comment: "Train with friends: cheered workout name")
        case .interval: String(localized: "intervals", comment: "Train with friends: cheered workout name")
        case .long: String(localized: "long run", comment: "Train with friends: cheered workout name")
        case .race: String(localized: "race", comment: "Train with friends: cheered workout name")
        case .cross: String(localized: "cross training", comment: "Train with friends: cheered workout name")
        case .strength: String(localized: "strength session", comment: "Train with friends: cheered workout name")
        case .walk: String(localized: "walk", comment: "Train with friends: cheered workout name")
        case .other: String(localized: "workout", comment: "Train with friends: cheered workout name")
        }
    }
}
