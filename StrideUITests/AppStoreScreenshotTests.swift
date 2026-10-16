import XCTest

/// Captures the raw iPhone screens for the App Store listing, in listing order, from the
/// demo history.
///
/// Not part of the normal UI-test run: it does nothing unless `APP_STORE_CAPTURE_DIR` is
/// set, which only the App Store screenshots workflow does (pass it to the test runner as
/// `TEST_RUNNER_APP_STORE_CAPTURE_DIR`). The PNGs land there as `NN-name.png`;
/// `design/appstore/compose.mjs` then frames each one with its caption. Run it on the
/// largest iPhone simulator (6.9", 1320 × 2868) with the status bar overridden to 9:41.
///
/// Navigation is `UXCaptureTests`' own — the onboarding CTAs and the tab-bar offsets —
/// so a layout change that breaks one breaks both, visibly.
final class AppStoreScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["APP_STORE_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        try XCTSkipIf(outputDirectory == nil, "APP_STORE_CAPTURE_DIR is not set")
        continueAfterFailure = true
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-demo-data"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func capture(_ name: String) {
        // Let entrance animations (the route drawing in, rings filling) settle first.
        sleep(2)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let outputDirectory {
            try? data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        }
    }

    private static let tabOffsets: [String: CGFloat] = [
        "Home": 0.157, "Plan": 0.328, "History": 0.498,
        "Progress": 0.669, "Settings": 0.838
    ]

    private func selectTab(_ name: String) {
        guard let dx = Self.tabOffsets[name] else { return XCTFail("Unknown tab \(name)") }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.951)).tap()
    }

    func testCaptureAppStoreScreens() throws {
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Onboarding never appeared")
        capture("06-welcome")
        getStarted.tap()

        // Through onboarding on its defaults, as UXCaptureTests does.
        for step in 1...6 {
            let button = app.buttons["onboarding.primaryCTA.\(step)"]
            if button.waitForExistence(timeout: 8) { button.tap() }
        }
        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        if skipPermissions.waitForExistence(timeout: 8) { skipPermissions.tap() }
        let startTraining = app.buttons["onboarding.startTraining"]
        if startTraining.waitForExistence(timeout: 8) { startTraining.tap() }

        XCTAssertTrue(
            app.buttons["dashboard.startFreeRun"].waitForExistence(timeout: 20),
            "Never reached Home"
        )
        capture("02-home")

        selectTab("Plan")
        capture("01-plan")

        selectTab("History")
        capture("04-history")

        selectTab("Progress")
        capture("05-progress")

        selectTab("Home")
        sleep(1)
        let startFreeRun = app.buttons["dashboard.startFreeRun"]
        if startFreeRun.waitForExistence(timeout: 8) {
            startFreeRun.tap()
            capture("03-run")
        } else {
            XCTFail("Could not reach the run screen from Home")
        }
    }
}
