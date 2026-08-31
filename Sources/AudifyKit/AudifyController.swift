import AppKit
import Combine
import CoreAudio
import Foundation
import OSLog

/// One application row in the mixer.
public struct AppRow: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var bundleURL: URL?
    public var volume: Float
    public var muted: Bool
    public var isPlaying: Bool
    public var isBrowser: Bool
    public var level: Float
}

/// One browser tab row in the mixer.
public struct TabRow: Identifiable, Equatable {
    public let id: String
    public let clientID: UUID
    public let tabID: Int
    public var title: String
    public var host: String
    public var favicon: String?
    public var volume: Float
    public var muted: Bool
    public var audible: Bool
    public var browserName: String
}

/// The single object the UI observes. Owns every subsystem and keeps them consistent.
///
/// Everything here is main-actor bound and event-driven. The only timer in the whole app is the
/// meter refresh, and it exists only while the mixer popover is on screen.
@MainActor
public final class AudifyController: ObservableObject {
    public let preferences: Preferences
    public let registry = AudioProcessRegistry()
    public let output = OutputDeviceController()
    public let bridge = BridgeServer()
    public let engine = TapMixerEngine()

    @Published public private(set) var appRows: [AppRow] = []
    @Published public private(set) var tabRows: [TabRow] = []
    @Published public private(set) var permission: AudioCapturePermission.Status = .unknown
    @Published public private(set) var engineMessage: String?

    private var tabsByClient: [UUID: [BridgeTabPayload]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var meterTimer: Timer?
    private var syncScheduled = false
    private var isUIVisible = false
    private var healthCheckScheduled = false
    private let log = Logger(subsystem: AudifyLog.subsystem, category: "controller")

    public init(preferences: Preferences? = nil) {
        self.preferences = preferences ?? Preferences()
    }

    // MARK: - Lifecycle

    public func start() {
        engine.onError = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engineMessage = error.description
                if case .permissionDenied = error { self.permission = .denied }
            }
        }

        output.onDeviceInvalidated = { [weak self] in
            MainActor.assumeIsolated {
                // Rebuild against the new device; taps themselves survive.
                self?.engine.teardown()
                self?.syncEngine()
            }
        }

