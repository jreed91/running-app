import Foundation
import SwiftData
import Testing
@testable import Stride

// MARK: - Shoe tracking
//
// A pair's mileage is never stored: it is the runs that name the pair plus whatever the
// pair had on it when it was added. These tests hold the rules around that — how worn a
// pair reads, which pair a new run goes on, and when Home says so.

@MainActor
struct ShoeTrackingTests {

    // MARK: Fixtures

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func shoe(
        _ name: String = "Pegasus",
        since startDate: Date = Date(timeIntervalSince1970: 0),
        startingKm: Double = 0,
        limitKm: Double = 800
    ) -> Shoe {
        Shoe(
            name: name,
            startDate: startDate,
            startingDistanceMeters: startingKm * 1_000,
            replacementDistanceMeters: limitKm * 1_000
        )
    }

    private func run(km: Double, on date: Date = Date(), type: WorkoutType = .easy, shoe: Shoe? = nil) -> RunWorkout {
        let run = RunWorkout(date: date, distanceMeters: km * 1_000, durationSeconds: km * 330, workoutType: type)
        run.shoeID = shoe?.id
        return run
    }

    // MARK: - Wear

    @Test("Wear reads fresh, then nearly done in the last tenth, then worn at the limit")
    func wearThresholds() {
        #expect(ShoeWearPolicy.wear(totalMeters: 0, replacementMeters: 800_000) == .fresh)
        #expect(ShoeWearPolicy.wear(totalMeters: 719_999, replacementMeters: 800_000) == .fresh)
        #expect(ShoeWearPolicy.wear(totalMeters: 720_000, replacementMeters: 800_000) == .replaceSoon)
        #expect(ShoeWearPolicy.wear(totalMeters: 799_999, replacementMeters: 800_000) == .replaceSoon)
        #expect(ShoeWearPolicy.wear(totalMeters: 800_000, replacementMeters: 800_000) == .worn)
        #expect(ShoeWearPolicy.wear(totalMeters: 1_200_000, replacementMeters: 800_000) == .worn)
    }

    @Test("A pair with no limit set never nudges")
    func zeroLimitIsFresh() {
        #expect(ShoeWearPolicy.wear(totalMeters: 5_000_000, replacementMeters: 0) == .fresh)
    }

    @Test("The default limit is a round number in the runner's own unit")
    func defaultLimits() {
        #expect(ShoeWearPolicy.defaultReplacementMeters(for: .metric) == 800_000)
        let imperialMiles = ShoeWearPolicy.defaultReplacementMeters(for: .imperial).distanceValue(unit: .imperial)
        #expect(abs(imperialMiles - 500) < 1e-9)
    }

    // MARK: - Mileage

    @Test("Mileage sums each pair's runs, adds what it came with, and ignores runs with no shoe")
    func mileage() {
        let pegasus = shoe("Pegasus", startingKm: 100)
        let vaporfly = shoe("Vaporfly")
        let runs = [
            run(km: 10, shoe: pegasus),
            run(km: 5, shoe: pegasus),
            run(km: 21.1, shoe: vaporfly),
            run(km: 8)
        ]
        let logged = ShoeWearPolicy.loggedMeters(runs)
        #expect(logged.count == 2)
        #expect(ShoeWearPolicy.totalMeters(for: pegasus, logged: logged) == 115_000)
        #expect(ShoeWearPolicy.totalMeters(for: vaporfly, logged: logged) == 21_100)
        #expect(ShoeWearPolicy.totalMeters(for: shoe("Unworn", startingKm: 3), logged: logged) == 3_000)
    }

    // MARK: - Default pair

    @Test("The default pair only goes on runs from the day it went into use")
    func defaultRespectsStartDate() {
        let pegasus = shoe(since: date(2026, 9, 1, 18))
        ShoeAssignment.makeDefault(pegasus, among: [pegasus])

        // Same calendar day as the start, but earlier in the day: still counts.
        let sameDay = ShoeWearPolicy.defaultShoe(among: [pegasus], forRunOn: date(2026, 9, 1, 7), calendar: calendar)
        let dayBefore = ShoeWearPolicy.defaultShoe(among: [pegasus], forRunOn: date(2026, 8, 31), calendar: calendar)
        #expect(sameDay === pegasus)
        #expect(dayBefore == nil)
    }

    @Test("A retired pair is never the default, and two synced defaults resolve to the latest")
    func defaultResolution() {
        let older = shoe("Older")
        let newer = shoe("Newer")
        older.defaultSetAt = date(2026, 1, 1)
        newer.defaultSetAt = date(2026, 6, 1)
        #expect(ShoeWearPolicy.defaultShoe(among: [older, newer], forRunOn: date(2026, 9, 1)) === newer)

        ShoeAssignment.retire(newer)
        #expect(newer.defaultSetAt == nil)
        #expect(ShoeWearPolicy.defaultShoe(among: [older, newer], forRunOn: date(2026, 9, 1)) === older)
    }

