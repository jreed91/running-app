import Foundation

/// Pure lap math for the manual lap control (A2).
///
/// The tracker records only *boundaries* — the elapsed time and cumulative distance at
/// each tap — and this turns them into ``Lap`` values. Keeping the arithmetic here means
/// the live lap read-out on the run HUD and the lap table on the run summary are built by
/// the same code, and that it can be tested without a running workout.
///
/// The app already closes a bucket every kilometre or mile (`SplitBucketing`). Laps exist
/// for the boundaries that math cannot know about: the top of a rep, a turnaround, the lap
/// line on a track. So a run with no taps has no laps at all — a single lap spanning the
/// whole run would just restate the run's own distance, duration and average pace.
enum LapRecorder {

    /// A lap boundary: where one lap closed and the next opened.
    struct Mark: Equatable, Sendable {
        /// Elapsed run time at the boundary, in seconds.
        var elapsedSeconds: Double
        /// Cumulative run distance at the boundary, in metres.
        var distanceMeters: Double

        init(elapsedSeconds: Double, distanceMeters: Double) {
            self.elapsedSeconds = elapsedSeconds
            self.distanceMeters = distanceMeters
        }

        /// The implicit boundary every run opens with.
        static let start = Mark(elapsedSeconds: 0, distanceMeters: 0)
    }

    /// The laps the runner has already closed — everything between `Mark.start` and the
    /// last tap. Excludes the lap currently in progress, which has no end yet.
    ///
    /// This is what the HUD counts: after two taps the runner is on lap 3, with laps 1
    /// and 2 behind them.
    static func closedLaps(marks: [Mark]) -> [Lap] {
        laps(boundaries: [.start] + marks)
    }

    /// Every lap of a finished run: the ones `marks` closed, plus the final lap running
    /// from the last tap to `finish`.
    ///
    /// Returns `[]` when no lap was ever marked — see the type's note on why a run is not
    /// its own single lap.
    static func laps(marks: [Mark], finish: Mark) -> [Lap] {
        guard !marks.isEmpty else { return [] }
        return laps(boundaries: [.start] + marks + [finish])
    }

    // MARK: - Private

    /// Turns an ordered boundary list into the laps between consecutive pairs.
    ///
    /// Laps with no elapsed time are dropped rather than stored: a double-tap inside one
    /// clock tick is a slip, and a zero-duration lap would sit in the table claiming a
    /// pace it never ran. Numbering is applied after that filter, so the surviving laps
    /// always read 1…n with no gap.
    private static func laps(boundaries: [Mark]) -> [Lap] {
        guard boundaries.count >= 2 else { return [] }
        var result: [Lap] = []
        for (open, close) in zip(boundaries, boundaries.dropFirst()) {
            let duration = close.elapsedSeconds - open.elapsedSeconds
            guard duration > 0, duration.isFinite else { continue }
            // Distance can only be clamped, never trusted to rise: an indoor resume banks
            // its baseline and a rejected GPS fix leaves the total where it was.
            let distance = max(0, close.distanceMeters - open.distanceMeters)
            result.append(
                Lap(
                    number: result.count + 1,
                    startElapsedSeconds: open.elapsedSeconds,
                    durationSeconds: duration,
                    distanceMeters: distance,
                    paceSecondsPerKm: SplitBucketing.splitPaceSecondsPerKm(
                        deltaSeconds: duration,
                        deltaMeters: distance
                    ) ?? 0
                )
            )
        }
        return result
    }
}
