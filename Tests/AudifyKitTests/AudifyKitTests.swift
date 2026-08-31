import CoreAudio
import XCTest
@testable import AudifyKit

// MARK: - Core Audio helpers

final class FourCCTests: XCTestCase {
    func testDecodesPrintableCodes() {
        // kAudioHardwareBadObjectError == '!obj'
        XCTAssertEqual(CAError.fourCC(OSStatus(bitPattern: 0x216F_626A)), "'!obj'")
    }

    func testFallsBackToNumberForUnprintableCodes() {
        XCTAssertEqual(CAError.fourCC(-1), "-1")
    }
}

// MARK: - Process identity

final class BundleIdentityTests: XCTestCase {
    /// Chromium and Electron apps only ever emit audio from helper processes, so collapsing helper
    /// identifiers onto the host app is what makes a single "Google Chrome" row possible.
    func testHelperProcessesCollapseOntoTheHostApp() {
        let cases = [
            "com.google.Chrome.helper": "com.google.chrome",
            "com.google.Chrome.helper.renderer": "com.google.chrome",
            "com.microsoft.teams2.helper": "com.microsoft.teams2",
            "com.brave.Browser.helper (GPU)": "com.brave.browser",
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                AudioProcessRegistry.canonicalBundleID(input), expected, "input: \(input)"
            )
        }
    }

    func testNonHelperIdentifiersAreOnlyLowercased() {
        XCTAssertEqual(
            AudioProcessRegistry.canonicalBundleID("com.apple.Music"), "com.apple.music"
        )
    }

    /// A bundle identifier that merely contains "helper" as a word must not be truncated.
    func testIdentifiersWithoutTheHelperSuffixSurvive() {
        XCTAssertEqual(
            AudioProcessRegistry.canonicalBundleID("com.example.helperapp"),
            "com.example.helperapp"
        )
    }

    func testBrowserDetectionIsCaseInsensitive() {
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(BrowserIdentity.isBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(BrowserIdentity.isBrowser(bundleID: "com.apple.Music"))
    }
}

// MARK: - Engine targeting

final class MixerTargetTests: XCTestCase {
    private func target(volume: Float, muted: Bool = false) -> MixerTarget {
        MixerTarget(
            id: "com.example.app", bundleIDs: ["com.example.app"],
            processObjectIDs: [42], volume: volume, muted: muted
        )
    }

    /// The single most important behaviour in the engine: an app at unity gain must not be tapped,
    /// so it keeps its native latency and costs nothing.
    func testUnityGainNeedsNoProcessing() {
        XCTAssertFalse(target(volume: 1).needsProcessing)
        XCTAssertFalse(target(volume: 1.002).needsProcessing, "inside the dead band")
    }

    func testAdjustedOrMutedAppsNeedProcessing() {
        XCTAssertTrue(target(volume: 0.5).needsProcessing)
        XCTAssertTrue(target(volume: 1.5).needsProcessing)
        XCTAssertTrue(target(volume: 1, muted: true).needsProcessing)
    }

    func testMuteWinsOverVolume() {
        XCTAssertEqual(target(volume: 0.8, muted: true).effectiveGain, 0)
        XCTAssertEqual(target(volume: 0.8).effectiveGain, 0.8)
    }
}

