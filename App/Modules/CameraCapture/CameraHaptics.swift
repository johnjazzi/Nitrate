import AVFAudio
import OSLog

/// Capture's active audio input must not silence the camera controls. This
/// changes only the haptic opt-in, never the audio category, route or activity.
enum CameraHaptics {
    private static let logger = Logger(subsystem: "com.nitrate.app", category: "CameraHaptics")

    static func prepareForCaptureFeedback() {
        let audio = AVAudioSession.sharedInstance()
        guard !audio.allowHapticsAndSystemSoundsDuringRecording else { return }
        do {
            try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            logger.error("Could not enable capture control haptics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
