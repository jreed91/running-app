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
/// Compiled into the app and `StrideWatch`, Foundation only, and tested in `StrideCoreTests` (`swift test`).
public struct WatchRunCheckpoint: Codable, Equatable, Sendable {

    /// `nil` on a free run.
    public var runSession: WatchRunSession?
    public var usesMetricUnits: Bool
    public var stepStarts: [WatchGuidedRun.StepStart]

    public static let defaultsKey = "watchRunCheckpoint"

    /// The steps as they were when this was saved, or `nil` for a run without steps.
    public func guided() -> WatchGuidedRun? {
        runSession.flatMap { WatchGuidedRun(session: $0, replaying: stepStarts) }
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public static func load(from defaults: UserDefaults = .standard) -> WatchRunCheckpoint? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    public static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    public init(
        runSession: WatchRunSession? = nil,
        usesMetricUnits: Bool,
        stepStarts: [WatchGuidedRun.StepStart]
    ) {
        self.runSession = runSession
        self.usesMetricUnits = usesMetricUnits
        self.stepStarts = stepStarts
    }
}

// MARK: - WatchBattery

/// When the run screen warns about the Watch's battery (PR 6). A long GPS run can flatten
/// an older Watch, and a run that dies with the battery is never saved.
public enum WatchBattery {
    /// At or below this the run screen shows the level and the Watch taps once.
    public static let lowPercent = 15

    /// The battery level to warn about, or `nil` when it's fine or unknown.
    /// - Parameter level: `WKInterfaceDevice.batteryLevel`, 0...1, or negative when unknown.
    public static func warningPercent(level: Float) -> Int? {
        guard level >= 0 else { return nil }
        let percent = Int((level * 100).rounded())
        return percent <= lowPercent ? percent : nil
    }
}
