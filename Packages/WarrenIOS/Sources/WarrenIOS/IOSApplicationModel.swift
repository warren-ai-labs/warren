import Combine
import Foundation
import WarrenDomain
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

/// High-frequency terminal state published by the active Terminal surface.
/// The dashboard never observes this object, so PTY frames cannot invalidate
/// the Sessions list while it is still in the navigation stack.
@MainActor
public final class IOSTerminalState: ObservableObject {
    @Published public fileprivate(set) var terminalReadyBySessionID: [String: Bool] = [:]
    /// The Host can acknowledge a subscribe before its output registration is
    /// attached. This flag is kept separate from renderer readiness.
    @Published public fileprivate(set) var terminalSubscriptionBySessionID: [String: Bool] = [:]
    @Published public fileprivate(set) var terminalOutputBySessionID: [String: Data] = [:]
    @Published public fileprivate(set) var terminalOutputRevisionBySessionID: [String: UInt64] = [:]
    @Published public fileprivate(set) var terminalSnapshotBySessionID: [String: Data] = [:]
    fileprivate func reset() {
        terminalReadyBySessionID = [:]
        terminalSubscriptionBySessionID = [:]
        terminalOutputBySessionID = [:]
        terminalOutputRevisionBySessionID = [:]
        terminalSnapshotBySessionID = [:]
    }
}

/// High-frequency Agent transcript state. Keeping it separate from terminal
/// state prevents hidden chat/terminal surfaces from invalidating one another
/// while a provider streams output.
@MainActor
public final class IOSAgentLiveState: ObservableObject {
    @Published public fileprivate(set) var agentEventsBySessionID: [String: [WarrenRemoteAgentEvent]] = [:]
    @Published public fileprivate(set) var agentEventRevisionBySessionID: [String: UInt64] = [:]

    fileprivate func reset() {
        agentEventsBySessionID = [:]
        agentEventRevisionBySessionID = [:]
    }
}

/// Main-actor projection consumed by the native SwiftUI hierarchy. The
/// WebSocket actor remains behind typed methods; views never access it or a
/// renderer directly.
@MainActor
public final class IOSApplicationModel: ObservableObject {
    @Published public private(set) var roster: WarrenRemoteRoster?
    @Published public private(set) var connectionState: WarrenRemoteConnectionState = .stopped
    @Published public private(set) var connectionError: String?
    @Published public private(set) var maintenanceMessage: String?
    @Published public private(set) var currentSessionID: String?
    /// Set only when a deleted current Session has no replacement. The root
    /// navigation consumes this one-shot destination to reveal its Workspace
    /// (or Terminal Group) instead of dropping the user at the Host dashboard.
    @Published public private(set) var sessionDeletionDestination: IOSSessionScopeDestination?
    @Published public private(set) var displayMode: IOSSessionDisplayMode
    @Published public private(set) var hasControlLease = false
    /// Live stores are intentionally separate from the dashboard model. They
    /// are exposed read-only; mutation remains on the main-actor projection.
    public let terminalState: IOSTerminalState
    public let agentState: IOSAgentLiveState
    public var terminalReadyBySessionID: [String: Bool] { terminalState.terminalReadyBySessionID }
    public var terminalSubscriptionBySessionID: [String: Bool] { terminalState.terminalSubscriptionBySessionID }
    public var terminalOutputBySessionID: [String: Data] { terminalState.terminalOutputBySessionID }
    public var terminalOutputRevisionBySessionID: [String: UInt64] { terminalState.terminalOutputRevisionBySessionID }
    public var terminalSnapshotBySessionID: [String: Data] { terminalState.terminalSnapshotBySessionID }
    public var agentEventsBySessionID: [String: [WarrenRemoteAgentEvent]] { agentState.agentEventsBySessionID }
    public var agentEventRevisionBySessionID: [String: UInt64] { agentState.agentEventRevisionBySessionID }
    @Published public private(set) var agentStatusBySessionID: [String: WarrenRemoteAgentStatus] = [:]
    @Published public private(set) var agentQueuedMessageCountBySessionID: [String: Int] = [:]
    @Published public private(set) var agentQueuedMessagesBySessionID: [String: [IOSAgentQueuedMessage]] = [:]
    @Published public private(set) var historyLoadingBySessionID: Set<String> = []
    @Published public private(set) var navigation: IOSNavigationState
    @Published public private(set) var endpointMetadata: IOSEndpointMetadata
    /// Metadata for every saved Host. Tokens are never published here; each
    /// row only exposes the Keychain-backed credential's presence flag.
    @Published public private(set) var endpointMetadataList: [IOSEndpointMetadata]
    @Published public private(set) var endpointError: String?
    @Published public private(set) var isPairingRelay = false
    @Published public private(set) var mutationError: String?
    @Published public private(set) var isMutating = false

    public private(set) var client: WarrenRemoteClient
    public let localStore: IOSLocalStore

    private var endpointToken: String
    private var eventTask: Task<Void, Never>?
    /// The UI's desired lifecycle is separate from the transport's last
    /// published state.  A stop event can still be buffered while a scene is
    /// returning to the foreground; when the user expects a live connection,
    /// that stale event must not turn the surface into a false "Offline".
    private var connectionRequested = false
    /// Serializes client start/stop operations. Scene transitions can happen
    /// faster than an actor hop to WarrenRemoteClient; without this fence a
    /// foreground start could race the previous background stop and leave a
    /// running client immediately stopped again.
    private var clientLifecycleTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var sessionSelectionGeneration: UInt64 = 0
    private var agentEpochBySessionID: [String: UInt64] = [:]
    private var agentEventKeysBySessionID: [String: Set<String>] = [:]
    /// Display mode is a presentation preference of each Session, not a
    /// property of the Host process. Agent-backed Sessions open on Agent by
    /// default; an explicit Terminal/Agent switch is remembered while the
    /// model remains alive so changing Sessions does not leak the previous
    /// surface's strategy into the next one.
    private var displayModeBySessionID: [String: IOSSessionDisplayMode] = [:]
    private var historyCursorBySessionID: [String: UInt64] = [:]
    private var historyHasMoreBySessionID: [String: Bool] = [:]
    private var historyLoadedBySessionID: Set<String> = []
    private var terminalSizeBySessionID: [String: TerminalSize] = [:]
    private var terminalResizeTasksBySessionID: [String: Task<Void, Never>] = [:]
    private var pendingTerminalResizeBySessionID: [String: TerminalSize] = [:]
    private var lastSentTerminalSizeBySessionID: [String: TerminalSize] = [:]
    private var terminalEpochBySessionID: [String: UInt64] = [:]
    private var terminalNextSequenceBySessionID: [String: UInt64] = [:]
    private var pendingTerminalRecoveryBySessionID: [String: WarrenRemoteRecoveryAnchor] = [:]
    private var terminalRecoveryRequests: Set<String> = []
    private var terminalSubscriptionRequests: Set<String> = []
    private var pendingTerminalFocusBySessionID: Set<String> = []
    private var pendingSessionSelectionID: String?
    private var pendingSessionDeletion: PendingSessionDeletion?
    private var pendingAgentMessagesBySessionID: [String: [IOSAgentQueuedMessage]] = [:]
    private var agentMessageSubmissionsInFlight: Set<String> = []

    private struct PendingSessionDeletion {
        let sessionID: String
        let replacementSessionID: String?
    }

    public init(
        client: WarrenRemoteClient,
        localStore: IOSLocalStore = IOSLocalStore(),
        endpointMetadata: IOSEndpointMetadata? = nil
    ) {
        let restoredNavigation = localStore.navigation
        let storedEndpoint = localStore.endpoint
        let restoredEndpoint = endpointMetadata
            ?? storedEndpoint.map(IOSEndpointMetadata.init)
            ?? IOSEndpointMetadata(
                name: IOSDevelopmentEndpoint.name,
                url: IOSDevelopmentEndpoint.url,
                hasToken: !IOSDevelopmentEndpoint.token.isEmpty
            )
        var restoredEndpoints = localStore.endpoints.map(IOSEndpointMetadata.init)
        if !restoredEndpoints.contains(where: { $0.name == restoredEndpoint.name }) {
            restoredEndpoints.append(restoredEndpoint)
        }
        self.terminalState = IOSTerminalState()
        self.agentState = IOSAgentLiveState()
        self.client = client
        self.localStore = localStore
        self.endpointToken = storedEndpoint?.token ?? ""
        self.navigation = restoredNavigation
        self.displayMode = restoredNavigation.displayMode
        self.endpointMetadata = restoredEndpoint
        self.endpointMetadataList = restoredEndpoints
        self.endpointError = nil
        self.mutationError = nil
        self.connectionError = nil
        // The persisted ID is a restore hint. It becomes active only after a
        // fresh roster confirms that the Host still owns the Session.
        self.currentSessionID = nil
        self.sessionDeletionDestination = nil
    }

