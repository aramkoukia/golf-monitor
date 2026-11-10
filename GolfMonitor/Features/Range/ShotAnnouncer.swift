import AVFoundation

protocol ShotAnnouncing: AnyObject {
    func announce(_ text: String)
}

/// Speaks the result so you hear your numbers at the mat without looking at
/// the phone (on-device speech synthesis).
final class ShotAnnouncer: ShotAnnouncing {
    private let synthesizer = AVSpeechSynthesizer()

    func announce(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    /// "152 yards carry. Ball speed 121." — nil when there is nothing to say.
    static func sentence(for outcome: SessionOutcome, settings: SettingsStore) -> String? {
        guard let shot = outcome.featured?.shot else { return nil }
        guard shot.hasLaunchData else {
            return outcome.struckCount > 0 ? "Shot saved. Ball flight unclear." : "Swing saved."
        }
        let carry = Int(settings.distanceValue(yards: shot.carryYards).rounded())
        let unit = settings.distanceUnit == .yards ? "yards" : "metres"
        let speed = Int(settings.speedValue(mph: shot.ballSpeedMph).rounded())
        return "\(carry) \(unit) carry. Ball speed \(speed)."
    }
}
