import CoreAudio
import Foundation
import OSLog

/// Owns the system default input device's mute state.
///
/// Mirrors `OutputDeviceController` deliberately: same event-driven shape, same "read hardware
/// state back, never assume" discipline, so the two read identically in the UI and cost the same
/// (nothing) while idle.
///
/// Muting here is a hardware/driver-level toggle (`kAudioDevicePropertyMute` on the input scope),
/// the same control System Settings and Control Center use — it is not audio capture, so it needs
/// no privacy permission and involves no Core Audio tap.
@MainActor
public final class MicrophoneController: ObservableObject {
    @Published public private(set) var defaultDeviceID = AudioObjectID.unknown
    @Published public private(set) var deviceName = ""
    @Published public private(set) var isMuted = false
    /// False for the rare input device with no mute control at all (falls back to volume 0).
    @Published public private(set) var supportsHardwareMute = true
    /// True once a default input device has been found at all — false on a Mac with no mic.
    @Published public private(set) var isAvailable = false

    private var defaultDeviceObserver: CAPropertyObserver?
    private var muteObserver: CAPropertyObserver?
    /// Volume saved before a software-mute fallback, restored on unmute.
    private var volumeBeforeFallbackMute: Float?

    private let log = Logger(subsystem: AudifyLog.subsystem, category: "microphone")

    public init() {}

    public func start() {
        defaultDeviceObserver = CAPropertyObserver(
            object: CAProperty.systemObject,
            selector: kAudioHardwarePropertyDefaultInputDevice
        ) { [weak self] in
            MainActor.assumeIsolated { self?.reloadDefaultDevice() }
        }
        reloadDefaultDevice()
    }

    public func stop() {
        defaultDeviceObserver = nil
        muteObserver = nil
    }

    private func reloadDefaultDevice() {
        let id = (try? CAProperty.value(
            CAProperty.systemObject,
            kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioObjectID.unknown
        )) ?? .unknown

        defaultDeviceID = id
        volumeBeforeFallbackMute = nil
        guard id.isValid else {
            isAvailable = false
            deviceName = ""
            return
        }

        isAvailable = true
        deviceName = (try? CAProperty.string(id, kAudioObjectPropertyName)) ?? "Microphone"
        supportsHardwareMute = CAProperty.isSettable(
            id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput
        )
        observe(id)
        readState()
    }

    private func observe(_ id: AudioObjectID) {
        muteObserver = CAPropertyObserver(
            object: id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput
        ) { [weak self] in
            MainActor.assumeIsolated { self?.readState() }
        }
    }

    private func readState() {
        guard defaultDeviceID.isValid else { return }

        if supportsHardwareMute {
            let mute = (try? CAProperty.value(
                defaultDeviceID, kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeInput, defaultValue: UInt32(0)
            )) ?? 0
            isMuted = mute == 1
        }
        // When hardware mute is unsupported, `isMuted` is driven entirely by `toggleMute()` below
        // rather than read back, since a volume of 0 is not distinguishable from a user choice.
    }

    /// Toggles the microphone off or on, this is what the global shortcut and menu button call.
    public func toggleMute() {
        setMuted(!isMuted)
    }

    public func setMuted(_ muted: Bool) {
        guard defaultDeviceID.isValid else { return }

        if supportsHardwareMute {
            try? CAProperty.setValue(
                defaultDeviceID, kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeInput, to: UInt32(muted ? 1 : 0)
            )
            isMuted = muted
            return
        }

        // Fallback for input devices that expose no mute control (some USB and Bluetooth mics):
        // drive the volume to zero and restore whatever it was before.
        if muted {
            let current = (try? CAProperty.value(
                defaultDeviceID, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput, defaultValue: Float32(1)
            )) ?? 1
            volumeBeforeFallbackMute = current
            try? CAProperty.setValue(
                defaultDeviceID, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput, to: Float32(0)
            )
        } else {
            let restore = volumeBeforeFallbackMute ?? 1
            try? CAProperty.setValue(
                defaultDeviceID, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput, to: Float32(restore)
            )
            volumeBeforeFallbackMute = nil
        }
        isMuted = muted
    }
}