    @Test("Making a pair the default takes the default off every other pair")
    func makeDefaultIsExclusive() {
        let a = shoe("A"), b = shoe("B")
        ShoeAssignment.makeDefault(a, among: [a, b])
        ShoeAssignment.makeDefault(b, among: [a, b])
        #expect(!a.isDefault)
        #expect(b.isDefault)
    }

    @Test("New runs get the default pair; walks and runs that already have a pair do not")
    func assignDefault() {
        let context = TestStore.makeContext()
        let pegasus = shoe("Pegasus", since: date(2026, 9, 1))
        let racer = shoe("Racer", since: date(2026, 1, 1))
        context.insert(pegasus)
        context.insert(racer)
        ShoeAssignment.makeDefault(pegasus, among: [pegasus, racer])

        let fresh = run(km: 10, on: date(2026, 9, 10))
        let alreadyShod = run(km: 5, on: date(2026, 9, 10), shoe: racer)
        let walk = run(km: 4, on: date(2026, 9, 10), type: .walk)
        let ride = run(km: 30, on: date(2026, 9, 10), type: .crossTraining)
        let beforeThePair = run(km: 8, on: date(2026, 8, 20))
        for workout in [fresh, alreadyShod, walk, ride, beforeThePair] { context.insert(workout) }

        ShoeAssignment.assignDefaultShoe(to: [fresh, alreadyShod, walk, ride, beforeThePair], in: context)

        #expect(fresh.shoeID == pegasus.id)
        #expect(alreadyShod.shoeID == racer.id)
        #expect(walk.shoeID == nil)
        #expect(ride.shoeID == nil)
        #expect(beforeThePair.shoeID == nil)
    }

    @Test("With no default pair, nothing is assigned")
    func assignWithoutDefault() {
        let context = TestStore.makeContext()
        context.insert(shoe())
        let workout = run(km: 10)
        context.insert(workout)
        ShoeAssignment.assignDefaultShoe(to: [workout], in: context)
        #expect(workout.shoeID == nil)
    }

    @Test("Deleting a pair takes it off its runs")
    func deleteClearsRuns() throws {
        let context = TestStore.makeContext()
        let pegasus = shoe()
        let other = shoe("Other")
        context.insert(pegasus)
        context.insert(other)
        let mine = run(km: 10, shoe: pegasus)
        let theirs = run(km: 10, shoe: other)
        context.insert(mine)
        context.insert(theirs)
        try context.save()

        ShoeAssignment.delete(pegasus, in: context)
        try context.save()

        #expect(mine.shoeID == nil)
        #expect(theirs.shoeID == other.id)
        #expect(try context.fetch(FetchDescriptor<Shoe>()).count == 1)
    }

    // MARK: - Nudge

    @Test("Only pairs in rotation that are nearly done or worn out nudge, most worn first")
    func nudgeCandidates() {
        let fresh = shoe("Fresh")
        let nearlyDone = shoe("Nearly", startingKm: 750)
        let wornOut = shoe("Worn", startingKm: 820)
        let retired = shoe("Retired", startingKm: 900)
        ShoeAssignment.retire(retired)

        let nudges = ShoeWearPolicy.shoesToNudge(
            [fresh, nearlyDone, wornOut, retired],
            logged: [:],
            dismissed: [:]
        )
        #expect(nudges.map { $0.shoe.name } == ["Worn", "Nearly"])
        #expect(nudges.first?.wear == .worn)
    }

    @Test("Saying not yet silences a pair until it gets more worn")
    func dismissalIsPerWearLevel() {
        let pegasus = shoe(startingKm: 750)
        let dismissed: [UUID: ShoeWearPolicy.Wear] = [pegasus.id: .replaceSoon]

        #expect(ShoeWearPolicy.shoesToNudge([pegasus], logged: [:], dismissed: dismissed).isEmpty)

        // Another 60 km takes it past 800: that is new information and it asks again.
        let logged = [pegasus.id: 60_000.0]
        let nudges = ShoeWearPolicy.shoesToNudge([pegasus], logged: logged, dismissed: dismissed)
        #expect(nudges.first?.wear == .worn)
    }

    @Test("Dismissals survive a round trip through storage")
    func dismissalsRoundTrip() throws {
        let suite = "shoe-nudge-dismissals"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let id = UUID()
        ShoeNudgeDismissals.dismiss(id, at: .replaceSoon, in: defaults)
        #expect(ShoeNudgeDismissals.load(from: defaults) == [id: .replaceSoon])

        ShoeNudgeDismissals.dismiss(id, at: .worn, in: defaults)
        #expect(ShoeNudgeDismissals.load(from: defaults) == [id: .worn])

        ShoeNudgeDismissals.removeAll(from: defaults)
        #expect(ShoeNudgeDismissals.load(from: defaults).isEmpty)
    }
}
