import XCTest

/// Captures the screenshots on the What's New sheet, one per headline feature of the
/// release (`ReleaseFeature.hasScreenshot` in `Stride/Core/Models/ReleaseNotes.swift`),
/// from the demo history.
///
/// Not part of the normal UI-test run: it does nothing unless `WHATS_NEW_CAPTURE_DIR` is
/// set, which only the What's New screenshots workflow does (passed to the runner as
/// `TEST_RUNNER_WHATS_NEW_CAPTURE_DIR`). Each PNG is named by its feature's `id`; the
/// workflow scales them down and writes them into `Stride/Resources/WhatsNew.xcassets`
/// as `whatsnew-<version>-<id>`. A feature added to the release needs a capture here
/// with the same id. `whats-new-sheet.png` is the sheet itself, for review only.
final class WhatsNewScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["WHATS_NEW_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        try XCTSkipIf(outputDirectory == nil, "WHATS_NEW_CAPTURE_DIR is not set")
        continueAfterFailure = true
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Captures

    func testCaptureProgressFeatures() throws {
        launchToHome()
        selectTab("Progress")
        capture("progress")

        let bestEfforts = app.descendants(matching: .any)["progress.bestEfforts"]
        if scrollTo(bestEfforts) {
            capture("best-efforts")
        } else {
            XCTFail("No best efforts card on Progress")
        }

        let fullScreen = app.buttons["progress.heatmap.fullScreen"]
        if scrollTo(fullScreen) {
            fullScreen.tap()
            // Tracing every demo route the first time takes a moment.
            sleep(6)
            capture("heatmap")
        } else {
            XCTFail("No heatmap card on Progress")
        }
    }

    func testCaptureRunFeatures() throws {
        launchToHome()
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
                capture("run-analysis")
                app.navigationBars["Run analysis"].buttons.element(boundBy: 0).tap()
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
        capture("share-studio")
    }

    func testCaptureTrainingBreak() throws {
        launchToHome()
        selectTab("Plan")
        let row = app.buttons["plan.trainingBreakRow"]
        guard scrollTo(row) else {
            return XCTFail("No 'Not feeling your best?' row on Plan")
        }
        row.tap()
        capture("training-break")
    }

    /// The sheet itself, for reviewing the layout. Not bundled.
    func testCaptureSheet() throws {
        launchToHome(extraArguments: ["--show-whats-new"])
        guard app.buttons["whatsNew.next"].waitForExistence(timeout: 10) else {
            return XCTFail("The What's New sheet did not open")
        }
        capture("whats-new-sheet")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        // Let entrance animations settle first.
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

    /// A fresh launch on the demo history, through onboarding on its defaults, to Home.
    private func launchToHome(extraArguments: [String] = []) {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seed-demo-data"] + extraArguments
        app.launch()
        // The first launch on a freshly booted simulator can fail ("Failed to launch");
        // one more try, so a cold simulator doesn't cost the capture.
        if app.state != .runningForeground {
            app.launch()
        }

        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Onboarding never appeared")
        getStarted.tap()
        for step in 1...6 {
            let button = app.buttons["onboarding.primaryCTA.\(step)"]
            if button.waitForExistence(timeout: 8) { button.tap() }
        }
        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        if skipPermissions.waitForExistence(timeout: 8) { skipPermissions.tap() }
        let startTraining = app.buttons["onboarding.startTraining"]
        if startTraining.waitForExistence(timeout: 8) { startTraining.tap() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20), "Never reached the tabs")
    }

    private func selectTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            sleep(1)
        } else {
            XCTFail("No \(name) tab")
        }
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
}
