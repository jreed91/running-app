import Foundation
import Testing
@testable import Stride

/// Covers `RaceInvite`, the race a runner shares with "Train with a friend". The link is
/// read on someone else's phone, often in another time zone, and can be edited by hand,
/// so the round trip and the refusals are what matter.
struct RaceInviteTests {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: String) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: Round trip

    @Test func namedRaceRoundTripsThroughTheWebLink() throws {
        let invite = try #require(RaceInvite(
            name: "Chicago Marathon",
            raceType: .marathon,
            raceDate: date(2027, 10, 10, in: "America/Chicago"),
            calendar: calendar("America/Chicago")
        ))

        #expect(invite.webURL.absoluteString
            == "https://www.jacobreed.dev/stride/race?name=Chicago%20Marathon&date=2027-10-10&distance=marathon")

        let read = try #require(RaceInvite(url: invite.webURL))
        #expect(read == invite)
        #expect(read.distanceMeters == 42_195)
    }

    @Test func appLinkCarriesTheSameQuery() throws {
        let invite = try #require(RaceInvite(
            name: "Parkrun",
            raceType: .fiveK,
            raceDate: date(2027, 3, 6, in: "UTC"),
            calendar: calendar("UTC")
        ))
        #expect(invite.appURL.absoluteString == "stride://race?name=Parkrun&date=2027-03-06&distance=5k")
        #expect(RaceInvite(url: invite.appURL) == invite)
    }

    @Test func everyNamedDistanceRoundTrips() throws {
        for type in [RaceType.fiveK, .tenK, .halfMarathon, .marathon] {
            let invite = try #require(RaceInvite(
                name: "Race",
                raceType: type,
                raceDate: date(2027, 5, 1, in: "UTC"),
                calendar: calendar("UTC")
            ))
            #expect(RaceInvite(url: invite.webURL)?.raceType == type)
        }
    }

    @Test func customDistanceTravelsInWholeMetres() throws {
        let invite = try #require(RaceInvite(
            name: "Ten Mile",
            raceType: .custom,
            customDistanceMeters: 16_093.44,
            raceDate: date(2027, 4, 4, in: "UTC"),
            calendar: calendar("UTC")
        ))
        #expect(invite.webURL.absoluteString.hasSuffix("distance=16093"))

        let read = try #require(RaceInvite(url: invite.webURL))
        #expect(read.raceType == .custom)
        #expect(read.customDistanceMeters == 16_093)
        #expect(read.distanceMeters == 16_093)
    }

    @Test func namedRaceIgnoresAStrayCustomDistance() throws {
        let invite = try #require(RaceInvite(
            name: "Half",
            raceType: .halfMarathon,
            customDistanceMeters: 15_000,
            raceDate: date(2027, 4, 4, in: "UTC"),
            calendar: calendar("UTC")
        ))
        #expect(invite.customDistanceMeters == nil)
        #expect(invite.distanceMeters == 21_097.5)
    }

    // MARK: Days, not instants

    @Test func raceDayIsTheSharersCalendarDay() throws {
        // 7 a.m. on the 10th in Chicago is already the 10th in UTC, but 11 p.m. on the
        // 9th in Los Angeles is the 10th in UTC: the sharer's own day is the one sent.
        let invite = try #require(RaceInvite(
            name: "Race",
            raceType: .tenK,
            raceDate: date(2027, 10, 9, hour: 23, in: "America/Los_Angeles"),
            calendar: calendar("America/Los_Angeles")
        ))
        #expect(invite.day == RaceInvite.Day(year: 2027, month: 10, day: 9))
    }

    @Test func friendElsewhereGetsTheSameDay() throws {
        let invite = try #require(RaceInvite(url: URL(string:
            "https://jacobreed.dev/stride/race?name=Tokyo&date=2027-03-07&distance=marathon")!))

        for zone in ["Asia/Tokyo", "America/Los_Angeles", "Europe/London", "Pacific/Auckland"] {
            let local = calendar(zone)
            let raceDate = try #require(invite.raceDate(calendar: local))
            let parts = local.dateComponents([.year, .month, .day, .hour], from: raceDate)
            #expect(parts.year == 2027 && parts.month == 3 && parts.day == 7 && parts.hour == 0, "\(zone)")
        }
    }

    @Test func hasPassedComparesDays() throws {
        let utc = calendar("UTC")
        let invite = try #require(RaceInvite(url: URL(string:
            "stride://race?name=R&date=2027-06-01&distance=10k")!))
        #expect(!invite.hasPassed(now: date(2027, 5, 31, hour: 23, in: "UTC"), calendar: utc))
        #expect(!invite.hasPassed(now: date(2027, 6, 1, hour: 23, in: "UTC"), calendar: utc))
        #expect(invite.hasPassed(now: date(2027, 6, 2, in: "UTC"), calendar: utc))
    }

    // MARK: Names

    @Test func nameIsOneTidyLine() {
        #expect(RaceInvite.tidiedName("  Big \n\t Sur\u{0007}  Marathon ") == "Big Sur Marathon")
        #expect(RaceInvite.tidiedName("Run 👨‍👩‍👧 Fun") == "Run 👨‍👩‍👧 Fun")
        #expect(RaceInvite.tidiedName("Zürich") == "Zürich")
    }

    @Test func longNameIsCut() {
        let long = String(repeating: "a", count: 200)
        #expect(RaceInvite.tidiedName(long).count == RaceInvite.maxNameLength)
    }

    @Test func missingNameFallsBackToTheDistance() throws {
        let read = try #require(RaceInvite(url: URL(string:
            "https://jacobreed.dev/stride/race?date=2027-06-01&distance=half")!))
        #expect(read.name == RaceType.halfMarathon.displayName)

        let blank = try #require(RaceInvite(url: URL(string:
            "https://jacobreed.dev/stride/race?name=%20%20&date=2027-06-01&distance=half")!))
        #expect(blank.name == RaceType.halfMarathon.displayName)
    }

    @Test func nameWithReservedCharactersRoundTrips() throws {
        let invite = try #require(RaceInvite(
            name: "Run & Fun = 5K? #1 / 100%",
            raceType: .fiveK,
            raceDate: date(2027, 6, 1, in: "UTC"),
            calendar: calendar("UTC")
        ))
        #expect(RaceInvite(url: invite.webURL)?.name == "Run & Fun = 5K? #1 / 100%")
        #expect(RaceInvite(url: invite.appURL)?.name == "Run & Fun = 5K? #1 / 100%")
    }

    @Test func plusIsEncodedSoAWebPageDoesNotReadASpace() throws {
        let invite = try #require(RaceInvite(
            name: "C25K+",
            raceType: .fiveK,
            raceDate: date(2027, 6, 1, in: "UTC"),
            calendar: calendar("UTC")
        ))
        #expect(invite.webURL.absoluteString.contains("name=C25K%2B&"))
        #expect(RaceInvite(url: invite.webURL)?.name == "C25K+")
    }

    // MARK: Which links are invites

    @Test func recognisesBothSpellingsAndNothingElse() {
        let yes = [
            "https://jacobreed.dev/stride/race?date=2027-06-01&distance=5k",
            "https://www.jacobreed.dev/stride/race/?date=2027-06-01&distance=5k",
            "HTTPS://JacobReed.dev/stride/race?date=2027-06-01&distance=5k",
            "stride://race?date=2027-06-01&distance=5k",
        ]
        let no = [
            "https://jacobreed.dev/stride?date=2027-06-01&distance=5k",
            "https://jacobreed.dev/stride/race/extra?date=2027-06-01&distance=5k",
            "http://jacobreed.dev/stride/race?date=2027-06-01&distance=5k",
            "https://example.com/stride/race?date=2027-06-01&distance=5k",
            "stride://active-run",
            "stride://plan",
        ]
        for text in yes { #expect(RaceInvite.isInviteURL(URL(string: text)!), "\(text)") }
        for text in no { #expect(!RaceInvite.isInviteURL(URL(string: text)!), "\(text)") }
    }

    // MARK: Refusals

    @Test func refusesWhatAnInviteCannotSay() {
        let bad = [
            "stride://race?distance=5k",                          // no date
            "stride://race?date=2027-06-01",                      // no distance
            "stride://race?date=2027-02-30&distance=5k",          // not a day
            "stride://race?date=2027-13-01&distance=5k",
            "stride://race?date=27-06-01&distance=5k",
            "stride://race?date=2027-6-1&distance=5k",
            "stride://race?date=1999-06-01&distance=5k",          // outside the year range
            "stride://race?date=2027-06-01&distance=ultra",       // unknown distance
            "stride://race?date=2027-06-01&distance=500",         // custom too short
            "stride://race?date=2027-06-01&distance=900000",      // custom too long
            "stride://race?date=2027-06-01&distance=-5000",
            "stride://race?date=2027-06-01&distance=5e3",
        ]
        for text in bad { #expect(RaceInvite(url: URL(string: text)!) == nil, "\(text)") }
    }

    @Test func maintainFitnessIsNotARace() {
        #expect(RaceInvite(
            name: "Fitness",
            raceType: .maintainFitness,
            raceDate: date(2027, 6, 1, in: "UTC"),
            calendar: calendar("UTC")
        ) == nil)
    }

    @Test func customWithoutADistanceIsRefused() {
        #expect(RaceInvite(
            name: "Mystery",
            raceType: .custom,
            raceDate: date(2027, 6, 1, in: "UTC"),
            calendar: calendar("UTC")
        ) == nil)
    }

    @Test func distanceSlugIgnoresCase() throws {
        let read = try #require(RaceInvite(url: URL(string:
            "stride://race?date=2027-06-01&distance=Marathon")!))
        #expect(read.raceType == .marathon)
    }
}
