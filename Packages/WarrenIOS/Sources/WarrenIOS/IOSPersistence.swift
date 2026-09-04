import Foundation
import WarrenTransport

#if canImport(Security)
import Security
#endif

/// The small amount of navigation state a phone can safely restore. Layout
/// geometry and desktop pane/window state deliberately do not cross this
/// boundary.
public struct IOSNavigationState: Codable, Equatable, Sendable {
    public var workspaceID: String?
    public var terminalGroupID: String?
    public var sessionID: String?
    public var displayMode: IOSSessionDisplayMode

    public init(
        workspaceID: String? = nil,
        terminalGroupID: String? = nil,
        sessionID: String? = nil,
        displayMode: IOSSessionDisplayMode = .terminal
    ) {
        self.workspaceID = workspaceID
        self.terminalGroupID = terminalGroupID
        self.sessionID = sessionID
        self.displayMode = displayMode
    }
}

public enum IOSSessionDisplayMode: String, Codable, CaseIterable, Sendable {
    case terminal
    case agent
}

/// The scope to which the native client should return after the currently
/// visible Session is deleted. This is an ephemeral routing hint, not a
/// persisted resource reference.
public enum IOSSessionScopeDestination: Equatable, Sendable {
    case workspace(String)
    case terminalGroup(String)
}

/// Non-secret endpoint information exposed to the settings UI. The token is
/// intentionally represented only by a presence flag; its value remains in
/// the Keychain and is never published through SwiftUI state.
public struct IOSEndpointMetadata: Equatable, Sendable {
    public let name: String
    public let url: String
    public let hasToken: Bool
    public let type: String
    public let hostID: String?
    public let routeID: String?

    public init(
        name: String,
        url: String,
        hasToken: Bool = false,
        type: String = "daemon",
        hostID: String? = nil,
        routeID: String? = nil
    ) {
        self.name = name
        self.url = url
        self.hasToken = hasToken
        self.type = type
        self.hostID = hostID
        self.routeID = routeID
    }

    public init(configuration: WarrenRemoteEndpointConfiguration) {
        self.init(
            name: configuration.name,
            url: configuration.url,
            hasToken: !configuration.token.isEmpty,
            type: configuration.type,
            hostID: configuration.hostID,
            routeID: configuration.routeID
        )
    }

    public var isRelay: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "relay"
    }
}

/// Keychain-backed secret storage. The UserDefaults store below never writes
/// endpoint tokens, even when an endpoint is edited or removed.
public struct IOSKeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.warren.ios") {
        self.service = service
    }

    public func read(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
        #else
        return false
        #endif
    }

    @discardableResult
    public func remove(account: String) -> Bool {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        return true
        #endif
    }
}

