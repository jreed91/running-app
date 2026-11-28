import Foundation
import Testing
@testable import StrideCore

// MARK: - Custom workouts (PR 2): the builder's draft, starters and summaries

struct CustomWorkoutDraftTests {

    private let paces = TrainingPaces(easyRange: 330...370, marathon: 290, threshold: 270, interval: 245, repetition: 225)

    // MARK: Draft ⇄ structure

    @Test("A draft becomes a structure and reads back the same")
    func roundTrip() {
        let draft = CustomWorkoutDraft(
            name: "Mixed",
            notes: "Track",
            warmup: .time(seconds: 600),
            sets: [
                .init(label: "Tempo", repetitions: 2, work: .distance(meters: 1_609.344),
                      workPaceSecondsPerKm: 270, recovery: .time(seconds: 120), recoveryKind: .jog),
                .init(repetitions: 4, work: .time(seconds: 60), recovery: .distance(meters: 200), recoveryKind: .walk)
            ],
            cooldown: nil
        )
        let structure = draft.structure()
        #expect(structure.warmup.durationSeconds == 600)
        #expect(structure.cooldown.isEmpty)
        #expect(structure.mainSets[0].workSegment.targetPaceSecondsPerKm == 270)
        #expect(structure.mainSets[1].recoverySegment.distanceMeters == 200)

        var back = CustomWorkoutDraft(name: "Mixed", structure: structure, notes: "Track")
        // Ids are minted fresh on read; everything the runner typed survives.
        for index in back.sets.indices { back.sets[index].id = draft.sets[index].id }
        #expect(back == draft)
    }

    @Test("No recovery is an empty segment, so the guided run has no recovery step")
    func noRecovery() {
        let draft = CustomWorkoutDraft(name: "x", sets: [.init(repetitions: 3, work: .distance(meters: 400))])
        let steps = GuidedWorkoutState.flatten(draft.structure())
        #expect(steps.map(\.kind) == [.work, .work, .work])
    }

    @Test("Adding a set copies the last one with a new id")
    func addSetCopiesTheLast() {
        var draft = CustomWorkoutDraft(name: "x", sets: [.init(repetitions: 5, work: .time(seconds: 90))])
        draft.addSet()
        #expect(draft.sets.count == 2)
        #expect(draft.sets[1].repetitions == 5 && draft.sets[1].work == .time(seconds: 90))
        #expect(draft.sets[1].id != draft.sets[0].id)
    }

    // MARK: Typed values

    @Test("m:ss text parses, and nonsense does not")
    func minutesSeconds() {
        #expect(MinutesSecondsText.seconds(from: "1:30") == 90)
        #expect(MinutesSecondsText.seconds(from: "12") == 720)
        #expect(MinutesSecondsText.seconds(from: "1:02:00") == 3_720)
        #expect(MinutesSecondsText.seconds(from: "1:75") == nil)
        #expect(MinutesSecondsText.seconds(from: "") == nil)
        #expect(MinutesSecondsText.seconds(from: "0:00") == nil)
        #expect(MinutesSecondsText.seconds(from: "a:10") == nil)
        #expect(MinutesSecondsText.seconds(from: "-1:10") == nil)
    }

    @Test("A pace typed per mile is stored per kilometre")
    func imperialPace() throws {
        let perKm = try #require(MinutesSecondsText.paceSecondsPerKm(from: "8:00", unit: .imperial))
        #expect(abs(perKm - 480 / 1.60934) < 0.001)
        #expect(MinutesSecondsText.paceText(secondsPerKm: perKm, unit: .imperial) == "8:00")
    }

    @Test("Distances read in the unit they were typed in")
    func displayUnit() {
        #expect(CustomWorkoutDistanceUnit.display(for: 800, unit: .imperial) == .meters)
        #expect(CustomWorkoutDistanceUnit.display(for: 1_609.344, unit: .metric) == .miles)
        #expect(CustomWorkoutDistanceUnit.display(for: 2_000, unit: .imperial) == .kilometers)
        #expect(CustomWorkoutDistanceUnit.display(for: 1_234, unit: .imperial) == .miles)
    }

    // MARK: Starters

    @Test("Every starter can be saved as it comes")
    func startersAreValid() {
        for unit in [UnitPreference.metric, .imperial] {
            for knownPaces in [paces, nil] {
                for starter in CustomWorkoutStarters.all(paces: knownPaces, unit: unit) {
                    let problems = CustomWorkoutRules.problems(name: starter.draft.name, structure: starter.draft.structure())
                    #expect(problems.isEmpty, "\(starter.id): \(problems)")
                }
            }
        }
    }

    @Test("Starters take the runner's paces, and none without them")
    func starterPaces() throws {
        let withPaces = try #require(CustomWorkoutStarters.all(paces: paces, unit: .metric).first { $0.id == "800s" })
        #expect(withPaces.draft.sets.first?.workPaceSecondsPerKm == 245)
        let without = try #require(CustomWorkoutStarters.all(paces: nil, unit: .metric).first { $0.id == "800s" })
        #expect(without.draft.sets.first?.workPaceSecondsPerKm == nil)
    }

    // MARK: Summary

    @Test("The sets line names each set's reps and length")
    func setsLine() {
        let draft = CustomWorkoutDraft(name: "x", sets: [
            .init(repetitions: 6, work: .distance(meters: 800)),
            .init(repetitions: 1, work: .distance(meters: 1_609.344)),
            .init(repetitions: 4, work: .time(seconds: 60))
        ])
        #expect(CustomWorkoutSummary.setsLine(draft.structure(), unit: .imperial) == "6 × 800 m + 1 mi + 4 × 1:00")
    }

    @Test("The totals line rounds to whole minutes")
    func totalsLine() {
        var structure = CustomWorkoutDraft(name: "x").structure()
        #expect(CustomWorkoutSummary.totalsLine(structure, unit: .metric) == nil)
        structure.totalEstimatedDurationSeconds = 44 * 60 + 40
        structure.totalEstimatedDistanceMeters = 0
        #expect(CustomWorkoutSummary.totalsLine(structure, unit: .metric) == "About 45 min")
    }

    @Test("Numbers drop trailing zeros")
    func numbers() {
        #expect(CustomWorkoutSummary.number(800) == "800")
        #expect(CustomWorkoutSummary.number(1.5) == "1.5")
        #expect(CustomWorkoutSummary.number(0.25) == "0.25")
    }
}
