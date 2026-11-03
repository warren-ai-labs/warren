import Foundation

/// The Host's serverless remote access state, as the Desktop renders it.
///
/// Remote access is the Bolthole path: the Host dials out to a stateless relay
/// that only forwards end-to-end encrypted traffic, so a phone reaches this Mac
/// without an enrolled Relay service and without the relay being trusted. The
/// values here are the non-secret projection of `remote.status`; the connect
/// code never leaves the Host or the paired device.
public struct WarrenDesktopRemoteAccess: Hashable, Sendable {
    public var enabled: Bool
    public var connected: Bool
    /// `disabled`, `connecting`, `connected`, `disconnected` or `error`.
    public var state: String
    /// The relay in use right now, empty until remote access has started once.
    public var relayURL: String
    /// `default` while the Host uses its build's relay, `self-hosted` once it
    /// carries its own.
    public var relaySource: String
    /// The relay this Host was told to use, empty when it is on the default.
    public var configuredRelayURL: String
    /// The relay a build without overrides would use.
    public var defaultRelayURL: String
    /// Devices paired through a share link.
    public var devices: Int
    public var lastError: String

    public init(
        enabled: Bool = false,
        connected: Bool = false,
        state: String = "disabled",
        relayURL: String = "",
        relaySource: String = "default",
        configuredRelayURL: String = "",
        defaultRelayURL: String = "",
        devices: Int = 0,
        lastError: String = ""
    ) {
        self.enabled = enabled
        self.connected = connected
        self.state = state
        self.relayURL = relayURL
        self.relaySource = relaySource
        self.configuredRelayURL = configuredRelayURL
        self.defaultRelayURL = defaultRelayURL
        self.devices = devices
        self.lastError = lastError
    }

    /// True while this Host self-hosts the relay instead of using the build's.
    public var isSelfHostedRelay: Bool {
        relaySource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "self-hosted"
    }

    /// The relay currently carrying traffic, falling back through the values the
    /// Host reports so the page never shows an empty address while connected.
    public var effectiveRelayURL: String {
        for candidate in [relayURL, configuredRelayURL, defaultRelayURL] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// A sentence for the status row, not a state identifier.
    public var stateText: String {
        switch state.lowercased() {
        case "connected": return "Connected. Reconnects on its own after sleep."
        case "connecting": return "Connecting to the relay…"
        case "disconnected": return "Disconnected. Retrying in the background."
        case "error": return "The relay refused this Host."
        default: return "Off. Nothing is published and no device can pair."
        }
    }

    /// Which relay is in use, in words.
    public var relaySourceText: String {
        if isSelfHostedRelay {
            return "Self-hosted relay"
        }
        return defaultRelayURL.isEmpty ? "Official relay" : "Official relay (\(defaultRelayURL))"
    }
}

/// One short-lived remote share link, as returned by `remote.share`.
///
/// The link carries the Host's connect code and a pairing invite in its
/// fragment; it is a bearer credential until it expires, ten minutes later.
public struct WarrenDesktopRemoteShare: Hashable, Sendable {
    public let url: URL
    public let expiresAt: Date?
    public let expiresIn: Int

    public init(url: URL, expiresAt: Date? = nil, expiresIn: Int = 0) {
        self.url = url
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
    }
}
