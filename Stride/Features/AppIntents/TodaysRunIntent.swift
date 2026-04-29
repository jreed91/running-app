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
        return .result(dialog: Self.dialog(for: data)) {
            TodaysRunIntentView(data: data)
        }
    }

    private static func dialog(for data: TodaysRunData?) -> IntentDialog {
        guard let data else { return "No run scheduled for today." }
        return "You have a \(data.workoutType.displayName) run today."
    }
}
