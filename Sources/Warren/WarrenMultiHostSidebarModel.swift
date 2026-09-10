import Combine
import Foundation
import WarrenClientCore
import WarrenDesktop
import WarrenDomain
import WarrenTransport

/// Owns the roster-only connections used by the aggregated desktop sidebar.
///
/// The selected endpoint remains the exclusive owner of terminal attachment
/// through WarrenRemoteApplicationModel. This coordinator deliberately never
/// subscribes to a session, claims control, focuses a session, or resizes a
/// terminal. It only consumes Host roster snapshots and deltas.
@MainActor
final class WarrenMultiHostSidebarModel: ObservableObject {
    static let maximumConnections = 8

    @Published private(set) var projection = WarrenDesktopSidebarProjection()
    @Published private(set) var configurationError: String?

    private final class Connection {
        let endpointID: String
        let endpointLabel: String
        let configuration: WarrenRemoteEndpointConfiguration
        let generation = UUID()

        var task: Task<Void, Never>?
        var client: WarrenRemoteClient?
        var tunnel: WarrenEmbeddedSSHTunnel?
        var roster: WarrenRemoteRoster?
        var state: WarrenDesktopConnectionState = .connecting
        var lastError: String?
        var tunnelRestartScheduled = false

        init(
            endpointID: String,
            endpointLabel: String,
            configuration: WarrenRemoteEndpointConfiguration
        ) {
            self.endpointID = endpointID
            self.endpointLabel = endpointLabel
            self.configuration = configuration
        }
    }

    private struct ActiveHost {
        let endpointID: String
        let endpointLabel: String
        let projection: WarrenDesktopProjection
        let lastError: String?
    }

    private var aliases: [String] = []
    private var configurations: [String: WarrenRemoteEndpointConfiguration] = [:]
    private var labels: [String: String] = [:]
    private var activeEndpointID = "local"
    private var activeHost: ActiveHost?
    private var overflowAliases = Set<String>()
    private var connections: [String: Connection] = [:]

    /// Reconciles the client-local display configuration with the current
    /// interactive Host projection. Repeated calls are cheap: unchanged
    /// endpoint definitions retain their connection and latest roster.
    func configure(
        display: WarrenDisplayConfiguration?,
        endpoints: [WarrenRemoteEndpointConfiguration],
        activeEndpointID: String,
        activeProjection: WarrenDesktopProjection,
        activeConnectionError: String?
    ) {
        let activeID = Self.normalizedEndpointID(activeEndpointID)
        let resolvedAliases = Self.resolveAliases(
            display: display,
            current: activeID
        )
        aliases = resolvedAliases.aliases
        self.activeEndpointID = activeID

        // A malformed catalog can contain duplicate aliases when it was
        // edited by an older client. Keep the last value instead of trapping
        // while the sidebar is being reconciled.
        var nextConfigurations = endpoints.reduce(into: [String: WarrenRemoteEndpointConfiguration]()) {
            $0[$1.id] = $1
        }
        nextConfigurations["local"] = .localDaemon()
        configurations = nextConfigurations
        labels = nextConfigurations.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = entry.key == "local" ? "Local" : entry.value.name
        }
        labels["local"] = "Local"

        let unknownAlias = resolvedAliases.aliases.first {
            nextConfigurations[$0] == nil
        }
        configurationError = Self.boundedError(
            resolvedAliases.error
                ?? unknownAlias.map {
                    "Display endpoint \($0) is not configured. Update the endpoint catalog and retry."
                }
        )

        activeHost = ActiveHost(
            endpointID: activeID,
            endpointLabel: labels[activeID] ?? activeID,
            projection: activeProjection,
            lastError: Self.boundedError(activeConnectionError)
        )

        let backgroundAliases = aliases.filter { $0 != activeID }
        let backgroundCapacity = max(0, Self.maximumConnections - 1)
        let connectableAliases = Array(backgroundAliases.prefix(backgroundCapacity))
        overflowAliases = Set(backgroundAliases.dropFirst(backgroundCapacity))

        let connectionsToRemove: [(String, Connection)] = connections.compactMap { endpointID, connection in
            guard !connectableAliases.contains(endpointID)
                    || nextConfigurations[endpointID] != connection.configuration else {
                return nil
            }
            return (endpointID, connection)
        }
        for (endpointID, connection) in connectionsToRemove {
            stop(connection)
            connections.removeValue(forKey: endpointID)
        }

