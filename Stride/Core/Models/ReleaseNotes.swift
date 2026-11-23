import Foundation

// MARK: - Release notes

/// One App Store release as the app tells it: the What's New sheet shows its headline
/// features once, after the update, and Settings → What's new in Stride lists every
/// release so a runner can go back and read them.
///
/// Releases are keyed by their `major.minor` version (`Release.key(forMarketingVersion:)`),
/// so a 1.2.1 bug-fix build reads 1.2's notes rather than showing the sheet again.
struct Release: Identifiable, Hashable, Sendable {
    /// `major.minor`, matching `MARKETING_VERSION` in `ci_scripts/Version.xcconfig`.
    let version: String
    /// The day it went live on the App Store, or `nil` while it is still in TestFlight.
    let releaseDate: DateComponents?
    /// One line under the version on the sheet.
    let headline: String
    /// The marketable features, each a page of the What's New sheet with its screenshot.
    let features: [ReleaseFeature]
    /// Smaller changes, listed on the full release notes only.
    let improvements: [String]
    let fixes: [String]

    var id: String { version }

    /// The `major.minor` key for a marketing version: "1.2.1" → "1.2", "2" → "2.0".
    /// Anything that isn't dotted numbers comes back unchanged.
    static func key(forMarketingVersion version: String) -> String {
        let parts = version.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return version }
        return "\(parts[0]).\(parts.count > 1 ? parts[1] : "0")"
    }

    /// Orders two `major.minor` keys numerically, so "1.10" comes after "1.9".
    /// Non-numeric keys compare as text.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard left.count == lhs.split(separator: ".").count,
              right.count == rhs.split(separator: ".").count else { return lhs > rhs }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// A headline feature: a page of the What's New sheet.
struct ReleaseFeature: Identifiable, Hashable, Sendable {
    /// Stable within its release; names the screenshot (`screenshotName`).
    let id: String
    let title: String
    let body: String
    /// Drawn on the page when the release has no screenshot for this feature.
    let icon: StrideIconName
    /// Whether `WhatsNewScreenshotTests` captures this feature. Only 1.2 onwards: older
    /// releases' features no longer look the way they did when they shipped.
    var hasScreenshot = false

    /// The image set in `Stride/Resources/WhatsNew.xcassets` holding this feature's
    /// screenshot, for example `whatsnew-1.2-heatmap`. The What's New screenshots
    /// workflow writes it; until it has run, the page falls back to `icon`.
    func screenshotName(in release: Release) -> String? {
        hasScreenshot ? "whatsnew-\(release.version)-\(id)" : nil
    }
}

// MARK: - The catalog

/// Every release, newest first. Add the next one at the top when its version is bumped;
/// `ReleaseNotesTests` checks the current `MARKETING_VERSION` has an entry, so a release
/// can't ship without one by accident.
enum ReleaseNotes {

    static let all: [Release] = [v1_2, v1_1, v1_0]

    /// The notes for a marketing version ("1.2.1" finds 1.2), or `nil` if it has none.
    static func release(forMarketingVersion version: String) -> Release? {
        let key = Release.key(forMarketingVersion: version)
        return all.first { $0.version == key }
    }

    // MARK: 1.2

