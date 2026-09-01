import Foundation

/// Stable section identifiers used by Warren settings deep links.
///
/// The display labels remain a UI concern; these values are intentionally
/// lowercase and stable so links can survive copy changes and localization.
public enum WarrenDesktopSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case terminalFont = "Font"
    case terminalTitle = "Title"
    case terminalRuntime = "Terminal runtime"
    case aiTitles = "AI titles"
    case presets = "Presets"
    case workspaces = "Workspaces"
    case notifications = "Notifications"
    case externalIDEs = "External IDEs"
    case relay = "Relay"
    case publicAccess = "Public Access"

    public var id: String { rawValue }

    public var deepLinkValue: String {
        switch self {
        case .terminalFont: "terminal-font"
        case .terminalTitle: "terminal-title"
        case .terminalRuntime: "terminal-runtime"
        case .aiTitles: "ai-titles"
        case .presets: "presets"
        case .workspaces: "workspaces"
        case .notifications: "notifications"
        case .externalIDEs: "external-ides"
        case .relay: "relay"
        case .publicAccess: "public-access"
        }
    }

    public init?(deepLinkValue: String) {
        switch deepLinkValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminal-font", "font": self = .terminalFont
        case "terminal-title", "title": self = .terminalTitle
        case "terminal-runtime", "runtime": self = .terminalRuntime
        case "ai-titles", "ai-title", "openai", "openai-titles": self = .aiTitles
        case "presets": self = .presets
        case "workspaces", "workspace": self = .workspaces
        case "notifications", "notification": self = .notifications
        case "external-ides", "external-ide", "ides": self = .externalIDEs
        case "relay": self = .relay
        case "public-access", "publicaccess", "public": self = .publicAccess
        default: return nil
        }
    }
}

/// Relay enrollment metadata carried by a Warren settings link. The URL and
/// key are public metadata; the enrollment ticket is short-lived and one-time
/// but still acts as a credential until consumed, so callers must not log or
/// persist the URL. Desktop consumes a complete link automatically.
public struct WarrenDesktopRelayPrefill: Equatable, Sendable {
    public let relayURL: String?
    public let hostID: String?
    public let enrollmentTicket: String?
    public let relayKeyID: String?
    public let relayPublicKey: String?

    public init(
        relayURL: String? = nil,
        hostID: String? = nil,
        enrollmentTicket: String? = nil,
        relayKeyID: String? = nil,
        relayPublicKey: String? = nil
    ) {
        self.relayURL = Self.nonEmpty(relayURL)
        self.hostID = Self.nonEmpty(hostID)
        self.enrollmentTicket = Self.nonEmpty(enrollmentTicket)
        self.relayKeyID = Self.nonEmpty(relayKeyID)
        self.relayPublicKey = Self.nonEmpty(relayPublicKey)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Values that may be carried by a Public Access route setup link.
public struct WarrenDesktopPublicAccessPrefill: Equatable, Sendable {
    public let publicHostname: String?
    public let pathPrefix: String?

    public init(
        publicHostname: String? = nil,
        pathPrefix: String? = nil
    ) {
        self.publicHostname = Self.nonEmpty(publicHostname)
        self.pathPrefix = Self.nonEmpty(pathPrefix)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The canonical `warren://settings` deep link.
///
/// Public Access and Relay links carry different setup values. They remain
/// separate sections so a route address cannot be mistaken for an enrollment
/// ticket.
public struct WarrenDesktopSettingsDeepLink: Equatable, Sendable {
    public static let scheme = "warren"
    public static let host = "settings"

    public let section: WarrenDesktopSettingsSection
    public let publicAccess: WarrenDesktopPublicAccessPrefill?
    public let relay: WarrenDesktopRelayPrefill?

    public init(
        section: WarrenDesktopSettingsSection,
        publicAccess: WarrenDesktopPublicAccessPrefill? = nil,
        relay: WarrenDesktopRelayPrefill? = nil
    ) {
        self.section = section
        self.publicAccess = section == .publicAccess ? publicAccess : nil
        self.relay = section == .relay ? relay : nil
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Keep the first value for duplicate keys. A malformed link should
        // be ignored or handled deterministically, never crash URL opening.
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            guard let value = item.value else { continue }
            let key = item.name.lowercased()
            if query[key] == nil {
                query[key] = value
            }
        }
        let pathSection = url.path
            .split(separator: "/")
            .first
            .map(String.init)
        guard let sectionValue = query["section"] ?? pathSection,
              let section = WarrenDesktopSettingsSection(deepLinkValue: sectionValue) else {
            return nil
        }

        self.section = section
        guard section == .publicAccess || section == .relay else {
            self.publicAccess = nil
            self.relay = nil
            return
        }

        if section == .relay {
            let relayURL = Self.nonEmpty(query["relayurl"])
            let hostID = Self.nonEmpty(query["hostid"])
            let enrollmentTicket = Self.nonEmpty(query["enrollmentticket"])
            let relayKeyID = Self.nonEmpty(query["relaykeyid"])
            let relayPublicKey = Self.nonEmpty(query["relaypublickey"])
            let hasRelayValues = [relayURL, hostID, enrollmentTicket, relayKeyID, relayPublicKey].contains { $0 != nil }
            self.relay = hasRelayValues
                ? WarrenDesktopRelayPrefill(
                    relayURL: relayURL,
                    hostID: hostID,
                    enrollmentTicket: enrollmentTicket,
                    relayKeyID: relayKeyID,
                    relayPublicKey: relayPublicKey
                )
                : nil
            self.publicAccess = nil
            return
        }

        self.relay = nil

        let publicHostname = Self.nonEmpty(query["publichostname"] ?? query["hostname"])
        let pathPrefix = Self.nonEmpty(query["pathprefix"] ?? query["path"])
        let hasPublicAccessValues = [publicHostname, pathPrefix].contains { $0 != nil }
        self.publicAccess = hasPublicAccessValues
            ? WarrenDesktopPublicAccessPrefill(
                publicHostname: publicHostname,
                pathPrefix: pathPrefix
            )
            : nil
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [URLQueryItem(name: "section", value: section.deepLinkValue)]

        if section == .relay, let relay {
            if let relayURL = relay.relayURL {
                items.append(URLQueryItem(name: "relayUrl", value: relayURL))
            }
            if let hostID = relay.hostID {
                items.append(URLQueryItem(name: "hostId", value: hostID))
            }
            if let enrollmentTicket = relay.enrollmentTicket {
                items.append(URLQueryItem(name: "enrollmentTicket", value: enrollmentTicket))
            }
            if let relayKeyID = relay.relayKeyID {
                items.append(URLQueryItem(name: "relayKeyId", value: relayKeyID))
            }
            if let relayPublicKey = relay.relayPublicKey {
                items.append(URLQueryItem(name: "relayPublicKey", value: relayPublicKey))
            }
        } else if section == .publicAccess, let publicAccess {
            if let publicHostname = publicAccess.publicHostname {
                items.append(URLQueryItem(name: "publicHostname", value: publicHostname))
            }
            if let pathPrefix = publicAccess.pathPrefix {
                items.append(URLQueryItem(name: "pathPrefix", value: pathPrefix))
            }
        }

        components.queryItems = items
        return components.url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
