import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

public extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    var isValid: Bool { self != AudioObjectID(kAudioObjectUnknown) }
}

/// One app whose level Audify should control.
public struct MixerTarget: Equatable, Sendable {
    public let id: String
    public let bundleIDs: [String]
    public let processObjectIDs: [AudioObjectID]
    public let volume: Float
    public let muted: Bool

    public init(
        id: String,
        bundleIDs: [String],
        processObjectIDs: [AudioObjectID],
        volume: Float,
        muted: Bool
    ) {
        self.id = id
        self.bundleIDs = bundleIDs
        self.processObjectIDs = processObjectIDs
        self.volume = volume
        self.muted = muted
    }

    public var effectiveGain: Float { muted ? 0 : volume }

    /// An app sitting at exactly unity gain needs no tap at all, so Audify leaves it strictly
    /// alone: no capture, no extra buffer, no added latency, no CPU. This is what keeps idle cost
    /// at zero and is the single most important behaviour in the engine.
    public var needsProcessing: Bool {
        muted || abs(volume - 1) > 0.005
    }
}

public enum MixerEngineError: Error, CustomStringConvertible {
    case noOutputDevice
    case permissionDenied
    case coreAudio(CAError)

    public var description: String {
        switch self {
        case .noOutputDevice: return "No usable audio output device."
        case .permissionDenied: return "Audify needs permission to capture system audio."
        case let .coreAudio(error): return error.description
        }
    }
}

/// Routes selected apps through a private aggregate device so their levels can be changed
/// independently, then mixes the result back to the real output device.
///
/// Shape of the graph — one aggregate device and one render callback no matter how many apps are
/// being controlled:
///
/// ```
///  Safari  ──▶ tap ─┐
///  Music   ──▶ tap ─┼─▶ private aggregate device ──▶ audifyRender (gain) ──▶ real output device
///  Zoom    ──▶ tap ─┘
///  everything else ─────────────────────────────────────────────────────────▶ real output device
/// ```
///
/// Taps use `.mutedWhenTapped`, so if Audify crashes or is killed the tapped apps immediately go
/// back to playing through the hardware at full volume. Failing open like that is worth more than
/// a slightly tidier graph.
public final class TapMixerEngine {
    private struct Tap {
        let objectID: AudioObjectID
        let uuid: UUID
        var processObjectIDs: [AudioObjectID]
    }

    private let renderContext = MixerRenderContext()
    private let log = Logger(subsystem: AudifyLog.subsystem, category: "engine")

    private var taps: [String: Tap] = [:]
    /// Tap keys in the same order as the aggregate device's tap list, which is also slot order.
    private var slotOrder: [String] = []
    private var slotIndexByKey: [String: Int] = [:]

    private var aggregateID = AudioObjectID.unknown
    private var aggregateUID: String?
    /// Tap UUIDs currently installed in the aggregate device, in order.
    private var appliedTapUUIDs: [String] = []
    private var ioProcID: AudioDeviceIOProcID?
    private var currentOutputDeviceID = AudioObjectID.unknown
    private var currentOutputUID: String?
    private var bufferFrames: UInt32 = 512
    private var inputBufferCount = 0

    public private(set) var isRunning = false
    public private(set) var lastError: MixerEngineError?
    /// Called on the main queue when the engine cannot do its job (typically missing permission).
    public var onError: ((MixerEngineError) -> Void)?

    public init() {}

    deinit { teardown() }

    // MARK: - Public control

    /// Reconciles the audio graph with the requested set of targets.
    ///
    /// Cheap and idempotent: called on every slider tick, every process-list change and every
    /// output-device change. Only real differences cause Core Audio work.
    @discardableResult
    public func update(
        targets: [MixerTarget],
        outputDeviceID: AudioObjectID,
        bufferFrames: UInt32,
        metersEnabled: Bool
    ) -> Bool {
        let active = targets.filter(\.needsProcessing)

        guard !active.isEmpty, outputDeviceID.isValid else {
            teardown()
            return true
        }

        do {
            // Reading the device UID is a Core Audio round trip, so only do it when the device
            // actually changed. `update` runs on every slider tick.
            let outputUID: String
            if outputDeviceID == currentOutputDeviceID, let cached = currentOutputUID {
                outputUID = cached
            } else {
                outputUID = try CAProperty.string(outputDeviceID, kAudioDevicePropertyDeviceUID)
            }

            let deviceChanged = outputUID != currentOutputUID
            let bufferChanged = bufferFrames != self.bufferFrames
            self.bufferFrames = bufferFrames

            if deviceChanged || bufferChanged {
                teardown()
                currentOutputDeviceID = outputDeviceID
                currentOutputUID = outputUID
            }

            try syncTaps(with: active)

            if aggregateID.isValid {
                try syncAggregateTapList()
            } else {
                try buildAggregate(outputUID: outputUID)
            }

            applyGains(active, metersEnabled: metersEnabled)
            lastError = nil
            return true
        } catch let error as CAError {
            handle(.coreAudio(error))
            return false
        } catch let error as MixerEngineError {
            handle(error)
            return false
        } catch {
            handle(.coreAudio(.osStatus(-1, "\(error)")))
            return false
        }
    }

