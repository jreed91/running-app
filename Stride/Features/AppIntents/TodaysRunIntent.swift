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
        guard let data else {
            return String(localized: "No run scheduled for today.", comment: "Siri answer with nothing planned")
        }
        let name = data.workoutType.localizedName
        switch data.workoutType.sessionKind {
        case .run:
            // "Long Run" and "Race" already name the session; appending "run" to them
            // produces the kind of sentence only a template writes.
            switch data.workoutType {
            case .longRun, .race:
                return String(localized: "You have a \(name) today.", comment: "Siri answer for a long run or race")
            default:
                return String(localized: "You have a \(name) run today.", comment: "Siri answer for a run")
            }
        case .walk:
            return String(localized: "You have a \(name.lowercased()) today.", comment: "Siri answer for a walk")
        case .strength:
            return String(localized: "You have a \(name) session today.", comment: "Siri answer for a strength session")
        case .crossTraining:
            return String(localized: "You have \(name.lowercased()) today.", comment: "Siri answer for a cross-training day")
        case .rest:
            return String(localized: "Today is a rest day.", comment: "Siri answer for a rest day")
        }
    }
}
