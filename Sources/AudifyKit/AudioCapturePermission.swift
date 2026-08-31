import CoreAudio
import Foundation
import OSLog

/// Audify's use of Core Audio process taps is gated by the system's audio-capture privacy control
/// (System Settings ▸ Privacy & Security ▸ Audio Recording). This wraps priming and checking it.
public enum AudioCapturePermission {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        case unknown
    }

    private static let log = Logger(subsystem: AudifyLog.subsystem, category: "permission")

    /// Creates and immediately destroys a silent, private global tap.
    ///
    /// This is what surfaces the system permission prompt on first launch, without needing an app
    /// to be playing audio: a global tap needs no target process.
    ///
    /// Note what this can and cannot tell us. A failure here is conclusive — the tap was refused.
    /// Success is **not** proof of permission: when audio capture is denied, Core Audio still
    /// creates the tap and still runs the render callback, and merely delivers buffers of zeros.
    /// That is why the verdict is `.unknown` on success and only `TapMixerEngine`'s
    /// `hasSeenSignal` can promote it to `.granted`.
    @discardableResult
    public static func probe() -> Status {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Audify permission check"
        description.uuid = UUID()
        description.isPrivate = true
        // Nothing is muted and nothing is read; this exists purely to trigger the prompt.
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        if status == noErr, tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            return .unknown
        }

        log.notice("Audio capture probe returned \(CAError.fourCC(status), privacy: .public)")
        return .denied
    }

    /// Opens the pane where the user grants audio capture.
    ///
    /// The anchor name has moved between releases, so the candidates are tried in order and the
    /// Privacy root is the final fallback.
    public static var settingsURLs: [URL] {
        [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ].compactMap(URL.init(string:))
    }
}
