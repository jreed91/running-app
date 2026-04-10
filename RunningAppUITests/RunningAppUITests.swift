import XCTest

final class RunningAppUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    // MARK: Onboarding

    func testOnboardingFlowCompletesSuccessfully() throws {
        // If already onboarded the home tab appears directly
        if app.tabBars.firstMatch.exists { return }

        // Step 1: name
        let nameField = app.textFields["Runner name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Test Runner")
        app.buttons["Next"].tap()

        // Step 2: race goal
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 3))
        app.buttons["Next"].tap()

        // Step 3: fitness level
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 3))
        app.buttons["Next"].tap()

        // Step 4: run days → start
        XCTAssertTrue(app.buttons["Start Training"].waitForExistence(timeout: 3))
        app.buttons["Start Training"].tap()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Tab navigation

    func testAllTabsAreAccessible() throws {
        guard app.tabBars.firstMatch.waitForExistence(timeout: 5) else {
            try XCTSkip("Onboarding not completed — run onboarding test first")
        }
        let tabBar = app.tabBars.firstMatch
        for label in ["Home", "Plan", "History", "Progress", "Settings"] {
            tabBar.buttons[label].tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 3),
                          "\(label) tab nav bar missing")
        }
    }
}
