import Combine
import Foundation
import WarrenDomain
import WarrenTransport

#if canImport(CryptoKit)
import CryptoKit
#endif

private func agentSHA256(_ data: Data) -> String {
#if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
    // CryptoKit is present on all supported iOS/macOS targets. Keep a safe
    // empty digest fallback for non-Apple test toolchains; the Host still
    // validates length and its own checksum policy.
    return ""
#endif
}

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
    @Published public private(set) var agentTurnBySessionID: [String: WarrenRemoteAgentTurn] = [:]
    @Published public private(set) var agentQueuedMessageCountBySessionID: [String: Int] = [:]
    @Published public private(set) var agentQueueBySessionID: [String: IOSAgentMessageQueue] = [:]
    @Published public private(set) var agentCapabilities: Set<String> = []
    @Published public private(set) var agentActionError: String?
    @Published public private(set) var historyLoadingBySessionID: Set<String> = []
    @Published public private(set) var historyErrorBySessionID: [String: String] = [:]
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
    private var mutationGeneration: UInt64 = 0
    private var clientGeneration: UInt64 = 0
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
    private var historyRequestTokenBySessionID: [String: UInt64] = [:]
    private var historyRequestSequence: UInt64 = 0
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
    private var terminalFocusGeneration: UInt64 = 0
    private var terminalFocusRequestsBySessionID: [String: UInt64] = [:]
    private var pendingSessionSelectionID: String?
    private var pendingSessionDeletion: PendingSessionDeletion?
    // Pending entries contain stable local queue IDs rather than text copies.
    // Editing or reordering therefore updates the exact item that will be
    // submitted, even when two queued messages have identical text.
    private var pendingAgentMessagesBySessionID: [String: [String]] = [:]
    private var agentMessageSubmissionsInFlight: Set<String> = []
    private var agentMessageSubmissionTokenBySessionID: [String: UInt64] = [:]
    private var agentMessageSubmissionSequence: UInt64 = 0
    /// Cancel and Send now share one per-Session gate. The token prevents a
    /// late response from an older request from clearing a newer request's
    /// in-flight marker after a retry.
    private var agentInterruptInFlightBySessionID: [String: String] = [:]
    private var draftSaveTasksBySessionID: [String: Task<Void, Never>] = [:]
    /// A deleted Session's chat view can disappear one frame after the model
    /// clears its draft. Keep a scoped tombstone so that its `onDisappear`
    /// flush cannot write the deleted text back to UserDefaults. The endpoint
    /// is part of the key so a late response from an old Host cannot suppress
    /// a draft on a newly selected Host with the same Session ID.
    private var invalidatedAgentDraftKeys: Set<String> = []

    private struct PendingSessionDeletion {
        let sessionID: String
        let replacementSessionID: String?
        let endpointIdentity: String
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
        draftSaveTasksBySessionID.values.forEach { $0.cancel() }
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
        sessionSelectionGeneration &+= 1
        mutationGeneration &+= 1
        clientGeneration &+= 1
        isMutating = false
        terminalResizeTasksBySessionID.values.forEach { $0.cancel() }
        terminalResizeTasksBySessionID.removeAll()
        pendingTerminalResizeBySessionID.removeAll()
        historyRequestTokenBySessionID.removeAll()
        historyLoadingBySessionID.removeAll()
        historyErrorBySessionID.removeAll()
        terminalFocusGeneration &+= 1
        terminalFocusRequestsBySessionID.removeAll()
        let client = client
        let previousLifecycle = clientLifecycleTask
        clientLifecycleTask = Task {
            await previousLifecycle?.value
            await client.stop()
        }
        hasControlLease = false
        if let currentSessionID {
            invalidateAgentMessageSubmission(for: currentSessionID)
        }
        agentInterruptInFlightBySessionID.removeAll()
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
        sessionSelectionGeneration &+= 1
        mutationGeneration &+= 1
        clientGeneration &+= 1
        isMutating = false
        terminalResizeTasksBySessionID.values.forEach { $0.cancel() }
        terminalResizeTasksBySessionID.removeAll()
        pendingTerminalResizeBySessionID.removeAll()
        historyRequestTokenBySessionID.removeAll()
        historyLoadingBySessionID.removeAll()
        historyErrorBySessionID.removeAll()
        terminalFocusGeneration &+= 1
        terminalFocusRequestsBySessionID.removeAll()
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
        agentTurnBySessionID = [:]
        agentCapabilities = []
        agentActionError = nil
        displayModeBySessionID = [:]
        agentQueuedMessageCountBySessionID = [:]
        agentQueueBySessionID = [:]
        pendingAgentMessagesBySessionID = [:]
        agentMessageSubmissionsInFlight = []
        agentMessageSubmissionTokenBySessionID = [:]
        agentInterruptInFlightBySessionID = [:]
        invalidatedAgentDraftKeys = []
        agentEpochBySessionID = [:]
        agentEventKeysBySessionID = [:]
        historyCursorBySessionID = [:]
        historyHasMoreBySessionID = [:]
        draftSaveTasksBySessionID.values.forEach { $0.cancel() }
        draftSaveTasksBySessionID = [:]
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
        // First, try to resign the terminal's text view
        if let window = UIApplication.shared.windows.first {
            for subview in window.subviews where subview.isKind(of: UIView.classForCoder()) {
                subview.resignFirstResponder()
            }
        }
        
        // Then try the standard approach
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        
        // Finally, try to find and resign any UITextView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.findAndResignTextView()
        }
        #endif
    }
    
    #if canImport(UIKit)
    private func findAndResignTextView() {
        guard let window = UIApplication.shared.windows.first else { return }
        self.resignFromView(window)
    }
    
    private func resignFromView(_ view: UIView) {
        if view.isKind(of: UITextView.classForCoder()), let textView = view as? UITextView {
            textView.resignFirstResponder()
        }
        for subview in view.subviews {
            resignFromView(subview)
        }
    }
    #endif

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
        let previousSession = oldSessionID.flatMap { id in
            roster?.sessions.first(where: { $0.id == id && $0.isRunning })
        }
        invalidateAgentHistoryRequest(for: sessionID)
        if let oldSessionID {
            invalidateAgentHistoryRequest(for: oldSessionID)
        }
        invalidateAgentMessageSubmission(for: sessionID)
        if let oldSessionID {
            invalidateAgentMessageSubmission(for: oldSessionID)
        }
        agentInterruptInFlightBySessionID.removeAll()
        terminalFocusGeneration &+= 1
        terminalFocusRequestsBySessionID.removeAll()
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
                    let retainIntent = Self.shouldRetainSubscriptionIntent(after: error)
                    self.terminalState.terminalSubscriptionBySessionID[sessionID] = false
                    self.terminalSubscriptionRequests.remove(sessionID)
                    self.pendingTerminalFocusBySessionID.remove(sessionID)
                    self.hasControlLease = false
                    if let previousSession {
                        // A rejected handoff must not leave navigation pointing
                        // at a Session that is no longer subscribed. Restore the
                        // previous scope immediately; its subscription intent
                        // is retained for reconnect or retried while connected.
                        self.currentSessionID = previousSession.id
                        self.navigation.sessionID = previousSession.id
                        self.navigation.workspaceID = previousSession.workspaceID
                        self.navigation.terminalGroupID = previousSession.terminalGroupID
                        self.applyPreferredDisplayMode(for: previousSession)
                        self.terminalState.terminalReadyBySessionID[previousSession.id] = false
                        self.terminalState.terminalSubscriptionBySessionID[previousSession.id] = false
                        self.terminalSubscriptionRequests.insert(previousSession.id)
                        if retainIntent {
                            self.connectionState = .reconnecting
                        } else {
                            self.ensureTerminalSubscription(for: previousSession.id)
                        }
                    } else {
                        self.currentSessionID = nil
                        self.navigation.sessionID = nil
                        if retainIntent { self.connectionState = .reconnecting }
                    }
                    self.persistNavigation()
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
        invalidateAgentHistoryRequest(for: oldSessionID)
        invalidateAgentMessageSubmission(for: oldSessionID)
        agentInterruptInFlightBySessionID.removeValue(forKey: oldSessionID)
        terminalFocusGeneration &+= 1
        terminalFocusRequestsBySessionID.removeAll()
        let client = client
        sessionTask = Task { [weak self] in
            await previousTask?.value
            _ = try? await client.unsubscribe(sessionID: oldSessionID)
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
        guard terminalFocusRequestsBySessionID[sessionID] == nil else { return }
        pendingTerminalFocusBySessionID.remove(sessionID)
        terminalFocusGeneration &+= 1
        let generation = terminalFocusGeneration
        terminalFocusRequestsBySessionID[sessionID] = generation
        let client = client
        Task { [weak self] in
            do {
                let result = try await client.focus(sessionID: sessionID, focused: true, size: size)
                await MainActor.run {
                    guard let self,
                          self.currentSessionID == sessionID,
                          self.terminalFocusRequestsBySessionID[sessionID] == generation else { return }
                    self.terminalFocusRequestsBySessionID.removeValue(forKey: sessionID)
                    self.hasControlLease = result.focused
                    if result.focused {
                        self.drainQueuedAgentMessages(for: sessionID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.currentSessionID == sessionID,
                          self.terminalFocusRequestsBySessionID[sessionID] == generation else { return }
                    self.terminalFocusRequestsBySessionID.removeValue(forKey: sessionID)
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
        terminalFocusGeneration &+= 1
        let focusGeneration = terminalFocusGeneration
        terminalFocusRequestsBySessionID.removeValue(forKey: sessionID)
        hasControlLease = false
        let client = client
        Task { [weak self] in
            _ = try? await client.focus(sessionID: sessionID, focused: false)
            await MainActor.run {
                guard let self,
                      self.currentSessionID == sessionID,
                      self.terminalFocusGeneration == focusGeneration else { return }
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
        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
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
                    guard self.sessionSelectionGeneration == selectionGeneration,
                          self.clientGeneration == currentClientGeneration,
                          self.currentSessionID == sessionID else { return }
                    guard self.pendingTerminalResizeBySessionID[sessionID] == size else { return }
                    self.lastSentTerminalSizeBySessionID[sessionID] = size
                    self.pendingTerminalResizeBySessionID.removeValue(forKey: sessionID)
                    self.terminalResizeTasksBySessionID.removeValue(forKey: sessionID)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.sessionSelectionGeneration == selectionGeneration,
                          self.clientGeneration == currentClientGeneration,
                          self.currentSessionID == sessionID else { return }
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

    @discardableResult
    public func sendAgentMessage(_ text: String, attachments: [WarrenRemoteAgentAttachmentRef] = []) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !attachments.isEmpty),
              hasControlLease,
              let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID) else { return false }

        switch status.activity {
        case .ready:
            enqueueAgentMessage(value, for: sessionID, attachments: attachments)
            drainQueuedAgentMessages(for: sessionID)
            return true
        case .working:
            enqueueAgentMessage(value, for: sessionID, attachments: attachments)
            return true
        case .blocked:
            guard status.attention?.kind == .input else { return false }
            enqueueAgentMessage(value, for: sessionID, attachments: attachments, atFront: true)
            submitBlockedAgentMessage(for: sessionID)
            return true
        case .stalled, .failed, .exited, .unknown:
            return false
        }
    }

    public func supportsAgentCapability(_ capability: String) -> Bool {
        agentCapabilities.contains(capability)
    }

    @discardableResult
    public func editQueuedAgentMessage(
        sessionID: String,
        itemID: String,
        text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = []
    ) -> Bool {
        guard var queue = agentQueueBySessionID[sessionID],
              let previous = queue.items.first(where: { $0.id == itemID }),
              queue.edit(id: itemID, text: text, attachments: attachments) else { return false }
        agentQueueBySessionID[sessionID] = queue
        // Editing a failed item makes it retryable. Reinsert its stable ID in
        // the pending FIFO so a ready Agent does not leave the edited item
        // stranded in the local queue.
        if previous.status == .failed,
           !pendingAgentMessagesBySessionID[sessionID, default: []].contains(itemID) {
            pendingAgentMessagesBySessionID[sessionID, default: []].insert(itemID, at: 0)
        }
        updateAgentQueuedMessageCount(for: sessionID)
        drainQueuedAgentMessages(for: sessionID)
        return true
    }

    @discardableResult
    public func deleteQueuedAgentMessage(sessionID: String, itemID: String) -> Bool {
        guard var queue = agentQueueBySessionID[sessionID], queue.remove(id: itemID) else { return false }
        agentQueueBySessionID[sessionID] = queue
        pendingAgentMessagesBySessionID[sessionID]?.removeAll { $0 == itemID }
        updateAgentQueuedMessageCount(for: sessionID)
        return true
    }

    @discardableResult
    public func moveQueuedAgentMessageToFront(sessionID: String, itemID: String) -> Bool {
        guard var queue = agentQueueBySessionID[sessionID], queue.moveToFront(id: itemID) else { return false }
        agentQueueBySessionID[sessionID] = queue
        reorderPendingIDs(for: sessionID, accordingTo: queue)
        drainQueuedAgentMessages(for: sessionID)
        return true
    }

    @discardableResult
    public func reorderQueuedAgentMessage(sessionID: String, itemID: String, beforeID: String?) -> Bool {
        guard var queue = agentQueueBySessionID[sessionID], queue.move(id: itemID, beforeID: beforeID) else { return false }
        agentQueueBySessionID[sessionID] = queue
        reorderPendingIDs(for: sessionID, accordingTo: queue)
        drainQueuedAgentMessages(for: sessionID)
        return true
    }

    @discardableResult
    public func retryQueuedAgentMessage(sessionID: String, itemID: String) -> Bool {
        guard var queue = agentQueueBySessionID[sessionID], queue.retry(id: itemID) else { return false }
        agentQueueBySessionID[sessionID] = queue
        if !pendingAgentMessagesBySessionID[sessionID, default: []].contains(itemID) {
            pendingAgentMessagesBySessionID[sessionID, default: []].insert(itemID, at: 0)
            updateAgentQueuedMessageCount(for: sessionID)
            drainQueuedAgentMessages(for: sessionID)
        }
        return true
    }

    /// Returns the draft for the active endpoint and Session. The endpoint
    /// identity is metadata only (name + URL); credentials never enter the
    /// UserDefaults key.
    public func agentDraft(for sessionID: String) -> String {
        localStore.agentDraft(
            sessionID: sessionID,
            endpointIdentity: "\(endpointMetadata.name)|\(endpointMetadata.url)"
        ) ?? ""
    }

    /// Debounced draft persistence. Oversized text remains usable in the live
    /// editor but is deliberately not written to local storage.
    public func updateAgentDraft(_ text: String, for sessionID: String) {
        draftSaveTasksBySessionID[sessionID]?.cancel()
        if text.utf8.count > IOSLocalStore.agentDraftMaximumBytes {
            agentActionError = "Draft is too large to save locally."
            return
        }
        let endpointIdentity = "\(endpointMetadata.name)|\(endpointMetadata.url)"
        let store = localStore
        draftSaveTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            _ = store.saveAgentDraft(text, sessionID: sessionID, endpointIdentity: endpointIdentity)
            await MainActor.run {
                guard let self else { return }
                if self.draftSaveTasksBySessionID[sessionID] != nil {
                    self.draftSaveTasksBySessionID.removeValue(forKey: sessionID)
                }
            }
        }
    }

    public func flushAgentDraft(_ text: String, for sessionID: String) {
        draftSaveTasksBySessionID[sessionID]?.cancel()
        draftSaveTasksBySessionID.removeValue(forKey: sessionID)
        let endpointIdentity = "\(endpointMetadata.name)|\(endpointMetadata.url)"
        if invalidatedAgentDraftKeys.remove(agentDraftStateKey(endpointIdentity: endpointIdentity, sessionID: sessionID)) != nil {
            return
        }
        guard text.utf8.count <= IOSLocalStore.agentDraftMaximumBytes else { return }
        _ = localStore.saveAgentDraft(text, sessionID: sessionID, endpointIdentity: endpointIdentity)
    }

    public func clearAgentDraft(for sessionID: String) {
        draftSaveTasksBySessionID[sessionID]?.cancel()
        draftSaveTasksBySessionID.removeValue(forKey: sessionID)
        let endpointIdentity = "\(endpointMetadata.name)|\(endpointMetadata.url)"
        localStore.removeAgentDraft(sessionID: sessionID, endpointIdentity: endpointIdentity)
    }

    public var canInterruptAgentTurn: Bool {
        guard supportsAgentCapability(WarrenRemoteAgentCapability.interrupt),
              let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID),
              status.activity == .working else { return false }
        let turn = agentTurnBySessionID[sessionID]?.id
            ?? agentEventsBySessionID[sessionID]?.last?.turn
            ?? 0
        return turn > 0
    }

    private func beginAgentInterrupt(for sessionID: String) -> String? {
        guard agentInterruptInFlightBySessionID[sessionID] == nil else { return nil }
        let token = UUID().uuidString.lowercased()
        agentInterruptInFlightBySessionID[sessionID] = token
        return token
    }

    private func finishAgentInterrupt(for sessionID: String, token: String) {
        guard agentInterruptInFlightBySessionID[sessionID] == token else { return }
        agentInterruptInFlightBySessionID.removeValue(forKey: sessionID)
    }

    private func invalidateAgentMessageSubmission(for sessionID: String) {
        agentMessageSubmissionsInFlight.remove(sessionID)
        agentMessageSubmissionTokenBySessionID.removeValue(forKey: sessionID)
        guard var queue = agentQueueBySessionID[sessionID] else { return }
        var requeued = false
        for item in queue.items where item.status == .sending {
            if queue.markQueued(id: item.id) {
                requeued = true
                if !pendingAgentMessagesBySessionID[sessionID, default: []].contains(item.id) {
                    pendingAgentMessagesBySessionID[sessionID, default: []].insert(item.id, at: 0)
                }
            }
        }
        if requeued {
            agentQueueBySessionID[sessionID] = queue
            updateAgentQueuedMessageCount(for: sessionID)
        }
    }

    private func requeueAgentMessage(_ item: IOSAgentQueueItem, for sessionID: String) {
        guard pendingSessionDeletion?.sessionID != sessionID else { return }
        var queue = agentQueueBySessionID[sessionID] ?? IOSAgentMessageQueue()
        if let existing = queue.items.first(where: { $0.id == item.id }) {
            switch existing.status {
            case .sending:
                _ = queue.markQueued(id: item.id)
            case .failed:
                _ = queue.retry(id: item.id)
            case .queued:
                break
            }
        } else {
            // The captured item is usually still marked `.sending`. If the
            // user removed it after a session switch, re-adding that captured
            // value must not resurrect a permanent spinner.
            _ = queue.enqueue(IOSAgentQueueItem(
                id: item.id,
                text: item.text,
                attachments: item.attachments,
                createdAt: item.createdAt,
                status: .queued
            ))
        }
        if !pendingAgentMessagesBySessionID[sessionID, default: []].contains(item.id) {
            pendingAgentMessagesBySessionID[sessionID, default: []].insert(item.id, at: 0)
        }
        agentQueueBySessionID[sessionID] = queue
        updateAgentQueuedMessageCount(for: sessionID)
    }

    @discardableResult
    public func cancelAgentTurn() -> Bool {
        guard supportsAgentCapability(WarrenRemoteAgentCapability.interrupt),
              let sessionID = currentSessionID,
              let status = agentStatus(for: sessionID), status.activity == .working else { return false }
        let turn = agentTurnBySessionID[sessionID]?.id
            ?? agentEventsBySessionID[sessionID]?.last?.turn
            ?? 0
        guard turn > 0, let token = beginAgentInterrupt(for: sessionID) else { return false }
        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
        let client = client
        agentActionError = nil
        Task { [weak self] in
            do {
                _ = try await client.interruptAgentTurn(
                    WarrenRemoteAgentTurnInterruptRequest(session: sessionID, turn: turn, reason: "cancel")
                )
                await MainActor.run {
                    guard let self,
                          self.agentInterruptInFlightBySessionID[sessionID] == token else { return }
                    self.finishAgentInterrupt(for: sessionID, token: token)
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.agentInterruptInFlightBySessionID[sessionID] == token else { return }
                    let isCurrent = self.currentSessionID == sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                    self.finishAgentInterrupt(for: sessionID, token: token)
                    if isCurrent {
                        self.agentActionError = error.localizedDescription
                    }
                }
            }
        }
        return true
    }

    /// Queues a stable replacement item before issuing the atomic interrupt.
    /// The item is removed only after the Host acknowledges the replacement;
    /// request failures keep it locally retryable instead of losing text.
    @discardableResult
    public func sendAgentMessageNow(_ text: String, attachments: [WarrenRemoteAgentAttachmentRef] = []) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !attachments.isEmpty),
              supportsAgentCapability(WarrenRemoteAgentCapability.interrupt),
              let sessionID = currentSessionID,
              hasControlLease,
              let status = agentStatus(for: sessionID), status.activity == .working,
              let turn = agentTurnBySessionID[sessionID]?.id ?? agentEventsBySessionID[sessionID]?.last?.turn,
              turn > 0,
              !agentMessageSubmissionsInFlight.contains(sessionID),
              let interruptToken = beginAgentInterrupt(for: sessionID) else { return false }
        guard attachments.isEmpty || supportsAgentCapability(WarrenRemoteAgentCapability.attachments) else {
            finishAgentInterrupt(for: sessionID, token: interruptToken)
            agentActionError = "This Host does not support attachments."
            return false
        }

        let item = IOSAgentQueueItem(text: value, attachments: attachments)
        var queue = agentQueueBySessionID[sessionID] ?? IOSAgentMessageQueue()
        _ = queue.enqueue(item)
        _ = queue.markSending(id: item.id)
        agentQueueBySessionID[sessionID] = queue
        updateAgentQueuedMessageCount(for: sessionID)

        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
        let client = client
        let replacement = WarrenRemoteAgentMessageSendRequest(
            session: sessionID,
            clientMessageID: item.id,
            text: value,
            attachments: attachments
        )
        agentActionError = nil
        Task { [weak self] in
            do {
                let result = try await client.interruptAgentTurn(
                    WarrenRemoteAgentTurnInterruptRequest(
                        session: sessionID,
                        turn: turn,
                        reason: "send_now",
                        replacement: replacement
                    )
                )
                guard result.accepted else {
                    throw WarrenRemoteClientError.requestFailed("Host did not accept Send now.")
                }
                await MainActor.run {
                    guard let self else { return }
                    guard self.agentInterruptInFlightBySessionID[sessionID] == interruptToken else {
                        // Session switches and reconnects invalidate the
                        // interrupt token before an old response can arrive.
                        // The queue item still needs a terminal state; a late
                        // accepted response is already delivered by the Host,
                        // while an item that remains local must not spin.
                        if var localQueue = self.agentQueueBySessionID[sessionID],
                           localQueue.items.contains(where: { $0.id == item.id }) {
                            _ = localQueue.deliver(id: item.id)
                            self.agentQueueBySessionID[sessionID] = localQueue
                            self.pendingAgentMessagesBySessionID[sessionID]?.removeAll { $0 == item.id }
                            self.updateAgentQueuedMessageCount(for: sessionID)
                        }
                        return
                    }
                    let isCurrent = self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                    self.finishAgentInterrupt(for: sessionID, token: interruptToken)
                    if isCurrent {
                        if var localQueue = self.agentQueueBySessionID[sessionID] {
                            _ = localQueue.deliver(id: item.id)
                            self.agentQueueBySessionID[sessionID] = localQueue
                        }
                        self.updateAgentQueuedMessageCount(for: sessionID)
                    } else {
                        self.requeueAgentMessage(item, for: sessionID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    guard self.agentInterruptInFlightBySessionID[sessionID] == interruptToken else {
                        // The request is no longer authoritative, but the
                        // stable local item remains retryable after the
                        // session regains focus/control.
                        self.requeueAgentMessage(item, for: sessionID)
                        return
                    }
                    let canRetryInPlace = self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                    self.finishAgentInterrupt(for: sessionID, token: interruptToken)
                    if var localQueue = self.agentQueueBySessionID[sessionID],
                       localQueue.items.contains(where: { $0.id == item.id }) {
                        if canRetryInPlace {
                            _ = localQueue.markFailed(id: item.id, reason: error.localizedDescription)
                            self.agentQueueBySessionID[sessionID] = localQueue
                            self.updateAgentQueuedMessageCount(for: sessionID)
                        } else {
                            self.requeueAgentMessage(item, for: sessionID)
                        }
                    } else if canRetryInPlace {
                        self.enqueueAgentMessage(item.text, for: sessionID, atFront: true)
                    }
                    if self.currentSessionID == sessionID {
                        self.agentActionError = error.localizedDescription
                    }
                }
            }
        }
        return true
    }

    public func respondToAgentInteraction(
        sessionID: String,
        requestID: String,
        kind: String,
        response: [String: WarrenRemoteJSONValue]
    ) -> Task<Bool, Never> {
        guard supportsAgentCapability(WarrenRemoteAgentCapability.interactions) else {
            return Task { false }
        }
        let client = client
        agentActionError = nil
        return Task { [weak self] in
            do {
                _ = try await client.respondAgentInteraction(
                    WarrenRemoteAgentInteractionResponse(
                        session: sessionID,
                        requestID: requestID,
                        kind: kind,
                        response: response
                    )
                )
                return true
            } catch {
                await MainActor.run {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.agentActionError = error.localizedDescription
                }
                return false
            }
        }
    }

    /// Uploads one local attachment through the opaque prepare/chunk/complete
    /// lifecycle. The local bytes never enter the transcript or draft store;
    /// only the Host-issued attachment reference is returned to the caller.
    public func uploadAgentAttachment(
        data: Data,
        name: String,
        mime: String,
        sessionID: String,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> WarrenRemoteAgentAttachmentRef {
        guard supportsAgentCapability(WarrenRemoteAgentCapability.attachments) else {
            throw WarrenRemoteClientError.requestFailed("This Host does not support attachments.")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw WarrenRemoteClientError.requestFailed("Attachment is too large.")
        }
        guard currentSessionID == sessionID else {
            throw WarrenRemoteClientError.requestFailed("Session changed; attachment upload canceled.")
        }
        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
        let client = client
        func ensureCurrentSession() throws {
            guard currentSessionID == sessionID,
                  sessionSelectionGeneration == selectionGeneration,
                  clientGeneration == currentClientGeneration else {
                throw WarrenRemoteClientError.requestFailed("Session changed; attachment upload canceled.")
            }
        }
        let digest = agentSHA256(data)
        let prepared = try await client.prepareAgentAttachment(
            WarrenRemoteAgentAttachmentPrepareRequest(
                session: sessionID,
                name: name,
                mime: mime,
                size: Int64(data.count),
                sha256: digest
            )
        )
        try ensureCurrentSession()
        let chunkSize = max(1, prepared.chunkSize)
        let uploadID = prepared.uploadID
        do {
            var offset = 0
            var sequence: UInt64 = 0
            while offset < data.count {
                try ensureCurrentSession()
                let end = min(offset + chunkSize, data.count)
                let chunk = Data(data[offset..<end])
                let chunkHash = agentSHA256(chunk)
                let result = try await client.uploadAgentAttachmentChunk(
                    WarrenRemoteAgentAttachmentChunkRequest(
                        session: sessionID,
                        uploadID: uploadID,
                        sequence: sequence,
                        length: chunk.count,
                        sha256: chunkHash,
                        data: chunk.base64EncodedString()
                    )
                )
                try ensureCurrentSession()
                guard result.accepted else {
                    throw WarrenRemoteClientError.requestFailed(result.error ?? "Attachment chunk was rejected.")
                }
                offset = end
                sequence &+= 1
                progress(Double(offset) / Double(max(data.count, 1)))
            }
            try ensureCurrentSession()
            let completed = try await client.completeAgentAttachment(
                WarrenRemoteAgentAttachmentCompleteRequest(
                    session: sessionID,
                    uploadID: uploadID,
                    length: Int64(data.count),
                    sha256: digest
                )
            )
            try ensureCurrentSession()
            guard completed.accepted,
                  let attachmentID = completed.attachmentID, !attachmentID.isEmpty else {
                throw WarrenRemoteClientError.requestFailed(completed.error ?? "Attachment completion was rejected.")
            }
            progress(1)
            return WarrenRemoteAgentAttachmentRef(
                attachmentID: attachmentID,
                name: name,
                mime: mime,
                size: Int64(data.count)
            )
        } catch {
            _ = try? await client.abortAgentAttachment(
                WarrenRemoteAgentAttachmentAbortRequest(session: sessionID, uploadID: uploadID)
            )
            throw error
        }
    }

    private func submitAgentMessage(_ item: IOSAgentQueueItem, for sessionID: String) {
        guard agentMessageSubmissionsInFlight.insert(sessionID).inserted else {
            if !pendingAgentMessagesBySessionID[sessionID, default: []].contains(item.id) {
                pendingAgentMessagesBySessionID[sessionID, default: []].insert(item.id, at: 0)
            }
            return
        }
        agentMessageSubmissionSequence &+= 1
        let requestToken = agentMessageSubmissionSequence
        agentMessageSubmissionTokenBySessionID[sessionID] = requestToken
        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
        let client = client
        let timelineSupported = supportsAgentCapability(WarrenRemoteAgentCapability.timeline)
        let attachmentsSupported = supportsAgentCapability(WarrenRemoteAgentCapability.attachments)
        Task { [weak self] in
            do {
                let stillAllowed = await MainActor.run {
                    guard let self,
                          self.agentMessageSubmissionTokenBySessionID[sessionID] == requestToken else { return false }
                    return self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                }
                guard stillAllowed else {
                    await MainActor.run {
                        guard let self,
                              self.agentMessageSubmissionTokenBySessionID[sessionID] == requestToken else { return }
                        self.agentMessageSubmissionTokenBySessionID.removeValue(forKey: sessionID)
                        self.agentMessageSubmissionsInFlight.remove(sessionID)
                        self.requeueAgentMessage(item, for: sessionID)
                    }
                    return
                }
                if !item.attachments.isEmpty && !attachmentsSupported {
                    throw WarrenRemoteClientError.requestFailed("This Host does not support attachments.")
                }
                if timelineSupported || !item.attachments.isEmpty {
                    let result = try await client.sendAgentMessage(
                        WarrenRemoteAgentMessageSendRequest(
                            session: sessionID,
                            clientMessageID: item.id,
                            text: item.text,
                            attachments: item.attachments
                        )
                    )
                    guard result.accepted else {
                        throw WarrenRemoteClientError.requestFailed("Host did not accept the message.")
                    }
                } else {
                    try await client.sendAgentInput(item.text, sessionID: sessionID)
                }
                await MainActor.run {
                    guard let self,
                          self.agentMessageSubmissionTokenBySessionID[sessionID] == requestToken else { return }
                    let isCurrent = self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                    self.agentMessageSubmissionTokenBySessionID.removeValue(forKey: sessionID)
                    self.agentMessageSubmissionsInFlight.remove(sessionID)
                    if isCurrent {
                        if var localQueue = self.agentQueueBySessionID[sessionID],
                           localQueue.items.contains(where: { $0.id == item.id }) {
                            _ = localQueue.deliver(id: item.id)
                            self.agentQueueBySessionID[sessionID] = localQueue
                        }
                        self.updateAgentQueuedMessageCount(for: sessionID)
                        // Usually the Host emits working immediately and the
                        // next ready event drains the remaining queue. Keep
                        // this fallback for Hosts that only publish ready
                        // boundaries.
                        if self.agentStatus(for: sessionID)?.activity == .ready {
                            self.drainQueuedAgentMessages(for: sessionID)
                        }
                    } else {
                        self.requeueAgentMessage(item, for: sessionID)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.agentMessageSubmissionTokenBySessionID[sessionID] == requestToken else { return }
                    let canRetryInPlace = self.currentSessionID == sessionID
                        && self.hasControlLease
                        && self.pendingSessionDeletion?.sessionID != sessionID
                        && self.sessionSelectionGeneration == selectionGeneration
                        && self.clientGeneration == currentClientGeneration
                    self.agentMessageSubmissionTokenBySessionID.removeValue(forKey: sessionID)
                    self.agentMessageSubmissionsInFlight.remove(sessionID)
                    if canRetryInPlace {
                        if var localQueue = self.agentQueueBySessionID[sessionID],
                           localQueue.items.contains(where: { $0.id == item.id }) {
                            _ = localQueue.markFailed(id: item.id, reason: error.localizedDescription)
                            self.agentQueueBySessionID[sessionID] = localQueue
                            self.updateAgentQueuedMessageCount(for: sessionID)
                        } else {
                            self.enqueueAgentMessage(item.text, for: sessionID, atFront: true)
                        }
                    } else {
                        // A Session switch or lost control lease means the
                        // request may never have reached the Host. Keep the
                        // stable local identity queued for a later
                        // focus/reconnect instead of leaving a permanent
                        // `.sending` item that cannot be retried.
                        self.requeueAgentMessage(item, for: sessionID)
                    }
                }
            }
        }
    }

    private func drainQueuedAgentMessages(for sessionID: String) {
        guard currentSessionID == sessionID,
              hasControlLease,
              agentStatus(for: sessionID)?.activity == .ready,
              !agentMessageSubmissionsInFlight.contains(sessionID),
              agentInterruptInFlightBySessionID[sessionID] == nil,
              var pendingIDs = pendingAgentMessagesBySessionID[sessionID],
              !pendingIDs.isEmpty else { return }
        let itemID = pendingIDs.removeFirst()
        pendingAgentMessagesBySessionID[sessionID] = pendingIDs
        guard var localQueue = agentQueueBySessionID[sessionID],
              let item = localQueue.items.first(where: { $0.id == itemID }) else {
            updateAgentQueuedMessageCount(for: sessionID)
            drainQueuedAgentMessages(for: sessionID)
            return
        }
        _ = localQueue.markSending(id: item.id)
        agentQueueBySessionID[sessionID] = localQueue
        updateAgentQueuedMessageCount(for: sessionID)
        submitAgentMessage(item, for: sessionID)
    }

    private func submitBlockedAgentMessage(for sessionID: String) {
        guard currentSessionID == sessionID,
              hasControlLease,
              !agentMessageSubmissionsInFlight.contains(sessionID),
              agentInterruptInFlightBySessionID[sessionID] == nil,
              var pendingIDs = pendingAgentMessagesBySessionID[sessionID],
              let itemID = pendingIDs.first,
              var queue = agentQueueBySessionID[sessionID],
              let item = queue.items.first(where: { $0.id == itemID }) else { return }
        pendingIDs.removeFirst()
        pendingAgentMessagesBySessionID[sessionID] = pendingIDs
        _ = queue.markSending(id: item.id)
        agentQueueBySessionID[sessionID] = queue
        updateAgentQueuedMessageCount(for: sessionID)
        submitAgentMessage(item, for: sessionID)
    }

    private func enqueueAgentMessage(
        _ value: String,
        for sessionID: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        atFront: Bool = false
    ) {
        var localQueue = agentQueueBySessionID[sessionID] ?? IOSAgentMessageQueue()
        let item = IOSAgentQueueItem(text: value, attachments: attachments)
        _ = localQueue.enqueue(item)
        if atFront { _ = localQueue.moveToFront(id: item.id) }
        agentQueueBySessionID[sessionID] = localQueue
        if atFront {
            pendingAgentMessagesBySessionID[sessionID, default: []].insert(item.id, at: 0)
        } else {
            pendingAgentMessagesBySessionID[sessionID, default: []].append(item.id)
        }
        updateAgentQueuedMessageCount(for: sessionID)
    }

    private func updateAgentQueuedMessageCount(for sessionID: String) {
        let count = agentQueueBySessionID[sessionID]?.items.count ?? 0
        if count == 0 {
            agentQueuedMessageCountBySessionID.removeValue(forKey: sessionID)
        } else {
            agentQueuedMessageCountBySessionID[sessionID] = count
        }
    }

    private func reorderPendingIDs(for sessionID: String, accordingTo queue: IOSAgentMessageQueue) {
        guard let pending = pendingAgentMessagesBySessionID[sessionID], !pending.isEmpty else { return }
        let order = Dictionary(uniqueKeysWithValues: queue.items.enumerated().map { ($0.element.id, $0.offset) })
        pendingAgentMessagesBySessionID[sessionID] = pending.sorted {
            (order[$0] ?? Int.max) < (order[$1] ?? Int.max)
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
        return events
            .reversed()
            .compactMap { event in
                let value = event.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            .first
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
        mutationGeneration &+= 1
        let generation = mutationGeneration
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
                    guard let self, self.mutationGeneration == generation else { return }
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
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    self.mutationError = error.localizedDescription
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
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let retainingRoute = currentSessionID == sessionID
        let endpointIdentity = "\(endpointMetadata.name)|\(endpointMetadata.url)"
        if retainingRoute {
            pendingSessionDeletion = PendingSessionDeletion(
                sessionID: sessionID,
                replacementSessionID: replacementSessionID(for: sessionID),
                endpointIdentity: endpointIdentity
            )
            prepareCurrentSessionForDeletion(sessionID)
        }
        let client = client
        Task { [weak self] in
            do {
                let deleted = try await client.deleteSession(sessionID: sessionID)
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    self.pendingSessionSelectionID = nil
                    guard deleted else {
                        guard retainingRoute else { return }
                        self.pendingSessionDeletion = nil
                        self.restoreSessionAfterDeleteFailure(sessionID)
                        self.mutationError = "The Host did not delete this Session."
                        return
                    }
                    // Clear local-only composer state only after the Host
                    // confirms deletion. This also applies when the target
                    // was not the currently selected Session.
                    self.clearLocalAgentStateAfterSessionDeletion(
                        sessionID,
                        endpointIdentity: endpointIdentity
                    )
                    guard retainingRoute else { return }
                    guard self.currentSessionID == sessionID else {
                        self.pendingSessionDeletion = nil
                        return
                    }
                    self.finishCurrentSessionDeletion(sessionID)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
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
        invalidateAgentHistoryRequest(for: sessionID)
        invalidateAgentMessageSubmission(for: sessionID)
        agentInterruptInFlightBySessionID.removeValue(forKey: sessionID)
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
        hasControlLease = false
    }

    /// Removes device-local Agent state after a confirmed Host deletion. The
    /// queue and pending IDs intentionally survive `prepare...` so a failed
    /// delete can restore the Session without losing unsent messages.
    private func clearLocalAgentStateAfterSessionDeletion(
        _ sessionID: String,
        endpointIdentity: String
    ) {
        invalidateAgentHistoryRequest(for: sessionID)
        historyCursorBySessionID.removeValue(forKey: sessionID)
        historyHasMoreBySessionID.removeValue(forKey: sessionID)
        historyLoadedBySessionID.remove(sessionID)
        historyErrorBySessionID.removeValue(forKey: sessionID)
        agentQueueBySessionID.removeValue(forKey: sessionID)
        agentQueuedMessageCountBySessionID.removeValue(forKey: sessionID)
        pendingAgentMessagesBySessionID.removeValue(forKey: sessionID)
        agentMessageSubmissionsInFlight.remove(sessionID)
        agentMessageSubmissionTokenBySessionID.removeValue(forKey: sessionID)
        agentInterruptInFlightBySessionID.removeValue(forKey: sessionID)
        draftSaveTasksBySessionID[sessionID]?.cancel()
        draftSaveTasksBySessionID.removeValue(forKey: sessionID)
        invalidatedAgentDraftKeys.insert(
            agentDraftStateKey(endpointIdentity: endpointIdentity, sessionID: sessionID)
        )
        localStore.removeAgentDraft(sessionID: sessionID, endpointIdentity: endpointIdentity)
    }

    private func agentDraftStateKey(endpointIdentity: String, sessionID: String) -> String {
        "\(endpointIdentity)\u{1F}\(sessionID)"
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
        invalidateAgentHistoryRequest(for: sessionID)
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
        if !historyLoadedBySessionID.contains(sessionID) {
            loadOlderAgentHistory()
        }
    }

    public func renameWorkspace(_ workspaceID: String, name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty, !normalized.isEmpty, !isMutating else { return }
        mutationError = nil
        isMutating = true
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.renameWorkspace(workspaceID: workspaceID, name: normalized)
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    self.mutationError = error.localizedDescription
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
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.deleteWorkspace(
                    workspaceID: workspaceID,
                    force: force,
                    removeWorktree: removeWorktree
                )
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    if self.navigation.workspaceID == workspaceID {
                        self.navigation.workspaceID = nil
                        self.navigation.sessionID = nil
                        self.persistNavigation()
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    self.mutationError = error.localizedDescription
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
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.createWorkspace(
                    projectID: projectID,
                    branch: normalizedBranch,
                    name: name,
                    path: path
                )
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mutationGeneration == generation else { return }
                    self.isMutating = false
                    self.mutationError = error.localizedDescription
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

    private func invalidateAgentHistoryRequest(for sessionID: String) {
        historyRequestTokenBySessionID.removeValue(forKey: sessionID)
        historyLoadingBySessionID.remove(sessionID)
    }

    /// Loads one older page. The Host owns pagination cursors; this method
    /// only merges sequence-unique events into the local transcript.
    public func loadOlderAgentHistory() {
        guard let sessionID = currentSessionID,
              roster?.sessions.first(where: { $0.id == sessionID })?.isAgentBacked == true,
              historyLoadingBySessionID.insert(sessionID).inserted else { return }
        let before = historyCursorBySessionID[sessionID]
        let selectionGeneration = sessionSelectionGeneration
        let currentClientGeneration = clientGeneration
        let client = client
        historyRequestSequence &+= 1
        let requestToken = historyRequestSequence
        historyRequestTokenBySessionID[sessionID] = requestToken
        historyErrorBySessionID.removeValue(forKey: sessionID)
        Task { [weak self] in
            do {
                // Mobile history is a conversation surface. Tool and
                // reasoning events remain available in the live tail, but
                // must not consume the entire page before older user/
                // assistant messages arrive.
                let page = try await client.agentHistory(
                    sessionID: sessionID,
                    before: before,
                    conversationOnly: true
                )
                await MainActor.run {
                    guard let self,
                          self.historyRequestTokenBySessionID[sessionID] == requestToken,
                          self.sessionSelectionGeneration == selectionGeneration,
                          self.clientGeneration == currentClientGeneration,
                          self.currentSessionID == sessionID else { return }
                    self.historyRequestTokenBySessionID.removeValue(forKey: sessionID)
                    self.historyLoadingBySessionID.remove(sessionID)
                    if let pageEpoch = page.epoch,
                       pageEpoch != 0,
                       let currentEpoch = self.agentEpochBySessionID[sessionID],
                       currentEpoch != 0,
                       pageEpoch != currentEpoch {
                        self.historyErrorBySessionID[sessionID] = "Conversation changed. Try again."
                        return
                    }
                    self.mergeAgentEvents(
                        page.events,
                        sessionID: sessionID,
                        epoch: page.epoch ?? 0,
                        prepend: true
                    )
                    self.historyLoadedBySessionID.insert(sessionID)
                    self.historyErrorBySessionID.removeValue(forKey: sessionID)
                    if let cursor = page.cursor {
                        self.historyCursorBySessionID[sessionID] = cursor
                    }
                    self.historyHasMoreBySessionID[sessionID] = page.hasMore
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.historyRequestTokenBySessionID[sessionID] == requestToken,
                          self.sessionSelectionGeneration == selectionGeneration,
                          self.clientGeneration == currentClientGeneration,
                          self.currentSessionID == sessionID else { return }
                    self.historyRequestTokenBySessionID.removeValue(forKey: sessionID)
                    self.historyLoadingBySessionID.remove(sessionID)
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.historyErrorBySessionID[sessionID] = detail.isEmpty
                        ? "Unable to load Agent history. Try again."
                        : detail
                }
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

    public func agentHistoryError(for sessionID: String) -> String? {
        historyErrorBySessionID[sessionID]
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
                terminalFocusGeneration &+= 1
                terminalFocusRequestsBySessionID.removeAll()
                if let currentSessionID {
                    invalidateAgentMessageSubmission(for: currentSessionID)
                    agentInterruptInFlightBySessionID.removeValue(forKey: currentSessionID)
                }
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
            let client = client
            Task { [weak self] in
                let capabilities = await client.capabilities()
                await MainActor.run { self?.agentCapabilities = capabilities }
            }
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
            if epoch != 0,
               let previous = agentEpochBySessionID[sessionID], previous != epoch {
                agentState.agentEventsBySessionID[sessionID] = []
                agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
                agentEventKeysBySessionID[sessionID] = []
                historyCursorBySessionID.removeValue(forKey: sessionID)
                historyHasMoreBySessionID.removeValue(forKey: sessionID)
                historyLoadedBySessionID.remove(sessionID)
                historyErrorBySessionID.removeValue(forKey: sessionID)
                invalidateAgentHistoryRequest(for: sessionID)
            }
            if epoch != 0 {
                agentEpochBySessionID[sessionID] = epoch
            }
            agentStatusBySessionID[sessionID] = status
            if status.activity == .ready {
                drainQueuedAgentMessages(for: sessionID)
            } else if status.activity == .blocked, status.attention?.kind == .input {
                // A queued message can be the answer to a provider question.
                // Treat blocked/input as an executable boundary just like the
                // Web reducer so the first queued answer is submitted without
                // waiting for a synthetic ready event.
                submitBlockedAgentMessage(for: sessionID)
            }
        case .agentTurn(let sessionID, let epoch, let turn):
            if epoch != 0,
               let previous = agentEpochBySessionID[sessionID], previous != epoch {
                agentState.agentEventsBySessionID[sessionID] = []
                agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
                agentEventKeysBySessionID[sessionID] = []
                historyCursorBySessionID.removeValue(forKey: sessionID)
                historyHasMoreBySessionID.removeValue(forKey: sessionID)
                historyLoadedBySessionID.remove(sessionID)
                historyErrorBySessionID.removeValue(forKey: sessionID)
                invalidateAgentHistoryRequest(for: sessionID)
            }
            if epoch != 0 {
                agentEpochBySessionID[sessionID] = epoch
            }
            agentTurnBySessionID[sessionID] = turn
            if turn.status == .completed || turn.status == .failed || turn.status == .aborted {
                drainQueuedAgentMessages(for: sessionID)
            }
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
            terminalState.terminalReadyBySessionID[frame.sessionID] = false
            requestTerminalRecovery(for: frame.sessionID)
            return
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
        if epoch != 0,
           let previous = agentEpochBySessionID[sessionID], previous != epoch {
            agentState.agentEventsBySessionID[sessionID] = []
            agentState.agentEventRevisionBySessionID[sessionID, default: 0] &+= 1
            agentEventKeysBySessionID[sessionID] = []
            historyCursorBySessionID.removeValue(forKey: sessionID)
            historyHasMoreBySessionID.removeValue(forKey: sessionID)
            historyLoadedBySessionID.remove(sessionID)
            historyErrorBySessionID.removeValue(forKey: sessionID)
            invalidateAgentHistoryRequest(for: sessionID)
        }
        if epoch != 0 {
            agentEpochBySessionID[sessionID] = epoch
        }
        let eventEpoch = agentEpochBySessionID[sessionID] ?? epoch
        // Take ownership of the buffers while merging. Agent deltas can be
        // frequent; mutating a value left in the dictionary would trigger a
        // full copy of the transcript for each delta.
        var events = agentState.agentEventsBySessionID.removeValue(forKey: sessionID) ?? []
        var keys = agentEventKeysBySessionID.removeValue(forKey: sessionID) ?? []
        var didChange = false
        for event in incoming {
            let key = "\(eventEpoch):\(event.sequence)"
            // Fold any provider's content-delta events by (type,id) key so streaming replies do not
            // produce a bubble per database poll. Seed events have contentDelta=false; later updates
            // carry contentDelta=true and append to the accumulated content.
            if event.contentDelta,
               let index = events.lastIndex(where: {
                   $0.id == event.id && $0.type == event.type
               }) {
                let existing = events[index]
                // Sequence-deduplicate before merging deltas to avoid processing the same update twice.
                if keys.contains(key) { continue }
                let merged = WarrenRemoteAgentEvent(
                    sequence: existing.sequence,
                    turn: event.turn ?? existing.turn,
                    id: event.id,
                    provider: event.provider.isEmpty ? existing.provider : event.provider,
                    type: event.type,
                    role: event.role ?? existing.role,
                    content: (existing.content ?? "") + (event.content ?? ""),
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
                    timestamp: event.timestamp ?? existing.timestamp,
                    payload: event.payload ?? existing.payload
                )
                events[index] = merged
                keys.insert(key)
                didChange = true
                continue
            }
            if keys.contains(key) { continue }
            if prepend {
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
        let previousSessionIDs = Set(roster?.sessions.map(\.id) ?? [])
        let nextSessionIDs = Set(next.sessions.map(\.id))
        for sessionID in previousSessionIDs.subtracting(nextSessionIDs) {
            // Keep local state until our own delete request is confirmed. A
            // roster broadcast can precede its response; clearing here would
            // make a failed mutation lose the queue/draft that can still be
            // restored on the original Session.
            if pendingSessionDeletion?.sessionID == sessionID { continue }
            clearLocalAgentStateAfterSessionDeletion(
                sessionID,
                endpointIdentity: "\(endpointMetadata.name)|\(endpointMetadata.url)"
            )
        }
        roster = next
        maintenanceMessage = nil
        agentStatusBySessionID = [:]
        agentTurnBySessionID = [:]
        for session in next.sessions {
            if let status = session.agentStatus { agentStatusBySessionID[session.id] = status }
            if let turn = session.agentTurn { agentTurnBySessionID[session.id] = turn }
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
