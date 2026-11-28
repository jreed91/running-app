import Foundation

// MARK: - WatchRunCheckpoint

/// What the Watch needs to carry on a run after the app crashes or the Watch restarts
/// mid-run (Watch runs, PR 6).
///
/// HealthKit keeps the workout itself: `recoverActiveWorkoutSession()` hands back the
/// session and its builder, with the time, distance and heart rate so far. What it can't
/// know is Stride's side: which plan session was being run, and how far through its steps
/// the runner was. That is saved here as the run starts and at every step change, and
/// cleared when the run ends.
///
/// Compiled into the app and `StrideWatch`, Foundation only, and tested in `StrideTests`.
struct WatchRunCheckpoint: Codable, Equatable, Sendable {

    /// `nil` on a free run.
    var runSession: WatchRunSession?
    var usesMetricUnits: Bool
    var stepStarts: [WatchGuidedRun.StepStart]

    static let defaultsKey = "watchRunCheckpoint"

    /// The steps as they were when this was saved, or `nil` for a run without steps.
    func guided() -> WatchGuidedRun? {
        runSession.flatMap { WatchGuidedRun(session: $0, replaying: stepStarts) }
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> WatchRunCheckpoint? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

// MARK: - WatchBattery

/// When the run screen warns about the Watch's battery (PR 6). A long GPS run can flatten
/// an older Watch, and a run that dies with the battery is never saved.
enum WatchBattery {
    /// At or below this the run screen shows the level and the Watch taps once.
    static let lowPercent = 15

    /// The battery level to warn about, or `nil` when it's fine or unknown.
    /// - Parameter level: `WKInterfaceDevice.batteryLevel`, 0...1, or negative when unknown.
    static func warningPercent(level: Float) -> Int? {
        guard level >= 0 else { return nil }
        let percent = Int((level * 100).rounded())
        return percent <= lowPercent ? percent : nil
    }
}