/// Device-local non-sensitive preferences. Host tokens are represented by
/// their local names only; the values themselves stay in `IOSKeychainStore`.
public final class IOSLocalStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public let keychain: IOSKeychainStore

    public init(
        defaults: UserDefaults = .standard,
        keychain: IOSKeychainStore = IOSKeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    /// All configured Hosts in display order. The first release of the iOS
    /// client persisted one endpoint under `warren.ios.endpoint`; reading
    /// that key as a one-item list keeps existing installs intact while the
    /// next write upgrades them to the multi-Host format.
    public var endpoints: [WarrenRemoteEndpointConfiguration] {
        get {
            if let values = storedEndpoints() {
                return values.map(configuration(from:))
            }
            // UserDefaults is removed with the application. Keep a second
            // copy of the non-secret endpoint catalog in Keychain so an app
            // reinstall can restore the Relay route and find its token.
            if let values = keychainStoredEndpoints() {
                return values.map(configuration(from:))
            }
            guard let legacy = legacyEndpoint() else { return [] }
            return [configuration(from: legacy)]
        }
        set {
            let previousNames = Set(endpoints.map(\.name))
            writeEndpoints(newValue)
            let nextNames = Set(newValue.map(\.name))
            for name in previousNames.subtracting(nextNames) {
                _ = keychain.remove(account: name)
                _ = keychain.remove(account: "\(name).refresh")
            }
            for value in newValue {
                if !value.token.isEmpty {
                    _ = keychain.write(value.token, account: value.name)
                } else {
                    _ = keychain.remove(account: value.name)
                }
            }
            if activeEndpointName().map(nextNames.contains) != true {
                if let first = newValue.first?.name {
                    setActiveEndpointName(first)
                } else {
                    removeActiveEndpointName()
                }
            }
        }
    }

    /// The currently selected Host. This compatibility property remains the
    /// single endpoint API used by app bootstrap and older callers.
    public var endpoint: WarrenRemoteEndpointConfiguration? {
        get {
            let values = endpoints
            if let activeName = activeEndpointName(),
               let active = values.first(where: { $0.name == activeName }) {
                return active
            }
            return values.first
        }
        set {
            guard let value = newValue else {
                endpoints.forEach { _ = keychain.remove(account: $0.name) }
                defaults.removeObject(forKey: Keys.endpoints)
                defaults.removeObject(forKey: Keys.endpoint)
                removeActiveEndpointName()
                _ = keychain.remove(account: Keys.endpointMetadata)
                return
            }
            let previousName = endpoint?.name
            saveEndpoint(value, replacingName: previousName, activate: true)
        }
    }

    /// Returns a configured Host by its local display name.
    public func endpoint(named name: String) -> WarrenRemoteEndpointConfiguration? {
        endpoints.first(where: { $0.name == name })
    }

    /// Adds or refreshes the local development Host without changing the
    /// active Host. A Relay entry with the same display name is user-owned and
    /// is left untouched.
    @discardableResult
    public func ensureDevelopmentEndpoint(
        _ development: WarrenRemoteEndpointConfiguration
    ) -> Bool {
        guard !development.token.isEmpty,
              !development.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              development.webSocketURL != nil else {
            return false
        }

        guard let existing = endpoint(named: development.name) else {
            saveEndpoint(development, activate: false)
            return true
        }
        guard !existing.isRelay else { return false }

        let isManagedDevelopmentEndpoint = existing.type == development.type
            && existing.hostID == development.hostID
            && existing.routeID == development.routeID
        guard isManagedDevelopmentEndpoint else { return false }
        guard existing.url != development.url || existing.token != development.token else {
            return false
        }
        saveEndpoint(
            development,
            replacingName: existing.name,
            activate: false
        )
        return true
    }

    /// Persists an endpoint, optionally replacing an existing list item. The
    /// token is written only to the Keychain; the list remains metadata-only.
    public func saveEndpoint(
        _ value: WarrenRemoteEndpointConfiguration,
        replacingName: String? = nil,
        activate: Bool = true
    ) {
        var values = endpoints
        let replacementIndex = replacingName.flatMap { name in
            values.firstIndex(where: { $0.name == name })
        }
        var insertionIndex = replacementIndex ?? values.count
        if let replacementIndex {
            values.remove(at: replacementIndex)
        }
        if let duplicateIndex = values.firstIndex(where: { $0.name == value.name }) {
            values.remove(at: duplicateIndex)
            if duplicateIndex < insertionIndex {
                insertionIndex -= 1
            }
        }
        values.insert(value, at: min(insertionIndex, values.count))
        writeEndpoints(values)

        if let replacingName, replacingName != value.name {
            _ = keychain.remove(account: replacingName)
            _ = keychain.remove(account: "\(replacingName).refresh")
        }
        if !value.token.isEmpty {
            _ = keychain.write(value.token, account: value.name)
        } else {
            // Saving an endpoint without credentials is an explicit logout
            // for that account; do not leave an older token behind.
            _ = keychain.remove(account: value.name)
        }
        if activate {
            setActiveEndpointName(value.name)
        }
    }

    /// Selects a list item without rewriting its metadata or token.
    @discardableResult
    public func activateEndpoint(named name: String) -> Bool {
        guard endpoints.contains(where: { $0.name == name }) else { return false }
        setActiveEndpointName(name)
        return true
    }

    /// Removes one Host and its corresponding Keychain credential. Callers
    /// should keep at least one item active when the app is connected.
    @discardableResult
    public func removeEndpoint(named name: String) -> Bool {
        var values = endpoints
        guard let index = values.firstIndex(where: { $0.name == name }) else { return false }
        values.remove(at: index)
        writeEndpoints(values)
        _ = keychain.remove(account: name)
        _ = keychain.remove(account: "\(name).refresh")
        if activeEndpointName() == name {
            if let replacement = values.first?.name {
                setActiveEndpointName(replacement)
            } else {
                removeActiveEndpointName()
            }
        }
        return true
    }

    public var navigation: IOSNavigationState {
        get {
            guard let data = defaults.data(forKey: Keys.navigation),
                  let value = try? JSONDecoder().decode(IOSNavigationState.self, from: data)
            else { return IOSNavigationState() }
            return value
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.navigation)
        }
    }

    /// Last roster received from a Host. This is a display cache only; a
    /// fresh roster remains authoritative before any remote mutation.
    public func cachedRoster(endpointName: String, endpointURL: String) -> WarrenRemoteRoster? {
        guard let data = defaults.data(forKey: rosterKey(name: endpointName, url: endpointURL)) else { return nil }
        return try? JSONDecoder().decode(WarrenRemoteRoster.self, from: data)
    }

    public func cacheRoster(_ roster: WarrenRemoteRoster, endpointName: String, endpointURL: String) {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: rosterKey(name: endpointName, url: endpointURL))
    }

    /// The last Session kind chosen in the creation sheet. Keeping this small
    /// preference local makes repeated mobile Session creation predictable
    /// without persisting any Host data or credentials.
    public var lastSessionKind: String {
        get { defaults.string(forKey: Keys.lastSessionKind) ?? "shell" }
        set { defaults.set(newValue, forKey: Keys.lastSessionKind) }
    }

    public func clearToken(for endpointName: String) {
        _ = keychain.remove(account: endpointName)
    }

    // Kept internal so feature-specific stores can share the same
    // UserDefaults suite without exposing the defaults object itself.
    func localObject(forKey key: String) -> Any? { defaults.object(forKey: key) }

    func setLocalObject(_ value: Any?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    func removeLocalObject(forKey key: String) { defaults.removeObject(forKey: key) }

    private enum Keys {
        static let endpoint = "warren.ios.endpoint"
        static let endpoints = "warren.ios.endpoints"
        static let activeEndpoint = "warren.ios.active-endpoint"
        static let endpointMetadata = "warren.ios.endpoint-metadata"
        static let navigation = "warren.ios.navigation"
        static let lastSessionKind = "warren.ios.last-session-kind"
    }

    private func rosterKey(name: String, url: String) -> String {
        "warren.ios.roster.\(name)|\(url)"
    }

    private struct StoredEndpoint: Codable, Sendable {
        let name: String
        let url: String
        let ssh: String?
        let type: String
        let hostID: String?
        let routeID: String?
        // Note: refreshToken is stored separately in Keychain, not here
        // Keep the field for backwards compatibility but always ignored
        let _refreshToken: String?  // internal use only
        
        init(
            name: String,
            url: String,
            ssh: String?,
            type: String = "daemon",
            hostID: String? = nil,
            routeID: String? = nil,
            _refreshToken: String? = nil
        ) {
            self.name = name
            self.url = url
            self.ssh = ssh
            self.type = type
            self.hostID = hostID
            self.routeID = routeID
            self._refreshToken = _refreshToken
        }

        private enum CodingKeys: String, CodingKey {
            case name, url, ssh, type, hostID, routeID, _refreshToken = "refreshToken"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try values.decode(String.self, forKey: .name),
                url: try values.decode(String.self, forKey: .url),
                ssh: try values.decodeIfPresent(String.self, forKey: .ssh),
                type: try values.decodeIfPresent(String.self, forKey: .type) ?? "daemon",
                hostID: try values.decodeIfPresent(String.self, forKey: .hostID),
                routeID: try values.decodeIfPresent(String.self, forKey: .routeID),
                _refreshToken: try values.decodeIfPresent(String.self, forKey: ._refreshToken)
            )
        }
    }

    private func storedEndpoints() -> [StoredEndpoint]? {
        guard let data = defaults.data(forKey: Keys.endpoints) else { return nil }
        return try? JSONDecoder().decode([StoredEndpoint].self, from: data)
    }

    private func keychainStoredEndpoints() -> [StoredEndpoint]? {
        guard let value = keychain.read(account: Keys.endpointMetadata),
              let data = Data(base64Encoded: value),
              let endpoints = try? JSONDecoder().decode([StoredEndpoint].self, from: data)
        else { return nil }
        return endpoints
    }

    private func activeEndpointName() -> String? {
        defaults.string(forKey: Keys.activeEndpoint)
            ?? keychain.read(account: Keys.activeEndpoint)
    }

    private func setActiveEndpointName(_ name: String) {
        defaults.set(name, forKey: Keys.activeEndpoint)
        _ = keychain.write(name, account: Keys.activeEndpoint)
    }

    private func removeActiveEndpointName() {
        defaults.removeObject(forKey: Keys.activeEndpoint)
        _ = keychain.remove(account: Keys.activeEndpoint)
    }

    private func legacyEndpoint() -> StoredEndpoint? {
        guard let data = defaults.data(forKey: Keys.endpoint) else { return nil }
        return try? JSONDecoder().decode(StoredEndpoint.self, from: data)
    }

    private func configuration(from value: StoredEndpoint) -> WarrenRemoteEndpointConfiguration {
        WarrenRemoteEndpointConfiguration(
            name: value.name,
            url: value.url,
            token: keychain.read(account: value.name) ?? "",
            ssh: value.ssh,
            type: value.type,
            hostID: value.hostID,
            routeID: value.routeID,
            refreshToken: keychain.read(account: "\(value.name).refresh")
        )
    }
    
    private func writeEndpoints(_ values: [WarrenRemoteEndpointConfiguration]) {
        let metadata = values.map {
            StoredEndpoint(
                name: $0.name,
                url: $0.url,
                ssh: $0.ssh,
                type: $0.type,
                hostID: $0.hostID,
                routeID: $0.routeID
                // Note: refreshToken is NOT stored in JSON, it's kept in Keychain only
            )
        }
        defaults.set(try? JSONEncoder().encode(metadata), forKey: Keys.endpoints)
        if let data = try? JSONEncoder().encode(metadata) {
            _ = keychain.write(data.base64EncodedString(), account: Keys.endpointMetadata)
        }
        // A successful write upgrades any legacy single-endpoint record.
        defaults.removeObject(forKey: Keys.endpoint)
    }
}
