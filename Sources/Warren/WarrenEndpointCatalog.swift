import Foundation
import Darwin
import WarrenDesktop
import WarrenTransport

// Keep the desktop module's historical internal name while sharing the
// cross-platform endpoint value with native clients.
typealias WarrenRemoteEndpointConfiguration = WarrenTransport.WarrenRemoteEndpointConfiguration

extension WarrenRemoteEndpointConfiguration {
    static func localDaemon() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let tokenURL: URL
        if let configured = environment["WARREN_TOKEN_FILE"], !configured.isEmpty {
            tokenURL = URL(fileURLWithPath: configured)
        } else {
            tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warren/token")
        }
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(name: "local", url: localDaemonURL(listen: environment["WARREN_LISTEN"]), token: token, ssh: nil)
    }

    /// The loopback URL of the daemon this app launches. `WARREN_LISTEN` is
    /// handed to that daemon, so the app reaches it at the same port; a
    /// wildcard bind is reached over loopback.
    static func localDaemonURL(listen: String?) -> String {
        let fallback = "http://127.0.0.1:8789"
        guard let listen = listen?.trimmingCharacters(in: .whitespacesAndNewlines), !listen.isEmpty,
              let separator = listen.lastIndex(of: ":"),
              let port = UInt16(listen[listen.index(after: separator)...]) else { return fallback }
        let host = String(listen[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = ["", "0.0.0.0", "::", "*", "localhost"].contains(host) ? "127.0.0.1" : host
        return "http://\(loopback.contains(":") ? "[\(loopback)]" : loopback):\(port)"
    }

    /// The daemon records the Ghostline handoff phase before it starts the
    /// replacement runtime. Reading this small projection lets the Desktop
    /// explain the expected startup gap without probing a listener that is
    /// intentionally unavailable until migration completes.
    static func localDaemonMigrationInProgress() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let stateURL: URL
        if let configured = environment["WARREN_STATE"], !configured.isEmpty {
            stateURL = URL(fileURLWithPath: configured)
        } else {
            stateURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warren/state.json")
        }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(WarrenLocalDaemonState.self, from: data),
              let migration = state.ghostlineMigration else {
            return false
        }
        return migration.phase != "retired"
    }
}

private struct WarrenLocalDaemonState: Decodable {
    let ghostlineMigration: WarrenLocalGhostlineMigration?
}

private struct WarrenLocalGhostlineMigration: Decodable {
    let phase: String?
}

public struct WarrenDisplayConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var endpoints: [String]
    /// Optional client-local labels keyed by canonical endpoint alias. The
    /// alias remains the routing identity; this map only changes presentation.
    public var names: [String: String]

    private enum CodingKeys: String, CodingKey {
        case version
        case endpoints
        case names
    }

    public init(
        version: Int = Self.currentVersion,
        endpoints: [String],
        names: [String: String] = [:]
    ) {
        self.version = version
        self.endpoints = endpoints
        self.names = names
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        endpoints = try container.decode([String].self, forKey: .endpoints)
        names = try container.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(endpoints, forKey: .endpoints)
        if !names.isEmpty {
            try container.encode(names, forKey: .names)
        }
    }

    /// Resolves the user-facing label without changing the endpoint alias.
    public func displayName(for endpointID: String, fallback: String) -> String {
        if let value = names[endpointID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return fallback
    }
}

private struct WarrenEndpointConfigurationFile: Codable {
    let current: String?
    let endpoints: [String: WarrenRemoteEndpointConfiguration]
    let display: WarrenDisplayConfiguration?

    private enum CodingKeys: String, CodingKey {
        case current
        case endpoints
        case display
        case legacySidebar = "sidebar"
    }

