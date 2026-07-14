import AppIntents

/// Registers Stride's App Intents with the system so Siri (and the Shortcuts app,
/// Spotlight, and Action Button) can run them by voice or tap. `AppShortcutsProvider`
/// conformers are discovered automatically at launch — no manual registration needed.
struct StrideShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodaysRunIntent(),
            phrases: [
                "What's my run today in \(.applicationName)",
                "What's my workout today in \(.applicationName)",
                "Today's workout in \(.applicationName)",
                "Today's run in \(.applicationName)",
                "Show my run in \(.applicationName)",
                "What should I run in \(.applicationName)",
            ],
            shortTitle: "Today's Run",
            systemImageName: "figure.run"
        )
        AppShortcut(
            intent: WeeklySummaryIntent(),
            phrases: [
                "Show my weekly running summary in \(.applicationName)",
                "How far did I run this week in \(.applicationName)",
                "How many miles did I run this week in \(.applicationName)",
                "Weekly mileage in \(.applicationName)",
                "My running total in \(.applicationName)",
            ],
            shortTitle: "Weekly Summary",
            systemImageName: "chart.bar.fill"
        )
    }
}
