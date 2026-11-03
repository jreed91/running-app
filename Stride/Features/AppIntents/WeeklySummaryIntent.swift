import AppIntents
import SwiftData
import SwiftUI

struct WeeklySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Weekly Running Summary"
    static let description = IntentDescription(
        "Says how far you have run this week, Monday to today, in kilometres or miles. Walks and rides are not counted."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let container = try IntentDataProvider.makeContainer()
        let actor = IntentModelActor(modelContainer: container)
        let data = try await actor.weeklySummary()
        let unit = await MainActor.run { AppSettings.syncedUnitPreference() }
        let formatted = data.totalMeters.distanceString(unit: unit)
        return .result(dialog: "You've run \(formatted) this week.") {
            WeeklySummaryIntentView(data: data)
        }
    }
}