// MARK: - Preferences

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.audify.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testUnityVolumeIsNotPersisted() {
        let preferences = Preferences(defaults: defaults)
        preferences.setVolume(0.4, forApp: "com.example.app")
        XCTAssertEqual(preferences.appVolumes["com.example.app"], 0.4)

        // Returning to 100% should drop the entry rather than store a redundant 1.0, which keeps
        // `needsProcessing` honest and the stored dictionary small.
        preferences.setVolume(1, forApp: "com.example.app")
        XCTAssertNil(preferences.appVolumes["com.example.app"])
        XCTAssertEqual(preferences.volume(forApp: "com.example.app"), 1)
    }

    @MainActor
    func testVolumeIsClampedToTheBoostCeiling() {
        let preferences = Preferences(defaults: defaults)
        preferences.allowBoost = true
        preferences.setVolume(99, forApp: "com.example.app")
        XCTAssertEqual(preferences.volume(forApp: "com.example.app"), Preferences.maxBoostGain)
    }

    /// Turning boost off must also cap levels that were stored while it was on, otherwise an old
    /// setting could keep boosting invisibly.
    @MainActor
    func testDisablingBoostCapsStoredVolumes() {
        let preferences = Preferences(defaults: defaults)
        preferences.allowBoost = true
        preferences.setVolume(1.8, forApp: "com.example.app")
        preferences.allowBoost = false
        XCTAssertEqual(preferences.volume(forApp: "com.example.app"), 1)
    }

    @MainActor
    func testSiteLevelsAreIgnoredWhenRememberingIsOff() {
        let preferences = Preferences(defaults: defaults)
        preferences.setVolume(0.25, forSite: "youtube.com")
        XCTAssertEqual(preferences.volume(forSite: "youtube.com"), 0.25)

        preferences.rememberPerSite = false
        XCTAssertEqual(preferences.volume(forSite: "youtube.com"), 1)
    }

    @MainActor
    func testValuesSurviveANewInstance() {
        let first = Preferences(defaults: defaults)
        first.setVolume(0.3, forApp: "com.example.app")
        first.setMuted(true, forApp: "com.other.app")
        let token = first.bridgeToken

        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.volume(forApp: "com.example.app"), 0.3)
        XCTAssertTrue(second.isMuted(app: "com.other.app"))
        XCTAssertEqual(second.bridgeToken, token, "the pairing code must be stable")
    }

    @MainActor
    func testPairingTokenLooksLikeTheCodeShownInSettings() {
        let preferences = Preferences(defaults: defaults)
        let token = preferences.bridgeToken
        XCTAssertEqual(token.count, 14)
        XCTAssertEqual(token.split(separator: "-").count, 3)
        // Look-alike characters are excluded so the code can be read off a screen reliably.
        XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "OI01")))
    }

    @MainActor
    func testResetClearsEverything() {
        let preferences = Preferences(defaults: defaults)
        preferences.setVolume(0.5, forApp: "a")
        preferences.setMuted(true, forApp: "b")
        preferences.setVolume(0.5, forSite: "c.com")
        preferences.resetAllLevels()
        XCTAssertTrue(preferences.appVolumes.isEmpty)
        XCTAssertTrue(preferences.appMutes.isEmpty)
        XCTAssertTrue(preferences.siteVolumes.isEmpty)
    }
}

// MARK: - Bridge protocol

final class BridgeProtocolTests: XCTestCase {
    func testHostStripsWWWAndPort() {
        func host(_ url: String) -> String {
            BridgeTabPayload(
                id: 1, title: "", url: url, audible: true, muted: false,
                volume: 1, active: true, favicon: nil
            ).host
        }
        XCTAssertEqual(host("https://www.youtube.com/watch?v=abc"), "youtube.com")
        XCTAssertEqual(host("https://meet.google.com/abc-defg"), "meet.google.com")
        XCTAssertEqual(host("http://localhost:3000/app"), "localhost")
        XCTAssertEqual(host("not a url"), "")
        XCTAssertEqual(host("chrome://settings"), "")
    }

    func testDecodesHello() throws {
        let json = #"{"type":"hello","token":"ABCD-EFGH-JKLM","browser":"Brave","version":1}"#
        let message = try JSONDecoder().decode(BridgeInbound.self, from: Data(json.utf8))
        guard case let .hello(token, browser, version) = message else {
            return XCTFail("expected hello, got \(message)")
        }
        XCTAssertEqual(token, "ABCD-EFGH-JKLM")
        XCTAssertEqual(browser, "Brave")
        XCTAssertEqual(version, 1)
    }

    /// An older extension may omit fields; the app must not fall over.
    func testDecodesHelloWithMissingOptionalFields() throws {
        let json = #"{"type":"hello"}"#
        let message = try JSONDecoder().decode(BridgeInbound.self, from: Data(json.utf8))
        guard case let .hello(token, browser, _) = message else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(token, "")
        XCTAssertEqual(browser, "Browser")
    }

    func testRejectsUnknownMessageTypes() {
        let json = #"{"type":"somethingNew"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(BridgeInbound.self, from: Data(json.utf8))
        )
    }

    func testEncodesSetVolumeWithTheKeysTheExtensionReads() throws {
        let data = try JSONEncoder().encode(BridgeOutbound.setVolume(tabID: 7, volume: 0.25))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["type"] as? String, "setVolume")
        XCTAssertEqual(decoded?["tabId"] as? Int, 7)
        XCTAssertEqual(decoded?["volume"] as? Double ?? 0, 0.25, accuracy: 0.0001)
    }

    func testEncodesWelcome() throws {
        let data = try JSONEncoder().encode(
            BridgeOutbound.welcome(protocolVersion: 1, rememberPerSite: true, maxGain: 2)
        )
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["type"] as? String, "welcome")
        XCTAssertEqual(decoded?["rememberPerSite"] as? Bool, true)
    }
}

// MARK: - Latency profiles

final class LatencyProfileTests: XCTestCase {
    func testFramesArePowersOfTwoInAscendingOrder() {
        let frames = LatencyProfile.allCases.map(\.frames)
        XCTAssertEqual(frames, [256, 512, 1024])
        for value in frames {
            XCTAssertEqual(value & (value - 1), 0, "\(value) should be a power of two")
        }
    }
}
