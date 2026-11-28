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
/// CI runs it with the other UI tests and uploads every shot as the `app-screenshots`
/// artifact; `scripts/fetch_app_screenshots.py` downloads them for a PR or branch.
///
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
    // Four tabs since Settings became a sheet from Home: the same bar, quartered.
    private static let tabOffsets: [String: CGFloat] = [
        "Home": 0.178, "Plan": 0.391, "History": 0.604, "Progress": 0.817
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

        for tab in ["Plan", "History", "Progress"] {
            selectTab(tab)
            sleep(2)
            captureScrollingScreen(named: "tab-\(tab.lowercased())", screens: tab == "Progress" ? 7 : 3)
        }

        capturePlanTools()
        captureSmartAdaptPrompt()
        captureRunSummary()
        captureShareStudio()
        captureOlderRunSummary()
        captureAchievements()

        // Settings opens as a sheet from Home's profile button.
        selectTab("Home")
        sleep(1)
        let settingsButton = app.buttons["home.settings"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
            sleep(2)
            captureScrollingScreen(named: "settings")
            let done = app.buttons["settings.done"]
            if done.waitForExistence(timeout: 5) { done.tap() }
        }

        captureRunHUD()
    }

    /// The coach page and the coach chat. They only draw with AI Coach on and a finished
    /// read on the run, which `--seed-coach-read` provides; the CI simulator has no Apple
    /// Intelligence, so the chat shows whatever it says when no model is available.
    func testCaptureCoachScreens() throws {
        app.terminate()
        app.launchArguments = ["--uitesting", "--seed-demo-data", "--seed-coach-read"]
        app.launch()
        skipOnboarding()

        selectTab("History")
        let newestRun = app.buttons["history.run"].firstMatch
        guard newestRun.waitForExistence(timeout: 10) else {
            return XCTFail("The demo history has no runs to open")
        }
        newestRun.tap()
        let coachCard = app.buttons["runSummary.coachCard"]
        _ = coachCard.waitForExistence(timeout: 10)
        guard scrollIntoView(coachCard) else {
            capture("missing-coach")
            return XCTFail("The run had no coach card; the seeded read did not load")
        }
        coachCard.tap()
        sleep(2)
        captureScrollingScreen(named: "coach-read")

        let ask = app.buttons["runSummary.askCoach"]
        _ = ask.waitForExistence(timeout: 3)
        guard scrollIntoView(ask) else {
            capture("missing-coach-chat")
            return XCTFail("The coach page has no Ask about this run button")
        }
        ask.tap()
        guard app.navigationBars["Coach"].waitForExistence(timeout: 8) else {
            return XCTFail("The coach chat did not open")
        }
        sleep(3)
        capture("coach-chat")
    }

    /// Onboarding with every default, for a pass that has already captured it once.
    private func skipOnboarding() {
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
        XCTAssertTrue(
            app.buttons["dashboard.startFreeRun"].waitForExistence(timeout: 20),
            "Never reached Home"
        )
        sleep(2)
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
    /// `screens` is how many screenfuls to take; past three the middle ones are numbered.
    /// Progress gets more, because its lower cards (best efforts, fitness and freshness)
    /// never made it into a three-shot pass.
    private func captureScrollingScreen(named name: String, screens: Int = 3) {
        capture("\(name)-top")
        for page in 1..<max(screens, 2) {
            app.swipeUp(velocity: .slow)
            sleep(1)
            let isLast = page == max(screens, 2) - 1
            let label = isLast ? "bottom" : (screens == 3 ? "scrolled" : "scrolled-\(page)")
            capture("\(name)-\(label)")
        }
    }

    // MARK: - One level down

    /// Brings `element` above the floating tab bar, which covers the bottom of the screen
    /// and would take a tap meant for a tile under it. `isHittable` alone does not see that.
    /// Swipes while the element does not exist yet, too: Plan's tools are a `LazyVGrid`,
    /// so a tile below the fold is not in the accessibility tree until it is scrolled to.
    @discardableResult
    private func scrollIntoView(_ element: XCUIElement) -> Bool {
        let limit = app.frame.height * 0.82
        for _ in 0..<6 {
            if element.exists, element.isHittable, element.frame.maxY < limit { return true }
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        return element.exists && element.isHittable
    }

    /// Opens a page from `identifier` on the current screen, captures it, and comes back
    /// with the bar's back button.
    private func capturePage(from identifier: String, title: String, named name: String) {
        let row = app.buttons[identifier]
        _ = row.waitForExistence(timeout: 3)
        if scrollIntoView(row) {
            row.tap()
        } else if identifier == "plan.myWorkoutsRow", tapTileBelow("plan.raceInsightsRow") {
            // See `tapTileBelow`.
        } else {
            capture("missing-\(name)")
            return XCTFail("Could not reach \(identifier) to open \(title)")
        }
        let bar = app.navigationBars[title]
        guard bar.waitForExistence(timeout: 8) else {
            return XCTFail("\(title) did not open from \(identifier)")
        }
        sleep(2)
        captureScrollingScreen(named: name)
        scrollToTop()
        bar.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    /// Taps the grid tile under the tile `above`, by position. My workouts is the grid's
    /// fifth tile, alone on its row, and in CI runs 46071560695 and 46075739921 it never
    /// appeared in the accessibility tree, even scrolled on screen, while the four above
    /// it did. Its page's navigation bar still confirms the right tile opened.
    private func tapTileBelow(_ above: String) -> Bool {
        let anchor = app.buttons[above]
        guard anchor.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<4 where anchor.frame.minY > app.frame.height * 0.45 {
            app.swipeUp(velocity: .slow)
            sleep(1)
        }
        let frame = anchor.frame
        guard frame.maxY + frame.height < app.frame.height * 0.82 else { return false }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 12 + frame.height / 2))
            .tap()
        return true
    }

    /// Each Plan tools tile's page. The tiles open full pages that the tab's own capture
    /// never shows, and they are where new features have been landing.
    private func capturePlanTools() {
        let tools = [
            ("plan.paceInsightsRow", "Pace insights", "plan-pace-insights"),
            ("plan.raceInsightsRow", "Race insights", "plan-race-insights"),
            ("plan.friendsRow", "Train with friends", "plan-friends"),
            ("plan.myWorkoutsRow", "My workouts", "plan-my-workouts")
        ]
        for (identifier, title, name) in tools {
            selectTab("Plan")
            sleep(1)
            capturePage(from: identifier, title: title, named: name)
        }
    }

    /// The newest demo run's summary, the screen a run ends on.
    private func captureRunSummary() {
        selectTab("History")
        sleep(1)
        let firstRun = app.buttons["history.run"].firstMatch
        guard firstRun.waitForExistence(timeout: 10) else {
            return XCTFail("The demo history has no runs to open")
        }
        firstRun.tap()
        guard app.buttons["runSummary.breakdown.splits"].waitForExistence(timeout: 10) else {
            return XCTFail("The run summary did not open")
        }
        sleep(2)
        captureScrollingScreen(named: "run-summary")
        scrollToTop()
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    /// The Smart Adapt tile with AI Coach off (a UI-test launch wipes preferences): it
    /// asks to turn the coach on. Answers "Not Now", so the rest of the pass is unchanged.
    private func captureSmartAdaptPrompt() {
        selectTab("Plan")
        sleep(1)
        let tile = app.buttons["plan.smartAdaptTile"]
        _ = tile.waitForExistence(timeout: 5)
        guard scrollIntoView(tile) else {
            capture("missing-smart-adapt")
            return XCTFail("Could not reach the Smart Adapt tile")
        }
        tile.tap()
        let notNow = app.buttons["Not Now"]
        guard notNow.waitForExistence(timeout: 5) else {
            capture("missing-smart-adapt-prompt")
            return XCTFail("Smart Adapt did not offer to turn on AI Coach")
        }
        sleep(1)
        capture("plan-smart-adapt-prompt")
        notNow.tap()
        sleep(1)
        scrollToTop()
    }

    /// The share studio, from the newest run's Run actions menu.
    private func captureShareStudio() {
        selectTab("History")
        sleep(1)
        let firstRun = app.buttons["history.run"].firstMatch
        guard firstRun.waitForExistence(timeout: 10) else { return }
        firstRun.tap()
        let actions = app.buttons["runSummary.actions"]
        guard actions.waitForExistence(timeout: 10) else {
            capture("missing-share-studio")
            return XCTFail("The run summary has no Run actions menu")
        }
        actions.tap()
        let share = app.buttons["runSummary.shareCard"]
        guard share.waitForExistence(timeout: 5) else {
            capture("missing-share-studio")
            return XCTFail("Run actions has no Share run card")
        }
        share.tap()
        guard app.navigationBars["Share run"].waitForExistence(timeout: 8) else {
            return XCTFail("The share studio did not open")
        }
        // The card renders after the sheet appears.
        sleep(3)
        captureScrollingScreen(named: "share-studio", screens: 2)
        app.navigationBars["Share run"].buttons["Close"].tap()
        sleep(1)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    /// A run from a week ago, where "How did that feel?" sits under the route instead of
    /// right under the hero (the newest run may be less than a day old).
    private func captureOlderRunSummary() {
        selectTab("History")
        sleep(1)
        let runs = app.buttons.matching(identifier: "history.run")
        guard runs.element(boundBy: 0).waitForExistence(timeout: 10), runs.count > 3 else {
            return XCTFail("The demo history has too few runs for an older summary")
        }
        let older = runs.element(boundBy: 3)
        guard scrollIntoView(older) else {
            return XCTFail("Could not reach an older run in History")
        }
        older.tap()
        guard app.buttons["runSummary.breakdown.splits"].waitForExistence(timeout: 10) else {
            return XCTFail("The older run's summary did not open")
        }
        sleep(2)
        captureScrollingScreen(named: "run-summary-older", screens: 2)
        scrollToTop()
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        sleep(1)
        scrollToTop()
    }

    /// Progress's second segment, which the tab's capture never switches to.
    private func captureAchievements() {
        selectTab("Progress")
        sleep(1)
        let achievements = app.buttons["Achievements"].firstMatch
        guard achievements.waitForExistence(timeout: 5) else {
            return XCTFail("Progress has no Achievements segment")
        }
        achievements.tap()
        sleep(2)
        captureScrollingScreen(named: "progress-achievements")
        scrollToTop()
        app.buttons["Stats"].firstMatch.tap()
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

        // Started: the running layout, with whatever the simulator gives for location.
        // Last in the pass, because the run is left going.
        let start = app.buttons["activeRun.start"]
        guard start.waitForExistence(timeout: 5) else {
            return XCTFail("The run HUD has no Start button")
        }
        start.tap()
        sleep(6)
        capture("run-hud-running")
    }
}
