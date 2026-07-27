import XCTest

/// Walks the app end to end and captures a screenshot of every primary screen, so a UX
/// pass can be done by reading images rather than by driving the simulator by hand.
///
/// This is a capture harness, not an assertion suite — `StrideUITests` owns the
/// behavioural checks. It fails only when it cannot *reach* a screen, because a shot it
/// never took is the one thing a reviewer cannot notice is missing.
///
/// Run it:
/// ```
/// xcodebuild test -scheme Stride -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:StrideUITests/UXCaptureTests
/// ```
/// Screenshots land as attachments in the resulting `.xcresult`. To get loose PNGs
/// instead — easier to flip through, and diffable between runs — point `UX_CAPTURE_DIR`
/// at a directory in the scheme's test-action environment, or:
/// ```
/// xcodebuild test ... UX_CAPTURE_DIR=/tmp/ux
/// ```
final class UXCaptureTests: XCTestCase {

    private var app: XCUIApplication!
    private var shotIndex = 0

    /// Set `UX_CAPTURE_DIR` to also write loose PNGs there. Unset, shots are attachments
    /// only, which is what CI wants — a test that writes to a hardcoded path fails on
    /// any machine but the one it was written on.
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["UX_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        // A capture run should keep going after a missed screen and collect the rest,
        // rather than stopping at the first one and leaving the reviewer with a
        // partial set they might mistake for the whole app.
        continueAfterFailure = true

        if let outputDirectory {
            try? FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true
            )
        }

        app = XCUIApplication()
        // `--seed-demo-data` matters as much as `--uitesting` here: without it every
        // chart and list renders its empty state and the pass sees nothing.
        app.launchArguments = ["--uitesting", "--seed-demo-data"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Capture

    private func capture(_ name: String) {
        shotIndex += 1
        let filename = String(format: "%02d-%@", shotIndex, name)
        let data = XCUIScreen.main.screenshot().pngRepresentation

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)

        if let outputDirectory {
            try? data.write(to: outputDirectory.appendingPathComponent("\(filename).png"))
        }
    }

    // MARK: - Navigation

    /// Tab-bar geometry as a fraction of the screen, because the bar cannot be matched
    /// by label alone: the iOS 26+ floating bar minimises on scroll-down, and while
    /// minimised its buttons are not hittable even though they still resolve.
    /// ``scrollToTop()`` restores it before every switch.
    private static let tabOffsets: [String: CGFloat] = [
        "Home": 0.157, "Plan": 0.328, "History": 0.498,
        "Progress": 0.669, "Settings": 0.838
    ]

    private func scrollToTop() {
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        sleep(1)
    }

    private func selectTab(_ name: String) {
        guard let dx = Self.tabOffsets[name] else {
            return XCTFail("Unknown tab \(name)")
        }
        scrollToTop()
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.951)).tap()
    }

    // MARK: - The pass

    func testCaptureEveryScreen() throws {
        captureOnboarding()

        XCTAssertTrue(
            app.buttons["dashboard.startFreeRun"].waitForExistence(timeout: 20),
            "Never reached the dashboard — every shot after this one is missing"
        )
        sleep(2)
        captureScrollingScreen(named: "home")

        for tab in ["Plan", "History", "Progress", "Settings"] {
            selectTab(tab)
            sleep(2)
            captureScrollingScreen(named: "tab-\(tab.lowercased())")
        }

        captureRunHUD()
    }

    private func captureOnboarding() {
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Onboarding never appeared")
        capture("onboarding-welcome")
        getStarted.tap()

        // Titles are asserted so a reordered flow shows up as a failure here rather than
        // as a quietly mislabelled screenshot.
        let steps = [
            (1, "What are you training for?", "goal"),
            (2, "When's the big day?", "raceday"),
            (3, "How would you describe your running?", "level"),
            (4, "Your recent 5K time?", "5ktime"),
            (5, "Which days can you run?", "days"),
            (6, "What equipment do you have?", "equipment")
        ]
        for (step, title, slug) in steps {
            XCTAssertTrue(
                app.staticTexts[title].waitForExistence(timeout: 8),
                "Onboarding step \(step) did not show \"\(title)\""
            )
            capture("onboarding-\(step)-\(slug)")
            let button = app.buttons["onboarding.primaryCTA.\(step)"]
            if button.waitForExistence(timeout: 5) { button.tap() }
        }

        let skipPermissions = app.buttons["onboarding.secondaryCTA.7"]
        if skipPermissions.waitForExistence(timeout: 8) {
            capture("onboarding-7-permissions")
            skipPermissions.tap()
        }

        let startTraining = app.buttons["onboarding.startTraining"]
        if startTraining.waitForExistence(timeout: 8) {
            capture("onboarding-8-summary")
            startTraining.tap()
        }
    }

    /// Top, one screen down, and the far end — enough to catch content colliding with
    /// the tab bar and empty states that only appear below the fold.
    private func captureScrollingScreen(named name: String) {
        capture("\(name)-top")
        app.swipeUp(velocity: .slow)
        sleep(1)
        capture("\(name)-scrolled")
        app.swipeUp(velocity: .slow)
        sleep(1)
        capture("\(name)-bottom")
    }

    private func captureRunHUD() {
        selectTab("Home")
        sleep(1)
        let startFreeRun = app.buttons["dashboard.startFreeRun"]
        guard startFreeRun.waitForExistence(timeout: 8) else {
            return XCTFail("Could not reach the run HUD from the dashboard")
        }
        startFreeRun.tap()
        sleep(2)
        // Pre-start: no location permission and no GPS fix are needed to see the layout,
        // which is what this pass is checking.
        capture("run-hud")

        let close = app.buttons["activeRun.minimize"]
        if close.waitForExistence(timeout: 5) { close.tap() }
    }
}
