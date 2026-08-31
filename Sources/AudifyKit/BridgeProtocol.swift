import Foundation

/// Wire format shared with the browser extension (`Extension/`).
///
/// Deliberately tiny and versioned: the extension is updated through a browser store on its own
/// schedule, so both sides must tolerate an older peer.
public enum BridgeProtocol {
    public static let version = 1
}

public struct BridgeTabPayload: Codable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var url: String
    public var audible: Bool
    public var muted: Bool
    public var volume: Float
    public var active: Bool
    public var favicon: String?

    /// Host used as the persistence key for "remember this site's level".
    ///
    /// Restricted to http(s) so browser-internal pages (`chrome://settings`, `about:blank`) and
    /// local files never become persistence keys — `URLComponents` would happily report "settings"
    /// as the host of `chrome://settings`.
    public var host: String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Messages the extension sends to Audify.
public enum BridgeInbound: Decodable {
    case hello(token: String, browser: String, version: Int)
    case tabs([BridgeTabPayload])
    case tabClosed(id: Int)
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, token, browser, version, tabs, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                token: try container.decodeIfPresent(String.self, forKey: .token) ?? "",
                browser: try container.decodeIfPresent(String.self, forKey: .browser) ?? "Browser",
                version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            )
        case "tabs":
            self = .tabs(try container.decodeIfPresent([BridgeTabPayload].self, forKey: .tabs) ?? [])
        case "tabClosed":
            self = .tabClosed(id: try container.decode(Int.self, forKey: .id))
        case "pong":
            self = .pong
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown message type \(type)"
            )
        }
    }
}

/// Messages Audify sends to the extension.
public enum BridgeOutbound: Encodable {
    case welcome(protocolVersion: Int, rememberPerSite: Bool, maxGain: Float)
    case rejected(reason: String)
    case setVolume(tabID: Int, volume: Float)
    case setMuted(tabID: Int, muted: Bool)
    case siteDefaults([String: Float])
    case requestTabs

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, rememberPerSite, maxGain, reason, tabId, volume, muted, sites
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .welcome(protocolVersion, rememberPerSite, maxGain):
            try container.encode("welcome", forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(rememberPerSite, forKey: .rememberPerSite)
            try container.encode(maxGain, forKey: .maxGain)
        case let .rejected(reason):
            try container.encode("rejected", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case let .setVolume(tabID, volume):
            try container.encode("setVolume", forKey: .type)
            try container.encode(tabID, forKey: .tabId)
            try container.encode(volume, forKey: .volume)
        case let .setMuted(tabID, muted):
            try container.encode("setMuted", forKey: .type)
            try container.encode(tabID, forKey: .tabId)
            try container.encode(muted, forKey: .muted)
        case let .siteDefaults(sites):
            try container.encode("siteDefaults", forKey: .type)
            try container.encode(sites, forKey: .sites)
        case .requestTabs:
            try container.encode("requestTabs", forKey: .type)
        }
    }
}
