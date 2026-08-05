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

// MARK: - Track grouping tests

/// The track list is the only place a runner can see the playlist — iOS opens neither a private
/// library playlist nor the library root — so the grouping that gives it its shape is tested.
struct RunPlaylistTrackSectionTests {

    private func track(_ id: String, _ energy: RunPlaylistEnergy, seconds: Double = 200) -> RunPlaylistTrack {
        RunPlaylistTrack(id: id, title: "Track \(id)", artist: "Artist", seconds: seconds, energy: energy)
    }

    @Test("Consecutive tracks of one energy become one section")
    func consecutiveTracksGroup() {
        let sections = RunPlaylistTrackSection.sections(from: [
            track("1", .calm), track("2", .calm),
            track("3", .hard), track("4", .hard), track("5", .hard),
            track("6", .calm)
        ])
        #expect(sections.map(\.energy) == [.calm, .hard, .calm])
        #expect(sections.map { $0.tracks.count } == [2, 3, 1])
    }

    @Test("A section's duration is the sum of its tracks")
    func sectionDurationSums() {
        let sections = RunPlaylistTrackSection.sections(from: [
            track("1", .hard, seconds: 180), track("2", .hard, seconds: 220)
        ])
        #expect(sections.count == 1)
        #expect(sections[0].seconds == 400)
    }

    @Test("Section IDs are unique so the list can be rendered")
    func sectionIDsAreUnique() {
        let sections = RunPlaylistTrackSection.sections(from: [
            track("1", .calm), track("2", .hard), track("3", .calm), track("4", .hard)
        ])
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test("No tracks means no sections")
    func emptyInputGivesNoSections() {
        #expect(RunPlaylistTrackSection.sections(from: []).isEmpty)
    }

    /// The grouping only reproduces the plan's blocks because the planner guarantees no two
    /// neighbouring blocks share an energy. This ties the two halves together.
    @Test("Grouping reproduces the plan's block sequence")
    func groupingMatchesPlanBlocks() throws {
        let set = WorkoutSet(
            repetitions: 1,
            workSegment: WorkoutSegment(
                distanceMeters: nil, durationSeconds: 25 * 60,
                targetPaceSecondsPerKm: nil, label: "Tempo"
            ),
            recoverySegment: WorkoutSegment(
                distanceMeters: nil, durationSeconds: 0,
                targetPaceSecondsPerKm: nil, label: ""
            ),
            label: "Tempo"
        )
        let bookend = WorkoutSegment(
            distanceMeters: nil, durationSeconds: 10 * 60,
            targetPaceSecondsPerKm: nil, label: "Bookend"
        )
        let plan = try #require(
            RunPlaylistPlanner.plan(
                for: RunPlaylistPlanner.Session(
                    workoutType: .tempo,
                    structure: WorkoutStructure(
                        warmup: bookend,
                        mainSets: [set],
                        cooldown: bookend,
                        totalEstimatedDistanceMeters: 10_000,
                        totalEstimatedDurationSeconds: 0
                    )
                )
            )
        )

        // One track per block is enough to check the sequence survives the round trip.
        let tracks = plan.blocks.enumerated().map { index, block in
            track("\(index)", block.energy)
        }
        let sections = RunPlaylistTrackSection.sections(from: tracks)
        #expect(sections.map(\.energy) == plan.blocks.map(\.energy))
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

    /// Links written by earlier builds must still decode, or every playlist already built would
    /// read as missing rather than simply carrying no track list.
    @Test("A link from an earlier build still decodes")
    func legacyLinkDecodes() throws {
        let json = """
        {
          "workoutID": "\(UUID().uuidString)",
          "playlistID": "p.legacy",
          "name": "Stride · Easy · 1 Aug",
          "trackCount": 9,
          "totalSeconds": 1800,
          "builtAt": 776000000,
          "usedCatalog": true
        }
        """
        let decoded = try JSONDecoder().decode(RunPlaylistLink.self, from: Data(json.utf8))
        #expect(decoded.playlistID == "p.legacy")
        // No tracks rather than a decode failure — the card keeps such a link as a plain row
        // instead of pushing an empty track list.
        #expect(decoded.tracks.isEmpty)
    }

    @Test("Tracks round-trip with the link")
    func tracksSurvive() throws {
        let defaults = try makeDefaults()
        let id = UUID()
        var stored = link(workoutID: id)
        stored.tracks = [
            RunPlaylistTrack(id: "t1", title: "One", artist: "A", seconds: 200, energy: .calm),
            RunPlaylistTrack(id: "t2", title: "Two", artist: "B", seconds: 210, energy: .hard)
        ]
        RunPlaylistStore.save(stored, in: defaults)

        let read = try #require(RunPlaylistStore.link(for: id, in: defaults))
        #expect(read.tracks == stored.tracks)
        #expect(read.sections.map(\.energy) == [.calm, .hard])
    }

    /// Storing a track list per session is what makes retention matter, so both halves of that
    /// are pinned: old links go, recent ones stay.
    @Test("Pruning drops links past retention and keeps the rest")
    func pruneRespectsRetention() throws {
        let defaults = try makeDefaults()
        let now = Date()
        let fresh = UUID()
        let stale = UUID()

        var recent = link(workoutID: fresh)
        recent.builtAt = now.addingTimeInterval(-24 * 60 * 60)
        RunPlaylistStore.save(recent, in: defaults)

        var old = link(workoutID: stale)
        old.builtAt = now.addingTimeInterval(-(RunPlaylistStore.retention + 60))
        RunPlaylistStore.save(old, in: defaults)

        RunPlaylistStore.prune(now: now, in: defaults)

        #expect(RunPlaylistStore.link(for: fresh, in: defaults) != nil)
        #expect(RunPlaylistStore.link(for: stale, in: defaults) == nil)
    }

    @Test("Pruning leaves unrelated settings alone")
    func pruneIsScoped() throws {
        let defaults = try makeDefaults()
        defaults.set("keep me", forKey: "unrelatedSetting")
        RunPlaylistStore.prune(in: defaults)
        #expect(defaults.string(forKey: "unrelatedSetting") == "keep me")
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
