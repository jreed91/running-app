import AppIntents
import SwiftData
import SwiftUI

struct TodaysRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Run"
    static let description = IntentDescription("See your scheduled run for today.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let container = try IntentDataProvider.makeContainer()
        let actor = IntentModelActor(modelContainer: container)
        let data = try await actor.todaysRun()
        return .result(dialog: IntentDialog(stringLiteral: Self.dialogText(for: data))) {
            TodaysRunIntentView(data: data)
        }
    }

    /// The spoken answer, worded by session kind (N13).
    ///
    /// `todaysRun()` falls back to a strength or cross-training day when nothing is
    /// scheduled to be run, so a single "You have a … run today." template announced
    /// a gym session as "You have a Strength run today". Non-run days get their own
    /// phrasing; only run types are called runs.
    static func dialogText(for data: TodaysRunData?) -> String {
        guard let data else { return "No run scheduled for today." }
        let name = data.workoutType.displayName
        switch data.workoutType.sessionKind {
        case .run:
            // "Long Run" and "Race" already name the session; appending "run" to them
            // produces the kind of sentence only a template writes.
            switch data.workoutType {
            case .longRun, .race: return "You have a \(name) today."
            default:              return "You have a \(name) run today."
            }
        case .strength:
            return "You have a \(name) session today."
        case .crossTraining:
            return "You have \(name.lowercased()) today."
        case .rest:
            return "Today is a rest day."
        }
    }
}