    public convenience init(
        configuration: WarrenRemoteEndpointConfiguration,
        localStore: IOSLocalStore = IOSLocalStore()
    ) {
        self.init(
            client: WarrenRemoteClient(configuration: configuration),
            localStore: localStore,
            endpointMetadata: IOSEndpointMetadata(configuration: configuration)
        )
        self.endpointToken = configuration.token
    }

    deinit {
        eventTask?.cancel()
        clientLifecycleTask?.cancel()
        sessionTask?.cancel()
        terminalResizeTasksBySessionID.values.forEach { $0.cancel() }
    }

    /// Starts the actor-owned connection and consumes its event stream. The
    /// previous roster remains visible while a reconnect is in progress.
    public func start() {
        connectionRequested = true
        guard eventTask == nil else { return }
        let client = client
        let previousLifecycle = clientLifecycleTask
        let startup = Task {
            await previousLifecycle?.value
            guard !Task.isCancelled else { return }
            await client.start()
        }
        clientLifecycleTask = startup
        eventTask = Task { [weak self] in
            await startup.value
            guard !Task.isCancelled else { return }
            for await event in client.events() {
                guard !Task.isCancelled else { return }
                self?.consume(event)
            }
        }
    }

    public func stop() {
        connectionRequested = false
        eventTask?.cancel()
        eventTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        terminalResizeTasksBySessionID.values.forEach { $0.cancel() }
        terminalResizeTasksBySessionID.removeAll()
        pendingTerminalResizeBySessionID.removeAll()
        let client = client
        let previousLifecycle = clientLifecycleTask
        clientLifecycleTask = Task {
            await previousLifecycle?.value
            await client.stop()
        }
        hasControlLease = false
        if let currentSessionID {
            terminalState.terminalSubscriptionBySessionID[currentSessionID] = false
            // WarrenRemoteClient retains the subscription intent while its
            // socket is stopped and restores it on the next connection.
            terminalSubscriptionRequests.insert(currentSessionID)
            terminalRecoveryRequests.remove(currentSessionID)
        }
        connectionState = .stopped
    }

    /// Requests a reconnect without exposing the transport actor to a View.
    public func reconnect() {
        let client = client
        Task { await client.reconnectNow() }
    }

    /// Saves endpoint metadata and replaces the transport with a client for
    /// the new Host. A blank token keeps the existing Keychain credential;
    /// use `clearEndpointToken()` when the user explicitly wants to log out.
    @discardableResult
    public func saveEndpoint(
        name: String,
        url: String,
        token: String? = nil,
        type: String? = nil,
        hostID: String? = nil,
        routeID: String? = nil
    ) -> Bool {
        saveEndpoint(
            name: name,
            url: url,
            token: token,
            type: type,
            hostID: hostID,
            routeID: routeID,
            replacingEndpointName: localStore.endpoint?.name
        )
    }

    /// Adds a new Host without treating the currently selected credential as
    /// the default token for the new item.
    @discardableResult
    public func saveNewEndpoint(
        name: String,
        url: String,
        token: String? = nil,
        type: String? = nil,
        hostID: String? = nil,
        routeID: String? = nil
    ) -> Bool {
        saveEndpoint(
            name: name,
            url: url,
            token: token,
            type: type,
            hostID: hostID,
            routeID: routeID,
            replacingEndpointName: nil
        )
    }