    static let v1_2 = Release(
        version: "1.2",
        releaseDate: nil,
        headline: "See your running like never before, and share it your way.",
        features: [
            ReleaseFeature(
                id: "progress",
                title: "Progress, all on one page",
                body: "Filter by period and run type, tap a week to see its runs, and drag across any chart for the exact number.",
                icon: .chart,
                hasScreenshot: true
            ),
            ReleaseFeature(
                id: "best-efforts",
                title: "Best efforts and fitness",
                body: "Your fastest 1K, mile, 5K and more, found inside every run. Plus fitness, fatigue and form from your training load.",
                icon: .trophy,
                hasScreenshot: true
            ),
            ReleaseFeature(
                id: "heatmap",
                title: "Every route on one map",
                body: "A heatmap of everywhere you run. Open it full screen, filter by year or run type, and tap a street to see the runs that went along it.",
                icon: .location,
                hasScreenshot: true
            ),
            ReleaseFeature(
                id: "run-analysis",
                title: "Run analysis",
                body: "Pace, heart rate and elevation on one timeline. Scrub through a run to see what happened on that hill.",
                icon: .mountain,
                hasScreenshot: true
            ),
            ReleaseFeature(
                id: "share-studio",
                title: "Share studio",
                body: "Story, post, square and sticker cards for your runs, and a video of your route drawing itself in. Privacy zones hide where you start and finish.",
                icon: .export,
                hasScreenshot: true
            ),
            ReleaseFeature(
                id: "training-break",
                title: "Not feeling your best?",
                body: "Ill, injured or away? Ease off or pause your plan, and Stride brings you back gently. The coach knows you're on a break.",
                icon: .heart,
                hasScreenshot: true
            ),
        ],
        improvements: [
            "Share your goal race with a friend: the invite sets up their plan for the same race.",
            "Plan Replay: a finished plan as story cards to share.",
            "Strength workouts from Apple Health come into Stride, without duplicates, with their heart rate. The coach sees them too.",
            "Plan a route from a planned workout, already set to its distance.",
            "Importing years of runs from Apple Health no longer runs out of memory.",
            "Faster everywhere for people with a long run history.",
        ],
        fixes: [
            "Routes from Apple Watch runs that reach Apple Health late now appear.",
            "Progress charts read clearly over years of runs.",
            "Several Progress dashboard layout fixes.",
        ]
    )

    // MARK: 1.1

    static let v1_1 = Release(
        version: "1.1",
        releaseDate: DateComponents(year: 2026, month: 11, day: 10),
        headline: "Our biggest update yet.",
        features: [
            ReleaseFeature(
                id: "start-running",
                title: "Start Running plans",
                body: "Never run before, or coming back after time off? A run/walk plan builds you to 30 minutes non-stop, with spoken Run and Walk cues.",
                icon: .walk
            ),
            ReleaseFeature(
                id: "strength",
                title: "Strength training",
                body: "Log real weights, see what you lifted last time, and get a suggested load for next time. Rest timer, how-to cues and swaps for every exercise.",
                icon: .dumbbell
            ),
            ReleaseFeature(
                id: "course-pacing",
                title: "Course-aware race pacing",
                body: "Add your race's course GPX in the Race Day hub and Stride paces each split for the hills.",
                icon: .flag
            ),
            ReleaseFeature(
                id: "year-recap",
                title: "Your year in running",
                body: "A swipeable recap of your year with cards to share, in Achievements and on Home in December and January.",
                icon: .calendar
            ),
            ReleaseFeature(
                id: "coach-plan-changes",
                title: "Ask the coach to change your plan",
                body: "Tell the AI coach \"add an interval run this week\" or \"make Friday a rest day\" and confirm the change on a card.",
                icon: .bolt
            ),
        ],
        improvements: [
            "10K is now a goal race with its own training.",
            "New plans start from your recent running in Apple Health.",
            "The AI coach matches your experience: plain language for new runners, more detail for experienced ones.",
            "Redesigned planned workout screen.",
            "The Apple Watch app installs on watchOS 26 and gets your next session the evening before.",
            "Edits you make to a session are kept for a week instead of being overwritten.",
            "Indoor runs keep recording with the phone locked.",
            "More accurate elevation gain.",
        ],
        fixes: [
            "A run in progress is recovered if the app is closed or crashes.",
            "No more duplicate runs when the same run is recorded twice.",
            "Every split is recorded on indoor runs.",
            "The heat tip no longer appears on cold, humid days.",
        ]
    )

    // MARK: 1.0

    static let v1_0 = Release(
        version: "1.0",
        releaseDate: DateComponents(year: 2026, month: 11, day: 4),
        headline: "Stride's first release.",
        features: [
            ReleaseFeature(
                id: "coach",
                title: "An AI running coach",
                body: "Reads every run, answers your questions and keeps your plan on track, on your iPhone.",
                icon: .bolt
            ),
            ReleaseFeature(
                id: "plans",
                title: "Adaptive training plans",
                body: "5K to marathon, built around your days and your pace, and adjusted as you go.",
                icon: .calendar
            ),
            ReleaseFeature(
                id: "tracking",
                title: "Run tracking",
                body: "GPS runs with spoken cues, an Apple Watch app, widgets and Apple Health sync.",
                icon: .run
            ),
        ],
        improvements: [],
        fixes: []
    )
}
