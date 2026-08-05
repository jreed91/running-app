import Foundation
import Testing
@testable import Stride

// MARK: - Run playlist shape tests (N40)

/// The whole testable surface of run playlists. `RunPlaylistService` needs MusicKit, a
/// subscription and a device; everything that decides what a playlist *is* lives in
/// `RunPlaylistPlanner` and `MusicEnergyPolicy` and is exercised here.
struct RunPlaylistPlannerTests {

    // MARK: Helpers

    private func segment(minutes: Double, label: String = "") -> WorkoutSegment {
        WorkoutSegment(
            distanceMeters: nil,
            durationSeconds: minutes * 60,
            targetPaceSecondsPerKm: nil,
            label: label
        )
    }

    private func structure(
        warmupMinutes: Double,
        sets: [WorkoutSet],
        cooldownMinutes: Double
    ) -> WorkoutStructure {
        WorkoutStructure(
            warmup: segment(minutes: warmupMinutes, label: "Warm-up"),
            mainSets: sets,
            cooldown: segment(minutes: cooldownMinutes, label: "Cool-down"),
            totalEstimatedDistanceMeters: 10_000,
            totalEstimatedDurationSeconds: 0
        )
    }

    // MARK: Non-runs

    @Test("Rest, strength, cross-training and walks get no playlist")
    func nonRunSessionsAreRejected() {
        for type in [WorkoutType.rest, .strength, .crossTraining, .walk] {
            let session = RunPlaylistPlanner.Session(
                workoutType: type,
                targetDistanceMeters: 8_000,
                targetPaceSecondsPerKm: 330
            )
            #expect(RunPlaylistPlanner.plan(for: session) == nil, "\(type.displayName) should not be scored")
        }
    }

    @Test("A run with no structure and no way to estimate its length gets no playlist")
    func unmeasurableRunIsRejected() {
        let session = RunPlaylistPlanner.Session(workoutType: .easy)
        #expect(RunPlaylistPlanner.plan(for: session) == nil)
    }

    // MARK: Unstructured runs

