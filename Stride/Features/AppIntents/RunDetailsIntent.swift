import AppIntents
import SwiftUI

/// Looks up the details of a specific run. Because `run` is a `RunWorkoutEntity`, Siri,
/// the Shortcuts app, and Apple Intelligence resolve it through the entity's query and
/// Spotlight index — so "get details of my long run on Saturday" works without opening
/// the app.
struct RunDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Run Details"
    static let description = IntentDescription(
        "Shows a finished run's type, date, distance, time and average pace, in the units set in Stride."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Run",
        description: "A finished run, found by its type, date or distance, such as last Saturday's long run."
    )
    var run: RunWorkoutEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get details for \(\.$run)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        return .result(dialog: "\(run.workoutTypeName): \(run.subtitle).") {
            RunDetailsIntentView(run: run)
        }
    }
}

extension RunDetailsIntent {
    /// Tells the system the runner just looked at this run, the behavioural cue Siri uses
    /// to pick between intents that could answer the same request (Siri AI Developer
    /// Preview, "Make actions discoverable"). Runs only: walks and rides aren't offered as
    /// runs anywhere else in the intents either (N38). Best-effort and fire-and-forget.
    @MainActor
    static func donateViewing(_ workout: RunWorkout, unit: UnitPreference) {
        guard workout.workoutType.countsAsRunning else { return }
        var intent = RunDetailsIntent()
        intent.run = workout.runWorkoutEntity(unit: unit)
        _ = IntentDonationManager.shared.donate(intent: intent)
    }
}
