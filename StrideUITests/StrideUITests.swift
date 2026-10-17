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