        for endpointID in connectableAliases {
            guard let configuration = nextConfigurations[endpointID] else { continue }
            if connections[endpointID] == nil {
                let connection = Connection(
                    endpointID: endpointID,
                    endpointLabel: labels[endpointID] ?? endpointID,
                    configuration: configuration
                )
                connections[endpointID] = connection
                start(connection)
            }
        }
        rebuildProjection()
    }

    /// Restarts one background roster connection. The active endpoint is
    /// retried by the existing interactive controller instead.
    func retry(endpointID: String) {
        guard endpointID != activeEndpointID,
              aliases.contains(endpointID),
              !overflowAliases.contains(endpointID),
              let configuration = configurations[endpointID] else {
            return
        }
        if let existing = connections.removeValue(forKey: endpointID) {
            stop(existing)
        }
        let connection = Connection(
            endpointID: endpointID,
            endpointLabel: labels[endpointID] ?? endpointID,
            configuration: configuration
        )
        connections[endpointID] = connection
        start(connection)
        rebuildProjection()
    }

    func stop() {
        for connection in connections.values {
            stop(connection)
        }
        connections.removeAll()
        aliases.removeAll()
        overflowAliases.removeAll()
        activeHost = nil
        projection = WarrenDesktopSidebarProjection()
    }

    private func start(_ connection: Connection) {
        connection.state = .connecting
        connection.lastError = nil
        let generation = connection.generation
            connection.task = Task { @MainActor [weak self, weak connection] in
            guard let self, let connection else { return }
            guard let configuration = await self.connectionConfiguration(
                for: connection,
                generation: generation
            ) else {
                return
            }
            guard self.isCurrent(connection, generation: generation) else { return }

            // Keep token rotations scoped to the durable catalog entry. The
            // tunnel returns a runtime URL/token with `ssh` cleared; writing
            // that value back would silently turn an SSH alias into a direct
            // endpoint and leak ephemeral route metadata into config.json.
            let durableConfiguration = connection.configuration
            let isSSHEndpoint = durableConfiguration.ssh?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let isSyntheticLocal = connection.endpointID == "local"
            let tokenBase = !isSSHEndpoint
                ? configuration
                : durableConfiguration
            let client = WarrenRemoteClient(
                configuration: configuration,
                // The protocol validates terminal format compatibility during
                // authentication even for a roster-only client. Supplying
                // this format does not subscribe to or render a terminal.
                terminalStateFormats: [WarrenRemoteClient.snapshotTerminalStateFormat],
                tokenUpdateHandler: { accessToken, refreshToken in
                    // `local` is a synthetic endpoint. Its daemon token is
                    // owned by the token file, so never create a spurious
                    // "Local" catalog entry when the transport rotates it.
                    guard !isSSHEndpoint, !isSyntheticLocal else { return }
                    let updated = tokenBase.withTokens(
                        token: accessToken,
                        refreshToken: refreshToken
                    )
                    try? WarrenEndpointCatalog.upsert(updated)
                }
            )
            connection.client = client
            await client.start()

            for await event in client.events() {
                guard !Task.isCancelled else { return }
                guard self.isCurrent(connection, generation: generation),
                      connection.client === client else { return }
                self.consume(
                    event,
                    from: connection,
                    client: client,
                    generation: generation
                )
            }
        }
    }

    private func connectionConfiguration(
        for connection: Connection,
        generation: UUID
    ) async -> WarrenRemoteEndpointConfiguration? {
        var configuration = connection.configuration
        if connection.endpointID == "local" {
            guard let local = await waitForLocalConfiguration(
                connection: connection,
                generation: generation
            ) else {
                return nil
            }
            configuration = local
        }
        if let sshTarget = configuration.ssh?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sshTarget.isEmpty {
            let tunnel = WarrenEmbeddedSSHTunnel()
            connection.tunnel = tunnel
            do {
                configuration = try await tunnel.start(
                    name: connection.endpointID,
                    target: sshTarget,
                    remoteAddress: connection.configuration.sshRemote
                )
            } catch {
                guard isCurrent(connection, generation: generation) else { return nil }
                connection.state = .failed
                connection.lastError = Self.boundedError(error.localizedDescription)
                rebuildProjection()
                return nil
            }
            guard isCurrent(connection, generation: generation) else {
                tunnel.stop()
                return nil
            }
        }
        return resolvedRelayConfiguration(configuration)
    }

    private func waitForLocalConfiguration(
        connection: Connection,
        generation: UUID
    ) async -> WarrenRemoteEndpointConfiguration? {
        for _ in 0..<150 {
            guard isCurrent(connection, generation: generation) else { return nil }
            let configuration = WarrenRemoteEndpointConfiguration.localDaemon()
            if !configuration.token.isEmpty {
                return configuration
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return nil
            }
        }
        guard isCurrent(connection, generation: generation) else { return nil }
        connection.state = .failed
        connection.lastError = "The local daemon is not running."
        rebuildProjection()
        return nil
    }

    private func resolvedRelayConfiguration(
        _ configuration: WarrenRemoteEndpointConfiguration
    ) -> WarrenRemoteEndpointConfiguration {
        guard configuration.isRelay else { return configuration }
        let configuredID = configuration.clientID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuredID?.isEmpty != false else { return configuration }
        let resolved = configuration.withClientID(UUID().uuidString.lowercased())
        try? WarrenEndpointCatalog.upsert(resolved)
        return resolved
    }

    private func consume(
        _ event: WarrenRemoteEvent,
        from connection: Connection,
        client: WarrenRemoteClient,
        generation: UUID
    ) {
        guard isCurrent(connection, generation: generation),
              connection.client === client else { return }
        switch event {
        case .connection(let state):
            switch state {
            case .connected:
                connection.state = .attached
                connection.lastError = nil
                requestRoster(using: client, connection: connection, generation: generation)
            case .connecting:
                connection.state = .connecting
            case .reconnecting:
                connection.state = .reconnecting
                restartTunnelIfNeeded(
                    for: connection,
                    client: client,
                    generation: generation
                )
            case .disconnected:
                connection.state = .disconnected
            case .stopped:
                connection.state = .disconnected
            }
        case .roster(let roster):
            if Self.shouldApplyRoster(roster, over: connection.roster) {
                connection.roster = roster
                connection.state = .attached
                connection.lastError = nil
            }
        case .rosterDelta:
            // WarrenRemoteClient applies a valid delta and emits the full
            // snapshot immediately afterwards. Keeping only snapshots avoids
            // a second delta implementation at this presentation boundary.
            break
        case .disconnected(let reason):
            connection.state = .reconnecting
            connection.lastError = Self.boundedError(reason)
            restartTunnelIfNeeded(
                for: connection,
                client: client,
                generation: generation
            )
        case .welcome, .output, .atomicState, .anchor, .agentEvents, .maintenance:
            break
        }
        rebuildProjection()
    }

    private func restartTunnelIfNeeded(
        for connection: Connection,
        client: WarrenRemoteClient,
        generation: UUID
    ) {
        guard isCurrent(connection, generation: generation),
              connection.tunnel != nil,
              connection.tunnel?.isRunning == false,
              !connection.tunnelRestartScheduled else {
            return
        }
        connection.tunnelRestartScheduled = true
        connection.task?.cancel()
        connection.task = nil
        connection.tunnel?.stop()
        connection.tunnel = nil
        connection.client = nil
        Task { await client.stop() }
        connection.state = .reconnecting
        connection.lastError = "SSH tunnel disconnected; reconnecting…"
        rebuildProjection()
        // Keep the old Connection identity so a catalog refresh cannot race a
        // replacement task. A short delay prevents a dead helper from causing
        // a tight restart loop while preserving the client's roster snapshot.
        Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, let connection,
                  self.isCurrent(connection, generation: generation),
                  !Task.isCancelled else { return }
            connection.tunnelRestartScheduled = false
            self.start(connection)
        }
    }

    private func requestRoster(
        using client: WarrenRemoteClient,
        connection: Connection,
        generation: UUID
    ) {
        Task { @MainActor [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                let roster = try await client.request(
                    "roster",
                    decoding: WarrenRemoteRoster.self
                )
                guard self.isCurrent(connection, generation: generation),
                      connection.client === client else { return }
                guard Self.shouldApplyRoster(roster, over: connection.roster) else {
                    return
                }
                connection.roster = roster
                connection.state = .attached
                connection.lastError = nil
                self.rebuildProjection()
            } catch {
                guard self.isCurrent(connection, generation: generation),
                      connection.client === client,
                      !Task.isCancelled else {
                    return
                }
                connection.state = .failed
                connection.lastError = Self.boundedError(error.localizedDescription)
                self.rebuildProjection()
            }
        }
    }

    private func stop(_ connection: Connection) {
        connection.tunnelRestartScheduled = false
        connection.task?.cancel()
        connection.task = nil
        connection.tunnel?.stop()
        connection.tunnel = nil
        if let client = connection.client {
            Task { await client.stop() }
        }
        connection.client = nil
    }

    private func isCurrent(_ connection: Connection, generation: UUID) -> Bool {
        connections[connection.endpointID] === connection
            && connection.generation == generation
    }

    private func rebuildProjection() {
        let hosts = aliases.map { endpointID -> WarrenDesktopSidebarHostProjection in
            if endpointID == activeEndpointID, let activeHost {
                return WarrenDesktopSidebarHostProjection(
                    endpointID: endpointID,
                    endpointLabel: activeHost.endpointLabel,
                    host: activeHost.projection.host,
                    connectionState: activeHost.projection.connectionState,
                    projectGroups: activeHost.projection.groups,
                    tasks: activeHost.projection.taskGroups.map(\.task),
                    workspaceActivitySummaries: activeHost.projection.workspaceActivitySummaries,
                    activeWorkspaceIDs: activeHost.projection.activeWorkspaceIDs,
                    lastError: activeHost.lastError
                )
            }
            if let connection = connections[endpointID] {
                return Self.makeProjection(for: connection)
            }
            if overflowAliases.contains(endpointID) {
                return WarrenDesktopSidebarHostProjection(
                    endpointID: endpointID,
                    endpointLabel: labels[endpointID] ?? endpointID,
                    connectionState: .disconnected,
                    lastError: "Sidebar connection limit reached."
                )
            }
            if configurations[endpointID] == nil {
                return WarrenDesktopSidebarHostProjection(
                    endpointID: endpointID,
                    endpointLabel: endpointID,
                    connectionState: .failed,
                    lastError: "Endpoint is not configured."
                )
            }
            return WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: labels[endpointID] ?? endpointID,
                connectionState: .disconnected
            )
        }
        let next = WarrenDesktopSidebarProjection(
            hosts: hosts,
            currentEndpointID: activeEndpointID
        )
        if projection != next {
            projection = next
        }
    }

    nonisolated static func resolveAliases(
        display: WarrenDisplayConfiguration?,
        current: String
    ) -> (aliases: [String], error: String?) {
        let fallback = normalizedEndpointID(current)
        guard let display else {
            return ([fallback], nil)
        }
        guard display.version == 0
                || display.version == WarrenDisplayConfiguration.currentVersion else {
            return ([fallback], "Unsupported display configuration version \(display.version).")
        }
        var aliases: [String] = []
        var seen = Set<String>()
        for value in display.endpoints {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized == value,
                  !value.contains("\r"),
                  !value.contains("\n"),
                  !value.contains("\0") else {
                return ([fallback], "The display endpoint set is invalid.")
            }
            if seen.insert(value).inserted {
                aliases.append(value)
            }
        }
        guard !aliases.isEmpty else {
            return ([fallback], "The display endpoint set cannot be empty.")
        }
        return (aliases, nil)
    }

    nonisolated static func makeProjection(
        endpointID: String,
        endpointLabel: String,
        roster: WarrenRemoteRoster?,
        connectionState: WarrenDesktopConnectionState,
        lastError: String?
    ) -> WarrenDesktopSidebarHostProjection {
        guard let roster else {
            return WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointLabel,
                connectionState: connectionState,
                lastError: boundedError(lastError)
            )
        }
        guard let hostID = HostID(uuidString: roster.host.id) else {
            return WarrenDesktopSidebarHostProjection(
                endpointID: endpointID,
                endpointLabel: endpointLabel,
                connectionState: connectionState,
                lastError: boundedError(lastError ?? "Host returned an invalid identifier.")
            )
        }

        let host = Host(id: hostID, name: roster.host.name)
        let tasks = roster.tasks.compactMap { value -> WarrenTask? in
            guard let taskID = TaskID(uuidString: value.id) else { return nil }
            return WarrenTask(
                id: taskID,
                hostID: hostID,
                name: value.name,
                source: value.source,
                externalID: value.externalID,
                url: value.url.flatMap(URL.init(string:)),
                pinned: value.pinned,
                order: value.order
            )
        }
        let projects = roster.projects.compactMap { value -> Project? in
            guard let projectID = ProjectID(uuidString: value.id) else { return nil }
            return Project(
                id: projectID,
                hostID: hostID,
                name: value.name,
                rootPath: value.path,
                setupScript: value.setupScript,
                autoImportGitWorktrees: value.autoImportGitWorktrees,
                pinned: value.pinned,
                order: value.order
            )
        }
        let workspaces = roster.workspaces.compactMap { value -> Workspace? in
            guard let workspaceID = WorkspaceID(uuidString: value.id),
                  let projectID = ProjectID(uuidString: value.projectID) else {
                return nil
            }
            return Workspace(
                id: workspaceID,
                projectID: projectID,
                taskID: value.taskID.flatMap(TaskID.init(uuidString:)),
                name: value.name,
                path: value.path,
                branch: value.branch,
                pinned: value.pinned,
                mergeState: value.mergeState.flatMap(WorkspaceMergeState.init(rawValue:)),
                managedWorktree: value.managedWorktree,
                worktreeLocked: value.worktreeLocked,
                order: value.order
            )
        }
        let workspaceIDs = Set(workspaces.map(\.id))
        let sessions = roster.sessions.compactMap { value -> WarrenDesktopSession? in
            guard let sessionID = TerminalSessionID(uuidString: value.id),
                  let workspaceID = value.workspaceID.flatMap(WorkspaceID.init(uuidString:)),
                  workspaceIDs.contains(workspaceID) else {
                return nil
            }
            return WarrenDesktopSession(
                id: sessionID,
                workspaceID: workspaceID,
                title: value.title,
                customTitle: value.customTitle,
                pinned: value.pinned,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom,
                state: value.isRunning ? .attached : .exited,
                agentStatus: agentStatus(from: value.agentStatus),
                runtimeProcess: value.process ?? value.command ?? "",
                workingDirectory: value.directory ?? ""
            )
        }
        let tabs = sessions.compactMap { session -> ClientTab? in
            guard session.state.isActive else { return nil }
            return ClientTab(
                id: "sidebar-\(endpointID)-\(session.id.description)",
                title: session.title,
                sessionID: session.id,
                kind: session.kind
            )
        }
        let sessionWorkspaceIDs = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                session.workspaceID.map { (session.id, $0) }
            }
        )
        let valueProjection = WarrenDesktopProjection(
            host: host,
            tasks: tasks,
            projects: projects,
            workspaces: workspaces,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            connectionState: .attached
        )
        return WarrenDesktopSidebarHostProjection(
            endpointID: endpointID,
            endpointLabel: endpointLabel,
            host: host,
            connectionState: connectionState,
            projectGroups: valueProjection.groups,
            tasks: tasks,
            workspaceActivitySummaries: valueProjection.workspaceActivitySummaries,
            activeWorkspaceIDs: valueProjection.activeWorkspaceIDs,
            lastError: boundedError(lastError)
        )
    }

    /// A direct roster request can race a pushed snapshot or delta. Never let
    /// an older response replace the newer in-memory view; a missing revision
    /// is also treated as older once a revisioned snapshot is available.
    nonisolated static func shouldApplyRoster(
        _ next: WarrenRemoteRoster,
        over current: WarrenRemoteRoster?
    ) -> Bool {
        guard let current else { return true }
        switch (current.revision, next.revision) {
        case let (currentRevision?, nextRevision?):
            return nextRevision >= currentRevision
        case (_?, nil):
            return false
        case (nil, _):
            return true
        }
    }

    private static func makeProjection(
        for connection: Connection
    ) -> WarrenDesktopSidebarHostProjection {
        makeProjection(
            endpointID: connection.endpointID,
            endpointLabel: connection.endpointLabel,
            roster: connection.roster,
            connectionState: connection.state,
            lastError: connection.lastError
        )
    }

    nonisolated private static func agentStatus(
        from value: WarrenRemoteAgentStatus?
    ) -> AgentStatus? {
        guard let value,
              let activity = AgentActivityState(rawValue: value.activity.rawValue) else {
            return nil
        }
        let attention = value.attention.flatMap { value -> AgentAttention? in
            guard let kind = AgentAttentionKind(rawValue: value.kind.rawValue) else {
                return nil
            }
            return AgentAttention(
                kind: kind,
                reason: value.reason,
                requestID: value.requestID,
                since: value.since
            )
        }
        return AgentStatus(activity: activity, attention: attention)
    }

    nonisolated private static func normalizedEndpointID(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "local" : normalized
    }

    nonisolated private static func boundedError(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(240))
    }
}
