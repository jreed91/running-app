import AppIntents
import SwiftData
import SwiftUI

struct WeeklySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Weekly Running Summary"
    static let description = IntentDescription("See how far you've run this week.")
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
