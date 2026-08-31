import Foundation

public enum LatencyProfile: Int, CaseIterable, Identifiable, Sendable {
    case low = 256
    case balanced = 512
    case powerSaver = 1024

    public var id: Int { rawValue }
    public var frames: UInt32 { UInt32(rawValue) }

    public var title: String {
        switch self {
        case .low: return "Low latency"
        case .balanced: return "Balanced"
        case .powerSaver: return "Power saver"
        }
    }

    public var detail: String {
        switch self {
        case .low: return "≈5 ms delay, slightly more CPU"
        case .balanced: return "≈11 ms delay, recommended"
        case .powerSaver: return "≈21 ms delay, fewest wakeups"
        }
    }
}

/// All persisted settings, backed by `UserDefaults`.
///
/// Volumes are stored by canonical bundle identifier and by site host, so a choice survives both
/// quitting the app being controlled and quitting Audify itself.
@MainActor
public final class Preferences: ObservableObject {
    private enum Key {
        static let appVolumes = "appVolumes"
        static let appMutes = "appMutes"
        static let siteVolumes = "siteVolumes"
        static let siteMutes = "siteMutes"
        static let showMeters = "showMeters"
        static let allowBoost = "allowBoost"
        static let latency = "latencyFrames"
        static let hideIdleApps = "hideIdleApps"
        static let rememberPerSite = "rememberPerSite"
        static let bridgeEnabled = "bridgeEnabled"
        static let bridgePort = "bridgePort"
        static let bridgeToken = "bridgeToken"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let menuBarStyle = "menuBarStyle"
    }

    public static let maxBoostGain: Float = 2.0
    public static let defaultBridgePort = 17843

    private let defaults: UserDefaults

    @Published public var appVolumes: [String: Float] {
        didSet { defaults.set(appVolumes, forKey: Key.appVolumes) }
    }
    @Published public var appMutes: [String: Bool] {
        didSet { defaults.set(appMutes, forKey: Key.appMutes) }
    }
    @Published public var siteVolumes: [String: Float] {
        didSet { defaults.set(siteVolumes, forKey: Key.siteVolumes) }
    }
    @Published public var siteMutes: [String: Bool] {
        didSet { defaults.set(siteMutes, forKey: Key.siteMutes) }
    }
    @Published public var showMeters: Bool {
        didSet { defaults.set(showMeters, forKey: Key.showMeters) }
    }
    @Published public var allowBoost: Bool {
        didSet { defaults.set(allowBoost, forKey: Key.allowBoost) }
    }
    @Published public var latency: LatencyProfile {
        didSet { defaults.set(latency.rawValue, forKey: Key.latency) }
    }
    @Published public var hideIdleApps: Bool {
        didSet { defaults.set(hideIdleApps, forKey: Key.hideIdleApps) }
    }
    @Published public var rememberPerSite: Bool {
        didSet { defaults.set(rememberPerSite, forKey: Key.rememberPerSite) }
    }
    @Published public var bridgeEnabled: Bool {
        didSet { defaults.set(bridgeEnabled, forKey: Key.bridgeEnabled) }
    }
    @Published public var bridgePort: Int {
        didSet { defaults.set(bridgePort, forKey: Key.bridgePort) }
    }
    @Published public var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    /// Shared secret the browser extension must present. Generated once, on first launch.
    public let bridgeToken: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showMeters: true,
            Key.allowBoost: true,
            Key.latency: LatencyProfile.balanced.rawValue,
            Key.hideIdleApps: false,
            Key.rememberPerSite: true,
            Key.bridgeEnabled: true,
            Key.bridgePort: Preferences.defaultBridgePort,
        ])

        appVolumes = defaults.dictionary(forKey: Key.appVolumes) as? [String: Float] ?? [:]
        appMutes = defaults.dictionary(forKey: Key.appMutes) as? [String: Bool] ?? [:]
        siteVolumes = defaults.dictionary(forKey: Key.siteVolumes) as? [String: Float] ?? [:]
        siteMutes = defaults.dictionary(forKey: Key.siteMutes) as? [String: Bool] ?? [:]
        showMeters = defaults.bool(forKey: Key.showMeters)
        allowBoost = defaults.bool(forKey: Key.allowBoost)
        latency = LatencyProfile(rawValue: defaults.integer(forKey: Key.latency)) ?? .balanced
        hideIdleApps = defaults.bool(forKey: Key.hideIdleApps)
        rememberPerSite = defaults.bool(forKey: Key.rememberPerSite)
        bridgeEnabled = defaults.bool(forKey: Key.bridgeEnabled)
        bridgePort = defaults.integer(forKey: Key.bridgePort)
        hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)

        if let existing = defaults.string(forKey: Key.bridgeToken), !existing.isEmpty {
            bridgeToken = existing
        } else {
            let token = Preferences.makeToken()
            defaults.set(token, forKey: Key.bridgeToken)
            bridgeToken = token
        }
    }

    public var maxGain: Float { allowBoost ? Preferences.maxBoostGain : 1 }

    // MARK: - Per-app

    public func volume(forApp key: String) -> Float {
        min(appVolumes[key] ?? 1, maxGain)
    }

    public func isMuted(app key: String) -> Bool {
        appMutes[key] ?? false
    }

    public func setVolume(_ value: Float, forApp key: String) {
        let clamped = min(max(value, 0), maxGain)
        if abs(clamped - 1) < 0.005 {
            appVolumes.removeValue(forKey: key)
        } else {
            appVolumes[key] = clamped
        }
    }

    public func setMuted(_ muted: Bool, forApp key: String) {
        if muted { appMutes[key] = true } else { appMutes.removeValue(forKey: key) }
    }

    // MARK: - Per-site

    public func volume(forSite host: String) -> Float {
        guard rememberPerSite else { return 1 }
        return min(siteVolumes[host] ?? 1, maxGain)
    }

    public func isMuted(site host: String) -> Bool {
        guard rememberPerSite else { return false }
        return siteMutes[host] ?? false
    }

    public func setVolume(_ value: Float, forSite host: String) {
        guard rememberPerSite, !host.isEmpty else { return }
        let clamped = min(max(value, 0), maxGain)
        if abs(clamped - 1) < 0.005 {
            siteVolumes.removeValue(forKey: host)
        } else {
            siteVolumes[host] = clamped
        }
    }

    public func setMuted(_ muted: Bool, forSite host: String) {
        guard rememberPerSite, !host.isEmpty else { return }
        if muted { siteMutes[host] = true } else { siteMutes.removeValue(forKey: host) }
    }

    // MARK: - Reset

    public func resetAllLevels() {
        appVolumes = [:]
        appMutes = [:]
        siteVolumes = [:]
        siteMutes = [:]
    }

    /// Short, unambiguous pairing code — no look-alike characters, easy to read off screen.
    private static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let code = bytes.map { alphabet[Int($0) % alphabet.count] }
        return String(code[0..<4]) + "-" + String(code[4..<8]) + "-" + String(code[8..<12])
    }
}