    init(
        current: String?,
        endpoints: [String: WarrenRemoteEndpointConfiguration],
        display: WarrenDisplayConfiguration? = nil
    ) {
        self.current = current
        self.endpoints = endpoints
        self.display = display
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decodeIfPresent(String.self, forKey: .current)
        endpoints = try container.decode(
            [String: WarrenRemoteEndpointConfiguration].self,
            forKey: .endpoints
        )
        let configuredDisplay = try container.decodeIfPresent(
            WarrenDisplayConfiguration.self,
            forKey: .display
        )
        if let configuredDisplay {
            display = configuredDisplay
        } else {
            display = try container.decodeIfPresent(
                WarrenDisplayConfiguration.self,
                forKey: .legacySidebar
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(current, forKey: .current)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encodeIfPresent(display, forKey: .display)
    }
}

private struct WarrenLoadedEndpointConfiguration {
    let catalog: (
        current: String?,
        endpoints: [WarrenRemoteEndpointConfiguration],
        display: WarrenDisplayConfiguration?
    )
}

enum WarrenEndpointCatalog {
    // fcntl record locks coordinate separate processes, but are associated
    // with the process on Darwin. The UI and detached catalog monitor can
    // therefore still race when they open independent descriptors; serialize
    // Swift callers before taking the shared sidecar lock.
    private static let processLock = NSLock()

    static func configurationURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["WARREN_CONFIG"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warren/config.json")
    }

    static func load() -> (
        current: String?,
        endpoints: [WarrenRemoteEndpointConfiguration],
        display: WarrenDisplayConfiguration?
    ) {
        load(from: configurationURL())
    }

    static func load(
        from configURL: URL
    ) -> (
        current: String?,
        endpoints: [WarrenRemoteEndpointConfiguration],
        display: WarrenDisplayConfiguration?
    ) {
        (try? loadThrowing(from: configURL)) ?? (nil, [], nil)
    }

    static func loadThrowing(
        from configURL: URL
    ) throws -> (
        current: String?,
        endpoints: [WarrenRemoteEndpointConfiguration],
        display: WarrenDisplayConfiguration?
    ) {
        try withLock(configURL) {
            let loaded = try loadUnlocked(from: configURL)
            return loaded.catalog
        }
    }

    static func save(
        endpoints: [WarrenRemoteEndpointConfiguration],
        current: String?,
        display: WarrenDisplayConfiguration? = nil,
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try? loadUnlocked(from: configURL).catalog
            let endpointValues = endpointDictionary(endpoints)
            let requestedDisplay = display ?? existing?.display
            let normalized = try normalizedCatalogDisplay(
                requestedDisplay,
                endpointNames: Set(endpointValues.keys).union(["local"]),
                current: current
            )
            let file = WarrenEndpointConfigurationFile(
                current: normalized.current,
                endpoints: endpointValues,
                display: normalized.display
            )
            try writeUnlocked(file, to: configURL)
        }
    }

    static func setCurrent(
        _ current: String?,
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            let normalized = try normalizedCatalogDisplay(
                existing.display,
                endpointNames: Set(existing.endpoints.map(\.name)).union(["local"]),
                current: current
            )
            try writeUnlocked(
                WarrenEndpointConfigurationFile(
                    current: normalized.current,
                    endpoints: endpointDictionary(existing.endpoints),
                    display: normalized.display
                ),
                to: configURL
            )
        }
    }

