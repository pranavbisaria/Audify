import AppKit
import AudifyKit
import CoreAudio
import Foundation

/// `Audify --diagnose` prints the audio graph as Audify sees it.
///
/// This exists because per-app audio problems are almost always environmental — a permission that
/// was never granted, an output device with no software volume, an aggregate device whose stream
/// layout differs from the norm. Having one command that dumps all of it makes support tractable.
enum Diagnostics {
    /// Collected output, so the report can be written to a file when Audify is launched by
    /// Launch Services (`open -a Audify --args --diagnose <path>`) rather than from a shell.
    ///
    /// The distinction matters: macOS attributes a privacy request to the *responsible* process,
    /// so a run started from a terminal is judged as the terminal, while a Launch Services start is
    /// judged as Audify. Only the latter can raise Audify's own permission prompt.
    private nonisolated(unsafe) static var transcript: [String] = []
    private nonisolated(unsafe) static var capturing = false

    private static func print(_ line: String = "") {
        if capturing { transcript.append(line) } else { Swift.print(line) }
    }

    static func run(writingTo path: String?) {
        if path != nil {
            capturing = true
            transcript.removeAll()
        }
        run()
        if let path {
            capturing = false
            try? transcript.joined(separator: "\n").appending("\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func run() {
        print("Audify \(AppInfo.version) (\(AppInfo.build)) diagnostics")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Bundled: \(Bundle.main.bundleIdentifier ?? "no — running as a bare executable")")
        print("")

        let creation = AudioCapturePermission.probe()
        print("Tap creation: \(creation == .denied ? "REFUSED" : "allowed")")
        print("  note: allowed creation does not prove permission — when audio capture is denied,")
        print("        macOS creates the tap anyway and delivers silence. The live test below is")
        print("        what actually settles it.")
        print("")

        let processes = (try? CAProperty.array(
            CAProperty.systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self
        )) ?? []
        print("Audio process objects: \(processes.count)")
        for object in processes {
            let pid = (try? CAProperty.value(object, kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            let bundle = (try? CAProperty.string(object, kAudioProcessPropertyBundleID)) ?? "—"
            let playing = ((try? CAProperty.value(
                object, kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)
            )) ?? 0) == 1
            print("  [\(object)] pid \(pid)\(playing ? " ▶︎" : "  ") \(bundle)")
        }
        print("")

        let devices = (try? CAProperty.array(
            CAProperty.systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self
        )) ?? []
        let defaultDevice = (try? CAProperty.value(
            CAProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioObjectID.unknown
        )) ?? .unknown
        print("Output devices:")
        for device in devices {
            guard let name = try? CAProperty.string(device, kAudioObjectPropertyName) else { continue }
            let hasOutput = ((try? CAProperty.dataSize(
                device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput
            )) ?? 0) > 0
            guard hasOutput else { continue }
            let settable = CAProperty.isSettable(
                device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput
            )
            let rate = (try? CAProperty.value(
                device, kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0)
            )) ?? 0
            let marker = device == defaultDevice ? "▸" : " "
            print("  \(marker) [\(device)] \(name) — \(Int(rate)) Hz, software volume: \(settable ? "yes" : "no")")
        }
        print("")

        guard defaultDevice.isValid else {
            print("Skipping live graph test: no default output device.")
            return
        }

        // Tap every process that is currently producing output, each in its own slot, and
        // report what actually arrives. Testing them all at once is the fastest way to tell a
        // broken graph apart from an app that happens to be emitting silence.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let playing = processes.filter { object in
            let running = ((try? CAProperty.value(
                object, kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)
            )) ?? 0) == 1
            let pid = (try? CAProperty.value(
                object, kAudioProcessPropertyPID, defaultValue: pid_t(-1)
            )) ?? -1
            return running && pid != ownPID
        }

        guard !playing.isEmpty else {
            print("Live graph test: no app is playing audio right now — start something and retry.")
            return
        }

        print("Live graph test against \(playing.count) playing process(es):")
        let engine = TapMixerEngine()
        let targets = playing.prefix(16).map { object -> MixerTarget in
            let pid = (try? CAProperty.value(
                object, kAudioProcessPropertyPID, defaultValue: pid_t(-1)
            )) ?? -1
            let bundle = (try? CAProperty.string(object, kAudioProcessPropertyBundleID)) ?? ""
            let key = bundle.isEmpty ? "pid:\(pid)" : bundle
            return MixerTarget(
                id: key, bundleIDs: bundle.isEmpty ? [] : [bundle],
                processObjectIDs: [object], volume: 0.5, muted: false
            )
        }

        let ok = engine.update(
            targets: Array(targets), outputDeviceID: defaultDevice,
            bufferFrames: 512, metersEnabled: true
        )
        let info = engine.diagnostics()
        print("  update succeeded: \(ok)")
        print("  running: \(info.isRunning)")
        print("  aggregate device: \(info.aggregateDeviceID)")
        print("  taps: \(info.tapCount)")
        print("  input buffer channels: \(info.inputBufferChannels)")
        if let error = engine.lastError { print("  error: \(error.description)") }

        // Let it render for a moment so the meters have something to report.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }

        print("  render callbacks: \(engine.renderCycles)")
        print("  input frames from taps: \(engine.inputFrames)")
        print("  skipped render cycles: \(engine.skippedCycles)")
        print("  peak per tap:")
        for target in targets {
            let peak = engine.peakLevel(for: target.id)
            let bar = String(repeating: "█", count: Int(min(peak, 1) * 30))
            print(String(format: "    %-42s %.4f %@", (target.id as NSString).utf8String!, peak, bar))
        }
        print("")
        if engine.renderCycles == 0 {
            print("  VERDICT: the render callback never fired — the aggregate device is not pulling.")
        } else if engine.inputFrames == 0 {
            print("  VERDICT: rendering, but no tap stream was mapped.")
        } else if !engine.hasSeenSignal {
            print("  VERDICT: audio capture is BLOCKED.")
            print("  Buffers arrive but every sample is zero, which is exactly how macOS behaves")
            print("  when a client lacks audio-capture permission. Enable Audify in")
            print("  System Settings ▸ Privacy & Security ▸ Audio Recording, then relaunch.")
        } else {
            print("  VERDICT: audio capture is working — per-app volume is fully functional.")
        }
        engine.teardown()
        print("  torn down cleanly")
    }
}