    /// Live peak level (0...1+) for a target, or 0 when it is not being processed.
    public func peakLevel(for key: String) -> Float {
        guard let index = slotIndexByKey[key] else { return 0 }
        return renderContext.peak(slot: index)
    }

    /// Number of render cycles dropped because the graph was being restructured. Diagnostics only.
    public var skippedCycles: Int32 { renderContext.header.pointee.skippedCycles }

    /// Render callbacks served since the graph started. Diagnostics only.
    public var renderCycles: Int32 { renderContext.header.pointee.renderCycles }

    /// Total input frames pulled from taps. Zero with a non-zero render count means the taps are
    /// running but delivering nothing.
    public var inputFrames: Int32 { renderContext.header.pointee.inputFrames }

    /// True once any tap has delivered a non-silent sample, which is the only trustworthy proof
    /// that audio capture is actually permitted.
    public var hasSeenSignal: Bool { renderContext.header.pointee.signalSeen != 0 }

    public var activeTapCount: Int { taps.count }

    /// Tears the whole graph down. Tapped apps revert to playing directly through the hardware.
    public func teardown() {
        if let ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        aggregateUID = nil
        appliedTapUUIDs = []

        for tap in taps.values {
            AudioHardwareDestroyProcessTap(tap.objectID)
        }
        taps.removeAll()
        slotOrder.removeAll()
        slotIndexByKey.removeAll()
        renderContext.withStructuralLock {
            renderContext.header.pointee.slotCount = 0
        }
        currentOutputUID = nil
        isRunning = false
    }

    // MARK: - Taps

    private func syncTaps(with targets: [MixerTarget]) throws {
        let wanted = Set(targets.map(\.id))

        for (key, tap) in taps where !wanted.contains(key) {
            AudioHardwareDestroyProcessTap(tap.objectID)
            taps.removeValue(forKey: key)
        }

        for target in targets {
            if let existing = taps[target.id] {
                if existing.processObjectIDs != target.processObjectIDs {
                    // The app relaunched, or spawned a new audio helper: retarget in place rather
                    // than destroying the tap, which would glitch the audio.
                    retarget(existing, to: target)
                }
            } else {
                taps[target.id] = try makeTap(for: target)
            }
        }
    }

    private func makeTap(for target: MixerTarget) throws -> Tap {
        let description = CATapDescription(
            stereoMixdownOfProcesses: target.processObjectIDs
        )
        let uuid = UUID()
        description.uuid = uuid
        description.name = "Audify · \(target.id)"
        description.isPrivate = true
        description.isExclusive = false
        description.isMono = false
        description.isMixdown = true
        // Fail open: if Audify goes away mid-session the app is heard again immediately.
        description.muteBehavior = .mutedWhenTapped

        if #available(macOS 26.0, *) {
            // macOS 26 can re-attach a tap to an app by bundle identifier when it relaunches,
            // which keeps a user's choice sticky across quits without any work on our side.
            description.bundleIDs = target.bundleIDs
            description.isProcessRestoreEnabled = true
        }

        var tapID = AudioObjectID.unknown
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID.isValid else {
            if Self.isPermissionFailure(status) { throw MixerEngineError.permissionDenied }
            throw CAError.osStatus(status, "AudioHardwareCreateProcessTap(\(target.id))")
        }