    static func upsert(
        _ endpoint: WarrenRemoteEndpointConfiguration,
        current: String? = nil,
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            var endpoints = endpointDictionary(existing.endpoints)
            endpoints[endpoint.name] = endpoint
            let requestedCurrent = current ?? existing.current
            let normalized = try normalizedCatalogDisplay(
                existing.display,
                endpointNames: Set(endpoints.keys).union(["local"]),
                current: requestedCurrent
            )
            try writeUnlocked(
                WarrenEndpointConfigurationFile(
                    current: normalized.current,
                    endpoints: endpoints,
                    display: normalized.display
                ),
                to: configURL
            )
        }
    }

    /// Returns the ordered endpoint aliases visible in the Desktop sidebar.
    /// A missing section intentionally preserves the legacy single-current
    /// behavior and falls back to the synthetic local endpoint.
    static func effectiveDisplay(
        from catalog: (
            current: String?,
            endpoints: [WarrenRemoteEndpointConfiguration],
            display: WarrenDisplayConfiguration?
        )
    ) throws -> [String] {
        if catalog.display == nil {
            if let current = catalog.current?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !current.isEmpty {
                return [current]
            }
            return ["local"]
        }
        let normalized = try normalizedCatalogDisplay(
            catalog.display,
            endpointNames: Set(catalog.endpoints.map(\.name)).union(["local"]),
            current: catalog.current
        )
        return normalized.aliases
    }

    static func setDisplay(
        _ aliases: [String],
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            let normalized = try normalizedDisplay(
                aliases,
                knownEndpointNames: Set(existing.endpoints.map(\.name)).union(["local"]),
                current: existing.current,
                names: existing.display?.names ?? [:]
            )
            try writeUnlocked(WarrenEndpointConfigurationFile(
                current: normalized.current,
                endpoints: endpointDictionary(existing.endpoints),
                display: WarrenDisplayConfiguration(
                    endpoints: normalized.aliases,
                    names: normalized.names
                )
            ), to: configURL)
        }
    }

    /// Persists a client-local label for one endpoint without changing its
    /// canonical alias, connection route, or sidebar membership.
    static func setDisplayName(
        _ endpointID: String,
        name: String?,
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            let endpointNames = Set(existing.endpoints.map(\.name)).union(["local"])
            guard endpointNames.contains(endpointID) else {
                throw NSError(
                    domain: "WarrenEndpointCatalog",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Endpoint not found: \(endpointID)"]
                )
            }

            let aliases: [String]
            if let display = existing.display {
                aliases = try normalizedCatalogDisplay(
                    display,
                    endpointNames: endpointNames,
                    current: existing.current
                ).aliases
            } else {
                aliases = [
                    try normalizedCurrent(
                        existing.current,
                        endpointNames: endpointNames
                    ) ?? "local",
                ]
            }

            var names = existing.display?.names ?? [:]
            if let name {
                let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedName.isEmpty,
                      normalizedName == name,
                      !name.contains("\r"),
                      !name.contains("\n"),
                      !name.contains("\0") else {
                    throw NSError(
                        domain: "WarrenEndpointCatalog",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint display name: \(name)"]
                    )
                }
                names[endpointID] = normalizedName
            } else {
                names.removeValue(forKey: endpointID)
            }

            let normalized = try normalizedDisplay(
                aliases,
                knownEndpointNames: endpointNames,
                current: existing.current,
                names: names
            )
            try writeUnlocked(WarrenEndpointConfigurationFile(
                current: normalized.current,
                endpoints: endpointDictionary(existing.endpoints),
                display: WarrenDisplayConfiguration(
                    endpoints: normalized.aliases,
                    names: normalized.names
                )
            ), to: configURL)
        }
    }

    /// Atomically changes one endpoint's explicit sidebar membership without
    /// selecting it as the foreground endpoint. Removing the final explicit
    /// alias restores the legacy single-current representation.
    static func setDisplayMembership(
        _ endpointID: String,
        isDisplayed: Bool,
        to configURL: URL = configurationURL()
    ) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            let endpointNames = Set(existing.endpoints.map(\.name)).union(["local"])
            guard endpointNames.contains(endpointID) else {
                throw NSError(
                    domain: "WarrenEndpointCatalog",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Endpoint not found: \(endpointID)"]
                )
            }

            // A missing display section means the legacy current endpoint is
            // already visible. The first menu "Add" must retain that Host,
            // rather than silently replacing it with the newly added one.
            var aliases = existing.display?.endpoints ?? []
            if isDisplayed, existing.display == nil {
                aliases = [
                    try normalizedCurrent(
                        existing.current,
                        endpointNames: endpointNames
                    ) ?? "local",
                ]
            }
            if isDisplayed {
                if !aliases.contains(endpointID) {
                    aliases.append(endpointID)
                }
            } else {
                aliases.removeAll { $0 == endpointID }
            }

            let display: WarrenDisplayConfiguration?
            if aliases.isEmpty {
                display = nil
            } else {
                let normalized = try normalizedDisplay(
                    aliases,
                    knownEndpointNames: endpointNames,
                    current: existing.current,
                    names: existing.display?.names ?? [:]
                )
                display = WarrenDisplayConfiguration(
                    endpoints: normalized.aliases,
                    names: normalized.names
                )
            }
            try writeUnlocked(WarrenEndpointConfigurationFile(
                current: try normalizedCurrent(existing.current, endpointNames: endpointNames),
                endpoints: endpointDictionary(existing.endpoints),
                display: display
            ), to: configURL)
        }
    }

    static func resetDisplay(to configURL: URL = configurationURL()) throws {
        try withLock(configURL) {
            let existing = try loadUnlocked(from: configURL).catalog
            try writeUnlocked(WarrenEndpointConfigurationFile(
                current: existing.current,
                endpoints: endpointDictionary(existing.endpoints),
                display: nil
            ), to: configURL)
        }
    }

    private static func normalizeDisplayAliases(_ values: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == value,
                  !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw NSError(
                    domain: "WarrenEndpointCatalog",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid display endpoint name: \(value)"]
                )
            }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func normalizedDisplay(
        _ aliases: [String],
        knownEndpointNames: Set<String>,
        current: String?,
        names: [String: String] = [:]
    ) throws -> (aliases: [String], current: String?, names: [String: String]) {
        let normalized = try normalizeDisplayAliases(aliases)
        guard !normalized.isEmpty else {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Display endpoint set cannot be empty"]
            )
        }
        if let unknown = normalized.first(where: { !knownEndpointNames.contains($0) }) {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Display endpoint not found: \(unknown)"]
            )
        }
        return (
            normalized,
            try normalizedCurrent(current, endpointNames: knownEndpointNames),
            try normalizeDisplayNames(names, knownEndpointNames: knownEndpointNames)
        )
    }

    /// Normalizes an optional persisted display while preserving the
    /// pre-display nil representation. The foreground endpoint remains
    /// independent from the explicitly chosen sidebar aliases.
    private static func normalizedCatalogDisplay(
        _ display: WarrenDisplayConfiguration?,
        endpointNames: Set<String>,
        current: String?
    ) throws -> (
        display: WarrenDisplayConfiguration?,
        aliases: [String],
        current: String?
    ) {
        guard let display else {
            return (
                nil,
                [],
                try normalizedCurrent(current, endpointNames: endpointNames)
            )
        }
        guard display.version == 0 || display.version == WarrenDisplayConfiguration.currentVersion else {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported display config version: \(display.version)"]
            )
        }
        let aliases = try normalizeDisplayAliases(display.endpoints)
        guard !aliases.isEmpty else {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Display endpoint set cannot be empty"]
            )
        }
        if let unknown = aliases.first(where: { !endpointNames.contains($0) }) {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Display endpoint not found: \(unknown)"]
            )
        }
        let names = try normalizeDisplayNames(
            display.names,
            knownEndpointNames: endpointNames
        )
        return (
            WarrenDisplayConfiguration(
                version: WarrenDisplayConfiguration.currentVersion,
                endpoints: aliases,
                names: names
            ),
            aliases,
            try normalizedCurrent(current, endpointNames: endpointNames)
        )
    }

    private static func normalizeDisplayNames(
        _ names: [String: String],
        knownEndpointNames: Set<String>
    ) throws -> [String: String] {
        var normalized: [String: String] = [:]
        for (endpointID, rawName) in names {
            // A removed endpoint may leave stale presentation metadata behind;
            // dropping that entry keeps the catalog usable and avoids making a
            // display-only field block unrelated endpoint operations.
            guard knownEndpointNames.contains(endpointID) else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name == rawName,
                  !rawName.contains("\r"),
                  !rawName.contains("\n"),
                  !rawName.contains("\0") else {
                throw NSError(
                    domain: "WarrenEndpointCatalog",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint display name: \(rawName)"]
                )
            }
            normalized[endpointID] = name
        }
        return normalized
    }

    private static func normalizedCurrent(
        _ current: String?,
        endpointNames: Set<String>
    ) throws -> String? {
        guard let current else { return nil }
        let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard endpointNames.contains(normalized) else {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Endpoint not found: \(normalized)"]
            )
        }
        return normalized
    }

    private static func loadUnlocked(
        from configURL: URL
    ) throws -> WarrenLoadedEndpointConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
                return WarrenLoadedEndpointConfiguration(catalog: (nil, [], nil))
            }
            throw error
        }
        let file: WarrenEndpointConfigurationFile
        do {
            file = try JSONDecoder().decode(WarrenEndpointConfigurationFile.self, from: data)
        } catch {
            throw NSError(
                domain: "WarrenEndpointCatalog",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to decode endpoint catalog: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                ]
            )
        }
        for endpoint in file.endpoints.values {
            if endpoint.ssh?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               !endpoint.url.isEmpty || !endpoint.token.isEmpty {
                throw NSError(
                    domain: "WarrenEndpointCatalog",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "state_reset_required: SSH endpoint \(endpoint.name) contains removed runtime fields"
                    ]
                )
            }
        }
        return WarrenLoadedEndpointConfiguration(
            catalog: (file.current, file.endpoints.values.sorted { $0.name < $1.name }, file.display)
        )
    }

    private static func writeUnlocked(
        _ file: WarrenEndpointConfigurationFile,
        to configURL: URL
    ) throws {
        let endpoints = file.endpoints.values.map { endpoint in
            guard endpoint.ssh?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return endpoint
            }
            return WarrenRemoteEndpointConfiguration(
                name: endpoint.name,
                url: "",
                token: "",
                ssh: endpoint.ssh,
                sshRemote: endpoint.sshRemote,
                type: endpoint.type,
                hostID: endpoint.hostID,
                routeID: endpoint.routeID,
                clientID: endpoint.clientID,
                refreshToken: endpoint.refreshToken,
                directURL: endpoint.directURL,
                relayURL: endpoint.relayURL,
                routePreference: endpoint.routePreference
            )
        }
        let normalizedFile = WarrenEndpointConfigurationFile(
            current: file.current,
            endpoints: endpointDictionary(endpoints),
            display: file.display
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalizedFile)
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directory.appendingPathComponent(
            ".\(configURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        var output = data
        output.append(0x0A)
        try output.write(to: temporaryURL, options: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: configURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private static func endpointDictionary(
        _ endpoints: [WarrenRemoteEndpointConfiguration]
    ) -> [String: WarrenRemoteEndpointConfiguration] {
        endpoints.reduce(into: [:]) { result, endpoint in
            // Keep the last value for duplicate names instead of trapping on
            // malformed or concurrently edited catalogs.
            result[endpoint.name] = endpoint
        }
    }

    private static func withLock<Value>(
        _ configURL: URL,
        _ body: () throws -> Value
    ) throws -> Value {
        processLock.lock()
        defer { processLock.unlock() }
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = configURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        var exclusive = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard Darwin.fcntl(descriptor, F_SETLKW, &exclusive) == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        defer {
            var unlocked = flock(
                l_start: 0,
                l_len: 0,
                l_pid: 0,
                l_type: Int16(F_UNLCK),
                l_whence: Int16(SEEK_SET)
            )
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlocked)
            Darwin.close(descriptor)
        }
        return try body()
    }
}
