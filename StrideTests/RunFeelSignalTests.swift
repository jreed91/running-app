import Foundation
import Testing
@testable import Stride

/// Covers `RunFeel` storage and `RunFeelSignal`, the one reading of "how did that feel?"
/// that the coach read, the coach chat and plan adaptation all share.
@MainActor
struct RunFeelSignalTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func rating(_ type: WorkoutType, _ feel: RunFeel, daysAgo: Double = 1) -> RunFeelSignal.Rating {
        RunFeelSignal.Rating(date: now.addingTimeInterval(-daysAgo * 86_400), type: type, feel: feel)
    }

    // MARK: - Storage

    @Test("The rating round-trips through its raw value and clears to nil")
    func storageRoundTrip() {
        let context = TestStore.makeContext()
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_800)
        context.insert(run)
        #expect(run.feel == nil)
        #expect(run.feelRaw == nil)

        run.feel = .hard
        #expect(run.feelRaw == 4)
        #expect(run.feel == .hard)

        run.feel = nil
        #expect(run.feelRaw == nil)
    }

    @Test("A raw value outside the scale reads as unrated rather than as a guess")
    func unknownRawValueIsUnrated() {
        let context = TestStore.makeContext()
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_800)
        context.insert(run)
        run.feelRaw = 9
        #expect(run.feel == nil)
    }

    @Test("Raw values are the scale position, one to five")
    func rawValuesArePinned() {
        // Persisted: renumbering these would silently re-rate every stored run.
        #expect(RunFeel.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    // MARK: - One run

    @Test("An easy or long run that felt hard is harder than intended")
    func easyRunFeltHard() {
        #expect(RunFeelSignal.mismatch(feel: .hard, type: .easy) == .harderThanIntended)
        #expect(RunFeelSignal.mismatch(feel: .veryHard, type: .longRun) == .harderThanIntended)
        #expect(RunFeelSignal.mismatch(feel: .moderate, type: .easy) == nil)
        #expect(RunFeelSignal.mismatch(feel: .veryEasy, type: .longRun) == nil)
    }

    @Test("A tempo is judged from both sides")
    func tempoBothSides() {
        #expect(RunFeelSignal.mismatch(feel: .easy, type: .tempo) == .easierThanIntended)
        #expect(RunFeelSignal.mismatch(feel: .moderate, type: .tempo) == nil)
        #expect(RunFeelSignal.mismatch(feel: .hard, type: .tempo) == nil)
        #expect(RunFeelSignal.mismatch(feel: .veryHard, type: .tempo) == .harderThanIntended)
    }

    @Test("Intervals are meant to hurt, so only an easy rating stands out")
    func intervalsOnlyFlagEasy() {
        #expect(RunFeelSignal.mismatch(feel: .veryHard, type: .interval) == nil)
        #expect(RunFeelSignal.mismatch(feel: .easy, type: .interval) == .easierThanIntended)
    }

    @Test("A race and non-run types have no expected feel")
    func noExpectation() {
        for type in [WorkoutType.race, .rest, .crossTraining, .strength, .walk] {
            #expect(RunFeelSignal.expectedRange(for: type) == nil)
            #expect(RunFeelSignal.mismatch(feel: .veryHard, type: type) == nil)
            #expect(RunFeelSignal.mismatch(feel: .veryEasy, type: type) == nil)
        }
    }

    @Test("The run sentence names the run, so the type and the rating never run together")
    func runSentenceNamesTheRun() {
        #expect(RunFeelSignal.runSentence(feel: .easy, type: .easy)
            == "You rated this easy run easy, about what it was meant to feel like.")
        #expect(RunFeelSignal.runSentence(feel: .hard, type: .longRun).hasPrefix("You rated this long run hard"))
        #expect(RunFeelSignal.runSentence(feel: .hard, type: .race).hasPrefix("You rated this race hard"))
    }

    @Test("Only a mismatched rating adds a focus item")
    func focusOnlyOnMismatch() {
        #expect(RunFeelSignal.runFocus(feel: .hard, type: .easy) != nil)
        #expect(RunFeelSignal.runFocus(feel: .easy, type: .tempo) != nil)
        #expect(RunFeelSignal.runFocus(feel: .moderate, type: .easy) == nil)
    }

    @Test("History rows carry the rating only when there is one")
    func historySuffix() {
        #expect(RunFeelSignal.historySuffix(for: nil) == "")
        #expect(RunFeelSignal.historySuffix(for: .hard) == " | felt hard (4 of 5)")
    }

    // MARK: - The trend

    @Test("One hard easy run is not a trend")
    func singleRatingIsNotATrend() {
        let ratings = [
            rating(.easy, .hard, daysAgo: 1),
            rating(.easy, .easy, daysAgo: 2),
            rating(.tempo, .hard, daysAgo: 3)
        ]
        #expect(RunFeelSignal.trendSentence(ratings, now: now) == nil)
    }

    @Test("Two easy runs that felt hard read as fatigue")
    func twoHardEasyRunsIsFatigue() throws {
        let ratings = [
            rating(.easy, .hard, daysAgo: 1),
            rating(.longRun, .veryHard, daysAgo: 3),
            rating(.tempo, .hard, daysAgo: 5)
        ]
        let sentence = try #require(RunFeelSignal.trendSentence(ratings, now: now))
        #expect(sentence.contains("2 of the runner's last 3 rated runs felt harder"))
        #expect(sentence.contains("fatigue"))
    }

    @Test("Two quality sessions that felt easy suggest soft paces")
    func twoEasyQualitySessions() throws {
        let ratings = [
            rating(.tempo, .easy, daysAgo: 2),
            rating(.interval, .veryEasy, daysAgo: 6)
        ]
        let sentence = try #require(RunFeelSignal.trendSentence(ratings, now: now))
        #expect(sentence.contains("felt easier"))
        #expect(!sentence.contains("harder"))
    }

    @Test("Only the newest ratings in the window count, in any input order")
    func windowTakesNewest() {
        // Two old hard easy runs, pushed out of the five-run window by five newer, normal ones.
        let normal = (1...RunFeelSignal.trendWindow).map { rating(.easy, .easy, daysAgo: Double($0)) }
        let old = [rating(.easy, .veryHard, daysAgo: 8), rating(.easy, .veryHard, daysAgo: 9)]
        #expect(RunFeelSignal.trendSentence(old + normal, now: now) == nil)
        #expect(RunFeelSignal.trendSentence(Array((old + normal).reversed()), now: now) == nil)
    }

    @Test("Ratings older than the age limit are ignored")
    func staleRatingsIgnored() {
        let stale = Double(RunFeelSignal.trendMaxAgeDays + 1)
        let ratings = [
            rating(.easy, .hard, daysAgo: stale),
            rating(.easy, .veryHard, daysAgo: stale + 2)
        ]
        #expect(RunFeelSignal.trendSentence(ratings, now: now) == nil)
    }

    // MARK: - Prompt section

    @Test("The adaptation prompt section says so when nothing is rated")
    func sectionWithNoRatings() {
        let context = TestStore.makeContext()
        let run = RunWorkout(date: now.addingTimeInterval(-86_400), distanceMeters: 5_000, durationSeconds: 1_800)
        context.insert(run)

        let section = AICoachService.feelTrendSection([run], now: now)
        #expect(section.hasPrefix("How recent runs felt:\n"))
        #expect(section.contains("has not rated"))
    }

    @Test("The section reads the fatigue trend from rated runs, with walks left out")
    func sectionReadsTrendAndSkipsWalks() {
        let context = TestStore.makeContext()
        func makeRun(_ type: WorkoutType, _ feel: RunFeel, daysAgo: Double) -> RunWorkout {
            let run = RunWorkout(
                date: now.addingTimeInterval(-daysAgo * 86_400),
                distanceMeters: 5_000,
                durationSeconds: 1_800,
                workoutType: type
            )
            run.feel = feel
            context.insert(run)
            return run
        }

        let hardEasyRuns = [makeRun(.easy, .hard, daysAgo: 8), makeRun(.easy, .veryHard, daysAgo: 9)]
        #expect(AICoachService.feelTrendSection(hardEasyRuns, now: now).contains("felt harder"))

        // Five newer rated walks would push both runs out of the window if they counted.
        let walks = (1...RunFeelSignal.trendWindow).map { makeRun(.walk, .easy, daysAgo: Double($0)) }
        #expect(AICoachService.feelTrendSection(walks + hardEasyRuns, now: now).contains("felt harder"))

        let oneHard = [makeRun(.easy, .hard, daysAgo: 1), makeRun(.easy, .easy, daysAgo: 2)]
        #expect(AICoachService.feelTrendSection(oneHard, now: now).contains("in line with"))
    }

    @Test("A run that fulfilled a plan day is judged against the day's type")
    func intendedTypeComesFromThePlan() throws {
        let context = TestStore.makeContext()
        // Recorded as easy, but the day asked for a tempo: "hard" is on target for that.
        let scheduled = ScheduledWorkout(scheduledDate: now, workoutType: .tempo)
        let run = RunWorkout(date: now, distanceMeters: 8_000, durationSeconds: 2_400, workoutType: .easy)
        run.scheduledWorkout = scheduled
        scheduled.completedWorkout = run
        context.insert(scheduled)
        context.insert(run)

        run.feel = .hard
        #expect(run.intendedWorkoutType == .tempo)
        let rating = try #require(run.feelRating)
        #expect(rating.type == .tempo)
        #expect(RunFeelSignal.mismatch(feel: rating.feel, type: rating.type) == nil)
    }

    @Test("An unlinked run is judged against its own type")
    func intendedTypeFallsBackToTheRun() {
        let context = TestStore.makeContext()
        let run = RunWorkout(distanceMeters: 5_000, durationSeconds: 1_800, workoutType: .longRun)
        context.insert(run)
        #expect(run.intendedWorkoutType == .longRun)
        #expect(run.feelRating == nil)
    }
}
