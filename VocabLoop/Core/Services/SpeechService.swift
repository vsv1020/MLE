import Foundation
import AVFoundation
import OSLog

/// Pronounces words and example sentences.
///
/// Uses `AVSpeechSynthesizer` rather than recorded audio because it is on-device,
/// free, offline, and available in every language on the roadmap. Recorded audio would
/// sound better but would have to be downloaded, which breaks the offline-first rule
/// that everything the app teaches must work with the radio off.
@MainActor
public final class SpeechService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "speech")

    /// `true` while speaking, so the speaker button can show its active state.
    public private(set) var isSpeaking = false

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `text` in `language`.
    ///
    /// Slightly below the default rate: learners need to hear the segments, and the
    /// system default is tuned for people who already know the language.
    public func speak(_ text: String, language: LearningLanguage, rate: Float = 0.45) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Tapping the speaker twice should restart, not queue up a second reading.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        configureAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// `false` when no voice for the language is installed, so the UI can hide the
    /// speaker button instead of offering a control that silently does nothing.
    public func isSupported(_ language: LearningLanguage) -> Bool {
        voice(for: language) != nil
    }

    private func voice(for language: LearningLanguage) -> AVSpeechSynthesisVoice? {
        // Exact tag first ("en-US"), then any voice for the base language, so a device
        // with only "en-GB" installed still speaks English.
        if let exact = AVSpeechSynthesisVoice(language: language.speechLanguageTag) {
            return exact
        }
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.language.hasPrefix(language.rawValue)
        }
    }

    /// Play through the silent switch — a user who has taken the trouble to tap the
    /// speaker wants to hear it — but duck rather than stop whatever else is playing,
    /// so studying alongside music or a podcast still works.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            logger.error("Audio session unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        releaseAudioSession()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        releaseAudioSession()
    }

    /// Hand the session back so other apps' audio returns to full volume. Leaving it
    /// active keeps everything else ducked for as long as the app is open.
    private func releaseAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
