import Foundation

/// Stable section identifiers used by Warren settings deep links.
///
/// The display labels remain a UI concern; these values are intentionally
/// lowercase and stable so links can survive copy changes and localization.
public enum WarrenDesktopSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case terminalFont = "Font"
    case terminalTitle = "Title"
    case terminalRuntime = "Terminal runtime"
    case presets = "Presets"
    case workspaces = "Workspaces"
    case externalIDEs = "External IDEs"
    case publicAccess = "Public Access"

    public var id: String { rawValue }

    public var deepLinkValue: String {
        switch self {
        case .terminalFont: "terminal-font"
        case .terminalTitle: "terminal-title"
        case .terminalRuntime: "terminal-runtime"
        case .presets: "presets"
        case .workspaces: "workspaces"
        case .externalIDEs: "external-ides"
        case .publicAccess: "public-access"
        }
    }

    public init?(deepLinkValue: String) {
        switch deepLinkValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminal-font", "font": self = .terminalFont
        case "terminal-title", "title": self = .terminalTitle
        case "terminal-runtime", "runtime": self = .terminalRuntime
        case "presets": self = .presets
        case "workspaces", "workspace": self = .workspaces
        case "external-ides", "external-ide", "ides": self = .externalIDEs
        case "public-access", "publicaccess", "public": self = .publicAccess
        default: return nil
        }
    }
}

public enum WarrenDesktopPublicAccessKeyKind: String, Sendable {
    case invite
    case approval
}

/// Values that may be carried by a Public Access setup link.
///
/// The bootstrap key is intentionally included only because the setup link is
/// an explicitly shareable credential in the current product flow. Treat the
/// resulting URL like the key itself: browser history, chat systems, and
/// launch services may retain it. Warren never logs this value.
public struct WarrenDesktopPublicAccessPrefill: Equatable, Sendable {
    public let edgeURL: String?
    public let accountName: String?
    public let keyKind: WarrenDesktopPublicAccessKeyKind?
    public let inviteKey: String?
    public let approvalKey: String?

    public init(
        edgeURL: String? = nil,
        accountName: String? = nil,
        keyKind: WarrenDesktopPublicAccessKeyKind? = nil,
        inviteKey: String? = nil,
        approvalKey: String? = nil
    ) {
        self.edgeURL = Self.nonEmpty(edgeURL)
        self.accountName = Self.nonEmpty(accountName)
        self.keyKind = keyKind
        self.inviteKey = Self.nonEmpty(inviteKey)
        self.approvalKey = Self.nonEmpty(approvalKey)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The canonical `warren://settings` deep link.
///
/// Only Public Access links carry setup values. Other section links contain a
/// section selector and no configuration data.
public struct WarrenDesktopSettingsDeepLink: Equatable, Sendable {
    public static let scheme = "warren"
    public static let host = "settings"

    public let section: WarrenDesktopSettingsSection
    public let publicAccess: WarrenDesktopPublicAccessPrefill?

    public init(
        section: WarrenDesktopSettingsSection,
        publicAccess: WarrenDesktopPublicAccessPrefill? = nil
    ) {
        self.section = section
        self.publicAccess = section == .publicAccess ? publicAccess : nil
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
        guard section == .publicAccess else {
            self.publicAccess = nil
            return
        }

        let inviteKey = Self.nonEmpty(query["invitekey"])
        let approvalKey = Self.nonEmpty(query["approvalkey"])
        let keyKind: WarrenDesktopPublicAccessKeyKind?
        switch query["keykind"]?.lowercased() {
        case "invite": keyKind = .invite
        case "approval": keyKind = .approval
        default:
            if approvalKey != nil { keyKind = .approval }
            else if inviteKey != nil { keyKind = .invite }
            else { keyKind = nil }
        }
        let hasPublicAccessValues = [
            query["edgeurl"], query["edge"], query["accountname"], query["account"],
            query["keykind"], inviteKey, approvalKey,
        ].contains { $0 != nil }
        self.publicAccess = hasPublicAccessValues
            ? WarrenDesktopPublicAccessPrefill(
                edgeURL: query["edgeurl"] ?? query["edge"],
                accountName: query["accountname"] ?? query["account"],
                keyKind: keyKind,
                inviteKey: inviteKey,
                approvalKey: approvalKey
            )
            : nil
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [URLQueryItem(name: "section", value: section.deepLinkValue)]

        if section == .publicAccess, let publicAccess {
            if let edgeURL = publicAccess.edgeURL {
                items.append(URLQueryItem(name: "edgeUrl", value: edgeURL))
            }
            if let accountName = publicAccess.accountName {
                items.append(URLQueryItem(name: "accountName", value: accountName))
            }
            if let keyKind = publicAccess.keyKind {
                items.append(URLQueryItem(name: "keyKind", value: keyKind.rawValue))
            }
            if let inviteKey = publicAccess.inviteKey {
                items.append(URLQueryItem(name: "inviteKey", value: inviteKey))
            }
            if let approvalKey = publicAccess.approvalKey {
                items.append(URLQueryItem(name: "approvalKey", value: approvalKey))
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
