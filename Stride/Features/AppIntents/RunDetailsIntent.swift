import AppIntents
import SwiftUI

/// Looks up the details of a specific run. Because `run` is a `RunWorkoutEntity`, Siri,
/// the Shortcuts app, and Apple Intelligence resolve it through the entity's query and
/// Spotlight index — so "get details of my long run on Saturday" works without opening
/// the app.
struct RunDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Run Details"
    static let description = IntentDescription("Look up the details of one of your runs.")
    static let openAppWhenRun = false

    @Parameter(title: "Run")
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
