import AVFoundation
import Combine
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "Speech")

/// Service to read AI responses aloud using text-to-speech
final class SpeechOutputService: NSObject, ObservableObject {
    static let shared = SpeechOutputService()

    private let synthesizer = AVSpeechSynthesizer()

    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var currentUtterance: String?

    // User preferences
    @Published var speechRate: Float = 0.52 {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "tts_speech_rate")
        }
    }

    @Published var speechPitch: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(speechPitch, forKey: "tts_speech_pitch")
        }
    }

    @Published var speechVolume: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(speechVolume, forKey: "tts_speech_volume")
        }
    }

    @Published var voiceIdentifier: String? {
        didSet {
            if let id = voiceIdentifier {
                UserDefaults.standard.set(id, forKey: "tts_voice_identifier")
            }
        }
    }

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "tts_enabled")
        }
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
        loadPreferences()
    }

    private func loadPreferences() {
        speechRate = UserDefaults.standard.float(forKey: "tts_speech_rate")
        if speechRate == 0 { speechRate = 0.52 }

        speechPitch = UserDefaults.standard.float(forKey: "tts_speech_pitch")
        if speechPitch == 0 { speechPitch = 1.0 }

        speechVolume = UserDefaults.standard.float(forKey: "tts_speech_volume")
        if speechVolume == 0 { speechVolume = 1.0 }

        voiceIdentifier = UserDefaults.standard.string(forKey: "tts_voice_identifier")
        isEnabled = UserDefaults.standard.bool(forKey: "tts_enabled")
    }

    /// Speak the given text
    func speak(_ text: String) {
        stop()

        let utterance = AVSpeechUtterance(string: text)

        // Apply settings
        if let voiceId = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else {
            // Default to a good US English voice
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        utterance.rate = speechRate
        utterance.pitchMultiplier = speechPitch
        utterance.volume = speechVolume

        currentUtterance = text
        synthesizer.speak(utterance)

        logger.info("Speaking: \(text.prefix(50))...")
    }

    /// Stop speaking immediately
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
        currentUtterance = nil
    }

    /// Pause speaking
    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
            isPaused = true
        }
    }

    /// Resume speaking
    func resume() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        }
    }

    /// Toggle pause/resume
    func togglePause() {
        if isPaused {
            resume()
        } else if isSpeaking {
            pause()
        }
    }

    /// Get all available voices
    func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
    }

    /// Get voices filtered by language
    func voices(forLanguage language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
    }

    /// Get English voices
    func englishVoices() -> [AVSpeechSynthesisVoice] {
        voices(forLanguage: "en")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechOutputService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
            self.isPaused = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPaused = false
            self.currentUtterance = nil
        }
        logger.info("Finished speaking")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPaused = false
            self.currentUtterance = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPaused = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPaused = false
        }
    }
}
