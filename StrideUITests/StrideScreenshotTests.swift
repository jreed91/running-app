import XCTest

/// Walks the app and attaches a screenshot of every screen a first-run user sees, so a
/// reviewer (or an agent) can look at the real rendered UI rather than reading SwiftUI.
/// These tests assert almost nothing — they exist to produce artefacts.
final class StrideScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var shotIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        shotIndex = 0
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testCaptureOnboardingScreens() throws {
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
        capture("onboarding-00-welcome")
        getStarted.tap()

        let steps = [
            "What are you training for?",
            "When's the big day?",
            "How would you describe your running?",
            "Your recent 5K time?",
            "Which days can you run?",
            "What equipment do you have?"
        ]

        for (offset, title) in steps.enumerated() {
            let step = offset + 1
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8))
            capture("onboarding-0\(step)-step\(step)")
            app.buttons["onboarding.primaryCTA.\(step)"].tap()
        }

        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        XCTAssertTrue(skipPermissions.waitForExistence(timeout: 8))
        capture("onboarding-07-permissions")
        skipPermissions.tap()

        let startTraining = app.buttons["onboarding.startTraining"]
        XCTAssertTrue(startTraining.waitForExistence(timeout: 8))
        capture("onboarding-08-ready")
        startTraining.tap()

        XCTAssertTrue(app.tabBars["main.tabs"].waitForExistence(timeout: 15))
        capture("onboarding-09-landing")
    }

    func testCaptureMainTabs() throws {
        completeOnboarding()

        for (tab, prefix) in [("Home", "home"), ("Plan", "plan"), ("History", "history"),
                              ("Progress", "progress"), ("Settings", "settings")] {
            let button = tabButton(tab)
            XCTAssertTrue(button.waitForExistence(timeout: 8), "no tab button for \(tab)")
            button.tap()
            sleep(2)
            capture("\(prefix)-01-top")
        }
    }

    func testCaptureActiveRunHUD() throws {
        completeOnboarding()

        tabButton("Home").tap()
        let startFreeRun = app.buttons["dashboard.startFreeRun"]
        XCTAssertTrue(startFreeRun.waitForExistence(timeout: 8))
        startFreeRun.tap()

        XCTAssertTrue(app.buttons["activeRun.finish"].waitForExistence(timeout: 8))
        sleep(2)
        capture("run-01-hud")
        scrollDown()
        capture("run-02-hud-scrolled")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        shotIndex += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%02d-%@", shotIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
    }

    private func scrollUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
    }

    private func tabButton(_ label: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[label]
        return inTabBar.exists ? inTabBar : app.buttons[label]
    }

    private func completeOnboarding() {
        let getStarted = app.buttons["onboarding.getStarted"]
        guard getStarted.waitForExistence(timeout: 10) else { return }
        getStarted.tap()

        for step in 1...6 {
            let button = app.buttons["onboarding.primaryCTA.\(step)"]
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            button.tap()
        }
        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        XCTAssertTrue(skipPermissions.waitForExistence(timeout: 8))
        skipPermissions.tap()
        app.buttons["onboarding.startTraining"].tap()
        XCTAssertTrue(app.buttons["dashboard.startFreeRun"].waitForExistence(timeout: 20))
    }
}
