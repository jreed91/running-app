import Foundation
import Testing
@testable import StrideCore

/// Covers `ImportedWorkoutDetails`, what the strength summary says about a session
/// recorded on the Watch or in another app.
struct ImportedWorkoutDetailsTests {

    private func details(
        _ kind: ImportedWorkoutDetails.Kind = .traditionalStrength,
        source: String? = "Workout",
        heartRate: Double? = nil
    ) -> ImportedWorkoutDetails {
        ImportedWorkoutDetails(kind: kind, sourceName: source, averageHeartRate: heartRate)
    }

    @Test func titlesFollowTheHealthActivity() {
        #expect(details(.traditionalStrength).title == "Strength Training")
        #expect(details(.functionalStrength).title == "Functional Strength")
        #expect(details(.core).title == "Core Training")
        #expect(details(.other).title == "Strength Workout")
    }

    @Test func namesTheAppThatRecordedIt() {
        #expect(details(source: "Fitbod").recordedByText == "Recorded by Fitbod")
        #expect(details(source: "  ").recordedByText == nil)
        #expect(details(source: nil).recordedByText == nil)
    }

    @Test func doesNotCallStrideAnotherApp() {
        #expect(details(source: "Stride").recordedByText == nil)
    }

    @Test func roundsHeartRateAndHidesAMissingOne() {
        #expect(details(heartRate: 121.6).heartRateText == "122 bpm")
        #expect(details(heartRate: nil).heartRateText == nil)
        #expect(details(heartRate: 0).heartRateText == nil)
    }
}