        log.debug("Created tap \(tapID) for \(target.id, privacy: .public)")
        return Tap(objectID: tapID, uuid: uuid, processObjectIDs: target.processObjectIDs)
    }

    /// Rewrites a live tap's description so it follows the app's current audio processes.
    private func retarget(_ tap: Tap, to target: MixerTarget) {
        let description = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
        description.uuid = tap.uuid
        description.name = "Audify · \(target.id)"
        description.isPrivate = true
        description.isExclusive = false
        description.isMono = false
        description.isMixdown = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            description.bundleIDs = target.bundleIDs
            description.isProcessRestoreEnabled = true
        }

        do {
            try CAProperty.setCFValue(
                tap.objectID, kAudioTapPropertyDescription, to: description
            )
            taps[target.id]?.processObjectIDs = target.processObjectIDs
            log.debug("Retargeted tap for \(target.id, privacy: .public)")
        } catch {
            log.warning("Retarget failed for \(target.id, privacy: .public), recreating tap")
            AudioHardwareDestroyProcessTap(tap.objectID)
            taps.removeValue(forKey: target.id)
            // The caller runs syncAggregateTapList() next, which now notices the new UUID.
            if let replacement = try? makeTap(for: target) {
                taps[target.id] = replacement
            }
        }
    }

    private static func isPermissionFailure(_ status: OSStatus) -> Bool {
        // Core Audio surfaces a denied TCC prompt as a generic "not permitted" style error.
        let permissionCodes: Set<OSStatus> = [
            OSStatus(bitPattern: 0x2170_726D), // '!prm'
            OSStatus(bitPattern: 0x2170_7269), // '!pri'
            kAudioHardwareIllegalOperationError,
            kAudioHardwareUnspecifiedError,
        ]
        return permissionCodes.contains(status)
    }

    // MARK: - Aggregate device

    private func buildAggregate(outputUID: String) throws {
        let uid = "com.audify.mixer." + UUID().uuidString
        let tapEntries = orderedTaps().map { tap in
            [
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ] as [String: Any]
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audify Mixer",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private keeps the device out of Sound Settings and every other app's device list.
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    // Zero input channels: we only ever want tap streams on the input side, which
                    // also keeps the buffer-index mapping below simple.
                    kAudioSubDeviceInputChannelsKey: 0,
                ] as [String: Any],
            ],
            kAudioAggregateDeviceTapListKey: tapEntries,
        ]

        var deviceID = AudioObjectID.unknown
        try checkStatus(
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = deviceID
        aggregateUID = uid
        appliedTapUUIDs = tapEntries.compactMap { $0[kAudioSubTapUIDKey] as? String }

        try? CAProperty.setValue(
            deviceID, kAudioDevicePropertyBufferFrameSize,
            scope: kAudioObjectPropertyScopeGlobal, to: bufferFrames
        )

        try startIO()
        rebuildSlotMap()
        isRunning = true
        log.info("Aggregate device \(deviceID) running with \(self.taps.count) tap(s)")
    }

    /// Pushes the current tap set onto a live aggregate device, avoiding a full rebuild.
    private func syncAggregateTapList() throws {
        guard aggregateID.isValid else { return }
        let ordered = orderedTaps()
        let desired = ordered.map(\.uuid.uuidString)

        // Compared by UUID, not by count: a tap that was destroyed and recreated keeps the count
        // the same while changing identity, and leaving the old UUID installed would silently
        // leave the app muted with nothing feeding it.
        guard desired != appliedTapUUIDs else { return }

        do {
            try CAProperty.setCFValue(
                aggregateID, kAudioAggregateDevicePropertyTapList, to: desired as CFArray
            )
            appliedTapUUIDs = desired
            rebuildSlotMap()
        } catch {
            // Some driver/OS combinations refuse a live tap-list edit; rebuilding always works.
            log.notice("Live tap-list update rejected, rebuilding aggregate device")
            let outputUID = currentOutputUID
            stopIO()
            if aggregateID.isValid {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                aggregateID = .unknown
            }
            if let outputUID { try buildAggregate(outputUID: outputUID) }
        }
    }

    private func orderedKeys() -> [String] { taps.keys.sorted() }

    private func orderedTaps() -> [Tap] {
        orderedKeys().compactMap { taps[$0] }
    }

    private func startIO() throws {
        guard aggregateID.isValid, ioProcID == nil else { return }

        let slots = renderContext.slots
        let header = renderContext.header
        let lock = renderContext.lock

        var procID: AudioDeviceIOProcID?
        // A nil queue keeps the callback on Core Audio's own real-time thread. Dispatching to a
        // queue would add a hop of latency and break the real-time guarantees we rely on.
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                audifyRender(
                    slots: slots, header: header, lock: lock, input: input, output: output
                )
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = procID

        guard let procID else { throw MixerEngineError.noOutputDevice }
        try checkStatus(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func stopIO() {
        guard let ioProcID, aggregateID.isValid else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        self.ioProcID = nil
        isRunning = false
    }

    // MARK: - Slot mapping

    /// Maps each tap onto its index in the aggregate device's input buffer list.
    ///
    /// Stream order in an aggregate device follows the composition: sub-devices first, then taps in
    /// tap-list order. The sub-device contributes zero input channels here, so taps should start at
    /// index 0 — but the offset is computed rather than assumed, so a driver that reports extra
    /// input streams still maps correctly.
    private func rebuildSlotMap() {
        let layout = inputChannelLayout()
        inputBufferCount = layout.count
        let keys = orderedKeys()
        let offset = max(0, layout.count - keys.count)

        // Everything that can be computed without the lock is computed first: the render thread
        // drops a buffer whenever it cannot take this lock, so the critical section is kept to a
        // handful of stores.
        var mapping: [String: Int] = [:]
        var plan: [(buffer: Int32, channels: Int32)] = []
        for key in keys where plan.count < MixerRenderContext.capacity {
            let bufferIndex = offset + plan.count
            let valid = bufferIndex < layout.count
            mapping[key] = plan.count
            plan.append((
                buffer: valid ? Int32(bufferIndex) : -1,
                channels: Int32(valid ? layout[bufferIndex] : 2)
            ))
        }
        let ramp = rampCoefficient()

        renderContext.withStructuralLock {
            for (index, entry) in plan.enumerated() {
                renderContext.slots[index].inputBufferIndex = entry.buffer
                renderContext.slots[index].inputChannels = entry.channels
            }
            renderContext.header.pointee.slotCount = Int32(plan.count)
            renderContext.header.pointee.rampCoefficient = ramp
        }

        slotIndexByKey = mapping
        slotOrder = keys

        if layout.count != keys.count {
            log.notice(
                "Input stream layout \(layout.count) buffer(s) vs \(keys.count) tap(s); using offset \(offset)"
            )
        }
    }

    /// Channel count of each input buffer the aggregate device will hand to the render callback.
    private func inputChannelLayout() -> [Int] {
        guard aggregateID.isValid else { return [] }
        var addr = CAProperty.address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<UInt32>.size)
        else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else {
            return []
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.map { Int($0.mNumberChannels) }
    }

    private func rampCoefficient() -> Float {
        let sampleRate = (try? CAProperty.value(
            aggregateID, kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48000)
        )) ?? 48000
        // ~12 ms glide: fast enough to feel instant, slow enough to be inaudible.
        let seconds: Float = 0.012
        return min(1, max(0.0005, 1 / (Float(sampleRate) * seconds)))
    }

    // MARK: - Gains

    private func applyGains(_ targets: [MixerTarget], metersEnabled: Bool) {
        var needsSoftClip = false
        for target in targets {
            guard let index = slotIndexByKey[target.id] else { continue }
            let gain = max(0, target.effectiveGain)
            renderContext.setGain(slot: index, gain: gain)
            if gain > 1.001 { needsSoftClip = true }
        }
        renderContext.header.pointee.softClip = needsSoftClip ? 1 : 0
        renderContext.header.pointee.metersEnabled = metersEnabled ? 1 : 0
    }

    private func handle(_ error: MixerEngineError) {
        lastError = error
        log.error("\(error.description, privacy: .public)")
        onError?(error)
    }

    // MARK: - Diagnostics

    public struct Diagnostics {
        public var aggregateDeviceID: AudioObjectID
        public var tapCount: Int
        public var inputBufferChannels: [Int]
        public var slotOrder: [String]
        public var skippedCycles: Int32
        public var renderCycles: Int32
        public var inputFrames: Int32
        public var hasSeenSignal: Bool
        public var isRunning: Bool
    }

    public func diagnostics() -> Diagnostics {
        Diagnostics(
            aggregateDeviceID: aggregateID,
            tapCount: taps.count,
            inputBufferChannels: inputChannelLayout(),
            slotOrder: slotOrder,
            skippedCycles: skippedCycles,
            renderCycles: renderCycles,
            inputFrames: inputFrames,
            hasSeenSignal: hasSeenSignal,
            isRunning: isRunning
        )
    }
}
