import Foundation

// MARK: - WidgetSnapshot

/// Everything Stride's Home Screen and Lock Screen widgets draw, in one value (B1).
///
/// Compiled into the app, `StrideWidgets` and `StrideWatch`, for the same reason
/// ``RunActivityAttributes`` is shared: the app writes it, the extension and the watch app
/// read it, and two hand-written copies of a payload in two targets is how a widget
/// silently starts rendering a field the app stopped filling in. Keep it free of anything
/// app-only — no SwiftData, no services, no theme, nothing iOS-only such as ActivityKit —
/// or the extension and the watch app stop building. The watch receives it over
/// WatchConnectivity rather than the App Group (see ``WatchContext``).
///
/// Like the Live Activity's content state, it carries **preformatted strings** rather
/// than raw metres and seconds. The app owns the unit preference and every formatter in
/// this repo, so shipping "18.4 km" instead of `18400` keeps the widget from needing
/// either, and keeps a widget agreeing with the dashboard by construction rather than by
/// two implementations happening to round the same way. The exceptions are the handful of
/// numbers a widget *draws* rather than prints — a goal ring's fraction, a streak's day
/// count — and the dates the system counts down for us.
struct WidgetSnapshot: Codable, Sendable, Equatable {

    // MARK: Tint

    /// Which entry of the app's palette a card should take its accent from.
    ///
    /// A name rather than a colour: the extension compiles its own copy of
    /// `Assets.xcassets` (see `project.yml`), so it resolves these against the same
    /// asset catalog the app does and light/dark/increase-contrast keep working. An
    /// encoded hex string would have frozen one appearance into the snapshot.
    enum Tint: String, Codable, Sendable {
        case brand
        case easy
        case tempo
        case interval
        case success
        case neutral
    }

    // MARK: Next workout

    /// The session the plan is asking for next — today's if there is one, otherwise the
    /// next day that holds work. A plan-scheduled rest day is a value here rather than
    /// `nil`: "the plan says rest" and "there is no plan" read the same on a widget and
    /// mean very different things (the distinction `ScheduledDayResolver.DayState` draws).
    struct NextWorkout: Codable, Sendable, Equatable {
        /// What the session is — "Tempo", "Long Run", "Rest".
        var title: String
        /// The headline prescription — "8.0 km", "45 min" — or `nil` for a rest day.
        var detail: String?
        /// Target pace range in the runner's own unit — "4:32–4:45 /km".
        var paceTarget: String?
        /// Coaching note, trimmed to a widget-sized length.
        var note: String?
        var symbolName: String
        var tint: Tint
        /// The day the plan asks for this. A **date**, not a rendered "Today", because a
        /// snapshot written on Tuesday is still on disk on Wednesday — the app is not
        /// running at midnight to rewrite it, and a card reading "Today" about yesterday
        /// is worse than no card. The widget derives the words at render time via
        /// ``WidgetRelativeDay``.
        var scheduledDate: Date
        var isRest: Bool

        /// "Today", "Tomorrow", "Friday", "8 Aug", "Overdue".
        func dayLabel(asOf now: Date, calendar: Calendar = .current) -> String {
            WidgetRelativeDay.label(for: scheduledDate, asOf: now, calendar: calendar)
        }
    }

    // MARK: Weekly goal

    /// Progress toward the weekly distance goal, for the Monday-anchored week the
    /// snapshot was built in.
    struct WeeklyGoal: Codable, Sendable, Equatable {
        /// Distance run so far this week — "18.4 km".
        var completedText: String
        /// The goal — "40 km".
        var goalText: String
        /// What is left — "21.6 km to go" — or a congratulation once the goal is met.
        var statusText: String
        /// 0–1, clamped. Drawn as a ring, which is why this one stays numeric.
        var fraction: Double
        var runCount: Int
        var isMet: Bool
        /// Whether a goal was ever set. Zero-goal installs get a neutral card rather
        /// than a ring that can only ever read empty.
        var hasGoal: Bool
    }

    // MARK: Streak

    struct Streak: Codable, Sendable, Equatable {
        /// Consecutive calendar days with a run, ending today or yesterday.
        var current: Int
        var longest: Int
        /// Whether today's run is already in. The difference between "keep it going"
        /// and "done for today", which is the whole point of glancing at this.
        var isActiveToday: Bool
    }

    // MARK: Race

    /// The goal race the active plan is pointed at.
    struct RaceCountdown: Codable, Sendable, Equatable {
        var name: String
        /// Race day. Counted down from at render time for the same reason
        /// ``NextWorkout/scheduledDate`` is a date: a countdown frozen at the moment the
        /// app was last opened is a countdown that is wrong by the second day.
        var date: Date
        /// Where the plan is — "Peak · Week 12 of 16".
        var phaseLabel: String?
        /// Goal finish time — "3:29:00".
        var goalTimeText: String?

