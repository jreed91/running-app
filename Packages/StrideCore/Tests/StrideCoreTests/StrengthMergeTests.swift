import Testing
import Foundation
@testable import StrideCore

// MARK: - Strength import merge tests

/// `StrengthImportMerge`: which Apple Health strength workouts are new sessions, which are
/// another recording of one Stride has, and which of those link to it.
struct StrengthMergeTests {

    private typealias Session = StrengthImportMerge.Session

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = day
        components.hour = hour; components.minute = minute
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func session(
        id: UUID = UUID(),
        hk: String?,
        _ hour: Int,
        _ minute: Int = 0,
        minutes: Double,
        day: Int = 10
    ) -> Session {
        Session(id: id, healthKitWorkoutID: hk, start: date(hour, minute, day: day), durationSeconds: minutes * 60)
    }

    @Test("A workout from another app with nothing stored at its time is a new session")
    func newSessionInserts() {
        let fitbod = session(hk: "fitbod", 18, minutes: 50)
        let stored = [session(hk: "stride-export", 7, minutes: 45)]
        #expect(StrengthImportMerge.decisions(imported: [fitbod], stored: stored) == ["fitbod": .insert])
    }

    @Test("Stride's own export links to the session it came from")
    func ownExportLinks() {
        let id = UUID()
        let logged = session(id: id, hk: nil, 7, minutes: 45)
        let export = session(id: id, hk: "export", 7, minutes: 45)
        #expect(StrengthImportMerge.decisions(imported: [export], stored: [logged]) == ["export": .link(id)])
    }

    @Test("A second export of a session that already has its own is a duplicate")
    func secondExportIsDuplicate() {
        let id = UUID()
        let logged = session(id: id, hk: "first-export", 7, minutes: 45)
        let again = session(id: id, hk: "second-export", 7, minutes: 45)
        #expect(StrengthImportMerge.decisions(imported: [again], stored: [logged]) == ["second-export": .duplicate])
    }

    @Test("A Watch recording of a Stride session that is already exported is a duplicate")
    func parallelWatchRecordingIsDuplicate() {
        // The runner started the Workout app for the rings and logged the sets in Stride.
        let logged = session(hk: "stride-export", 7, minutes: 50)
        let watch = session(hk: "watch", 7, 3, minutes: 52)
        #expect(StrengthImportMerge.decisions(imported: [watch], stored: [logged]) == ["watch": .duplicate])
    }

    @Test("A Watch recording of a Stride session not yet exported lends it its id")
    func parallelWatchRecordingLinksWhenUnexported() {
        let id = UUID()
        let logged = session(id: id, hk: nil, 7, minutes: 50)
        let watch = session(hk: "watch", 6, 58, minutes: 55)
        #expect(StrengthImportMerge.decisions(imported: [watch], stored: [logged]) == ["watch": .link(id)])
    }

    @Test("A morning and an evening session on the same day stay two sessions")
    func sameDayDistinctSessions() {
        let morning = session(hk: nil, 7, minutes: 45)
        let evening = session(hk: "evening", 19, minutes: 45)
        #expect(StrengthImportMerge.decisions(imported: [evening], stored: [morning]) == ["evening": .insert])
    }

    @Test("A session starting two hours later is not merged into an unexported one")
    func nearbyButSeparateSessionInserts() {
        // The old ±3 h start-time match merged these and lost the second session.
        let logged = session(hk: nil, 9, minutes: 40)
        let core = session(hk: "core", 11, minutes: 20)
        #expect(StrengthImportMerge.decisions(imported: [core], stored: [logged]) == ["core": .insert])
    }

    @Test("Back-to-back sessions are not one session")
    func backToBackSessionsStaySeparate() {
        let lift = session(hk: "lift", 18, minutes: 45)
        let core = session(hk: "core", 18, 45, minutes: 15)
        let result = StrengthImportMerge.decisions(imported: [lift, core], stored: [])
        #expect(result == ["lift": .insert, "core": .insert])
    }

    @Test("Of two apps recording the same session, the longer recording is kept")
    func twoImportsSameTimeKeepLonger() {
        let watch = session(hk: "watch", 18, minutes: 40)
        let app = session(hk: "app", 18, 2, minutes: 55)
        let result = StrengthImportMerge.decisions(imported: [watch, app], stored: [])
        #expect(result == ["app": .insert, "watch": .duplicate])
    }

    @Test("One unexported session links one recording; a second one at that time is a duplicate")
    func onlyOneLinkPerStoredSession() {
        let id = UUID()
        let logged = session(id: id, hk: nil, 7, minutes: 50)
        let watch = session(hk: "watch", 7, minutes: 52)
        let app = session(hk: "app", 7, 1, minutes: 49)
        let result = StrengthImportMerge.decisions(imported: [watch, app], stored: [logged])
        #expect(result == ["watch": .link(id), "app": .duplicate])
    }

    @Test("An unexported session at the same time is preferred over an exported one")
    func prefersUnlinkedStoredSession() {
        let unlinkedID = UUID()
        let exported = session(hk: "export", 7, minutes: 60)
        let unlinked = session(id: unlinkedID, hk: nil, 7, 10, minutes: 40)
        let watch = session(hk: "watch", 7, 10, minutes: 40)
        let result = StrengthImportMerge.decisions(imported: [watch], stored: [exported, unlinked])
        #expect(result == ["watch": .link(unlinkedID)])
    }

    @Test("Overlap must cover half of the shorter session")
    func overlapThreshold() {
        let base = session(hk: "a", 7, minutes: 60)
        let halfIn = session(hk: "b", 7, 40, minutes: 40)   // 20 of 40 minutes shared
        let lessThanHalf = session(hk: "c", 7, 41, minutes: 40) // 19 of 40
        #expect(StrengthImportMerge.isSameSession(base, halfIn))
        #expect(!StrengthImportMerge.isSameSession(base, lessThanHalf))
    }

    @Test("A session with no duration never matches by time")
    func zeroDurationNeverMatches() {
        let empty = session(hk: "a", 7, minutes: 0)
        let other = session(hk: "b", 7, minutes: 30)
        #expect(!StrengthImportMerge.isSameSession(empty, other))
    }
}