    /// The explicit replacement form is used by the Host list editor when a
    /// non-active item is renamed or reconfigured.
    @discardableResult
    public func saveEndpoint(
        name: String,
        url: String,
        token: String? = nil,
        type: String? = nil,
        hostID: String? = nil,
        routeID: String? = nil,
        replacingEndpointName: String?
    ) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            endpointError = "Host name is required."
            return false
        }
        if let duplicate = localStore.endpoint(named: normalizedName),
           duplicate.name != replacingEndpointName {
            endpointError = "A Host with this name already exists."
            return false
        }
        let existing = replacingEndpointName.flatMap { localStore.endpoint(named: $0) }
        let retainedToken = replacingEndpointName == nil
            ? ""
            : (existing?.token ?? endpointToken)
        let resolvedToken = token ?? retainedToken
        // A manually edited URL is an explicit switch back to a direct Host.
        // Preserve Relay routing only when the user is saving the same Relay
        // base (or when pairing supplies the type explicitly); otherwise a
        // stale host ID would make an ordinary LAN URL point at /h/<old-id>.
        let normalizedExistingURL = existing?.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepsRelayRoute = existing?.isRelay == true && normalizedExistingURL == normalizedURL
        let resolvedType = type ?? (keepsRelayRoute ? "relay" : "daemon")
        let isRelay = resolvedType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "relay"
        let resolvedHostID = isRelay
            ? (hostID ?? existing?.hostID)
            : nil
        let resolvedRouteID = isRelay
            ? (routeID ?? existing?.routeID)
            : nil
        let configuration = WarrenRemoteEndpointConfiguration(
            name: normalizedName,
            url: normalizedURL,
            token: resolvedToken,
            ssh: existing?.ssh,
            type: resolvedType,
            hostID: resolvedHostID,
            routeID: resolvedRouteID
        )
        guard configuration.webSocketURL != nil else {
            endpointError = "Enter a valid http(s) or ws(s) Host URL."
            return false
        }

        localStore.saveEndpoint(
            configuration,
            replacingName: replacingEndpointName,
            activate: true
        )
        activateEndpoint(configuration, shouldRestart: eventTask != nil)
        return true
    }

    /// Switches the active transport to a saved Host from the list.
    public func selectEndpoint(named name: String) {
        guard let configuration = localStore.endpoint(named: name) else { return }
        guard configuration.name != endpointMetadata.name else {
            _ = localStore.activateEndpoint(named: name)
            return
        }
        guard localStore.activateEndpoint(named: name) else { return }
        activateEndpoint(configuration, shouldRestart: eventTask != nil)
    }

    /// Removes a saved Host. The active transport moves to the next available
    /// item so a connected model never loses its client configuration.
    @discardableResult
    public func removeEndpoint(named name: String) -> Bool {
        let values = localStore.endpoints
        guard values.count > 1,
              values.contains(where: { $0.name == name }) else { return false }
        let wasActive = endpointMetadata.name == name
        guard localStore.removeEndpoint(named: name) else { return false }
        endpointMetadataList = localStore.endpoints.map(IOSEndpointMetadata.init)
        if wasActive, let replacement = localStore.endpoint {
            activateEndpoint(replacement, shouldRestart: eventTask != nil)
        }
        return true
    }

    private func activateEndpoint(
        _ configuration: WarrenRemoteEndpointConfiguration,
        shouldRestart: Bool
    ) {
        connectionRequested = shouldRestart
        let oldClient = client
        eventTask?.cancel()
        eventTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        terminalResizeTasksBySessionID.values.forEach { $0.cancel() }
        terminalResizeTasksBySessionID.removeAll()
        pendingTerminalResizeBySessionID.removeAll()
        lastSentTerminalSizeBySessionID.removeAll()
        let previousLifecycle = clientLifecycleTask
        clientLifecycleTask = Task {
            await previousLifecycle?.value
            await oldClient.stop()
        }
        client = WarrenRemoteClient(configuration: configuration)
        endpointToken = configuration.token
        endpointMetadata = IOSEndpointMetadata(configuration: configuration)
        endpointMetadataList = localStore.endpoints.map(IOSEndpointMetadata.init)
        endpointError = nil
        mutationError = nil
        connectionError = nil
        // Keep the persisted navigation as a restore hint, but do not expose
        // resources from the previous Host while the new roster is loading.
        roster = nil
        currentSessionID = nil
        sessionDeletionDestination = nil
        pendingSessionDeletion = nil
        hasControlLease = false
        terminalState.reset()
        agentState.reset()
        agentStatusBySessionID = [:]
        displayModeBySessionID = [:]
        agentQueuedMessageCountBySessionID = [:]
        agentQueuedMessagesBySessionID = [:]
        pendingAgentMessagesBySessionID = [:]
        agentMessageSubmissionsInFlight = []
        historyLoadingBySessionID = []
        historyLoadedBySessionID = []
        terminalSubscriptionRequests = []
        pendingTerminalFocusBySessionID = []
        terminalRecoveryRequests = []
        maintenanceMessage = nil
        connectionState = shouldRestart ? .connecting : .stopped
        if shouldRestart {
            start()
        }
    }

    /// Exchanges a shareable Relay URL (normally obtained from a QR code) and
    /// adds the resulting host-scoped Relay configuration. The URLSession is
    /// shared with WarrenRemoteClient so the Relay refresh cookie survives the
    /// subsequent WebSocket connection. Re-pairing the same Relay Host updates
    /// its saved credential; a different Host receives a local, non-sensitive
    /// display name.
    public func pairRelay(from url: URL, replacingEndpointName: String? = nil) {
        guard !isPairingRelay else { return }
        isPairingRelay = true
        endpointError = nil
        Task { [weak self] in
            do {
                let pairing = try WarrenRelayPairingClient.parse(url)
                let exchange = try await WarrenRelayPairingClient.exchange(
                    pairing,
                    urlSession: WarrenRemoteNetworking.session
                )
                await MainActor.run {
                    guard let self else { return }
                    let target = self.relayPairingTarget(
                        hostID: exchange.hostID,
                        relayURL: pairing.relayURL,
                        requestedEndpointName: replacingEndpointName
                    )
                    let saved = self.saveEndpoint(
                        name: target.name,
                        url: pairing.relayURL,
                        token: exchange.accessToken,
                        type: "relay",
                        hostID: exchange.hostID,
                        replacingEndpointName: target.replacingName
                    )
                    if !saved {
                        self.endpointError = "Relay pairing returned an invalid Host endpoint."
                    }
                    self.isPairingRelay = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isPairingRelay = false
                    self.endpointError = error.localizedDescription
                }
            }
        }
    }

    /// Resolves a stable local label for a scanned Relay Host without copying
    /// the Relay address or Host ID into the UI. Existing matching entries are
    /// replaced so rescanning rotates their access capability instead of
    /// creating a duplicate row.
    private func relayPairingTarget(
        hostID: String,
        relayURL: String,
        requestedEndpointName: String?
    ) -> (name: String, replacingName: String?) {
        if let requested = requestedEndpointName?.trimmingCharacters(in: .whitespacesAndNewlines),
           let existing = localStore.endpoint(named: requested) {
            return (existing.name, existing.name)
        }

        if let existing = localStore.endpoints.first(where: { endpoint in
            endpoint.isRelay
                && endpoint.hostID == hostID
                && normalizedRelayURL(endpoint.url) == normalizedRelayURL(relayURL)
        }) {
            return (existing.name, existing.name)
        }

        let baseName = "Relay Host"
        let existingNames = Set(localStore.endpoints.map(\.name))
        if !existingNames.contains(baseName) {
            return (baseName, nil)
        }
        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return ("\(baseName) \(suffix)", nil)
    }

    private func normalizedRelayURL(_ value: String) -> String {
        let fallback = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: fallback) else { return fallback }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        } else {
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        return components.string ?? fallback
    }

    /// Convenience entry point for the paste fallback shown beside the
    /// camera scanner. Keeping URL validation here makes the SwiftUI form
    /// independent of Relay's ticket format.
    public func pairRelayLink(_ value: String, replacingEndpointName: String? = nil) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else {
            endpointError = WarrenRelayPairingError.invalidURL.localizedDescription
            return
        }
        pairRelay(from: url, replacingEndpointName: replacingEndpointName)
    }

    /// Removes only the saved credential. An existing connection is allowed
    /// to finish normally; a future reconnect will require a new token.
    public func clearEndpointToken() {
        clearEndpointToken(named: nil)
    }

    /// Removes the credential for a specific Host list item. The active
    /// endpoint's published metadata is refreshed immediately; non-active
    /// rows update on the next list projection.
    public func clearEndpointToken(named name: String?) {
        let endpoint = name.flatMap { localStore.endpoint(named: $0) } ?? localStore.endpoint
        guard let endpoint else { return }
        localStore.clearToken(for: endpoint.name)
        if endpoint.name == endpointMetadata.name {
            endpointToken = ""
            endpointMetadata = IOSEndpointMetadata(
                name: endpoint.name,
                url: endpoint.url,
                hasToken: false,
                type: endpoint.type,
                hostID: endpoint.hostID,
                routeID: endpoint.routeID
            )
        }
        endpointMetadataList = localStore.endpoints.map(IOSEndpointMetadata.init)
    }

    public func setDisplayMode(_ mode: IOSSessionDisplayMode) {
        if let currentSessionID {
            displayModeBySessionID[currentSessionID] = mode
        }
        guard displayMode != mode else { return }
        displayMode = mode
        navigation.displayMode = mode
        persistNavigation()
    }

    private func applyPreferredDisplayMode(for session: WarrenRemoteRoster.Session) {
        let preferred = displayModeBySessionID[session.id]
            ?? (session.isAgentBacked ? .agent : .terminal)
        displayModeBySessionID[session.id] = preferred
        displayMode = preferred
        navigation.displayMode = preferred
    }

    /// Consumes the one-shot scope destination emitted after deleting the
    /// current Session. Navigation owns the actual stack mutation; the model
    /// only supplies the exact scope identity once.
    public func consumeSessionDeletionDestination() -> IOSSessionScopeDestination? {
        let destination = sessionDeletionDestination
        sessionDeletionDestination = nil
        return destination
    }

    /// Ends the native first responder without changing the remote terminal
    /// lease. This is deliberately separate from `releaseControl`: hiding the
    /// keyboard is a local presentation action, not a collaboration action.
    public func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }

    public func selectWorkspace(_ workspaceID: String) {
        pendingSessionDeletion = nil
        sessionDeletionDestination = nil
        leaveSessionIfNeeded()
        navigation.workspaceID = workspaceID
        navigation.terminalGroupID = nil
        navigation.sessionID = nil
        persistNavigation()
    }

    public func selectTerminalGroup(_ groupID: String) {
        pendingSessionDeletion = nil
        sessionDeletionDestination = nil
        leaveSessionIfNeeded()
        navigation.workspaceID = nil
        navigation.terminalGroupID = groupID
        navigation.sessionID = nil
        persistNavigation()
    }

    /// Changes the visible Session without ending it. The old subscription is
    /// acknowledged before its replacement to prevent stale recovery markers.
    public func selectSession(_ sessionID: String) {
        guard let selectedSession = roster?.sessions.first(where: { $0.id == sessionID && $0.isRunning }) else { return }
        guard currentSessionID != sessionID else { return }
        pendingSessionDeletion = nil
        sessionDeletionDestination = nil
        sessionSelectionGeneration &+= 1
        let generation = sessionSelectionGeneration
        let previousTask = sessionTask
        let oldSessionID = currentSessionID
        currentSessionID = sessionID
        navigation.sessionID = sessionID
        navigation.workspaceID = selectedSession.workspaceID
        navigation.terminalGroupID = selectedSession.terminalGroupID
        applyPreferredDisplayMode(for: selectedSession)
        hasControlLease = false
        terminalState.terminalReadyBySessionID[sessionID] = false
        terminalState.terminalSubscriptionBySessionID[sessionID] = false
        terminalSubscriptionRequests.insert(sessionID)
        pendingTerminalFocusBySessionID.removeAll()
        pendingTerminalRecoveryBySessionID.removeValue(forKey: sessionID)
        terminalRecoveryRequests.remove(sessionID)
        if let oldSessionID {
            terminalSubscriptionRequests.remove(oldSessionID)
            cancelTerminalResize(for: oldSessionID)
            terminalState.terminalSubscriptionBySessionID[oldSessionID] = false
            terminalRecoveryRequests.remove(oldSessionID)
        }
        persistNavigation()

        let client = client
        sessionTask = Task { [weak self] in
            // Selection changes are serialized. Cancelling a previous task
            // before its unsubscribe reaches the Host can leave two active
            // subscriptions and lets stale frames race the replacement.
            await previousTask?.value
            if let oldSessionID {
                _ = try? await client.unsubscribe(sessionID: oldSessionID)
            }
            guard !Task.isCancelled,
                  let self,
                  self.sessionSelectionGeneration == generation,
                  self.currentSessionID == sessionID else { return }
            let anchor = await client.recoveryAnchor(for: sessionID)
            do {
                let result = try await client.subscribe(
                    sessionID: sessionID,
                    anchor: anchor,
                    claimControl: false
                )
                guard result.subscribed else {
                    throw WarrenRemoteClientError.requestFailed("session subscription was not accepted")
                }
            } catch {
                await MainActor.run {
                    guard self.sessionSelectionGeneration == generation,
                          self.currentSessionID == sessionID else { return }
                    if !Self.shouldRetainSubscriptionIntent(after: error) {
                        self.terminalSubscriptionRequests.remove(sessionID)
                    } else {
                        // The transport records the subscription intent before
                        // sending the request, so reconnect restoration can
                        // complete this handoff after a transient disconnect.
                        self.terminalSubscriptionRequests.insert(sessionID)
                    }
                    self.terminalState.terminalSubscriptionBySessionID[sessionID] = false
                    self.connectionState = .reconnecting
                }
            }
        }
    }

    /// Leaves the visible Session without terminating its Host-owned process.
    /// The unsubscribe is ordered behind any in-flight replacement so a
    /// navigation pop cannot detach the newly selected Session by accident.
    public func leaveSession(_ sessionID: String) {
        guard currentSessionID == sessionID else { return }
        pendingSessionDeletion = nil
        sessionDeletionDestination = nil
        leaveSessionIfNeeded()
        navigation.sessionID = nil
        persistNavigation()
    }

    private func leaveSessionIfNeeded() {
        guard let oldSessionID = currentSessionID else {
            hasControlLease = false
            pendingTerminalFocusBySessionID.removeAll()
            return
        }
        pendingSessionDeletion = nil
        sessionDeletionDestination = nil
        sessionSelectionGeneration &+= 1
        let generation = sessionSelectionGeneration
        let previousTask = sessionTask
        sessionTask = Task { [weak self] in
            await previousTask?.value
            _ = try? await self?.client.unsubscribe(sessionID: oldSessionID)
            guard let self, self.sessionSelectionGeneration == generation else { return }
            self.hasControlLease = false
            self.currentSessionID = nil
        }
        terminalSubscriptionRequests.remove(oldSessionID)
        cancelTerminalResize(for: oldSessionID)
        terminalState.terminalSubscriptionBySessionID[oldSessionID] = false
        pendingTerminalFocusBySessionID.remove(oldSessionID)
        terminalRecoveryRequests.remove(oldSessionID)
        hasControlLease = false
    }

    private func cancelTerminalResize(for sessionID: String) {
        terminalResizeTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
        pendingTerminalResizeBySessionID.removeValue(forKey: sessionID)
    }

    public func focusTerminal(size: TerminalSize? = nil) {
        guard let sessionID = currentSessionID else { return }
        let requestedSize = size ?? terminalSizeBySessionID[sessionID]
        guard connectionState == .connected,
              terminalSubscriptionBySessionID[sessionID] == true else {
            // `session.subscribe` is handled by the Host in the background:
            // its response can arrive before the output registration and
            // atomic checkpoint. Keep the user's control intent until the
            // matching `attached` marker proves that focus can be promoted.
            pendingTerminalFocusBySessionID.insert(sessionID)
            ensureTerminalSubscription(for: sessionID)
            return
        }
        requestTerminalFocus(sessionID: sessionID, size: requestedSize)
    }

    private func requestTerminalFocus(sessionID: String, size: TerminalSize?) {
        guard currentSessionID == sessionID,
              connectionState == .connected,
              terminalSubscriptionBySessionID[sessionID] == true else {
            pendingTerminalFocusBySessionID.insert(sessionID)
            return
        }
        pendingTerminalFocusBySessionID.remove(sessionID)
        let client = client
        Task { [weak self] in
            do {
                let result = try await client.focus(sessionID: sessionID, focused: true, size: size)
                await MainActor.run {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.hasControlLease = result.focused
                    if result.focused {
                        self.drainQueuedAgentMessages(for: sessionID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.hasControlLease = false
                }
            }
        }
    }

    private func drainPendingTerminalFocus(for sessionID: String) {
        guard pendingTerminalFocusBySessionID.contains(sessionID),
              currentSessionID == sessionID,
              connectionState == .connected,
              terminalSubscriptionBySessionID[sessionID] == true else { return }
        requestTerminalFocus(sessionID: sessionID, size: terminalSizeBySessionID[sessionID])
    }

    /// Starts a passive subscription when the selection task failed while the
    /// socket was already connected. Normally `selectSession` or the client's
    /// reconnect restore owns this request; the set prevents duplicate output
    /// readers when Control is tapped during that handoff.
    private func ensureTerminalSubscription(for sessionID: String) {
        guard currentSessionID == sessionID,
              connectionState == .connected,
              terminalSubscriptionBySessionID[sessionID] != true,
              terminalSubscriptionRequests.insert(sessionID).inserted else { return }
        let generation = sessionSelectionGeneration
        let client = client
        sessionTask = Task { [weak self] in
            do {
                let anchor = await client.recoveryAnchor(for: sessionID)
                let result = try await client.subscribe(
                    sessionID: sessionID,
                    anchor: anchor,
                    claimControl: false
                )
                guard result.subscribed else {
                    throw WarrenRemoteClientError.requestFailed("session subscription was not accepted")
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.sessionSelectionGeneration == generation,
                          self.currentSessionID == sessionID else { return }
                    if !Self.shouldRetainSubscriptionIntent(after: error) {
                        self.terminalSubscriptionRequests.remove(sessionID)
                    }
                }
            }
        }
    }

    private static func shouldRetainSubscriptionIntent(after error: Error) -> Bool {
        guard let error = error as? WarrenRemoteClientError else { return false }
        switch error {
        case .notConnected, .closed:
            return true
        default:
            return false
        }
    }

    public func releaseControl() {
        guard let sessionID = currentSessionID else { return }
        pendingTerminalFocusBySessionID.remove(sessionID)
        cancelTerminalResize(for: sessionID)
        let client = client
        Task { [weak self] in
            _ = try? await client.focus(sessionID: sessionID, focused: false)
            await MainActor.run {
                guard let self, self.currentSessionID == sessionID else { return }
                self.hasControlLease = false
            }
        }
    }

    public func resizeTerminal(_ size: TerminalSize) {
        guard let sessionID = currentSessionID else { return }
        terminalSizeBySessionID[sessionID] = size
        guard hasControlLease else { return }
        guard lastSentTerminalSizeBySessionID[sessionID] != size else { return }
        if pendingTerminalResizeBySessionID[sessionID] == size {
            return
        }

        terminalResizeTasksBySessionID[sessionID]?.cancel()
        pendingTerminalResizeBySessionID[sessionID] = size
        let client = client
        terminalResizeTasksBySessionID[sessionID] = Task { [weak self] in
            do {
                // SwiftTerm can report several intermediate cell sizes while
                // the keyboard/safe-area animation settles. Coalescing those
                // reports prevents a burst of Host resizes and atomic
                // recoveries on an otherwise healthy LAN connection.
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                _ = try await client.resize(size)
                await MainActor.run {
                    guard let self else { return }
                    guard self.pendingTerminalResizeBySessionID[sessionID] == size else { return }
                    self.lastSentTerminalSizeBySessionID[sessionID] = size
                    self.pendingTerminalResizeBySessionID.removeValue(forKey: sessionID)
                    self.terminalResizeTasksBySessionID.removeValue(forKey: sessionID)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.pendingTerminalResizeBySessionID[sessionID] == size {
                        self.pendingTerminalResizeBySessionID.removeValue(forKey: sessionID)
                        self.terminalResizeTasksBySessionID.removeValue(forKey: sessionID)
                    }
                }
            }
        }
    }

    /// Records the renderer's latest measured viewport. The value is used by
    /// the first focus request, then later changes are sent only while this
    /// client owns the control lease.
    public func updateTerminalSize(_ size: TerminalSize, for sessionID: String? = nil) {
        guard let target = sessionID ?? currentSessionID else { return }
        terminalSizeBySessionID[target] = size
    }

    public func sendTerminalInput(_ data: Data) {
        guard hasControlLease, !data.isEmpty else { return }
        let client = client
        Task { try? await client.sendInput(data) }
    }

    public func sendAgentMessage(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              hasControlLease,
              let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID) else { return }

        switch status.activity {
        case .ready:
            if agentMessageSubmissionsInFlight.contains(sessionID)
                || !(pendingAgentMessagesBySessionID[sessionID]?.isEmpty ?? true) {
                enqueueAgentMessage(value, for: sessionID)
                drainQueuedAgentMessages(for: sessionID)
            } else {
                submitAgentMessage(value, for: sessionID)
            }
        case .working:
            enqueueAgentMessage(value, for: sessionID)
        case .blocked:
            guard status.attention?.kind == .input else { return }
            if agentMessageSubmissionsInFlight.contains(sessionID)
                || !(pendingAgentMessagesBySessionID[sessionID]?.isEmpty ?? true) {
                enqueueAgentMessage(value, for: sessionID)
                drainQueuedAgentMessages(for: sessionID)
            } else {
                submitAgentMessage(value, for: sessionID)
            }
        case .stalled, .failed, .exited, .unknown:
            return
        }
    }

    /// Sends Ctrl-C through the existing PTY control lease. Interrupt is a
    /// presentation action, not a new Agent wire request; the Host remains
    /// authoritative for the resulting status and transcript markers.
    @discardableResult
    public func interruptAgent() -> Bool {
        guard let sessionID = currentSessionID,
              hasControlLease,
              agentStatus(for: sessionID)?.activity == .working else { return false }
        sendTerminalInput(Data([0x03]))
        return true
    }

    /// Returns a snapshot of messages that have not yet entered the Host
    /// transcript. The returned values are safe for SwiftUI list rendering;
    /// mutation must go through the methods below.
    public func agentQueuedMessages(for sessionID: String) -> [IOSAgentQueuedMessage] {
        pendingAgentMessagesBySessionID[sessionID] ?? []
    }

    @discardableResult
    public func editQueuedAgentMessage(
        sessionID: String,
        id: UUID,
        text: String
    ) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var queue = pendingAgentMessagesBySessionID[sessionID],
              let index = queue.firstIndex(where: { $0.id == id }) else { return false }
        queue[index].text = value
        setPendingAgentQueue(queue, for: sessionID)
        return true
    }

    @discardableResult
    public func deleteQueuedAgentMessage(sessionID: String, id: UUID) -> Bool {
        guard var queue = pendingAgentMessagesBySessionID[sessionID],
              let index = queue.firstIndex(where: { $0.id == id }) else { return false }
        queue.remove(at: index)
        setPendingAgentQueue(queue, for: sessionID)
        return true
    }

    @discardableResult
    public func moveQueuedAgentMessage(
        sessionID: String,
        from source: Int,
        to destination: Int
    ) -> Bool {
        guard var queue = pendingAgentMessagesBySessionID[sessionID],
              queue.indices.contains(source),
              !queue.isEmpty else { return false }
        let target = min(max(destination, 0), queue.count)
        let item = queue.remove(at: source)
        let adjustedTarget = target > source ? target - 1 : target
        queue.insert(item, at: min(max(adjustedTarget, 0), queue.count))
        setPendingAgentQueue(queue, for: sessionID)
        return true
    }

    /// Places a queued message at the front and lets the normal ready-state
    /// drain submit it. This is intentionally local until the Host accepts it.
    @discardableResult
    public func retryQueuedAgentMessage(sessionID: String, id: UUID) -> Bool {
        guard var queue = pendingAgentMessagesBySessionID[sessionID],
              let index = queue.firstIndex(where: { $0.id == id }) else { return false }
        let item = queue.remove(at: index)
        queue.insert(item, at: 0)
        setPendingAgentQueue(queue, for: sessionID)
        drainQueuedAgentMessages(for: sessionID)
        return true
    }

    private func submitAgentMessage(_ value: String, for sessionID: String) {
        guard agentMessageSubmissionsInFlight.insert(sessionID).inserted else {
            enqueueAgentMessage(value, for: sessionID)
            return
        }
        let client = client
        Task { [weak self] in
            do {
                let stillAllowed = await MainActor.run {
                    guard let self else { return false }
                    return self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                }
                guard stillAllowed else {
                    _ = await MainActor.run { self?.agentMessageSubmissionsInFlight.remove(sessionID) }
                    return
                }
                try await client.sendAgentInput(value, sessionID: sessionID)
                await MainActor.run {
                    guard let self else { return }
                    self.agentMessageSubmissionsInFlight.remove(sessionID)
                    // Usually the Host emits working immediately and the
                    // next ready event drains the remaining queue. Keep this
                    // fallback for Hosts that only publish ready boundaries.
                    if self.agentStatus(for: sessionID)?.activity == .ready {
                        self.drainQueuedAgentMessages(for: sessionID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.agentMessageSubmissionsInFlight.remove(sessionID)
                    guard self.currentSessionID == sessionID,
                          self.hasControlLease,
                          self.pendingSessionDeletion?.sessionID != sessionID else { return }
                    self.enqueueAgentMessage(value, for: sessionID, atFront: true)
                }
            }
        }
    }

    private func drainQueuedAgentMessages(for sessionID: String) {
        guard currentSessionID == sessionID,
              hasControlLease,
              let status = agentStatus(for: sessionID),
              !agentMessageSubmissionsInFlight.contains(sessionID),
              var queue = pendingAgentMessagesBySessionID[sessionID],
              !queue.isEmpty else { return }
        guard status.activity == .ready
            || (status.activity == .blocked && status.attention?.kind == .input) else { return }
        let item = queue.removeFirst()
        pendingAgentMessagesBySessionID[sessionID] = queue
        publishPendingAgentQueue(for: sessionID)
        submitAgentMessage(item.text, for: sessionID)
    }

    private func enqueueAgentMessage(
        _ value: String,
        for sessionID: String,
        atFront: Bool = false
    ) {
        let item = IOSAgentQueuedMessage(text: value)
        if atFront {
            pendingAgentMessagesBySessionID[sessionID, default: []].insert(item, at: 0)
        } else {
            pendingAgentMessagesBySessionID[sessionID, default: []].append(item)
        }
        publishPendingAgentQueue(for: sessionID)
    }

    private func setPendingAgentQueue(_ queue: [IOSAgentQueuedMessage], for sessionID: String) {
        if queue.isEmpty {
            pendingAgentMessagesBySessionID.removeValue(forKey: sessionID)
        } else {
            pendingAgentMessagesBySessionID[sessionID] = queue
        }
        publishPendingAgentQueue(for: sessionID)
    }

    private func publishPendingAgentQueue(for sessionID: String) {
        let count = pendingAgentMessagesBySessionID[sessionID]?.count ?? 0
        if count == 0 {
            agentQueuedMessageCountBySessionID.removeValue(forKey: sessionID)
            agentQueuedMessagesBySessionID.removeValue(forKey: sessionID)
        } else {
            agentQueuedMessageCountBySessionID[sessionID] = count
            agentQueuedMessagesBySessionID[sessionID] = pendingAgentMessagesBySessionID[sessionID]
        }
    }

    public var currentSession: WarrenRemoteRoster.Session? {
        guard let currentSessionID else { return nil }
        return roster?.sessions.first(where: { $0.id == currentSessionID && $0.isRunning })
    }

    private func agentStatus(for sessionID: String) -> WarrenRemoteAgentStatus? {
        agentStatusBySessionID[sessionID]
            ?? roster?.sessions.first(where: { $0.id == sessionID })?.agentStatus
    }

    /// Returns the newest model identifier reported by the Host transcript.
    /// Model names are event data (for example `openai/gpt-5`) and are never
    /// inferred from provider text or Agent timing.
    public func agentModel(for sessionID: String) -> String? {
        guard let events = agentEventsBySessionID[sessionID] else { return nil }
        let value = events
            .reversed()
            .compactMap { event in
                let value = event.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            .first
        return formatAgentModel(value)
    }

    public func sessions(inWorkspace workspaceID: String) -> [WarrenRemoteRoster.Session] {
        activeSessions.filter { $0.workspaceID == workspaceID }
    }

    public func sessions(inTerminalGroup groupID: String) -> [WarrenRemoteRoster.Session] {
        activeSessions.filter { $0.terminalGroupID == groupID }
    }

    /// Host rosters intentionally retain ended records for desktop history and
    /// delta correctness. Mobile navigation is a live-session surface, so it
    /// never exposes those records as selectable UI resources.
    public var activeSessions: [WarrenRemoteRoster.Session] {
        roster?.sessions.filter(\.isRunning) ?? []
    }

    /// Creates a Session without manufacturing a local placeholder. The Host
    /// roster remains the source of truth; once its delta arrives the new
    /// Session is selected and the normal subscribe path takes over.
    public func createSession(
        workspaceID: String? = nil,
        terminalGroupID: String? = nil,
        command: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        runtimeKind: String? = nil
    ) {
        guard !isMutating else { return }
        mutationError = nil
        isMutating = true
        let client = client
        Task { [weak self] in
            do {
                let session = try await client.createSession(
                    workspaceID: workspaceID,
                    terminalGroupID: terminalGroupID,
                    command: command,
                    kind: kind,
                    title: title,
                    runtimeKind: runtimeKind
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isMutating = false
                    // The Host's response is authoritative for the launch
                    // kind. Set the local surface before the roster delta so
                    // the new Session opens in the right native mode without
                    // recording the preference against the old Session.
                    let preferredMode: IOSSessionDisplayMode = session.isAgentBacked ? .agent : .terminal
                    self.displayModeBySessionID[session.id] = preferredMode
                    self.displayMode = preferredMode
                    self.navigation.displayMode = preferredMode
                    self.persistNavigation()
                    self.pendingSessionSelectionID = session.id
                    self.selectPendingSessionIfPresent()
                    self.restoreNavigationIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self?.isMutating = false
                    self?.mutationError = error.localizedDescription
                }
            }
        }
    }

    /// Deletes a Host-owned Session. When the visible Session is removed, the
    /// next live Session in the same scope is selected; if none remains, the
    /// route returns to that scope. Deleting another Session only updates the
    /// Host roster.
    public func deleteSession(_ sessionID: String) {
        guard !sessionID.isEmpty, !isMutating else { return }
        mutationError = nil
        isMutating = true
        let retainingRoute = currentSessionID == sessionID
        if retainingRoute {
            pendingSessionDeletion = PendingSessionDeletion(
                sessionID: sessionID,
                replacementSessionID: replacementSessionID(for: sessionID)
            )
            prepareCurrentSessionForDeletion(sessionID)
        }
        let client = client
        Task { [weak self] in
            do {
                let deleted = try await client.deleteSession(sessionID: sessionID)
                await MainActor.run {
                    guard let self else { return }
                    self.isMutating = false
                    self.pendingSessionSelectionID = nil
                    guard retainingRoute else { return }
                    guard self.currentSessionID == sessionID else {
                        self.pendingSessionDeletion = nil
                        return
                    }
                    guard deleted else {
                        self.pendingSessionDeletion = nil
                        self.restoreSessionAfterDeleteFailure(sessionID)
                        self.mutationError = "The Host did not delete this Session."
                        return
                    }
                    self.finishCurrentSessionDeletion(sessionID)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isMutating = false
                    if retainingRoute {
                        self.pendingSessionDeletion = nil
                        self.restoreSessionAfterDeleteFailure(sessionID)
                    }
                    self.mutationError = error.localizedDescription
                }
            }
        }
    }

    private func replacementSessionID(for sessionID: String) -> String? {
        guard let session = activeSessions.first(where: { $0.id == sessionID }) else { return nil }
        let candidates: [WarrenRemoteRoster.Session]
        if let workspaceID = session.workspaceID {
            candidates = sessions(inWorkspace: workspaceID)
        } else if let terminalGroupID = session.terminalGroupID {
            candidates = sessions(inTerminalGroup: terminalGroupID)
        } else {
            candidates = []
        }
        return candidates.first(where: { $0.id != sessionID })?.id
    }

    /// Invalidates pending subscription work while the Host processes the
    /// delete. The terminal snapshot stays cached so the visible screen does
    /// not flash before the replacement Session is selected.
    private func prepareCurrentSessionForDeletion(_ sessionID: String) {
        guard currentSessionID == sessionID else { return }
        sessionSelectionGeneration &+= 1
        // The target is being removed; cancel an in-flight subscribe instead
        // of waiting for a response that can no longer be useful. The
        // completion path can then issue unsubscribe immediately; the target's
        // subscribe request was already sent before the delete action.
        sessionTask?.cancel()
        sessionTask = nil
        terminalSubscriptionRequests.remove(sessionID)
        cancelTerminalResize(for: sessionID)
        terminalState.terminalSubscriptionBySessionID[sessionID] = false
        pendingTerminalFocusBySessionID.remove(sessionID)
        terminalRecoveryRequests.remove(sessionID)
        pendingAgentMessagesBySessionID.removeValue(forKey: sessionID)
        publishPendingAgentQueue(for: sessionID)
        hasControlLease = false
    }

    /// Completes the delete transition without retaining a tombstone route.
    /// Selecting a sibling keeps the existing Session route mounted; without
    /// one, clear the route immediately after the target subscription has been
    /// cancelled.
    private func finishCurrentSessionDeletion(_ sessionID: String) {
        guard currentSessionID == sessionID else { return }
        let replacementID = pendingSessionDeletion?.replacementSessionID
        pendingSessionDeletion = nil
        if let replacementID,
           activeSessions.contains(where: { $0.id == replacementID && $0.isRunning }) {
            selectSession(replacementID)
            return
        }

        sessionSelectionGeneration &+= 1
        let previousTask = sessionTask
        let client = client
        sessionTask = Task {
            await previousTask?.value
            _ = try? await client.unsubscribe(sessionID: sessionID)
        }
        sessionDeletionDestination = navigation.workspaceID.map(IOSSessionScopeDestination.workspace)
            ?? navigation.terminalGroupID.map(IOSSessionScopeDestination.terminalGroup)
        terminalSubscriptionRequests.remove(sessionID)
        cancelTerminalResize(for: sessionID)
        terminalState.terminalSubscriptionBySessionID[sessionID] = false
        pendingTerminalFocusBySessionID.remove(sessionID)
        terminalRecoveryRequests.remove(sessionID)
        hasControlLease = false
        currentSessionID = nil
        navigation.sessionID = nil
        persistNavigation()
    }

    private func restoreSessionAfterDeleteFailure(_ sessionID: String) {
        guard currentSessionID == sessionID else { return }
        guard roster?.sessions.contains(where: { $0.id == sessionID && $0.isRunning }) == true else { return }
        terminalSubscriptionRequests.insert(sessionID)
        ensureTerminalSubscription(for: sessionID)
    }

    public func renameWorkspace(_ workspaceID: String, name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty, !normalized.isEmpty, !isMutating else { return }
        mutationError = nil
        isMutating = true
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.renameWorkspace(workspaceID: workspaceID, name: normalized)
                await MainActor.run { self?.isMutating = false }
            } catch {
                await MainActor.run {
                    self?.isMutating = false
                    self?.mutationError = error.localizedDescription
                }
            }
        }
    }

    public func deleteWorkspace(
        _ workspaceID: String,
        force: Bool = false,
        removeWorktree: Bool = false
    ) {
        guard !workspaceID.isEmpty, !isMutating else { return }
        mutationError = nil
        isMutating = true
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.deleteWorkspace(
                    workspaceID: workspaceID,
                    force: force,
                    removeWorktree: removeWorktree
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isMutating = false
                    if self.navigation.workspaceID == workspaceID {
                        self.navigation.workspaceID = nil
                        self.navigation.sessionID = nil
                        self.persistNavigation()
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isMutating = false
                    self?.mutationError = error.localizedDescription
                }
            }
        }
    }

    public func createWorkspace(
        projectID: String,
        branch: String,
        name: String? = nil,
        path: String? = nil
    ) {
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty, !normalizedBranch.isEmpty, !isMutating else { return }
        mutationError = nil
        isMutating = true
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.createWorkspace(
                    projectID: projectID,
                    branch: normalizedBranch,
                    name: name,
                    path: path
                )
                await MainActor.run { self?.isMutating = false }
            } catch {
                await MainActor.run {
                    self?.isMutating = false
                    self?.mutationError = error.localizedDescription
                }
            }
        }
    }

    public var canSendAgent: Bool {
        guard hasControlLease,
              let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID) else {
            return false
        }
        switch status.activity {
        case .ready, .working: return true
        case .blocked:
            // An input attention is the one provider-neutral case where the
            // Host explicitly expects a text answer. Approval requests remain
            // terminal-only because the protocol carries no safe answer shape.
            return status.attention?.kind == .input
        case .stalled, .failed, .exited, .unknown: return false
        }
    }

    public var agentDisabledReason: String? {
        guard hasControlLease else { return "Terminal control is held by another client." }
        guard let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID) else {
            return "Agent status is not ready yet."
        }
        switch status.activity {
        case .ready: return nil
        case .working:
            return "Agent is working. New messages will be queued."
        case .blocked:
            if status.attention?.kind == .approval {
                return "Approval is required in Terminal."
            }
            if status.attention?.kind == .input {
                return nil
            }
            return "Agent is waiting for input."
        case .stalled: return "Agent is stalled."
        case .failed: return "Agent failed."
        case .exited: return "Agent has exited."
        case .unknown: return "Agent status is unavailable."
        }
    }

    /// Returns the complete provider-neutral attention projection for a
    /// Session. Views use this to render an affordance without reaching into
    /// the transport actor or inferring state from transcript text.
    public func agentAttention(for sessionID: String) -> WarrenRemoteAgentAttention? {
        guard let status = agentStatus(for: sessionID), status.activity != .failed else { return nil }
        return status.attention
    }

    /// Loads one older page. The Host owns pagination cursors; this method
    /// only merges sequence-unique events into the local transcript.
    public func loadOlderAgentHistory() {
        guard let sessionID = currentSessionID,
              roster?.sessions.first(where: { $0.id == sessionID })?.isAgentBacked == true,
              historyLoadingBySessionID.insert(sessionID).inserted else { return }
        let before = historyCursorBySessionID[sessionID]
        let client = client
        Task { [weak self] in
            defer {
                Task { @MainActor in self?.historyLoadingBySessionID.remove(sessionID) }
            }
            // Mobile history is a conversation surface. Tool and reasoning
            // events remain available in the live tail, but must not consume
            // the entire page before older user/assistant messages arrive.
            guard let page = try? await client.agentHistory(
                sessionID: sessionID,
                before: before,
                conversationOnly: true
            ) else { return }
            await MainActor.run {
                guard let self else { return }
                self.mergeAgentEvents(page.events, sessionID: sessionID, epoch: page.epoch ?? 0, prepend: true)
                self.historyLoadedBySessionID.insert(sessionID)
                if let cursor = page.cursor {
                    self.historyCursorBySessionID[sessionID] = cursor
                }
                self.historyHasMoreBySessionID[sessionID] = page.hasMore
            }
        }
    }

    public func agentHistoryHasMore(for sessionID: String) -> Bool {
        historyHasMoreBySessionID[sessionID] ?? true
    }

    /// The Host attach includes a bounded tail that may contain only tool
    /// activity. Keep the initial history request independent from whether
    /// that tail made the local event array non-empty.
    public func agentHistoryLoaded(for sessionID: String) -> Bool {
        historyLoadedBySessionID.contains(sessionID)
    }

    private func consume(_ event: WarrenRemoteEvent) {
        switch event {
        case .connection(let state):
            // `stop()` publishes `.stopped` on the same long-lived event
            // stream.  If a foreground start has already requested a new
            // connection, that buffered lifecycle marker belongs to the
            // previous scene transition and must not overwrite a healthy
            // connection (or flash Offline while reconnecting).
            if state == .stopped, connectionRequested {
                if connectionState != .connected {
                    connectionState = .reconnecting
                }
                return
            }
            connectionState = state
            if state == .connected { connectionError = nil }
            if state != .connected {
                hasControlLease = false
                // Keep the last rendered checkpoint visible while offline,
                // but force the next control request to wait for the new
                // output registration after reconnect.
                if let currentSessionID {
                    terminalState.terminalSubscriptionBySessionID[currentSessionID] = false
                    terminalSubscriptionRequests.insert(currentSessionID)
                    terminalRecoveryRequests.remove(currentSessionID)
                }
            }
        case .welcome:
            break
        case .roster(let next):
            guard shouldApplyRoster(next) else { return }
            applyRoster(next)
        case .rosterDelta(let delta):
            guard let current = roster, let next = current.applying(delta) else { return }
            applyRoster(next)
        case .output(let frame):
            appendTerminalOutput(frame)
        case .atomicState(let state):
            terminalState.terminalSnapshotBySessionID[state.sessionID] = state.payload
            // The checkpoint is installed by the renderer itself. Keep live
            // output separate so the renderer never feeds the opaque replay
            // twice when the first post-checkpoint frame arrives.
            terminalState.terminalOutputBySessionID[state.sessionID] = Data()
            terminalState.terminalOutputRevisionBySessionID[state.sessionID, default: 0] &+= 1
            terminalEpochBySessionID[state.sessionID] = state.epoch
            terminalNextSequenceBySessionID[state.sessionID] = state.sequence
            pendingTerminalRecoveryBySessionID[state.sessionID] = WarrenRemoteRecoveryAnchor(
                epoch: state.epoch,
                sequence: state.sequence
            )
            terminalState.terminalReadyBySessionID[state.sessionID] = false
        case .anchor(let anchor):
            if anchor.reanchor {
                terminalState.terminalSubscriptionBySessionID[anchor.sessionID] = true
                terminalSubscriptionRequests.remove(anchor.sessionID)
                pendingTerminalRecoveryBySessionID.removeValue(forKey: anchor.sessionID)
                terminalState.terminalReadyBySessionID[anchor.sessionID] = false
                terminalEpochBySessionID[anchor.sessionID] = anchor.epoch
                terminalNextSequenceBySessionID[anchor.sessionID] = anchor.sequence
                drainPendingTerminalFocus(for: anchor.sessionID)
            }
            if anchor.synced,
               pendingTerminalRecoveryBySessionID[anchor.sessionID]
                   == WarrenRemoteRecoveryAnchor(epoch: anchor.epoch, sequence: anchor.sequence) {
                pendingTerminalRecoveryBySessionID.removeValue(forKey: anchor.sessionID)
                terminalState.terminalReadyBySessionID[anchor.sessionID] = true
            }
            if anchor.synced {
                // A recovery request stays coalesced until the Host has
                // crossed the atomic presentation boundary. Clearing it at
                // the subscribe response races the queued atomic/synced
                // frames and can produce an endless stream of anchor-less
                // re-subscriptions under active terminal output.
                terminalRecoveryRequests.remove(anchor.sessionID)
                // A synced marker is also a definitive output-registration
                // boundary for Hosts that omit a separate attached marker.
                terminalState.terminalSubscriptionBySessionID[anchor.sessionID] = true
                terminalSubscriptionRequests.remove(anchor.sessionID)
                drainPendingTerminalFocus(for: anchor.sessionID)
            }
        case .agent(let sessionID, let epoch, let events):
            mergeAgentEvents(events, sessionID: sessionID, epoch: epoch, prepend: false)
        case .agentStatus(let sessionID, let epoch, let status):
            if let previous = agentEpochBySessionID[sessionID], previous != epoch {
                agentState.agentEventsBySessionID[sessionID] = []
                agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
                agentEventKeysBySessionID[sessionID] = []
                historyCursorBySessionID.removeValue(forKey: sessionID)
                historyHasMoreBySessionID.removeValue(forKey: sessionID)
                historyLoadedBySessionID.remove(sessionID)
            }
            agentEpochBySessionID[sessionID] = epoch
            agentStatusBySessionID[sessionID] = status
            if status.activity == .ready {
                drainQueuedAgentMessages(for: sessionID)
            }
        case .agentTurn:
            break
        case .maintenance(let message):
            maintenanceMessage = message ?? "Host is updating."
            connectionState = .reconnecting
        case .disconnected(let reason):
            connectionError = reason
            hasControlLease = false
            if connectionState != .stopped { connectionState = .reconnecting }
        }
    }

    private func appendTerminalOutput(_ frame: WarrenRemoteOutputFrame) {
        guard !frame.payload.isEmpty else { return }
        if let currentEpoch = terminalEpochBySessionID[frame.sessionID], frame.epoch < currentEpoch {
            return
        }
        if terminalEpochBySessionID[frame.sessionID] != frame.epoch {
            terminalEpochBySessionID[frame.sessionID] = frame.epoch
            terminalNextSequenceBySessionID[frame.sessionID] = frame.sequence
            terminalState.terminalOutputBySessionID[frame.sessionID] = Data()
            terminalState.terminalReadyBySessionID[frame.sessionID] = false
        }
        let nextSequence = terminalNextSequenceBySessionID[frame.sessionID] ?? frame.sequence
        let sequenceResult = frame.sequence.addingReportingOverflow(UInt64(frame.payload.count))
        guard !sequenceResult.overflow else {
            terminalState.terminalReadyBySessionID[frame.sessionID] = false
            requestTerminalRecovery(for: frame.sessionID)
            return
        }
        let endSequence = sequenceResult.partialValue
        guard endSequence > nextSequence else { return }
        guard frame.sequence <= nextSequence else {
            // A sequence gap cannot be rendered safely. Keep the last screen
            // and wait for the next atomic subscription recovery.
            terminalState.terminalReadyBySessionID[frame.sessionID] = false
            requestTerminalRecovery(for: frame.sessionID)
            return
        }
        let offset = frame.sequence < nextSequence
            ? Int(nextSequence - frame.sequence)
            : 0
        guard offset < frame.payload.count else { return }
        // Remove the previous value before appending. Reading through the
        // dictionary subscript leaves the old Data buffer shared with the
        // dictionary, which makes every live frame copy the whole scrollback
        // before putting it back. Taking ownership keeps appends amortized
        // linear while the published value remains unchanged for SwiftUI.
        var data = terminalState.terminalOutputBySessionID.removeValue(forKey: frame.sessionID) ?? Data()
        data.append(frame.payload.dropFirst(offset))
        // Keep the visible model bounded; SwiftTerm owns its own scrollback
        // and receives the full atomic checkpoint when it is recreated.
        let maxBytes = 8 * 1024 * 1024
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes))
        }
        terminalState.terminalOutputBySessionID[frame.sessionID] = data
        terminalNextSequenceBySessionID[frame.sessionID] = endSequence
    }

    private func mergeAgentEvents(
        _ incoming: [WarrenRemoteAgentEvent],
        sessionID: String,
        epoch: UInt64,
        prepend: Bool
    ) {
        if let previous = agentEpochBySessionID[sessionID], previous != epoch {
            agentState.agentEventsBySessionID[sessionID] = []
            agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
            agentEventKeysBySessionID[sessionID] = []
            historyCursorBySessionID.removeValue(forKey: sessionID)
            historyHasMoreBySessionID.removeValue(forKey: sessionID)
            historyLoadedBySessionID.remove(sessionID)
        }
        agentEpochBySessionID[sessionID] = epoch
        // Take ownership of the buffers while merging. Agent deltas can be
        // frequent; mutating a value left in the dictionary would trigger a
        // full copy of the transcript for each delta.
        var events = agentState.agentEventsBySessionID.removeValue(forKey: sessionID) ?? []
        var keys = agentEventKeysBySessionID.removeValue(forKey: sessionID) ?? []
        var didChange = false
        for event in incoming {
            let key = "\(epoch):\(event.sequence)"
            let normalizedType = event.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedProvider = event.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isOpenCodeContentEvent = normalizedProvider == "opencode"
                && !event.id.isEmpty
                && (normalizedType == "user"
                    || normalizedType == "assistant"
                    || normalizedType == "reasoning"
                    || normalizedType.contains("thinking")
                    || normalizedType.contains("reason"))
            if isOpenCodeContentEvent,
               let index = events.lastIndex(where: {
                   $0.id == event.id && $0.type == event.type && $0.provider == event.provider
               }) {
                // A paged Host history response contains one complete,
                // non-delta value at the part's first sequence. That sequence
                // may already be in the live tail's deduplication set even
                // when the tail only had an earlier partial value; let the
                // complete replay replace it. Exact live replays remain
                // sequence-deduplicated before they can be appended twice.
                if keys.contains(key), event.contentDelta {
                    continue
                }
                let existing = events[index]
                let merged = WarrenRemoteAgentEvent(
                    // Keep the first sequence as the stable position of a
                    // mutable OpenCode part. The Host's conversation history
                    // projection uses the same rule, so live deltas and a
                    // later paged replay have identical ordering.
                    sequence: existing.sequence,
                    turn: event.turn ?? existing.turn,
                    id: event.id,
                    provider: event.provider.isEmpty ? existing.provider : event.provider,
                    type: event.type,
                    role: event.role ?? existing.role,
                    content: event.contentDelta
                        ? (existing.content ?? "") + (event.content ?? "")
                        : (event.content?.isEmpty == false ? event.content : existing.content),
                    contentDelta: false,
                    model: event.model ?? existing.model,
                    stopReason: event.stopReason ?? existing.stopReason,
                    toolName: event.toolName ?? existing.toolName,
                    toolInput: event.toolInput ?? existing.toolInput,
                    toolStatus: event.toolStatus ?? existing.toolStatus,
                    callID: event.callID ?? existing.callID,
                    output: (existing.output ?? "") + (event.output ?? ""),
                    files: event.files ?? existing.files,
                    error: event.error ?? existing.error,
                    usage: event.usage ?? existing.usage,
                    durationMs: event.durationMs ?? existing.durationMs,
                    sidechain: event.sidechain || existing.sidechain,
                    timestamp: event.timestamp ?? existing.timestamp
                )
                events[index] = merged
                keys.insert(key)
                didChange = true
                continue
            }
            if keys.contains(key) { continue }
            if isOpenCodeContentEvent {
                // The first observed delta can arrive before its non-delta
                // seed when attaching to a busy OpenCode session. Retain it
                // as a normal event; a later history page will fill in the
                // complete part through the replacement path above.
                events.append(event)
            } else if prepend {
                events.insert(event, at: 0)
            } else {
                events.append(event)
            }
            keys.insert(key)
            didChange = true
        }
        events.sort { $0.sequence < $1.sequence }
        agentState.agentEventsBySessionID[sessionID] = events
        agentEventKeysBySessionID[sessionID] = keys
        if didChange {
            agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
        }
    }

    private func shouldApplyRoster(_ next: WarrenRemoteRoster) -> Bool {
        guard let currentRevision = roster?.revision,
              let nextRevision = next.revision else { return true }
        return nextRevision >= currentRevision
    }

    private func applyRoster(_ next: WarrenRemoteRoster) {
        roster = next
        maintenanceMessage = nil
        agentStatusBySessionID = [:]
        for session in next.sessions {
            if let status = session.agentStatus { agentStatusBySessionID[session.id] = status }
        }
        selectPendingSessionIfPresent()
        restoreNavigationIfNeeded()
    }

    private func selectPendingSessionIfPresent() {
        guard let pendingID = pendingSessionSelectionID,
              roster?.sessions.contains(where: { $0.id == pendingID && $0.isRunning }) == true else { return }
        pendingSessionSelectionID = nil
        selectSession(pendingID)
    }

    private func requestTerminalRecovery(for sessionID: String) {
        guard terminalRecoveryRequests.insert(sessionID).inserted else { return }
            terminalState.terminalSubscriptionBySessionID[sessionID] = false
        terminalSubscriptionRequests.insert(sessionID)
        let client = client
        Task { [weak self] in
            do {
                let result = try await client.subscribe(sessionID: sessionID, anchor: nil, claimControl: false)
                guard result.subscribed else {
                    throw WarrenRemoteClientError.requestFailed("session subscription was not accepted")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.terminalRecoveryRequests.remove(sessionID)
                    guard self.currentSessionID == sessionID else { return }
                    if !Self.shouldRetainSubscriptionIntent(after: error) {
                        self.terminalSubscriptionRequests.remove(sessionID)
                    }
                }
            }
        }
    }

    private func restoreNavigationIfNeeded() {
        guard let roster else { return }
        // A delete request may remove the target from the roster before the
        // response arrives. Keep the current route stable until the mutation
        // decides whether to select a sibling or return to its scope.
        if let pendingSessionDeletion,
           currentSessionID == pendingSessionDeletion.sessionID {
            return
        }
        if let requested = navigation.sessionID,
           roster.sessions.contains(where: { $0.id == requested && $0.isRunning }) {
            if currentSessionID != requested { selectSession(requested) }
            return
        }
        // Do not manufacture a shell. A stale local selection simply leaves
        // the Host's empty-session state visible until the user picks one.
        if let currentSessionID,
           !roster.sessions.contains(where: { $0.id == currentSessionID && $0.isRunning }) {
            let client = client
            Task { _ = try? await client.unsubscribe(sessionID: currentSessionID) }
            terminalSubscriptionRequests.remove(currentSessionID)
            terminalState.terminalSubscriptionBySessionID[currentSessionID] = false
            pendingTerminalFocusBySessionID.remove(currentSessionID)
            hasControlLease = false
            self.currentSessionID = nil
        }
        if let requested = navigation.sessionID,
           !roster.sessions.contains(where: { $0.id == requested && $0.isRunning }) {
            navigation.sessionID = nil
            persistNavigation()
        }
    }

    private func persistNavigation() {
        localStore.navigation = navigation
    }
}