        /// Whole days from `now`'s day to race day. Zero on race day, negative after it.
        func daysRemaining(asOf now: Date, calendar: Calendar = .current) -> Int {
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
        }

        /// Whether the countdown is still worth showing. A race that has been and gone
        /// stops counting rather than showing a negative number.
        func isUpcoming(asOf now: Date, calendar: Calendar = .current) -> Bool {
            daysRemaining(asOf: now, calendar: calendar) >= 0
        }
    }

    // MARK: Coach tip

    /// The single highest-scoring coaching card, chosen by `SmartCoachCards` in the app.
    ///
    /// The widget extension cannot run that selection: it has no access to the SwiftData
    /// store, and every rule in it reads scheduled workouts, logged runs and the profile.
    /// So the app runs it and publishes the winner here, the same way it publishes a
    /// formatted distance rather than a count of metres. One set of thresholds decides
    /// what the dashboard, the Home Screen and Siri all say.
    ///
    /// The text is the card's **glance** form rather than its dashboard copy, for two
    /// reasons that both come back to the same fact — this file is written when the app
    /// runs and read whenever the runner looks at their phone. A glance carries no clock
    /// in its wording, so it cannot go stale between those two moments; and it is
    /// identical across writes when nothing has changed, which is what lets
    /// `WidgetRefreshService` skip a reload. A tip reading "about 30 minutes ago" would
    /// differ on every write and spend WidgetKit's whole daily reload budget on
    /// foregrounds.
    struct CoachTip: Codable, Sendable, Equatable {
        /// The card's heading — "Practise your fuelling", "Race day".
        var title: String
        /// One short, time-independent sentence of advice.
        var message: String
        /// "FUEL" or "TRAINING", the same overline the dashboard card carries.
        var categoryLabel: String
        var symbolName: String
        var tint: Tint
        /// When the advice stops being worth showing — the end of a refuelling window, or
        /// of race day. `nil` for tips that do not go off.
        ///
        /// A **date**, resolved at render time, for the same reason
        /// ``NextWorkout/scheduledDate`` is: the app is not running two hours later to
        /// retract it, and the widget's timeline already crosses those boundaries itself.
        var expiresAt: Date?

        /// Whether the tip is still worth drawing. A widget that has one expire falls
        /// back to its empty state rather than showing advice that has gone off.
        func isValid(asOf now: Date) -> Bool {
            guard let expiresAt else { return true }
            return now < expiresAt
        }
    }

    // MARK: Payload

    var nextWorkout: NextWorkout?
    var weekly: WeeklyGoal
    var streak: Streak
    var race: RaceCountdown?
    /// Optional so a snapshot written before this field existed still decodes — the app
    /// is the only writer, but a widget can be woken against a file the previous build
    /// left behind.
    var coachTip: CoachTip?

    /// When the app last wrote this. The widget uses it to notice a snapshot that has
    /// gone stale enough to be misleading rather than merely old.
    var generatedAt: Date

    /// How old a snapshot may get before a widget stops presenting it as current.
    ///
    /// Set well past a day: the app is the only writer, and someone who does not open
    /// Stride over a weekend should still see Monday's session rather than an empty card.
    /// It has to clear the widget timeline's horizon too — the provider pre-renders
    /// several days of entries, and a threshold inside that window would blank the last
    /// of them on a snapshot that had only just been written.
    static let staleAfter: TimeInterval = 60 * 60 * 24 * 8

    func isStale(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > Self.staleAfter
    }

    // MARK: Empty / sample

    /// What a widget shows before the app has ever written a snapshot — a real install
    /// that has not been opened since the widget was added, and every render in the
    /// widget gallery.
    static func empty(generatedAt: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            nextWorkout: nil,
            weekly: WeeklyGoal(
                completedText: "—",
                goalText: "—",
                statusText: String(localized: "Open Stride to get started", comment: "Widget empty state"),
                fraction: 0,
                runCount: 0,
                isMet: false,
                hasGoal: false
            ),
            streak: Streak(current: 0, longest: 0, isActiveToday: false),
            race: nil,
            coachTip: nil,
            generatedAt: generatedAt
        )
    }

    /// A plausible week, for the widget gallery and for SwiftUI previews. The gallery
    /// renders every widget before the user picks one, and an empty card there is a
    /// widget nobody adds.
    static func sample(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(
            nextWorkout: NextWorkout(
                title: String(localized: "Tempo", comment: "Workout type"),
                detail: "8.0 km",
                paceTarget: "4:32–4:45 /km",
                note: nil,
                symbolName: "gauge.with.needle",
                tint: .tempo,
                scheduledDate: now,
                isRest: false
            ),
            weekly: WeeklyGoal(
                completedText: "18.4 km",
                goalText: "40 km",
                statusText: "21.6 km to go",
                fraction: 0.46,
                runCount: 3,
                isMet: false,
                hasGoal: true
            ),
            streak: Streak(current: 5, longest: 21, isActiveToday: true),
            race: RaceCountdown(
                name: "Berlin Marathon",
                date: now.addingTimeInterval(60 * 60 * 24 * 63),
                phaseLabel: "Build · Week 6 of 16",
                goalTimeText: "3:29:00"
            ),
            coachTip: CoachTip(
                title: String(localized: "Practise your fuelling", comment: "Coach card title"),
                message: String(
                    localized: "65 g an hour from forty-five minutes in, with 450 ml an hour of fluid.",
                    comment: "Sample coach tip"
                ),
                categoryLabel: String(localized: "FUEL", comment: "Coach card category overline"),
                symbolName: "flame.fill",
                tint: .tempo,
                expiresAt: nil
            ),
            generatedAt: now
        )
    }
}

