import AppIntents

struct StrideShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodaysRunIntent(),
            phrases: [
                "What's my run today in \(.applicationName)",
                "Today's workout in \(.applicationName)",
                "Show my run in \(.applicationName)",
            ],
            shortTitle: "Today's Run",
            systemImageName: "figure.run"
        )
        AppShortcut(
            intent: WeeklySummaryIntent(),
            phrases: [
                "Show my weekly running summary in \(.applicationName)",
                "How far did I run this week in \(.applicationName)",
                "Weekly mileage in \(.applicationName)",
            ],
            shortTitle: "Weekly Summary",
            systemImageName: "chart.bar.fill"
        )
    }
}
