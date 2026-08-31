import AppKit
import CoreAudio
import Foundation
import OSLog

/// One Core Audio process object.
public struct AudioProcessObject: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isPlaying: Bool
}

/// A user-facing audio source: one row in the mixer.
///
/// Several Core Audio process objects can collapse into a single source. Chromium browsers are
/// the motivating case — audio is emitted by `…Chrome.helper` renderer/audio service processes,
/// never by the main app — so we canonicalise helper bundle identifiers back onto their host app.
public struct AudioSource: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var bundleURL: URL?
    public var processObjectIDs: [AudioObjectID]
    public var pids: [pid_t]
    public var isPlaying: Bool

    /// True when this source is a browser we can also control at tab granularity.
    public var isBrowser: Bool { BrowserIdentity.isBrowser(bundleID: id) }
}

enum BrowserIdentity {
    static let known: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev",
        "com.google.chrome.canary", "com.microsoft.edgemac", "com.microsoft.edgemac.beta",
        "com.brave.browser", "com.brave.browser.beta", "com.vivaldi.vivaldi",
        "company.thebrowser.browser", "company.thebrowser.dia", "com.operasoftware.opera",
        "com.operasoftware.operagx", "org.mozilla.firefox", "com.apple.safari",
        "ai.perplexity.comet", "com.pushplaylabs.sidekick", "com.sigmaos.sigmaos",
    ]

    static func isBrowser(bundleID: String) -> Bool {
        known.contains(bundleID.lowercased())
    }
}

/// Watches the system's audio process list and keeps `sources` current.
///
/// There is no timer anywhere in this class: updates arrive from Core Audio property listeners,
/// which means a machine with no audio activity costs Audify literally zero cycles.
@MainActor
public final class AudioProcessRegistry: ObservableObject {
    @Published public private(set) var sources: [AudioSource] = []

    private var listObserver: CAPropertyObserver?
    private var runningObservers: [AudioObjectID: CAPropertyObserver] = [:]
    private var identityCache: [String: (name: String, url: URL?)] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let log = Logger(subsystem: AudifyLog.subsystem, category: "processes")

    public init() {}

    public func start() {
        listObserver = CAPropertyObserver(
            object: CAProperty.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    public func stop() {
        listObserver = nil
        runningObservers.removeAll()
    }

    /// Rebuilds `sources` from the current process object list.
    public func refresh() {
        let processes = currentProcesses()
        syncRunningObservers(for: processes)

        var grouped: [String: AudioSource] = [:]
        for process in processes {
            let key = Self.canonicalBundleID(process.bundleID)
            if var existing = grouped[key] {
                existing.processObjectIDs.append(process.objectID)
                existing.pids.append(process.pid)
                existing.isPlaying = existing.isPlaying || process.isPlaying
                grouped[key] = existing
            } else {
                let identity = resolveIdentity(canonicalBundleID: key, pid: process.pid)
                grouped[key] = AudioSource(
                    id: key,
                    name: identity.name,
                    bundleURL: identity.url,
                    processObjectIDs: [process.objectID],
                    pids: [process.pid],
                    isPlaying: process.isPlaying
                )
            }
        }

        let updated = grouped.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if updated != sources { sources = updated }
    }

    /// Current process objects, excluding ourselves.
    ///
    /// Excluding Audify's own process object is not cosmetic: we render the mixed result back out
    /// through an aggregate device, so tapping ourselves would build a feedback loop.
    private func currentProcesses() -> [AudioProcessObject] {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try CAProperty.array(
                CAProperty.systemObject,
                kAudioHardwarePropertyProcessObjectList,
                of: AudioObjectID.self
            )
        } catch {
            log.error("Unable to read process object list: \(String(describing: error))")
            return []
        }

        return objectIDs.compactMap { objectID -> AudioProcessObject? in
            guard let pid = try? CAProperty.value(objectID, kAudioProcessPropertyPID, defaultValue: pid_t(-1)),
                  pid > 0, pid != ownPID
            else { return nil }

            let bundleID = (try? CAProperty.string(objectID, kAudioProcessPropertyBundleID)) ?? ""
            let resolved = bundleID.isEmpty ? "pid:\(pid)" : bundleID
            let playing = (try? CAProperty.value(
                objectID, kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)
            )) ?? 0

            return AudioProcessObject(
                objectID: objectID, pid: pid, bundleID: resolved, isPlaying: playing == 1
            )
        }
    }

    /// Adds listeners for newly seen processes and drops them for departed ones.
    private func syncRunningObservers(for processes: [AudioProcessObject]) {
        let live = Set(processes.map(\.objectID))
        runningObservers = runningObservers.filter { live.contains($0.key) }

        for process in processes where runningObservers[process.objectID] == nil {
            runningObservers[process.objectID] = CAPropertyObserver(
                object: process.objectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    // MARK: - Identity

    /// Collapses helper-process bundle identifiers onto the app the user recognises.
    ///
    /// `com.google.Chrome.helper.renderer` → `com.google.chrome`, and likewise for Electron-style
    /// `(GPU)`/`(Plugin)` helpers used by Slack, VS Code, Discord and friends.
    public nonisolated static func canonicalBundleID(_ bundleID: String) -> String {
        let value = bundleID.lowercased()
        guard let range = value.range(of: ".helper") else { return value }

        // Only treat ".helper" as a suffix when it really ends the component. Truncating
        // "com.example.helperapp" to "com.example" would merge two unrelated apps into one row.
        if range.upperBound < value.endIndex {
            let next = value[range.upperBound]
            if next.isLetter || next.isNumber { return value }
        }
        return String(value[value.startIndex..<range.lowerBound])
    }

    private func resolveIdentity(canonicalBundleID: String, pid: pid_t) -> (name: String, url: URL?) {
        if let cached = identityCache[canonicalBundleID] { return cached }

        var name = canonicalBundleID
        var url: URL?

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: canonicalBundleID) {
            url = appURL
            name = FileManager.default.displayName(atPath: appURL.path)
        } else if let running = NSRunningApplication(processIdentifier: pid) {
            // Helper processes report the helper bundle; walk up to the enclosing .app when possible.
            url = running.bundleURL.flatMap(Self.enclosingApplication)
            name = url.map { FileManager.default.displayName(atPath: $0.path) }
                ?? running.localizedName
                ?? canonicalBundleID
        } else if canonicalBundleID.hasPrefix("pid:") {
            name = Self.processName(for: pid) ?? canonicalBundleID
        }

        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let identity = (name: name, url: url)
        identityCache[canonicalBundleID] = identity
        return identity
    }

    /// Walks a helper bundle path upwards to the outermost `.app` wrapper.
    private static func enclosingApplication(_ url: URL) -> URL? {
        var candidate: URL?
        var cursor = url
        while cursor.pathComponents.count > 1 {
            if cursor.pathExtension == "app" { candidate = cursor }
            cursor = cursor.deletingLastPathComponent()
        }
        return candidate
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
