import Foundation
import Testing
@testable import StrideCore

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
