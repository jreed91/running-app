import Foundation
import AVFoundation

// MARK: - RunVoiceCoach

/// Speaks short coaching lines during a run — the split announcements built by
/// ``SplitAnnouncement`` and the structured-workout cues built by
/// ``GuidedStepAnnouncement``.
///
/// The audio channel was the one absence U4 left open: haptics tell a runner *that*
/// something happened, speech tells them *what*. Everything about this type is shaped by
/// the fact that a runner is almost always already playing something:
///
/// - The session is `.playback` in `.voicePrompt` mode with `.duckOthers`, so music dips
///   for the sentence instead of stopping, and `.interruptSpokenAudioAndMixWithOthers`
///   so a podcast (which cannot usefully be ducked — you would miss the words) pauses
///   and resumes.
/// - The session is activated for the utterance and deactivated when it finishes, with
///   `.notifyOthersOnDeactivation`, which is what lets the other app come back up. A
///   session left active would hold the duck for the rest of the run.
/// - Announcements are dropped rather than queued while one is speaking. A split closing
///   during the previous split's sentence means the runner is moving fast enough that the
///   stale sentence is the less useful one, and a backlog of them read out at km 6 is
///   worse than silence.
/// - The one exception is a cue that has to land *now* — "Rep 3 of 6 … Go" — which
///   cuts off whatever is being said instead (`interrupting: true`). A split read out
///   while the rep it belongs to has already ended is the stale one there too.
@MainActor
final class RunVoiceCoach {

    private let synthesizer = AVSpeechSynthesizer()
    private let sessionDeactivator = RunVoiceSessionDeactivator()

    /// Set once the app's session has been configured for speech, so the category is not
    /// re-applied on every split.
    private var sessionConfigured = false

    init() {
        // The app owns the session, so ducking and deactivation are configured here
        // rather than left to the synthesizer's private one — which cannot be told to
        // duck, and is why a naive `AVSpeechSynthesizer` stops the runner's music.
        // `true` is the default; it is spelled out because the whole design below
        // depends on it.
        synthesizer.usesApplicationAudioSession = true
        // Held strongly here: `AVSpeechSynthesizer.delegate` is weak.
        synthesizer.delegate = sessionDeactivator
    }

    /// Speaks `phrase`, or does nothing when the app is under UI test — or when a
    /// sentence is already in flight and this one may not interrupt it.
    ///
    /// - Parameters:
    ///   - phrase: a complete sentence from ``SplitAnnouncement`` or
    ///     ``GuidedStepAnnouncement``. `nil` is accepted so callers can pass the
    ///     builder's optional result straight through.
    ///   - interrupting: `true` cuts off anything being said and speaks this instead;
    ///     `false` (the default) drops this when something is already being said.
    func speak(_ phrase: String?, interrupting: Bool = false) {
        guard let phrase, !phrase.isEmpty else { return }
        // UI tests run on a simulator with no audio route and assert on screen state; a
        // real utterance there is a slow no-op that can also fail session activation.
        guard !UITestingSupport.isEnabled else { return }
        if synthesizer.isSpeaking {
            guard interrupting else { return }
            // The cancelled utterance's `didCancel` still arrives, and would release the
            // session under the sentence about to start — `RunVoiceSessionDeactivator`
            // checks for a queued utterance before it does.
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        guard activateSession() else { return }

        let utterance = AVSpeechUtterance(string: phrase)
        // Slightly above the default rate: these are two or three short sentences a
        // runner wants over with, and the default reads as a leisurely narration.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier(.bcp47))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Stops anything being spoken and releases the audio session, so finishing or
    /// discarding a run never leaves the runner's music ducked.
    func stop() {
        if synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        RunVoiceSessionDeactivator.deactivate()
    }

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if !sessionConfigured {
                try session.setCategory(
                    .playback,
                    mode: .voicePrompt,
                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
                )
                sessionConfigured = true
            }
            try session.setActive(true)
            return true
        } catch {
            AppLogger.log(
                "Couldn't start the audio session for a spoken cue: \(error.localizedDescription)",
                label: "RunVoiceCoach",
                level: .warning
            )
            return false
        }
    }
}

// MARK: - Session release

/// Releases the audio session once each utterance ends, which is what un-ducks the
/// runner's music.
///
/// A separate object rather than a conformance on ``RunVoiceCoach``:
/// `AVSpeechSynthesizerDelegate` is a UIKit-era protocol whose callbacks carry no
/// isolation, and satisfying it from the main-actor coach would mean making the coach's
/// own surface `nonisolated`. Nothing here touches coach state.
private final class RunVoiceSessionDeactivator: NSObject, AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Self.deactivate()
    }

    /// A cancel is either ``RunVoiceCoach/stop()``, which releases the session itself, or
    /// an interrupting cue cutting in — and then the replacement sentence has already been
    /// handed to the synthesizer, which `isSpeaking` reports ("speaking or has utterances
    /// enqueued"). Deactivating then would stop that sentence as it starts.
    ///
    /// `didFinish` above deliberately keeps no such check: if `isSpeaking` were still
    /// true while the last utterance's finish is delivered, the check would leave the
    /// runner's music ducked for the rest of the run, which is the worse failure.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard !synthesizer.isSpeaking else { return }
        Self.deactivate()
    }

    /// `.notifyOthersOnDeactivation` is the flag the other app is listening for: without
    /// it a paused podcast stays paused for the rest of the run.
    nonisolated static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
