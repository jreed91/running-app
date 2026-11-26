import AVFoundation
import Foundation

// MARK: - WatchRunVoice

/// Speaks the run's cues from the Watch (Watch runs, PR 4): through AirPods or other
/// Bluetooth headphones when they are connected, else the Watch's own speaker.
///
/// The Watch's counterpart of the phone's `RunVoiceCoach`, with the same voice settings
/// and the same audio session: a voice prompt that ducks the runner's music, released
/// after each phrase so the music comes back up. Kept separate because that type reaches
/// into app-only logging and UI-test support.
@MainActor
final class WatchRunVoice {

    private let synthesizer = AVSpeechSynthesizer()
    private let releaser = WatchVoiceSessionReleaser()
    private var sessionConfigured = false

    init() {
        synthesizer.delegate = releaser
    }

    /// Speaks `phrases` as one utterance, cutting off anything still being said: a cue
    /// that arrives late is worth less than the one about the runner's position now.
    /// One utterance, like the phone, so each finish can release the session safely.
    func speak(_ phrases: [String]) {
        guard !phrases.isEmpty else { return }
        if synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        guard activateSession() else { return }
        let utterance = AVSpeechUtterance(string: phrases.joined(separator: " "))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier(.bcp47))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Stops speaking and gives the audio back, at the end of a run.
    func stop() {
        if synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
        WatchVoiceSessionReleaser.release()
    }

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if !sessionConfigured {
                try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
                sessionConfigured = true
            }
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Session release

/// Releases the audio session when a phrase ends, which un-ducks the music.
/// Its own object for the reason the phone's `RunVoiceSessionDeactivator` is: the delegate
/// callbacks carry no isolation.
private final class WatchVoiceSessionReleaser: NSObject, AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Self.release()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        Self.release()
    }

    nonisolated static func release() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