        registry.$sources
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildRows() }
            .store(in: &cancellables)

        // Deliberately not subscribed to $appVolumes: `setVolume` already updates the affected row
        // and schedules an engine sync, so reacting here too would rebuild every row on every
        // frame of a slider drag. Only settings that change which rows exist are observed.
        preferences.$hideIdleApps
            .combineLatest(preferences.$allowBoost)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.rebuildRows() }
            .store(in: &cancellables)

        preferences.$showMeters
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isUIVisible else { return }
                self.startMeterTimer()
            }
            .store(in: &cancellables)

        registry.start()
        output.start()
        configureBridge()
        rebuildRows()
        refreshPermission()
    }

    public func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        engine.teardown()
        bridge.stop()
        registry.stop()
        output.stop()
    }

    /// Called by the menu bar controller. Meters and level polling cost nothing when hidden.
    public func setUIVisible(_ visible: Bool) {
        guard visible != isUIVisible else { return }
        isUIVisible = visible

        if visible {
            registry.refresh()
            output.reloadDefaultDevice()
            bridge.broadcast(.requestTabs)
            startMeterTimer()
        } else {
            meterTimer?.invalidate()
            meterTimer = nil
            syncEngine()
        }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        guard preferences.showMeters else { return }
        // 15 Hz is smooth to the eye and an order of magnitude cheaper than display-linked updates.
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func refreshMeters() {
        evaluateCaptureHealth()
        guard !appRows.isEmpty else { return }

        // Built as a local copy and assigned once: mutating `appRows` in place would publish a
        // change per row, so a ten-app mixer would redraw ten times per tick.
        var updated = appRows
        var changed = false
        for index in updated.indices {
            let level = engine.peakLevel(for: updated[index].id)
            if abs(level - updated[index].level) > 0.01 {
                updated[index].level = level
                changed = true
            }
        }
        if changed { appRows = updated }
    }

    // MARK: - Permission

    /// Re-runs the cheap up-front check.
    ///
    /// A refusal to create a tap is conclusive. Success is not, so a successful probe only clears a
    /// previous denial back to `.unknown`; `evaluateCaptureHealth()` is what confirms `.granted`.
    public func refreshPermission() {
        let probed = AudioCapturePermission.probe()
        switch probed {
        case .denied:
            permission = .denied
        case .unknown, .granted:
            if permission == .denied { permission = .unknown }
            engineMessage = nil
        }
    }

    /// Confirms or refutes audio capture from what the render thread actually received.
    ///
    /// When capture is denied, macOS gives no error at all: taps are created, the render callback
    /// runs, and every buffer is silent. So the test is behavioural — if apps we are tapping are
    /// playing, the graph has been running for a while, and not one non-zero sample has arrived,
    /// permission is missing.
    private func evaluateCaptureHealth() {
        guard engine.isRunning else { return }

        if engine.hasSeenSignal {
            if permission != .granted {
                permission = .granted
                engineMessage = nil
            }
            return
        }

        // Roughly a second of buffers at any supported size.
        guard engine.renderCycles > 80 else { return }
        let tappedAndPlaying = registry.sources.contains { source in
            source.isPlaying
                && (preferences.isMuted(app: source.id)
                    || abs(preferences.volume(forApp: source.id) - 1) > 0.005)
        }
        guard tappedAndPlaying else { return }
        permission = .denied
    }

    /// Gives the graph a moment to prove itself after it starts, without leaving a timer running.
    private func scheduleHealthCheck() {
        guard !healthCheckScheduled, permission != .granted else { return }
        healthCheckScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self else { return }
            self.healthCheckScheduled = false
            self.evaluateCaptureHealth()
        }
    }

    public func openPermissionSettings() {
        for url in AudioCapturePermission.settingsURLs {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Rows

    private func rebuildRows() {
        let rows = registry.sources.compactMap { source -> AppRow? in
            if preferences.hideIdleApps, !source.isPlaying,
               preferences.volume(forApp: source.id) == 1,
               !preferences.isMuted(app: source.id) {
                return nil
            }
            return AppRow(
                id: source.id,
                name: source.name,
                bundleURL: source.bundleURL,
                volume: preferences.volume(forApp: source.id),
                muted: preferences.isMuted(app: source.id),
                isPlaying: source.isPlaying,
                isBrowser: source.isBrowser,
                level: engine.peakLevel(for: source.id)
            )
        }
        if rows != appRows { appRows = rows }
        syncEngine()
    }

    // MARK: - App control

    public func setVolume(_ value: Float, forApp id: String) {
        preferences.setVolume(value, forApp: id)
        if let index = appRows.firstIndex(where: { $0.id == id }) {
            appRows[index].volume = preferences.volume(forApp: id)
        }
        syncEngine()
    }

    public func setMuted(_ muted: Bool, forApp id: String) {
        preferences.setMuted(muted, forApp: id)
        if let index = appRows.firstIndex(where: { $0.id == id }) {
            appRows[index].muted = muted
        }
        syncEngine()
    }

    public func toggleMute(app id: String) {
        setMuted(!preferences.isMuted(app: id), forApp: id)
    }

    public func resetApp(_ id: String) {
        preferences.setVolume(1, forApp: id)
        preferences.setMuted(false, forApp: id)
        rebuildRows()
    }

    public func resetAll() {
        preferences.resetAllLevels()
        rebuildRows()
        pushSiteDefaults()
        for tab in tabRows {
            bridge.send(.setVolume(tabID: tab.tabID, volume: 1), to: tab.clientID)
            bridge.send(.setMuted(tabID: tab.tabID, muted: false), to: tab.clientID)
        }
    }

    /// Mutes everything except one app — useful when a call starts.
    public func solo(app id: String) {
        for row in appRows {
            preferences.setMuted(row.id != id, forApp: row.id)
        }
        rebuildRows()
    }

    public var hasAnyAdjustment: Bool {
        !preferences.appVolumes.isEmpty || !preferences.appMutes.isEmpty
            || !preferences.siteVolumes.isEmpty || !preferences.siteMutes.isEmpty
    }

    // MARK: - Engine sync

    /// Coalesces graph updates to at most one per main run-loop turn.
    private func syncEngine() {
        guard !syncScheduled else { return }
        syncScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncScheduled = false
                self.performEngineSync()
            }
        }
    }

    private func performEngineSync() {
        let targets = registry.sources.map { source in
            MixerTarget(
                id: source.id,
                bundleIDs: [source.id],
                processObjectIDs: source.processObjectIDs,
                volume: preferences.volume(forApp: source.id),
                muted: preferences.isMuted(app: source.id)
            )
        }
        engine.update(
            targets: targets,
            outputDeviceID: output.defaultDeviceID,
            bufferFrames: preferences.latency.frames,
            metersEnabled: isUIVisible && preferences.showMeters
        )
        if engine.isRunning { scheduleHealthCheck() }
    }

    // MARK: - Master

    public func setMasterVolume(_ value: Float) {
        output.masterVolume = value
        output.applyMasterVolume(value)
    }

    public func toggleMasterMute() {
        output.toggleMute()
    }

    // MARK: - Browser bridge

    private func configureBridge() {
        bridge.tokenProvider = { [weak self] in self?.preferences.bridgeToken ?? "" }
        bridge.welcomeProvider = { [weak self] in
            guard let self else { return .welcome(protocolVersion: BridgeProtocol.version, rememberPerSite: false, maxGain: 1) }
            return .welcome(
                protocolVersion: BridgeProtocol.version,
                rememberPerSite: self.preferences.rememberPerSite,
                maxGain: self.preferences.maxGain
            )
        }
        bridge.onTabs = { [weak self] clientID, tabs in
            MainActor.assumeIsolated { self?.handleTabs(tabs, from: clientID) }
        }
        bridge.onClientDisconnected = { [weak self] clientID in
            MainActor.assumeIsolated {
                self?.tabsByClient.removeValue(forKey: clientID)
                self?.rebuildTabRows()
            }
        }
        if preferences.bridgeEnabled {
            bridge.start(port: preferences.bridgePort)
        }
    }

    public func restartBridge() {
        bridge.stop()
        if preferences.bridgeEnabled {
            bridge.start(port: preferences.bridgePort)
        }
    }

    private func handleTabs(_ tabs: [BridgeTabPayload], from clientID: UUID) {
        let known = Set(tabsByClient[clientID]?.map(\.id) ?? [])
        tabsByClient[clientID] = tabs
        rebuildTabRows()

        // Newly seen tabs inherit the stored level for their site, so a site the user turned down
        // stays down the next time it is opened.
        guard preferences.rememberPerSite else { return }
        for tab in tabs where !known.contains(tab.id) {
            let host = tab.host
            guard !host.isEmpty else { continue }
            let storedVolume = preferences.volume(forSite: host)
            let storedMute = preferences.isMuted(site: host)
            if abs(storedVolume - tab.volume) > 0.005 {
                bridge.send(.setVolume(tabID: tab.id, volume: storedVolume), to: clientID)
            }
            if storedMute != tab.muted {
                bridge.send(.setMuted(tabID: tab.id, muted: storedMute), to: clientID)
            }
        }
    }

    private func rebuildTabRows() {
        var rows: [TabRow] = []
        for client in bridge.clients {
            guard let tabs = tabsByClient[client.id] else { continue }
            for tab in tabs {
                rows.append(
                    TabRow(
                        id: "\(client.id.uuidString):\(tab.id)",
                        clientID: client.id,
                        tabID: tab.id,
                        title: tab.title.isEmpty ? tab.host : tab.title,
                        host: tab.host,
                        favicon: tab.favicon,
                        volume: tab.volume,
                        muted: tab.muted,
                        audible: tab.audible,
                        browserName: client.browserName
                    )
                )
            }
        }
        rows.sort { lhs, rhs in
            if lhs.audible != rhs.audible { return lhs.audible }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        if rows != tabRows { tabRows = rows }
    }

    public func setVolume(_ value: Float, forTab row: TabRow) {
        let clamped = min(max(value, 0), preferences.maxGain)
        if let index = tabRows.firstIndex(where: { $0.id == row.id }) {
            tabRows[index].volume = clamped
        }
        preferences.setVolume(clamped, forSite: row.host)
        bridge.send(.setVolume(tabID: row.tabID, volume: clamped), to: row.clientID)
    }

    public func setMuted(_ muted: Bool, forTab row: TabRow) {
        if let index = tabRows.firstIndex(where: { $0.id == row.id }) {
            tabRows[index].muted = muted
        }
        preferences.setMuted(muted, forSite: row.host)
        bridge.send(.setMuted(tabID: row.tabID, muted: muted), to: row.clientID)
    }

    public func toggleMute(tab row: TabRow) {
        setMuted(!row.muted, forTab: row)
    }

    private func pushSiteDefaults() {
        bridge.broadcast(.siteDefaults(preferences.siteVolumes))
    }

    // MARK: - Status

    /// Drives the menu bar glyph.
    public var statusSymbol: String {
        if output.isMuted { return "speaker.slash.fill" }
        if !preferences.appMutes.isEmpty { return "speaker.wave.1.fill" }
        if engine.isRunning { return "speaker.wave.3.fill" }
        return "speaker.wave.2.fill"
    }

    public var summary: String {
        var parts: [String] = []
        if engine.activeTapCount > 0 { parts.append("\(engine.activeTapCount) app adjusted") }
        if !tabRows.isEmpty { parts.append("\(tabRows.count) tabs") }
        return parts.isEmpty ? "All apps at full volume" : parts.joined(separator: " · ")
    }
}