// MARK: - WidgetRelativeDay

/// Turns a scheduled date into the words a widget prints for it.
///
/// Shared rather than app-side because it is the one piece of the snapshot's text that
/// must be resolved at *render* time. Everything else a widget shows is fixed the moment
/// the app writes it — a distance is 8.0 km whenever you look at it — but "Today" is only
/// true until midnight, and the app is not running then to say so. The widget's timeline
/// crosses each midnight itself and re-renders, which only works if the words are
/// derived here rather than baked into the file.
///
/// Weekday and date come from `Date.FormatStyle`, so they arrive already localized and in
/// the device's own calendar; hand-built abbreviations would not.
enum WidgetRelativeDay {

    static func label(for date: Date, asOf now: Date, calendar: Calendar = .current) -> String {
        switch dayDelta(for: date, asOf: now, calendar: calendar) {
        case ..<0:
            return String(localized: "Overdue", comment: "Widget day label for a missed session")
        case 0:
            return String(localized: "Today", comment: "Widget day label")
        case 1:
            return String(localized: "Tomorrow", comment: "Widget day label")
        case 2...6:
            return date.formatted(.dateTime.weekday(.wide))
        default:
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// Whole days from `now`'s day to `date`'s day. Negative for the past.
    static func dayDelta(for date: Date, asOf now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }
}

// MARK: - StrideAppGroup

/// The App Group the app and the widget extension share.
///
/// A widget runs in its own process with its own container, so this is the only way the
/// two sides can pass anything at all. **The identifier has to be registered at
/// [developer.apple.com → Identifiers → App Groups](https://developer.apple.com/account/resources/identifiers)
/// and enabled on both App IDs** (`com.running.stride` and
/// `com.running.stride.StrideWidgets`) before a signed build will export — automatic
/// signing cannot create it, least of all through Xcode Cloud's read-only signing proxy.
/// See the note in `AGENTS.md`.
enum StrideAppGroup {
    static let identifier = "group.com.running.stride"

    /// `nil` when the entitlement is missing or the group is not registered, which is
    /// exactly the case both sides have to survive: the app skips the write and the
    /// widget falls back to its empty state rather than either of them trapping.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

// MARK: - WidgetSnapshotStore

/// Reads and writes the single ``WidgetSnapshot`` file in the shared App Group container.
///
/// A file rather than shared `UserDefaults`: the payload is a structured value with dates
/// in it, so it wants an encoder either way, and a file gets an atomic replace for free —
/// a widget waking mid-write reads the previous snapshot rather than half of the new one.
///
/// Every failure path is silent by design. Nothing here is load-bearing for the app: the
/// worst case is a widget one refresh behind, and a `try!` in a Home Screen extension is
/// a crash in the one process the user cannot see a log from.
struct WidgetSnapshotStore: Sendable {

    /// The instance both sides use. `directory` is injectable so the round-trip can be
    /// tested against a temporary directory rather than a real entitled container.
    static let shared = WidgetSnapshotStore()

    private let directory: URL?

    init(directory: URL? = StrideAppGroup.containerURL) {
        self.directory = directory
    }

    private static let fileName = "WidgetSnapshot.json"

    var fileURL: URL? {
        directory?.appending(path: Self.fileName)
    }

    // MARK: Read

    func load() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    // MARK: Write

    /// Writes `snapshot`, replacing whatever was there.
    ///
    /// Returns whether the write landed, so the caller can decide whether it is worth
    /// asking WidgetKit to reload — spending a reload on a snapshot that never reached
    /// the container just burns budget.
    @discardableResult
    func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let fileURL, let data = try? Self.encoder.encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Removes the snapshot — used when the app's data is reset, so widgets do not go on
    /// showing a plan the runner just deleted.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Coding

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
