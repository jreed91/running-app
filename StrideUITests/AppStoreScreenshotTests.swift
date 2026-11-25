import XCTest

/// Captures the raw iPhone screens for the App Store listing, in listing order, from the
/// demo history.
///
/// Not part of the normal UI-test run: it does nothing unless `APP_STORE_CAPTURE_DIR` is
/// set, which only the App Store screenshots workflow does (pass it to the test runner as
/// `TEST_RUNNER_APP_STORE_CAPTURE_DIR`). The PNGs land there as `NN-name.png`;
/// `design/appstore/compose.mjs` then frames each one with its caption. Run it on the
/// largest iPhone simulator (6.9", 1320 × 2868) with the status bar overridden to 9:41,
/// and again on the iPhone Duo simulator, closed (outer display, 1398 × 2034) and
/// opened (inner display, 2007 × 2853).
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

    // Four tabs since Settings became a sheet from Home: the same bar, quartered.
    private static let tabOffsets: [String: CGFloat] = [
        "Home": 0.178, "Plan": 0.391, "History": 0.604, "Progress": 0.817
    ]

    /// The offsets only hold on an iPhone-shaped screen. The iPhone Duo's displays are
    /// wider (its inner one is regular width, where the tab bar is not at the bottom), so
    /// there the tab is found by its label.
    private var hasPhoneShapedScreen: Bool {
        let frame = app.windows.firstMatch.frame
        return frame.height > 0 && frame.width / frame.height < 0.6
    }

    private func selectTab(_ name: String) {
        guard let dx = Self.tabOffsets[name] else { return XCTFail("Unknown tab \(name)") }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        sleep(1)
        if hasPhoneShapedScreen {
            app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.951)).tap()
            return
        }
        let tab = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            XCTFail("No \(name) tab")
        }
    }

    /// Through onboarding on its defaults, as UXCaptureTests does, to Home.
    private func completeOnboarding(capturingWelcome: Bool) {
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Onboarding never appeared")
        if capturingWelcome { capture("06-welcome") }
        getStarted.tap()

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
    }

    func testCaptureAppStoreScreens() throws {
        completeOnboarding(capturingWelcome: true)
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

    /// The 1.2 features for the listing: the heatmap full screen, best efforts, run
    /// analysis and the share studio. The same paths as `WhatsNewScreenshotTests`, at full
    /// size for framing. One launch per feature, so a miss in one doesn't cost the rest.
    func testCaptureHeatmap() throws {
        relaunchToHome()
        selectTab("Progress")
        // The card holds the map back until asked, unless it was shown before.
        let showMap = app.buttons["Show the map"]
        if showMap.waitForExistence(timeout: 5) {
            showMap.tap()
        }
        let fullScreen = app.buttons["progress.heatmap.fullScreen"]
        guard scrollTo(fullScreen) else {
            return XCTFail("No heatmap card on Progress")
        }
        fullScreen.tap()
        // Tracing every demo route, then the picture's draw-in.
        sleep(6)
        capture("08-heatmap")
    }

    func testCaptureBestEfforts() throws {
        relaunchToHome()
        selectTab("Progress")
        let bestEfforts = app.descendants(matching: .any)["progress.bestEfforts"]
        guard scrollIntoView(bestEfforts) else {
            return XCTFail("No best efforts card on Progress")
        }
        capture("09-best-efforts")
    }

    func testCaptureRunAnalysisAndShareStudio() throws {
        relaunchToHome()
        selectTab("History")
        let newestRun = app.buttons["history.run"].firstMatch
        guard newestRun.waitForExistence(timeout: 10) else {
            return XCTFail("No run in History")
        }
        newestRun.tap()

        let analysis = app.buttons["runSummary.breakdown.analysis"]
        if scrollTo(analysis) {
            analysis.tap()
            if app.navigationBars["Run analysis"].waitForExistence(timeout: 8) {
                capture("10-run-analysis")
                goBack(from: "Run analysis")
            } else {
                XCTFail("Run analysis did not open")
            }
        } else {
            XCTFail("The newest run has no Run analysis row")
        }

        let actions = app.buttons["runSummary.actions"]
        guard actions.waitForExistence(timeout: 8) else {
            return XCTFail("No run actions menu")
        }
        actions.tap()
        let share = app.buttons["runSummary.shareCard"].exists
            ? app.buttons["runSummary.shareCard"]
            : app.buttons["Share run card"]
        guard share.waitForExistence(timeout: 5) else {
            return XCTFail("No Share run card in the actions menu")
        }
        share.tap()
        // The cards render after the studio opens.
        sleep(3)
        capture("11-share-studio")
    }

    /// A fresh launch on the demo history, through onboarding, to Home.
    private func relaunchToHome() {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seed-demo-data"]
        app.launch()
        completeOnboarding(capturingWelcome: false)
    }

    /// Swipes up until `element` can be tapped. Returns whether it got there.
    @discardableResult
    private func scrollTo(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<12 where !element.isHittable {
            app.swipeUp(velocity: .slow)
        }
        return element.isHittable
    }

    /// Swipes up until `element` sits in the upper part of the screen, for a capture
    /// rather than a tap. Returns whether it got on screen at all.
    ///
    /// Not `isHittable`: on the iPhone Duo's outer display the toolbar stacks down the
    /// side of the screen, over the left edge where a card's title sits, so the title is
    /// never hittable however far the page scrolls.
    @discardableResult
    private func scrollIntoView(_ element: XCUIElement) -> Bool {
        let screen = app.windows.firstMatch.frame
        func top() -> CGFloat? {
            guard element.exists, !element.frame.isEmpty,
                  screen.intersects(element.frame) else { return nil }
            return element.frame.minY
        }
        for _ in 0..<20 {
            if let minY = top(), minY < screen.minY + screen.height * 0.4 { return true }
            app.swipeUp(velocity: .slow)
        }
        return top() != nil
    }

    /// Back from a breakdown page to the run. The page opens in place with its own Back
    /// button, and on the iPhone Duo that button stacks down the side of the display
    /// rather than sitting in the navigation bar, so it's found anywhere on screen.
    private func goBack(from title: String) {
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        } else {
            XCTFail("No Back button on \(title)")
        }
        if !app.navigationBars[title].waitForNonExistence(timeout: 5) {
            XCTFail("Could not leave \(title)")
        }
    }

    /// The run's AI coach page, from a separate launch so the screens above keep AI Coach
    /// off as before. A CI simulator has no Apple Intelligence, so `--seed-coach-read`
    /// turns the coach on and stores a sample read on the newest run (see
    /// `DemoDataSeed.coachRead(metric:)`). Raw only: it has no App Store caption, so
    /// `compose.mjs` leaves it unframed. It feeds the Stride landing page.
    func testCaptureCoachScreen() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seed-demo-data", "--seed-coach-read"]
        app.launch()
        completeOnboarding(capturingWelcome: false)

        selectTab("History")
        let newestRun = app.buttons["history.run"].firstMatch
        guard newestRun.waitForExistence(timeout: 10) else {
            return XCTFail("No run in History")
        }
        newestRun.tap()

        let coachCard = app.buttons["runSummary.coachCard"]
        for _ in 0..<4 where !coachCard.isHittable {
            app.swipeUp(velocity: .slow)
        }
        guard coachCard.waitForExistence(timeout: 10) else {
            return XCTFail("The run had no coach card; the seeded read did not load")
        }
        coachCard.tap()
        capture("07-coach")
    }
}
