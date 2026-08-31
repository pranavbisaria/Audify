import CoreAudio
import Foundation
import OSLog

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let transportType: UInt32

    /// SF Symbol that matches how the device is connected.
    public var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform.circle"
        default:
            return "speaker.wave.2"
        }
    }
}

/// Owns the system output device: which one is default, its master level and its mute state.
///
/// The master slider drives the hardware device itself rather than anything in our own graph, so it
/// behaves exactly like the volume keys and affects untapped apps too.
@MainActor
public final class OutputDeviceController: ObservableObject {
    @Published public private(set) var devices: [AudioOutputDevice] = []
    @Published public private(set) var defaultDeviceID = AudioObjectID.unknown
    @Published public var masterVolume: Float = 1
    @Published public var isMuted = false
    /// False for devices with no software-settable level, e.g. many HDMI and pro interfaces.
    @Published public private(set) var supportsVolumeControl = true

    private var deviceListObserver: CAPropertyObserver?
    private var defaultDeviceObserver: CAPropertyObserver?
    private var volumeObserver: CAPropertyObserver?
    private var muteObserver: CAPropertyObserver?
    private var sampleRateObserver: CAPropertyObserver?
    private var suppressWrites = false

    private let log = Logger(subsystem: AudifyLog.subsystem, category: "device")

    /// Fires when the default device changes or its sample rate moves, so the mixer can rebuild.
    public var onDeviceInvalidated: (() -> Void)?

    public init() {}

    public func start() {
        deviceListObserver = CAPropertyObserver(
            object: CAProperty.systemObject,
            selector: kAudioHardwarePropertyDevices
        ) { [weak self] in
            MainActor.assumeIsolated { self?.reloadDevices() }
        }
        defaultDeviceObserver = CAPropertyObserver(
            object: CAProperty.systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadDefaultDevice()
                self?.onDeviceInvalidated?()
            }
        }
        reloadDevices()
        reloadDefaultDevice()
    }

    public func stop() {
        deviceListObserver = nil
        defaultDeviceObserver = nil
        volumeObserver = nil
        muteObserver = nil
        sampleRateObserver = nil
    }

    // MARK: - Device list

    public func reloadDevices() {
        let ids = (try? CAProperty.array(
            CAProperty.systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self
        )) ?? []

        let current = currentDefaultDeviceID()
        devices = ids.compactMap { id -> AudioOutputDevice? in
            guard hasOutputStreams(id) else { return nil }
            guard let name = try? CAProperty.string(id, kAudioObjectPropertyName),
                  let uid = try? CAProperty.string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            // Our own private aggregate is invisible to other processes but not to us.
            if uid.hasPrefix("com.audify.mixer.") { return nil }
            let transport = (try? CAProperty.value(
                id, kAudioDevicePropertyTransportType, defaultValue: UInt32(0)
            )) ?? 0
            return AudioOutputDevice(
                id: id, uid: uid, name: name, isDefault: id == current, transportType: transport
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        guard let size = try? CAProperty.dataSize(
            device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput
        ) else { return false }
        return size >= UInt32(MemoryLayout<AudioObjectID>.size)
    }

    private func currentDefaultDeviceID() -> AudioObjectID {
        (try? CAProperty.value(
            CAProperty.systemObject,
            kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioObjectID.unknown
        )) ?? .unknown
    }

    // MARK: - Default device

    public func reloadDefaultDevice() {
        let id = currentDefaultDeviceID()
        defaultDeviceID = id
        guard id.isValid else {
            supportsVolumeControl = false
            return
        }
        observeDefaultDevice(id)
        readLevel()
        reloadDevices()
    }

    public func selectDevice(_ device: AudioOutputDevice) {
        do {
            try CAProperty.setValue(
                CAProperty.systemObject,
                kAudioHardwarePropertyDefaultOutputDevice,
                to: device.id
            )
        } catch {
            log.error("Could not switch output device: \(String(describing: error))")
        }
    }

    private func observeDefaultDevice(_ id: AudioObjectID) {
        volumeObserver = CAPropertyObserver(
            object: id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput
        ) { [weak self] in
            MainActor.assumeIsolated { self?.readLevel() }
        }
        muteObserver = CAPropertyObserver(
            object: id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ) { [weak self] in
            MainActor.assumeIsolated { self?.readLevel() }
        }
        sampleRateObserver = CAPropertyObserver(
            object: id,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            MainActor.assumeIsolated { self?.onDeviceInvalidated?() }
        }
    }

    // MARK: - Level

    /// Reads volume and mute back from the hardware, tolerating devices that only expose
    /// per-channel controls.
    private func readLevel() {
        guard defaultDeviceID.isValid else { return }
        suppressWrites = true
        defer { suppressWrites = false }

        // Readable is not the same as adjustable: several HDMI and pro interfaces report a level
        // they will not let anyone change, and the slider must be disabled for those.
        let settable = CAProperty.isSettable(
            defaultDeviceID, kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput
        ) || CAProperty.isSettable(
            defaultDeviceID, kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput, element: 1
        )

        if let volume = readMainVolume() {
            masterVolume = volume
            supportsVolumeControl = settable
        } else {
            supportsVolumeControl = false
        }

        let mute = (try? CAProperty.value(
            defaultDeviceID, kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput, defaultValue: UInt32(0)
        )) ?? 0
        isMuted = mute == 1
    }

    private func readMainVolume() -> Float? {
        let device = defaultDeviceID
        if let value = try? CAProperty.value(
            device, kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput, defaultValue: Float32(0)
        ) {
            return value
        }
        // Fall back to averaging the first two channels.
        var sum: Float = 0
        var count = 0
        for channel in UInt32(1)...UInt32(2) {
            if let value = try? CAProperty.value(
                device, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput, element: channel, defaultValue: Float32(0)
            ) {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    /// Writes the master level to the hardware. Ignored while we are reading state back.
    public func applyMasterVolume(_ value: Float) {
        guard !suppressWrites, defaultDeviceID.isValid, supportsVolumeControl else { return }
        let clamped = min(max(value, 0), 1)
        let device = defaultDeviceID

        if CAProperty.isSettable(
            device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput
        ) {
            try? CAProperty.setValue(
                device, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput, to: Float32(clamped)
            )
            return
        }
        for channel in UInt32(1)...UInt32(2) {
            try? CAProperty.setValue(
                device, kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeOutput, element: channel, to: Float32(clamped)
            )
        }
    }

    public func applyMute(_ muted: Bool) {
        guard !suppressWrites, defaultDeviceID.isValid else { return }
        try? CAProperty.setValue(
            defaultDeviceID, kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput, to: UInt32(muted ? 1 : 0)
        )
    }

    public func toggleMute() {
        isMuted.toggle()
        applyMute(isMuted)
    }

    public var defaultDeviceName: String {
        devices.first { $0.id == defaultDeviceID }?.name ?? "Output"
    }
}
