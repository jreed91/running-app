import XCTest

final class StrideUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Matched by *type*, not by identifier. `MainTabView` sets
    /// `.accessibilityIdentifier("main.tabs")` on the `TabView`, and as of iOS 27 that
    /// lands on the container rather than on the tab bar element the system builds from
    /// it — `app.tabBars["main.tabs"]` matches nothing, while the bar itself is present
    /// with an empty identifier. There is only ever one tab bar on screen, so the type
    /// alone is unambiguous.
    private var tabBar: XCUIElement { app.tabBars.firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testE2EOnboardingCreatesTrainingPlanAndDashboard() throws {
        completeOnboarding()

        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        // By identifier: the eyebrow's `.textCase(.uppercase)` may change the label's case.
        XCTAssertTrue(app.staticTexts["dashboard.thisWeekHeader"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dashboard.startFreeRun"].waitForExistence(timeout: 5))

        tabBar.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars["My Plan"].waitForExistence(timeout: 5))
        // By identifier: pace insights is a row that opens its own page, and the weeks
        // header reads "All weeks" once the current week is shown above it.
        XCTAssertTrue(app.buttons["plan.paceInsightsRow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["plan.weeksHeader"].waitForExistence(timeout: 5))

        // The row's page reads Plan's queries, so open it: a lazily built page would read
        // them outside the view's body.
        let paceRow = app.buttons["plan.paceInsightsRow"]
        for _ in 0..<5 where !paceRow.isHittable {
            app.swipeUp()
        }
        paceRow.tap()
        XCTAssertTrue(app.navigationBars["Pace Insights"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testE2ETabNavigationShowsPrimaryScreens() throws {
        completeOnboarding()

        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))

        assertTab("Home", showsNavigationTitle: "Home")
        assertTab("Plan", showsNavigationTitle: "My Plan")
        assertTab("History", showsNavigationTitle: "History")
        assertTab("Progress", showsNavigationTitle: "Progress")
        assertTab("Settings", showsNavigationTitle: "Settings")
    }

    func testE2EFreeRunHUDOpensFromDashboard() throws {
        completeOnboarding()

        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        tabBar.buttons["Home"].tap()

        let startFreeRun = app.buttons["dashboard.startFreeRun"]
        XCTAssertTrue(startFreeRun.waitForExistence(timeout: 5))
        startFreeRun.tap()

        XCTAssertTrue(app.staticTexts["EASY ZONE"].waitForExistence(timeout: 5))
        // Each metric cell is a single accessibility element now, so its inner
        // "DISTANCE"/"TIME" labels are no longer separate static texts (N18). Match on
        // the cell identifiers instead, and check the finish control is a real button.
        XCTAssertTrue(app.descendants(matching: .any)["activeRun.metric.Distance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["activeRun.metric.Time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["activeRun.finish"].waitForExistence(timeout: 5))
    }

    /// The HUD used to have no way out but Finish or Discard, so opening it by mistake
    /// meant saving or throwing away a run to get back (U7). Before a run starts there is
    /// no session to minimise, so the control closes outright — that is the path here,
    /// because starting one would need location permission and a GPS fix.
    func testRunHUDClosesBeforeTheRunStarts() throws {
        completeOnboarding()

        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        tabBar.buttons["Home"].tap()

        let startFreeRun = app.buttons["dashboard.startFreeRun"]
        XCTAssertTrue(startFreeRun.waitForExistence(timeout: 5))
        startFreeRun.tap()

        let close = app.buttons["activeRun.minimize"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        XCTAssertTrue(startFreeRun.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
    }

    /// Each of a run's Breakdown rows opens its page. The pages read the run screen's
    /// environment and state, and building them in a lazy destination (outside the screen's
    /// body) crashed the app on device.
    func testBreakdownRowOpensItsPage() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seed-demo-data"]
        app.launch()
        completeOnboarding()

        XCTAssertTrue(tabBar.buttons["History"].waitForExistence(timeout: 5))
        tabBar.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        // Not `app.cells.firstMatch`: the list opens with the month hero, which is a cell
        // too. The newest demo run is an outdoor long run, so it has splits at least.
        let firstRun = app.descendants(matching: .any).matching(identifier: "history.run").firstMatch
        XCTAssertTrue(firstRun.waitForExistence(timeout: 10), "The demo history has no runs")
        firstRun.tap()

        let rows = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "runSummary.breakdown."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "The run has no Breakdown rows")
        let titles = [
            "plannedWorkout": "Planned workout", "splits": "Splits",
            "heartRateZones": "Heart-rate zones", "laps": "Laps", "paceInsights": "Pace insights"
        ]
        // Every row, not just the first: each page reads different state, and the first
        // fix only made the first one open.
        let identifiers = rows.allElementsBoundByIndex.map { $0.identifier }
        for identifier in identifiers {
            let row = app.buttons[identifier]
            for _ in 0..<5 where !row.isHittable {
                app.swipeUp()
            }
            let page = String(identifier.dropFirst("runSummary.breakdown.".count))
            let title = try XCTUnwrap(titles[page], "Unknown Breakdown row \(identifier)")
            row.tap()

            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "\(title) did not open")
            XCTAssertEqual(app.state, .runningForeground, "\(title) crashed the app")
            bar.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Did not come back from \(title)")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func completeOnboarding() {
        if tabBar.waitForExistence(timeout: 1) {
            return
        }

        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 8))
        getStarted.tap()

        // Eight steps, not nine: units moved onto "About you" as a pre-set control, since
        // the device already knows the answer (U10). The default goal is a 5K, so the
        // timing step asks about race day rather than a start date.
        tapPrimaryCTA(step: 1, expectedTitle: "What are you training for?")
        tapPrimaryCTA(step: 2, expectedTitle: "When's the big day?")
        tapPrimaryCTA(step: 3, expectedTitle: "How would you describe your running?")
        tapPrimaryCTA(step: 4, expectedTitle: "Your recent 5K time?")
        tapPrimaryCTA(step: 5, expectedTitle: "Which days can you run?")
        tapPrimaryCTA(step: 6, expectedTitle: "What equipment do you have?")

        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        XCTAssertTrue(skipPermissions.waitForExistence(timeout: 5))
        skipPermissions.tap()

        let startTraining = app.buttons["onboarding.startTraining"]
        XCTAssertTrue(startTraining.waitForExistence(timeout: 5))
        startTraining.tap()

        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
    }

    private func tapPrimaryCTA(step: Int, expectedTitle: String) {
        XCTAssertTrue(app.staticTexts[expectedTitle].waitForExistence(timeout: 5))
        let button = app.buttons["onboarding.primaryCTA.\(step)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    private func assertTab(_ tabLabel: String, showsNavigationTitle title: String) {
        XCTAssertTrue(tabBar.buttons[tabLabel].waitForExistence(timeout: 5))
        tabBar.buttons[tabLabel].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(tabLabel) did not show \(title)")
    }
}