    @Test("An unstructured easy run becomes one steady block of its estimated length")
    func unstructuredEasyRun() throws {
        let session = RunPlaylistPlanner.Session(
            workoutType: .easy,
            targetDistanceMeters: 8_000,
            targetPaceSecondsPerKm: 330
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        #expect(plan.blocks.count == 1)
        #expect(plan.blocks.first?.energy == .steady)
        // 8 km at 5:30/km = 44 minutes.
        #expect(abs(plan.sessionSeconds - 8 * 330) < 1)
    }

    // MARK: Structured runs

    @Test("A tempo run is calm, hard, calm")
    func tempoRunIsBookended() throws {
        let tempoSet = WorkoutSet(
            repetitions: 1,
            workSegment: segment(minutes: 25, label: "Tempo"),
            recoverySegment: segment(minutes: 0),
            label: "Tempo Block"
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .tempo,
            structure: structure(warmupMinutes: 10, sets: [tempoSet], cooldownMinutes: 10)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        #expect(plan.blocks.map(\.energy) == [.calm, .hard, .calm])
        #expect(abs(plan.sessionSeconds - 45 * 60) < 1)
    }

    /// The case the smoothing exists for: twenty alternating segments, none of which is long
    /// enough to be worth its own stretch of music, collapsing into one hard block.
    @Test("Short recoveries inside an interval set are absorbed into the work")
    func intervalRecoveriesAreAbsorbed() throws {
        let intervalSet = WorkoutSet(
            repetitions: 10,
            workSegment: segment(minutes: 1.5, label: "400 m"),
            recoverySegment: segment(minutes: 1.5, label: "Recovery"),
            label: "10 × 400 m"
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .interval,
            structure: structure(warmupMinutes: 15, sets: [intervalSet], cooldownMinutes: 10)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        #expect(plan.blocks.map(\.energy) == [.calm, .hard, .calm])
        // Nothing is lost in the merge: 15 + (10×1.5 + 9×1.5) + 10 minutes.
        #expect(abs(plan.sessionSeconds - (15 + 28.5 + 10) * 60) < 1)
    }

    @Test("No plan exceeds the block cap, however many sets it has")
    func blockCountIsCapped() throws {
        let sets = (0..<8).map { index in
            WorkoutSet(
                repetitions: 2,
                workSegment: segment(minutes: 8, label: "Rep \(index)"),
                recoverySegment: segment(minutes: 6, label: "Recovery"),
                label: "Set \(index)"
            )
        }
        let session = RunPlaylistPlanner.Session(
            workoutType: .interval,
            structure: structure(warmupMinutes: 12, sets: sets, cooldownMinutes: 12)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        #expect(plan.blocks.count <= MusicEnergyPolicy.maximumBlockCount)
    }

    @Test("Every block in a finished plan is at least the minimum length")
    func noBlockIsBelowTheMinimum() throws {
        let set = WorkoutSet(
            repetitions: 4,
            workSegment: segment(minutes: 3, label: "Rep"),
            recoverySegment: segment(minutes: 2, label: "Recovery"),
            label: "4 × 3 min"
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .interval,
            structure: structure(warmupMinutes: 2, sets: [set], cooldownMinutes: 2)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        for block in plan.blocks {
            #expect(block.seconds >= MusicEnergyPolicy.minimumBlockSeconds)
        }
    }

    @Test("Neighbouring blocks never share an energy")
    func adjacentBlocksAlwaysDiffer() throws {
        let set = WorkoutSet(
            repetitions: 3,
            workSegment: segment(minutes: 10, label: "Rep"),
            recoverySegment: segment(minutes: 8, label: "Recovery"),
            label: "3 × 10 min"
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .tempo,
            structure: structure(warmupMinutes: 10, sets: [set], cooldownMinutes: 10)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        for pair in zip(plan.blocks, plan.blocks.dropFirst()) {
            #expect(pair.0.energy != pair.1.energy)
        }
    }

    @Test("A segment stated in metres is timed with the session's pace")
    func distanceSegmentsAreConverted() throws {
        let warmup = WorkoutSegment(
            distanceMeters: 2_000,
            durationSeconds: nil,
            targetPaceSecondsPerKm: nil,
            label: "Warm-up"
        )
        let structure = WorkoutStructure(
            warmup: warmup,
            mainSets: [WorkoutSet(
                repetitions: 1,
                workSegment: segment(minutes: 20, label: "Tempo"),
                recoverySegment: segment(minutes: 0),
                label: "Tempo"
            )],
            cooldown: segment(minutes: 10, label: "Cool-down"),
            totalEstimatedDistanceMeters: 10_000,
            totalEstimatedDurationSeconds: 0
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .tempo,
            structure: structure,
            targetPaceSecondsPerKm: 300
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        // 2 km at 5:00/km = 10 minutes, plus 20 tempo plus 10 cool-down.
        #expect(abs(plan.sessionSeconds - 40 * 60) < 1)
        #expect(abs((plan.blocks.first?.seconds ?? 0) - 10 * 60) < 1)
    }

    // MARK: Pregnancy plans

    /// A pregnancy plan carries its moderate day as `WorkoutType.tempo`, so mapping by type
    /// alone would score it `.hard`. Its effort ceiling is "talk but not sing"; the music's
    /// ceiling matches.
    @Test("A pregnancy session never reaches the hard tier")
    func pregnancySessionsAreCappedAtSteady() throws {
        for type in [WorkoutType.tempo, .easy, .longRun] {
            let set = WorkoutSet(
                repetitions: 1,
                workSegment: segment(minutes: 20, label: "Moderate"),
                recoverySegment: segment(minutes: 0),
                label: "Block"
            )
            let session = RunPlaylistPlanner.Session(
                workoutType: type,
                isPregnancyPlan: true,
                structure: structure(warmupMinutes: 5, sets: [set], cooldownMinutes: 5)
            )
            let plan = try #require(RunPlaylistPlanner.plan(for: session))
            #expect(
                !plan.blocks.contains { $0.energy == .hard },
                "\(type.displayName) on a pregnancy plan reached the hard tier"
            )
        }
    }

    @Test("The same session on a race plan does reach hard")
    func racePlanTempoIsHard() throws {
        let set = WorkoutSet(
            repetitions: 1,
            workSegment: segment(minutes: 20, label: "Tempo"),
            recoverySegment: segment(minutes: 0),
            label: "Block"
        )
        let session = RunPlaylistPlanner.Session(
            workoutType: .tempo,
            isPregnancyPlan: false,
            structure: structure(warmupMinutes: 5, sets: [set], cooldownMinutes: 5)
        )
        let plan = try #require(RunPlaylistPlanner.plan(for: session))
        #expect(plan.blocks.contains { $0.energy == .hard })
    }

    // MARK: Naming

    @Test("A playlist name carries the app, the session and the date")
    func playlistNameIsIdentifiable() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 7
        let date = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        let name = RunPlaylistPlanner.playlistName(
            for: .tempo,
            date: date,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(name.contains("Stride"))
        #expect(name.contains(WorkoutType.tempo.localizedName))
        #expect(name.contains("7"))
    }
}

// MARK: - Policy tests

struct MusicEnergyPolicyTests {

    @Test("Genres map to the tier they belong to")
    func genreMapping() {
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Hip-Hop/Rap"]) == .hard)
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Pop"]) == .steady)
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Classical"]) == .calm)
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Polka"]) == nil)
        #expect(MusicEnergyPolicy.energy(forGenreNames: []) == nil)
    }

    @Test("Subgenres land under their parent")
    func subgenresMatchBySubstring() {
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Alternative Rap"]) == .hard)
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Hard Rock"]) == .hard)
    }

    /// The narrower pool wins, so a track that could pass as either is not spent on the
    /// block where a wrong pick matters least.
    @Test("A song matching two tiers is claimed by the higher one")
    func overlappingGenresResolveUpwards() {
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Rock", "Metal"]) == .hard)
        #expect(MusicEnergyPolicy.energy(forGenreNames: ["Jazz", "Pop"]) == .steady)
    }

    @Test("Every buffer is between two and five minutes")
    func bufferIsBounded() {
        for minutes in stride(from: 1.0, through: 180.0, by: 1.0) {
            let buffer = MusicEnergyPolicy.bufferSeconds(forBlockOf: minutes * 60)
            #expect(buffer >= 2 * 60)
            #expect(buffer <= 5 * 60)
        }
    }

    @Test("Every tier has candidate genres and search terms")
    func everyTierIsFillable() {
        for energy in RunPlaylistEnergy.allCases {
            #expect(MusicEnergyPolicy.genres[energy]?.isEmpty == false)
            #expect(!MusicEnergyPolicy.catalogSearchTerms(for: energy).isEmpty)
        }
    }
}

// MARK: - Store tests

struct RunPlaylistStoreTests {

    private func makeDefaults() throws -> UserDefaults {
        let suite = "RunPlaylistStoreTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    private func link(workoutID: UUID) -> RunPlaylistLink {
        RunPlaylistLink(
            workoutID: workoutID,
            playlistID: "p.123",
            name: "Stride · Tempo · 7 Aug",
            trackCount: 12,
            totalSeconds: 2_700,
            builtAt: Date(),
            usedCatalog: true
        )
    }

    @Test("A saved link round-trips")
    func saveAndRead() throws {
        let defaults = try makeDefaults()
        let id = UUID()
        RunPlaylistStore.save(link(workoutID: id), in: defaults)
        let read = try #require(RunPlaylistStore.link(for: id, in: defaults))
        #expect(read.playlistID == "p.123")
        #expect(read.trackCount == 12)
    }

    @Test("Links are keyed per workout")
    func linksAreIndependent() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()
        RunPlaylistStore.save(link(workoutID: first), in: defaults)
        #expect(RunPlaylistStore.link(for: second, in: defaults) == nil)
    }

    @Test("Removing one link leaves the others")
    func removeIsScoped() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()
        RunPlaylistStore.save(link(workoutID: first), in: defaults)
        RunPlaylistStore.save(link(workoutID: second), in: defaults)
        RunPlaylistStore.remove(for: first, in: defaults)
        #expect(RunPlaylistStore.link(for: first, in: defaults) == nil)
        #expect(RunPlaylistStore.link(for: second, in: defaults) != nil)
    }

    /// What `AppContainer.resetAllData` relies on: no link outlives the plan it names.
    @Test("removeAll clears every link and nothing else")
    func removeAllIsThorough() throws {
        let defaults = try makeDefaults()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { RunPlaylistStore.save(link(workoutID: id), in: defaults) }
        defaults.set("keep me", forKey: "unrelatedSetting")

        RunPlaylistStore.removeAll(in: defaults)

        for id in ids {
            #expect(RunPlaylistStore.link(for: id, in: defaults) == nil)
        }
        #expect(defaults.string(forKey: "unrelatedSetting") == "keep me")
    }
}
