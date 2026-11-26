import Foundation

// MARK: - WatchRunCues

/// Decides what the Watch says out loud as a run goes on (Watch runs, PR 4): each
/// kilometre or mile, each new step of a structured session, and the heads-up near the end
/// of a rep or recovery.
///
/// The words are the phone's own (`SplitAnnouncement`, `GuidedStepAnnouncement`), so a run
/// sounds the same from the wrist as from the pocket. This only works out *when* to say
/// them from the readings the recorder takes, and keeps the state that needs: where the
/// last split ended and how far into the step the previous reading was.
///
/// Compiled into the app and `StrideWatch`, Foundation only, and tested in `StrideTests`.
struct WatchRunCues: Equatable, Sendable {

    let unit: UnitPreference
    let speaksSplits: Bool
    let speaksSteps: Bool
    let targetPaceRange: ClosedRange<Double>?

    private var splitsAnnounced = 0
    private var lastSplitElapsedSeconds: TimeInterval = 0
    private var previous: WatchRunMetrics?

    init(
        unit: UnitPreference,
        speaksSplits: Bool,
        speaksSteps: Bool,
        targetPaceRange: ClosedRange<Double>? = nil
    ) {
        self.unit = unit
        self.speaksSplits = speaksSplits
        self.speaksSteps = speaksSteps
        self.targetPaceRange = targetPaceRange
    }

    init(session: WatchRunSession?, fallbackUnit: UnitPreference) {
        self.init(
            unit: session?.unit ?? fallbackUnit,
            speaksSplits: session?.speaksSplits ?? false,
            speaksSteps: session?.speaksSteps ?? false,
            targetPaceRange: session?.targetPaceRange
        )
    }

    var isSilent: Bool { !speaksSplits && !speaksSteps }

    /// The phrases to speak for the reading `metrics`, in order.
    ///
    /// - Parameters:
    ///   - guidedBefore: the steps as they were at the previous reading, before this one
    ///     moved them on.
    ///   - guidedAfter: the steps after this reading. Different from `guidedBefore` only
    ///     when a step just ended.
    mutating func phrases(
        for metrics: WatchRunMetrics,
        guidedBefore: WatchGuidedRun?,
        guidedAfter: WatchGuidedRun?
    ) -> [String] {
        defer { previous = metrics }
        var out: [String] = []

        if speaksSteps, let after = guidedAfter {
            if let before = guidedBefore, before.stepPosition != after.stepPosition {
                out.append(GuidedStepAnnouncement.stepStart(after.currentStep, unit: unit, style: after.state.cueStyle))
            } else if let previous, let before = guidedBefore,
                      let headsUp = GuidedStepAnnouncement.headsUp(
                          for: before.currentStep,
                          from: before.progress(with: previous),
                          to: before.progress(with: metrics),
                          unit: unit,
                          style: before.state.cueStyle
                      ) {
                out.append(headsUp)
            }
        }

        let splits = Int((max(0, metrics.distanceMeters) / unit.splitLengthMeters).rounded(.down))
        if splits > splitsAnnounced {
            // A late reading can cross two splits at once; only the latest is spoken.
            let splitSeconds = metrics.elapsedSeconds - lastSplitElapsedSeconds
            let covered = Double(splits - splitsAnnounced) * unit.splitLengthMeters
            splitsAnnounced = splits
            lastSplitElapsedSeconds = metrics.elapsedSeconds
            if speaksSplits, splitSeconds > 0,
               let phrase = SplitAnnouncement.phrase(
                   splitNumber: splits,
                   paceSecondsPerKm: splitSeconds / (covered / 1_000),
                   unit: unit,
                   targetPaceSecondsPerKm: targetPaceRange
               ) {
                out.append(phrase)
            }
        }
        return out
    }

    /// Picks up a run the Watch recovered after a crash (PR 6) at `metrics`, so the splits
    /// already run are not announced again, all at once, on the next reading.
    mutating func resume(at metrics: WatchRunMetrics) {
        splitsAnnounced = Int((max(0, metrics.distanceMeters) / unit.splitLengthMeters).rounded(.down))
        lastSplitElapsedSeconds = metrics.elapsedSeconds
        previous = metrics
    }

    /// The first step's cue, spoken as the run starts.
    func startPhrase(guided: WatchGuidedRun?) -> String? {
        guard speaksSteps, let guided else { return nil }
        return GuidedStepAnnouncement.stepStart(guided.currentStep, unit: unit, style: guided.state.cueStyle)
    }
}
