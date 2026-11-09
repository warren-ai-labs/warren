import Foundation
import AppKit
import CryptoKit
import Network
import Combine
import Darwin
import UniformTypeIdentifiers
import GhosttyAdapter
import WarrenClientCore
import WarrenDesignSystem
import WarrenDesktop
import WarrenDomain
import WarrenProtocol
import WarrenClientCore
import WarrenTransport

enum WarrenRemoteErrorInfoKey {
    static let method = "WarrenRemoteMethod"
    static let params = "WarrenRemoteParams"
    static let endpoint = "WarrenRemoteEndpoint"
    static let startedAt = "WarrenRemoteRequestStartedAt"
    static let daemonProtocol = "WarrenRemoteDaemonProtocol"
}

struct PendingAtomicRecovery: Sendable {
    let epoch: UInt64
    let sequence: UInt64
    let format: String
    let payload: Data
}

enum WarrenRemoteDiagnostics {
    static let sensitiveParameterNames = [
        "authorization", "cookie", "password", "secret", "token", "key",
    ]

    static func text(
        error: Error,
        endpoint: String?,
        selectedSessionID: TerminalSessionID?,
        attachedSessionID: TerminalSessionID?,
        focusedSessionID: TerminalSessionID?,
        now: Date = Date()
    ) -> String {
        let nsError = error as NSError
        let info = nsError.userInfo
        let requestEndpoint = info[WarrenRemoteErrorInfoKey.endpoint] as? String
        let method = info[WarrenRemoteErrorInfoKey.method] as? String ?? "unknown"
        let params = info[WarrenRemoteErrorInfoKey.params] as? [String: String] ?? [:]
        let daemonProtocol = info[WarrenRemoteErrorInfoKey.daemonProtocol] as? String ?? "unknown"
        let startedAt = info[WarrenRemoteErrorInfoKey.startedAt] as? Date
        let effectiveEndpoint = requestEndpoint ?? endpoint ?? "unknown"
        let elapsed = startedAt.map { max(0, now.timeIntervalSince($0)) }

        var lines = [
            "Warren daemon diagnostic",
            "timestamp: \(iso8601(now))",
            "endpoint: \(redactedEndpoint(effectiveEndpoint))",
            "operation: \(method)",
            "parameters: \(formattedParameters(params))",
            "selectedSession: \(selectedSessionID?.description ?? "none")",
            "attachedSession: \(attachedSessionID?.description ?? "none")",
            "focusedSession: \(focusedSessionID?.description ?? "none")",
            "clientProtocol: 4.0",
            "daemonProtocol: \(daemonProtocol)",
            "appVersion: \(appVersion())",
            "os: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "errorType: \(String(reflecting: type(of: error)))",
            "errorDomain: \(nsError.domain)",
            "errorCode: \(nsError.code)",
            "message: \(nsError.localizedDescription)",
        ]
        if let startedAt {
            lines.insert("requestStarted: \(iso8601(startedAt))", at: 2)
        }
        if let elapsed {
            lines.insert(String(format: "requestElapsedMs: %.0f", elapsed * 1_000), at: 3)
        }
        if let underlying = info[NSUnderlyingErrorKey] as? NSError {
            lines.append(
                "underlying: \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func formattedParameters(_ params: [String: String]) -> String {
        guard !params.isEmpty else { return "none" }
        return params.keys.sorted().map { key in
            let value = params[key] ?? ""
            let lowercased = key.lowercased()
            let redacted = sensitiveParameterNames.contains { lowercased.contains($0) }
                ? "<redacted>"
                : value
            return "\(key)=\(redacted)"
        }.joined(separator: ", ")
    }

    static func redactedEndpoint(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            // Keep malformed user input useful in diagnostics without
            // carrying a query/fragment that may contain a bearer token.
            let withoutFragment = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
            return withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? raw
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }
}

@MainActor
final class WarrenRemoteApplicationModel: ObservableObject {
    static let deletionReconciliationTimeout: Duration = .seconds(30)
    /// A daemon restart briefly drops the WebSocket before its listener is
    /// ready again. Keep that expected gap out of the notice center;
    /// persistent failures still become visible after the grace period.
    static let transientConnectionIssueDelay: Duration = .seconds(5)
    /// A bounded number of consecutive failures keeps a bad SSH target from
    /// spinning forever in the background. RetryConnection starts a fresh
    /// budget after the user fixes credentials or host-key configuration.
    static let maxReconnectAttempts = 8
    /// Granularity of the reconnect wait. The delay is served in slices so a
    /// wake or network change can end it early without cancelling the
    /// connection task.
    static let reconnectWaitSlice = 250

    @Published var connectionError: String?
    @Published var hostProbes: [WarrenRemoteEndpointConfiguration: WarrenHostProbe] = [:]
    /// Hosts whose probe is running now. Their last result stays in
    /// `hostProbes` until the new one lands, so a row never blanks out while
    /// it is being checked again.
    @Published var hostProbesInFlight: Set<WarrenRemoteEndpointConfiguration> = []
    var hostProbeTask: Task<Void, Never>?
    var hostProbesCheckedAt: ContinuousClock.Instant?
    /// Opening the Host picker probes again only when the last results are
    /// older than this; the picker's refresh button always probes.
    static let hostProbeFreshness: Duration = .seconds(60)

    func probeHosts(_ endpoints: [WarrenRemoteEndpointConfiguration], force: Bool = true) {
        let now = ContinuousClock.now
        if !force,
           let checkedAt = hostProbesCheckedAt,
           now - checkedAt < Self.hostProbeFreshness,
           endpoints.allSatisfy({ hostProbes[$0] != nil || hostProbesInFlight.contains($0) }) {
            return
        }
        hostProbeTask?.cancel()
        hostProbesCheckedAt = now
        // Results for Hosts no longer in the catalog go; the rest stay until
        // their new result replaces them.
        let wanted = Set(endpoints)
        hostProbes = hostProbes.filter { wanted.contains($0.key) }
        hostProbesInFlight = wanted
        let active = activeEndpointConfiguration
        let selected = endpointConfiguration
        hostProbeTask = Task { [weak self] in
            await withTaskGroup(of: (WarrenRemoteEndpointConfiguration, WarrenHostProbe).self) { group in
                for endpoint in endpoints {
                    group.addTask {
                        if endpoint.ssh != nil, endpoint != selected || active == nil {
                            return (endpoint, WarrenHostProbe(
                                message: "Checked once selected: reaching it needs its SSH connection",
                                isInconclusive: true
                            ))
                        }
                        let target = endpoint.ssh != nil ? (active ?? endpoint) : endpoint
                        return (endpoint, await WarrenHostProbe.check(target))
                    }
                }
                for await (endpoint, probe) in group {
                    guard !Task.isCancelled else { return }
                    self?.hostProbes[endpoint] = probe
                    self?.hostProbesInFlight.remove(endpoint)
                }
            }
        }
    }

    @Published var projection = WarrenDesktopProjection
        .empty(host: WarrenDomain.Host(name: "Server"))
        .withConnectionState(.connecting)
    /// Endpoint alias owning the current window navigation memory. The
    /// foreground controller is single-Host, but its IDs are not globally
    /// unique across Hosts, so persistence must follow this scope.
    var navigationScope = "local"
    /// The endpoint scope that owns `navigation`. During an endpoint switch it
    /// is the only safe scope for presenting a selected sidebar resource.
    var navigationEndpointID: String { navigationScope }
    @Published var navigation: WarrenDesktopNavigationState {
        didSet { scheduleNavigationPersistence() }
    }
    var navigationPersistenceTask: Task<Void, Never>?
    var pendingNavigationToPersist: WarrenDesktopNavigationState?
    var pendingNavigationScope = "local"
    var terminationObserver: NSObjectProtocol?
    /// Client-local diagnostics and system messages shown by the desktop
    /// notice center. Keep this bounded so repeated failures cannot grow the
    /// model without limit.
    @Published var notices: [WarrenDesktopNotice] = []
    @Published var webStatus = WarrenDesktopWebStatus()
    /// Non-secret Relay enrollment metadata owned by the selected Host
    /// daemon. The Host Secret remains in the daemon credential store.
    @Published var relaySettings = WarrenDesktopRelaySettings()
    @Published var relayDevices: [WarrenDesktopRelayDevice] = []
    /// Aggregated Agent token usage and equivalent cost, owned by the Host.
    /// Aggregation stays there because the client's event replica is a bounded
    /// cache and folding it would under-report older spend.
    @Published var usageStats = WarrenUsageStats()
    @Published var usageState = WarrenUsageLoadState.idle
    /// Range-and-day key of the payload currently in `usageStats`, so moving
    /// between the two Usage settings views reuses a fetch instead of repeating
    /// it. The refresh action and a rebuild bypass the cache.
    var usageLoadedKey: String?
    var usageLoadedAt: Date?
    /// Monotonic token for in-flight usage requests. Only the newest response
    /// may land, so switching range mid-load cannot leave the picker showing
    /// one window while the figures describe another.
    var usageRequestGeneration = 0
    /// A cached payload is reused for this long. Long enough to absorb the
    /// duplicate fetch from reopening the section, short enough that a person
    /// who reopened Settings to check fresh numbers is not shown a stale total.
    static let usageCacheLifetime: TimeInterval = 60
    /// The explicit, short-lived Host-side window that accepts an iPhone PIN.
    /// No pairing state is inferred from discovery; it is returned by the
    /// authenticated daemon settings projection.
    @Published var lanPairing = WarrenDesktopLANPairing()
    /// Serverless remote access (Bolthole), owned by the selected Host daemon.
    /// Asked for on demand, unlike the settings projection, because the relay
    /// connection changes while the window stays open.
    @Published var remoteAccess = WarrenDesktopRemoteAccess()
    @Published var remoteShare: WarrenDesktopRemoteShare?
    /// Default engine for new sessions, owned by the headless daemon.
    @Published var defaultRuntime: String?
    /// Whether opening an empty workspace creates a default Shell session.
    @Published var autoOpenShell = false
    /// Whether entering an empty workspace starts the first AI preset.
    @Published var autoStartAI = false
    /// OpenAI-compatible endpoint used for automatic session titles.
    @Published var openAIBaseURL = ""
    @Published var openAIModel = ""
    @Published var openAITitleEnabled = false
    var settingsLoaded = false
    /// Set while the daemon has announced an operator-initiated maintenance
    /// window (for example an app install that restarts the daemon). Clients
    /// show an update state instead of treating the disconnect as a failure.
    @Published var maintenanceMessage: String?
    /// Set while the local daemon's Ghostline handoff journal reports an
    /// in-flight migration. The Desktop uses this only for the startup
    /// connection spinner; it is not a transport or failure state.
    @Published var isMigratingRuntimeSessions = false
    @Published var creatingSessionWorkspaceIDs: Set<WorkspaceID> = []
    /// The Session each tokened create request produced. Entries are small and
    /// only cleared with the connection, so a late reader still finds its own.
    @Published var createdSessionIDsByToken: [UUID: TerminalSessionID] = [:]
    @Published var deletingProjectIDs: Set<ProjectID> = []
    @Published var deletingWorkspaceIDs: Set<WorkspaceID> = []
    @Published var attachingSessionID: TerminalSessionID?

    var wire: WarrenRemoteClient?
    var embeddedSSHTunnel: WarrenEmbeddedSSHTunnel?
    /// The endpoint currently backed by the live transport. SSH endpoints
    /// keep a durable alias in `endpointConfiguration`, while the helper
    /// supplies a fresh loopback URL and token for each connection attempt.
    var activeEndpointConfiguration: WarrenRemoteEndpointConfiguration?
    var connectionGeneration: UInt64 = 0
    var endpointConfiguration: WarrenRemoteEndpointConfiguration?
    var isLocalEndpoint = false
    var eventTask: Task<Void, Never>?
    var selectedSessionID: TerminalSessionID?
    var attachedSessionID: TerminalSessionID?
    var focusedSessionID: TerminalSessionID?
    /// The locally focused Session is the control target for split panes.
    /// Exposing this read-only projection lets the composition root scope
    /// per-pane search without leaking attachment mutability into the UI.
    var focusedTerminalSessionID: TerminalSessionID? {
        focusedSessionID ?? selectedSessionID
    }
    var pendingFocusSessionID: TerminalSessionID?
    var pendingFocusSize: TerminalSize?
    var pendingFocusResizeSize: TerminalSize?
    var focusClaimInFlight = false
    var focusClaimGeneration = 0
    let inputRouter = WarrenTerminalInputRouter()
    var initialRefreshPending = false
    var currentRoster: RemoteRoster?
    /// The last full roster off the wire and its application shape, so a
    /// Host resending an unchanged roster skips the JSON round trip.
    var decodedRosterCache: (source: WarrenRemoteRoster, roster: RemoteRoster)?
    var rosterApplicationGeneration: UInt64 = 0
    var resizeTask: Task<Void, Never>?
    var resizeBuffer = WarrenResizeRequestBuffer()
    /// Sessions this window currently renders. Split panes each own their
    /// viewport, so every visible Session may size its own PTY; only the
    /// selected one also holds the input lease.
    var visibleSessionIDs: Set<TerminalSessionID> = []
    /// Per-Session viewport queues for the panes that are not the keyboard
    /// target. One shared queue would let two panes overwrite each other's
    /// latest size.
    var passiveResizeBuffers: [TerminalSessionID: WarrenResizeRequestBuffer] = [:]
    var passiveResizeTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    var focusTask: Task<Void, Never>?
    var deletionReconciliationTask: Task<Void, Never>?
    var deletionReconciliationWire: WarrenRemoteClient?
    var attachGeneration: UInt64 = 0
    var terminalFont = TerminalFontPreference()
    /// 1 paints the terminal's own ground; 0 lets the window's glass coat,
    /// which is the same color, show through.
    var terminalBackgroundOpacity: Double = 1
    var pendingTerminalOpenRequest: WarrenTerminalOpenRequest?
    var maintenanceResetTask: Task<Void, Never>?
    var connectionIssueTask: Task<Void, Never>?
    var outputAnchors: [TerminalSessionID: TerminalOutputAnchor] = [:]
    var agentStatusBySessionID: [TerminalSessionID: AgentStatus] = [:]
    /// Canonical Agent event replication is a desktop concern. The shared
    /// transport only delivers typed batches; this state tracks which roster
    /// streams are projected into the local append-only replica.
    var agentNamespace: WarrenAgentEventStore.Namespace?
    var agentSessionByStreamID: [String: TerminalSessionID] = [:]
    var agentSubscribedStreamIDs: Set<String> = []
    var agentQuarantinedStreamIDs: Set<String> = []
    var agentProjectionSequenceByStreamID: [String: UInt64] = [:]
    var agentPendingProjectionByStreamID: [String: [UInt64: WarrenRemoteAgentEvent]] = [:]
    /// The tool step each stream's Agent is on, with the highest sequence
    /// folded into it, so a replayed batch cannot move it backwards.
    var agentCurrentStepByStreamID: [String: (step: WarrenConversation.Step?, sequence: UInt64)] = [:]
    /// The turn each stream is in, so a turn that settled no call can still say
    /// how long it ran once it ends.
    var agentTurnByStreamID: [String: WarrenAgentTurnFold] = [:]
    /// The steps of each stream's latest turn, so a resting row can say what the
    /// turn did and a working one can report what it has done so far. Reset at
    /// every turn boundary by `WarrenConversation.steps`.
    var agentTurnStepsByStreamID: [String: [WarrenConversation.Step]] = [:]
    /// The session's plan and context, the last each stream reported. They
    /// outlive a roster rebuild the same way the activity lines do.
    var agentPlanByStreamID: [String: WarrenDesktopPlanProgress] = [:]
    var agentContextByStreamID: [String: WarrenDesktopContextUsage] = [:]
    /// The subagents each stream has spawned, in first-seen order. Keyed by the
    /// child's stable identity so a later row updates its own entry.
    var agentSubagentsByStreamID: [String: [WarrenDesktopSubagent]] = [:]
    /// Every interaction event each stream has reported, so the decision a
    /// Session is stopped on can be answered from the approval tray without
    /// building that Session's Conversation. A turn reports a handful of
    /// these, and they are dropped with their stream. Nothing is pruned on
    /// resolution, because a gap refill can deliver a request after its own
    /// resolution and must not bring it back.
    var agentInteractionEventsByStreamID: [String: [UInt64: WarrenRemoteAgentEvent]] = [:]
    /// The decision each stream is waiting on, as the Conversation projection
    /// reads it from those events: the first one still pending, which is the
    /// one the dock shows.
    var agentOpenDecisionByStreamID: [String: WarrenConversation.Decision] = [:]
    /// The open decisions of this Host's Conversation Sessions, for the
    /// approval tray.
    @Published var pendingDecisions: [TerminalSessionID: WarrenDesktopPendingDecision] = [:]
    /// The activation token each Conversation composer has to consume.
    ///
    /// A token only moves when the user enters the Session, so a token issued
    /// before the pane exists still focuses the composer once it mounts. It is
    /// published because the token, not the mount, is what makes the pane
    /// claim the keyboard.
    @Published var conversationFocusTokens: [TerminalSessionID: UInt] = [:]
    var nextConversationFocusToken: UInt = 0
    var agentSubscriptionTasks: [String: Task<Void, Never>] = [:]
    /// ACP Sessions own no terminal (RFC 0023): no surface, no subscribe, no
    /// resize. The Conversation surface renders them from their Agent stream.
    var conversationSessionIDs: Set<TerminalSessionID> = []
    /// Bumped when a Lead's pending request changes. The attention notifier
    /// reads this instead of the projection, so a question's text can change
    /// without rebuilding the window's Session rows.
    @Published var leadAttentionRevision: UInt64 = 0
    var leadAttentionSignatures: [TerminalSessionID: String] = [:]
    /// Chat Sessions whose agent publishes selectors (`agent-config-v1`), and
    /// those with a provider conversation to hand off (RFC 0023 §6.11, §6.12).
    var conversationConfigSessionIDs: Set<TerminalSessionID> = []
    /// Each stream's latest state events older than its replica window,
    /// from the last subscription, for feeds created after it.
    var conversationStateEventsByStreamID: [String: [WarrenRemoteAgentEvent]] = [:]
    var conversationHandoffSessionIDs: Set<TerminalSessionID> = []
    /// Chat Sessions whose agent advertises `agent-attachments-v1`, so the
    /// composer only offers the file picker where the Host can take an upload.
    var conversationAttachmentSessionIDs: Set<TerminalSessionID> = []
    /// One feed per Conversation surface on screen, fed from the same replica
    /// the activity projection reads. Created on demand so a Host with many
    /// idle ACP Sessions keeps no transcripts in memory.
    var conversationFeeds: [TerminalSessionID: WarrenConversationFeed] = [:]
    /// Client-observed activity history used by the desktop switcher to
    /// prioritize sessions that have just become ready. The daemon status
    /// payload has no transition timestamp, so this is intentionally kept
    /// local to the live application model.
    var lastObservedActivityBySessionID: [TerminalSessionID: AgentActivityState] = [:]
    var activityUpdatedAtBySessionID: [TerminalSessionID: Date] = [:]
    /// What each Session last did, folded from its Agent event stream.
    ///
    /// The daemon roster describes what a Session is, not what it last did, so
    /// this outlives the roster snapshot the same way the activity timestamps
    /// do: a roster rebuild recreates every session value and would otherwise
    /// empty the resting line on every Host change.
    var lastActivityBySessionID: [TerminalSessionID: String] = [:]
    /// The last non-empty primary fact each Session's second line showed while
    /// working. A roster rebuild recreates every Session value, so the sticky
    /// line has to live beside `lastActivityBySessionID` rather than on the value.
    var lastPrimaryLineBySessionID: [TerminalSessionID: String] = [:]
    var agentCompletionTracker = WarrenAgentCompletionTracker()
    let agentCompletionSubject = PassthroughSubject<WarrenAgentCompletionEvent, Never>()
    var activityAcknowledgments = WarrenDesktopActivityAcknowledgments()
    var suppressFramedAnchorUpdates: Set<TerminalSessionID> = []
    /// Sessions with a live daemon-side output subscription feeding their
    /// retained surface. One entry per warm/active surface; background
    /// frames keep these surfaces current so tab promotion stays local.
    var outputSubscriptions: Set<TerminalSessionID> = []
    /// The Desktop root reports presentation state independently of the
    /// transport lifecycle. Retain the latest set so a freshly authenticated
    /// WebSocket receives the report even when reconnecting leaves the visible
    /// Session IDs unchanged and SwiftUI emits no Set change.
    var lastReportedScreenSessions: Set<TerminalSessionID> = []
    /// Background subscriptions are launched from SwiftUI's visibility
    /// callback, which may fire more than once while a split tree is being
    /// mounted. The token prevents duplicate requests and lets a stale task
    /// finish without clearing a newer connection's in-flight marker.
    var backgroundAttachTokens: [TerminalSessionID: UInt64] = [:]
    var nextBackgroundAttachToken: UInt64 = 0
    /// Atomic states accepted by Ghostty but not yet released by the matching
    /// synced marker. The anchor prevents a late marker from an older attach
    /// generation from exposing a newly replaced surface.
    var installedAtomicStateAnchors: [TerminalSessionID: TerminalOutputAnchor] = [:]
    /// Atomic payloads that arrived during the tiny native-surface creation
    /// window. They remain opaque and invisible until the surface reports a
    /// valid viewport; a transient restore failure must never tear down the
    /// whole WebSocket and strand the user on a black pane.
    var pendingAtomicRecoveries: [TerminalSessionID: PendingAtomicRecovery] = [:]
    var pendingSyncedAnchors: [TerminalSessionID: TerminalOutputAnchor] = [:]
    var recoveryRetryTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    var recoveryRetryGenerations: [TerminalSessionID: UInt64] = [:]
    var failedAtomicRecoverySessions: Set<TerminalSessionID> = []
    /// Consecutive `recoveryFailed` events per Session. A failed payload is
    /// retried a bounded number of times and the streak resets only when a
    /// payload installs, so a Host that keeps failing cannot spin.
    var recoveryFailureStreak = RecoveryFailureStreak()
    var recoveryFailureTasks: [TerminalSessionID: Task<Void, Never>] = [:]
    /// Surfaces retained across a transient transport drop and waiting for a
    /// fresh daemon-side output subscription.
    var pendingRetainedSurfaceRebinds: Set<TerminalSessionID> = []
    /// Active surfaces in the above set keep their last presented frame while
    /// the replacement atomic state is installed.
    var reconnectPreservedSessions: Set<TerminalSessionID> = []
    /// Set by `resumeConnectionNow` so a pending backoff wait ends early.
    var reconnectResumeRequested = false
    /// Lifetime-scoped like `terminationObserver`: the model lives as long as
    /// the app, and a nonisolated deinit cannot touch these tokens.
    var wakeObserver: NSObjectProtocol?
    var activationObserver: NSObjectProtocol?
    let pathMonitor = NWPathMonitor()
    var hasSeenNetworkPath = false
    /// Background Host connections live in another model; the composition
    /// root routes the same resume signal to them.
    var onResumeConnection: (() -> Void)?
    var retainedSurfaceRebindTask: Task<Void, Never>?
    var tabOrderByWorkspaceID: [WorkspaceID: [String]] = [:]
    var appliedLiveTabSessionIDs: Set<TerminalSessionID> = []
    /// What the Host kept of each stopped Session's last output, keyed by
    /// Session. Loaded on demand the first time a stopped Tab is opened; a
    /// stopped Session never subscribes to the runtime, so this is its whole
    /// stream.
    @Published var stoppedSessionHistory: [TerminalSessionID: WarrenStoppedSessionHistory] = [:]
    /// The stopped Sessions whose last output was already fed into their surface.
    var stoppedSessionHistoryFed: Set<TerminalSessionID> = []
    /// The stopped Sessions with an action in flight, so the one button they
    /// offer cannot be pressed twice.
    @Published var stoppedSessionActionInFlight: Set<TerminalSessionID> = []
    /// The stopped Tabs that offer Resume, refreshed with the roster. Not
    /// published: it changes only with the projection, which already is.
    var stoppedResumeCandidates: [WarrenDesktopResumeCandidate] = []
    /// Why a stopped Session's one action failed, shown in its banner until the
    /// next attempt.
    @Published var stoppedSessionActionFailure: [TerminalSessionID: String] = [:]
    let surfaceManager: TerminalSurfaceManager
    /// Latest screencast frame per Warren Browser Session. Kept out of the
    /// terminal surface manager because the payload is an image, not VT state.
    let browserFrameStore = WarrenBrowserFrameStore()
    public var onOpenTerminalURL: ((TerminalSessionID, String, TerminalOpenURLKind, String?) -> Bool)?
    var projectionPublicationCount: UInt64 = 0

    /// Events emitted after a roster confirms a newly completed Agent turn.
    /// The publisher does not replay old events to a newly attached client.
    var agentCompletionEvents: AnyPublisher<WarrenAgentCompletionEvent, Never> {
        agentCompletionSubject.eraseToAnyPublisher()
    }

    init(
        surfaceManager: TerminalSurfaceManager = TerminalSurfaceManager(),
        initialNavigationScope: String = "local"
    ) {
        self.surfaceManager = surfaceManager
        let normalizedScope = initialNavigationScope
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = normalizedScope.isEmpty ? "local" : normalizedScope
        self.navigationScope = scope
        self.pendingNavigationScope = scope
        self.navigation = WarrenDesktopNavigationPersistence.restore(scope: scope)
            ?? WarrenDesktopNavigationState(selection: nil, selectedTabID: nil)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Keep termination flushing synchronous: the process may exit before
            // an asynchronous persistence task gets a chance to run.
            self?.flushNavigationPersistence()
        }
        // Sleep freezes the reconnect wait and leaves a socket that still looks
        // connected. Both notifications mean the user is back and expects the
        // terminal to be live, so shorten the wait and verify the transport.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeConnectionNow() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeConnectionNow() }
        }
        // A new route (Wi-Fi to Ethernet, another network, VPN up or down)
        // strands a socket bound to the old one. The monitor reports the
        // current path once on start; that report is not a change.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleNetworkPathUpdate(isSatisfied: isSatisfied) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.warren.desktop.network-monitor"))
        let tabOrders = WarrenDesktopNavigationPersistence.restoreTabOrders(scope: scope)
        self.tabOrderByWorkspaceID = tabOrders.workspace.reduce(into: [:]) { result, entry in
            guard let id = WorkspaceID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    deinit {
        // Best-effort flush: close tab is a focus-loss operation, persistence
        // is allowed to be asynchronous, but termination must not lose the
        // last selection. Synchronous save here is only a few microseconds.
        if let pending = pendingNavigationToPersist {
            WarrenDesktopNavigationPersistence.save(pending, scope: pendingNavigationScope)
        }
        navigationPersistenceTask?.cancel()
        hostProbeTask?.cancel()
        pathMonitor.cancel()
    }

    func scheduleNavigationPersistence() {
        pendingNavigationToPersist = navigation
        pendingNavigationScope = navigationScope
        navigationPersistenceTask?.cancel()
        let pending = navigation
        let scope = navigationScope
        navigationPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch { return }
            guard let self else { return }
            // Coalesce rapid closes: only the latest navigation is persisted.
            // Flush is also triggered on termination (see flushNavigationPersistence).
            WarrenDesktopNavigationPersistence.save(pending, scope: scope)
            if self.pendingNavigationToPersist == pending,
               self.pendingNavigationScope == scope {
                self.pendingNavigationToPersist = nil
            }
            self.navigationPersistenceTask = nil
        }
    }

    func flushNavigationPersistence() {
        navigationPersistenceTask?.cancel()
        navigationPersistenceTask = nil
        if let pending = pendingNavigationToPersist {
            WarrenDesktopNavigationPersistence.save(pending, scope: pendingNavigationScope)
            pendingNavigationToPersist = nil
        } else {
            WarrenDesktopNavigationPersistence.save(navigation, scope: navigationScope)
        }
    }

    func resolvedConnectionConfiguration(
        _ configuration: WarrenRemoteEndpointConfiguration
    ) -> WarrenRemoteEndpointConfiguration {
        guard configuration.isRelay else { return configuration }
        let configuredID = configuration.clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedID = WarrenEndpointCatalog.load().endpoints
            .first(where: { $0.name == configuration.name })?.clientID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID: String
        if let configuredID, !configuredID.isEmpty {
            clientID = configuredID
        } else if let persistedID, !persistedID.isEmpty {
            clientID = persistedID
        } else {
            clientID = UUID().uuidString.lowercased()
        }
        let resolved = configuration.withClientID(clientID)
        if resolved != configuration {
            // Relay capabilities may bind access to client_id. Persist the
            // identity before opening the first socket so retry and token
            // refresh paths all use the same device association.
            try? WarrenEndpointCatalog.upsert(resolved, current: configuration.name)
        }
        return resolved
    }

    func connect(
        _ configuration: WarrenRemoteEndpointConfiguration,
        isLocal: Bool = false
    ) {
        // A click into a passive split pane is routed by AppKit, so the manager
        // reports it here. Selecting that Session moves the input router and
        // the control lease to the pane the user clicked; without this, the
        // keystrokes that follow the click are dropped by the router.
        surfaceManager.onFocusRequested = { [weak self] sessionID in
            self?.selectTab(forSessionID: sessionID)
        }
        // While the Host decides a surface's grid, the pane's own size only
        // reaches the model through this callback; Ghostty's grid reports then
        // describe the PTY and are ignored.
        surfaceManager.onViewportGridChanged = { [weak self] sessionID, size in
            self?.requestViewportSize(sessionID: sessionID, size: size)
        }
        // A promotion that never drew leaves the pane black with no work in
        // flight. Recover it the only way that can rebuild a surface whose
        // native renderer is gone: re-subscribe and install a fresh snapshot.
        // A passive pane is left alone; it takes this path when it is selected.
        surfaceManager.onPresentStalled = { [weak self] sessionID in
            guard let self else { return }
            guard sessionID == self.selectedSessionID else {
                TerminalDiagnostics.logVerbose("present_stalled_passive", [
                    "session": sessionID.description,
                ])
                return
            }
            Task { @MainActor in
                await self.recoverStalledPrimarySession(sessionID)
            }
        }
        surfaceManager.onSurfaceDisposed = { [weak self] sessionID in
            guard let self else { return }
            self.outputAnchors.removeValue(forKey: sessionID)
            self.suppressFramedAnchorUpdates.remove(sessionID)
            self.installedAtomicStateAnchors.removeValue(forKey: sessionID)
            self.clearAtomicRecoveryState(for: sessionID)
            self.failedAtomicRecoverySessions.remove(sessionID)
            self.pendingRetainedSurfaceRebinds.remove(sessionID)
            self.reconnectPreservedSessions.remove(sessionID)
            self.unsubscribeFromOutput(sessionID)
        }
        let resolvedConfiguration = resolvedConnectionConfiguration(configuration)
        if resolvedConfiguration.isRelay,
           let current = endpointConfiguration,
           current != resolvedConfiguration,
           current.hasSameRoute(as: resolvedConfiguration),
           eventTask != nil,
           isLocalEndpoint == isLocal {
            // Only the credentials moved, which is what a Relay refresh does
            // to the catalog while this connection is healthy. Keep the
            // connection and hand the next attempt the new tokens.
            endpointConfiguration = resolvedConfiguration
            return
        }
        guard endpointConfiguration != resolvedConfiguration
            || eventTask == nil
            || isLocalEndpoint != isLocal else {
            // The root view's `.task` can restart on window transitions such
            // as entering full screen. Tearing down and recreating an already
            // healthy connection is both wasteful and the trigger for the
            // terminal teardown deadlock, so keep the live connection instead.
            return
        }
        // Endpoint URLs may be user-supplied and can carry credentials in a
        // query or fragment. Diagnostics only need the stable endpoint name;
        // never put the URL (or a bearer token embedded in it) in logs.
        TerminalDiagnostics.log("remote_connect_begin", ["endpoint": resolvedConfiguration.name])
        disconnect()
        connectionError = nil
        connectionGeneration &+= 1
        let generation = connectionGeneration
        cancelTransientConnectionIssue()
        switchNavigationScope(to: isLocal ? "local" : resolvedConfiguration.name)
        endpointConfiguration = resolvedConfiguration
        activeEndpointConfiguration = nil
        isLocalEndpoint = isLocal
        settingsLoaded = false
        defaultRuntime = nil
        autoOpenShell = false
        autoStartAI = false
        openAIBaseURL = ""
        openAIModel = ""
        openAITitleEnabled = false
        relaySettings = WarrenDesktopRelaySettings()
        lanPairing = WarrenDesktopLANPairing()
        remoteAccess = WarrenDesktopRemoteAccess()
        remoteShare = nil
        isMigratingRuntimeSessions = isLocal
            && WarrenRemoteEndpointConfiguration.localDaemonMigrationInProgress()
        if resolvedConfiguration.url.hasPrefix("http://127.0.0.1:8789"),
           !resolvedConfiguration.token.isEmpty,
           let localBaseURL = URL(string: "http://127.0.0.1:8789/") {
            let url = Self.authenticatedWebURL(localBaseURL, daemonToken: resolvedConfiguration.token)
            let lanURL: URL? = WarrenLANAddress.primaryIPv4().flatMap { ip in
                guard let baseURL = URL(string: "http://\(ip):8789/") else { return nil }
                return Self.authenticatedWebURL(baseURL, daemonToken: resolvedConfiguration.token)
            }
            webStatus = WarrenDesktopWebStatus(
                isRunning: true,
                localURL: url,
                lanURL: lanURL,
                canControl: true
            )
        }
        publishProjectionIfChanged(
            WarrenDesktopProjection
                .empty(host: WarrenDomain.Host(name: isLocal ? "Local" : resolvedConfiguration.name))
                .withConnectionState(.connecting)
        )
        eventTask = Task { @MainActor [weak self] in
            await self?.runConnectionLoop(resolvedConfiguration, generation: generation)
        }
    }

    func disconnect() {
        isMigratingRuntimeSessions = false
        guard eventTask != nil || endpointConfiguration != nil || wire != nil
            || surfaceManager.retainedSurfaceCount > 0 else {
            return
        }
        // Flush pending navigation persistence synchronously before tearing down:
        // close tab is allowed to be asynchronous, but endpoint switch/termination
        // must not lose the last selection within the 50ms debounce window.
        flushNavigationPersistence()
        let disconnectStart = Date()
        let prevEndpoint = endpointConfiguration?.name ?? "none"
        TerminalDiagnostics.log("remote_disconnect_begin", ["endpoint": prevEndpoint, "surfaces": String(surfaceManager.retainedSurfaceCount)])
        connectionGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
        endpointConfiguration = nil
        activeEndpointConfiguration = nil
        isLocalEndpoint = false
        cancelTransientConnectionIssue()
        clearMaintenance()
        embeddedSSHTunnel?.stop()
        embeddedSSHTunnel = nil
        if let wire { Task { await wire.stop() } }
        wire = nil
        currentRoster = nil
        appliedLiveTabSessionIDs.removeAll()
        agentStatusBySessionID.removeAll()
        resetAgentReplicationState()
        lastObservedActivityBySessionID.removeAll()
        activityUpdatedAtBySessionID.removeAll()
        agentCompletionTracker = WarrenAgentCompletionTracker()
        tabOrderByWorkspaceID.removeAll()
        activityAcknowledgments = WarrenDesktopActivityAcknowledgments()
        lastReportedScreenSessions.removeAll()
        creatingSessionWorkspaceIDs.removeAll()
        createdSessionIDsByToken.removeAll()
        clearDeletionState()
        resetAttachmentState()
        webStatus = WarrenDesktopWebStatus()
        relaySettings = WarrenDesktopRelaySettings()
        lanPairing = WarrenDesktopLANPairing()
        remoteAccess = WarrenDesktopRemoteAccess()
        remoteShare = nil
        publishProjectionIfChanged(projection.withConnectionState(.disconnected))
        let ms = Int(Date().timeIntervalSince(disconnectStart) * 1000)
        TerminalDiagnostics.log("remote_disconnect_end", ["endpoint": prevEndpoint, "duration_ms": String(ms)])
    }

    /// Shortens a pending reconnect wait and verifies a socket that still looks
    /// alive. Wake from sleep and network changes both invalidate the delay the
    /// backoff computed before the environment changed: a Mac that slept for an
    /// hour would otherwise sit out the full ceiling, and its socket usually
    /// reports connected until the first write fails.
    func handleNetworkPathUpdate(isSatisfied: Bool) {
        let isChange = hasSeenNetworkPath
        hasSeenNetworkPath = true
        guard isChange, isSatisfied else { return }
        resumeConnectionNow()
    }

    func resumeConnectionNow() {
        reconnectResumeRequested = true
        onResumeConnection?()
        guard let wire else { return }
        Task { await wire.probeConnection() }
    }

    /// Waits before the next reconnect attempt in slices so `resumeConnectionNow`
    /// can end the wait early. Returns true when a resume cut the wait short.
    func waitBeforeReconnect(milliseconds: Int) async -> Bool {
        reconnectResumeRequested = false
        var remaining = max(0, milliseconds)
        while remaining > 0 {
            if Task.isCancelled { return false }
            if reconnectResumeRequested {
                reconnectResumeRequested = false
                return true
            }
            let step = min(Self.reconnectWaitSlice, remaining)
            do {
                try await Task.sleep(for: .milliseconds(step))
            } catch {
                return false
            }
            remaining -= step
        }
        if reconnectResumeRequested {
            reconnectResumeRequested = false
            return true
        }
        return false
    }

    /// Retries the currently selected endpoint after a terminal connection
    /// failure. Keeping this explicit avoids an unbounded retry loop and gives
    /// keyboard/accessibility clients a deterministic action target.
    func retryConnection() {
        guard let configuration = endpointConfiguration else { return }
        let local = isLocalEndpoint
        disconnect()
        connect(configuration, isLocal: local)
    }

    /// Publishes a terminal connection failure for callers that could not
    /// create a transport yet (for example, the local daemon token is absent).
    /// Keeping this on the model gives the endpoint popover a deterministic
    /// failed state and makes its Retry action usable for that path too.
    func markConnectionFailed(_ error: Error) {
        failConnection(error)
    }

    /// Updates the projection while a local daemon token is still being
    /// published. There is no wire/event task yet in that window, so the
    /// regular connect loop cannot provide the loading state itself.
    func markConnectionConnecting() {
        isMigratingRuntimeSessions = WarrenRemoteEndpointConfiguration.localDaemonMigrationInProgress()
        publishProjectionIfChanged(projection.withConnectionState(.connecting))
    }

    /// Refreshes the local migration journal while the Desktop is waiting for
    /// the daemon token. The daemon can create the journal just after the app
    /// begins its startup wait, so a one-time read would miss that transition.
    func refreshLocalRuntimeMigrationStatus() {
        let inProgress = WarrenRemoteEndpointConfiguration.localDaemonMigrationInProgress()
        if isMigratingRuntimeSessions != inProgress {
            isMigratingRuntimeSessions = inProgress
        }
    }

    /// Stops either an active transport or a pending pre-transport wait. The
    /// latter has no endpointConfiguration/eventTask for `disconnect()` to
    /// tear down, but it still needs a stable state so the Stop action does
    /// not leave the popover stuck on Connecting….
    func stopConnection() {
        disconnect()
        publishProjectionIfChanged(projection.withConnectionState(.disconnected))
    }

    func isConnected(to configuration: WarrenRemoteEndpointConfiguration) -> Bool {
        endpointConfiguration == configuration && eventTask != nil
    }

    /// Returns true only after the foreground transport for the requested
    /// Endpoint has produced an attached projection. A stale projection from
    /// the previously selected Host may briefly remain available while an
    /// endpoint switch is being reconciled, so callers must not use
    /// `projection.isConnected` alone for scoped activation.
    func isReady(for endpointID: String) -> Bool {
        let normalized = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = normalized.isEmpty ? "local" : normalized
        guard projection.isConnected, eventTask != nil, let endpointConfiguration else {
            return false
        }
        if isLocalEndpoint {
            return expected == "local"
        }
        return endpointConfiguration.name == expected
    }

    /// Keeps the endpoint alive across daemon restarts and transient network
    /// failures. A fresh wire is created per attempt; the old wire's event
    /// stream is finished by `close()` so it can never be reused.
    func runConnectionLoop(
        _ configuration: WarrenRemoteEndpointConfiguration,
        generation: UInt64
    ) async {
        var attempt = 0
        while !Task.isCancelled, isCurrentConnection(configuration, generation: generation) {
            // A Relay refresh during the last attempt left newer tokens on
            // the endpoint; dialing with the ones this loop started with would
            // present a refresh token the Relay already rotated.
            let latestConfiguration = endpointConfiguration ?? configuration
            var wireConfiguration = latestConfiguration
            var tunnel: WarrenEmbeddedSSHTunnel?
            var helper: WarrenEmbeddedSSHTunnel?
            defer {
                tunnel?.stop()
                if let helper, embeddedSSHTunnel === helper {
                    embeddedSSHTunnel = nil
                }
            }
            if let target = configuration.ssh, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let embedded = WarrenEmbeddedSSHTunnel()
                helper = embedded
                embeddedSSHTunnel = embedded
                do {
                    wireConfiguration = try await embedded.start(
                        name: configuration.name,
                        target: target,
                        remoteAddress: configuration.sshRemote
                    )
                    tunnel = embedded
                } catch {
                    guard !Task.isCancelled, isCurrentConnection(configuration, generation: generation) else { return }
                    if Self.isPermanentConnectionError(error)
                        || attempt >= Self.maxReconnectAttempts - 1 {
                        failConnection(error)
                        return
                    }
                    if attempt == 0, maintenanceMessage == nil { present(error) }
                    resetAttachmentState(preserveMountedSurfaces: true)
                    publishProjectionIfChanged(projection.withConnectionState(.reconnecting))
                    let delay = Self.reconnectDelay(attempt: attempt)
                    attempt += 1
                    // A wake or network change is a new opportunity, not a
                    // continuation of the failed sequence: retry at once and
                    // give the endpoint a fresh attempt budget.
                    if await waitBeforeReconnect(milliseconds: delay) { attempt = 0 }
                    continue
                }
            }
            guard isCurrentConnection(configuration, generation: generation) else {
                return
            }
            activeEndpointConfiguration = wireConfiguration
            let isSSHEndpoint = configuration.ssh?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            let isSyntheticLocal = isLocalEndpoint
            // SSH helpers provide an ephemeral loopback URL and token. Keep
            // refresh callbacks anchored to the durable alias so a token
            // rotation cannot replace SSH metadata with that runtime route.
            let persistedConfiguration = isSSHEndpoint
                ? latestConfiguration
                : wireConfiguration
            let wire = WarrenRemoteClient(
                configuration: wireConfiguration,
                terminalStateFormats: [WarrenRemoteClient.snapshotTerminalStateFormat],
                // The Desktop subscribes every roster stream at once. Without
                // this each subscribe replaced the last, so only one Agent's
                // events stayed live on the connection.
                // The Desktop lays each Ghostty grid out from the Host's size
                // reports, so output written for one PTY size is never parsed
                // against another.
                additionalCapabilities: [
                    WarrenRemoteAgentCapability.streams,
                    WarrenRemoteCapability.terminalSize,
                ],
                tokenUpdateHandler: { accessToken, refreshToken in
                    guard !isSyntheticLocal else { return }
                    let updated = persistedConfiguration.withTokens(
                        token: accessToken,
                        refreshToken: refreshToken
                    )
                    // Token rotation updates endpoint metadata only. Do not
                    // rewrite `current`: this callback can finish after the
                    // user has switched Hosts, and selecting the old alias
                    // would race the shared catalog monitor.
                    try? WarrenEndpointCatalog.upsert(updated)
                },
                // Only a Relay credential is final: a direct daemon token can be
                // rewritten under the client (the local token file, an SSH
                // bootstrap), and the next attempt picks the new one up.
                stopsWhenCredentialsRejected: wireConfiguration.isRelay
            )
            self.wire = wire
            let events = wire.events()
            var disconnectReason: String?
            await wire.start()
            // A daemon restart clears its tunnel state, so refresh the
            // projection on every (re)connect to keep the top-bar tunnel
            // indicator truthful. Do not hold the initial roster behind
            // this optional five-second request.
            let tunnelStatusTask = Task { @MainActor [weak self] in
                await self?.refreshTunnelStatus()
            }
            defer { tunnelStatusTask.cancel() }
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .connection(.connected) = event {
                    attempt = 0
                    // A reconnect creates a new authenticated peer whose screen
                    // telemetry starts empty. Re-send the latest Desktop set even
                    // when the visible Session IDs did not change.
                    let reportedScreenSessions = self.lastReportedScreenSessions
                    self.sendScreenReport(reportedScreenSessions, using: wire)
                }
                if case .credentialsRejected = event {
                    // The Relay refused this Mac and the refresh capability is
                    // gone too. Retrying cannot recover; only a new pairing can.
                    await wire.stop()
                    failConnection(NSError(
                        domain: "WarrenRemote", code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "\(configuration.name) no longer accepts this Mac. Pair it again from a new pairing code."]
                    ))
                    return
                }
                if let tunnel, !tunnel.isRunning, Self.isConnectionLoss(event) {
                    // The SSH helper exits when its connection drops, after a
                    // sleep or a network change. The client would keep dialing
                    // the dead loopback port forever, so end this wire and let
                    // the next attempt build a new tunnel.
                    disconnectReason = "ssh_tunnel_exited"
                    break
                }
                if case .disconnected(let reason) = event {
                    disconnectReason = reason
                    if Self.isUpgradeFailure(reason) {
                        await wire.stop()
                        failConnection(NSError(
                            domain: "WarrenRemote", code: 31,
                            userInfo: [NSLocalizedDescriptionKey: reason]
                        ))
                        return
                    }
                }
                await consume(event)
            }
            // Invalidate request tasks before closing the old wire. Otherwise
            // a late cancellation can report an error against a new
            // connection, and a deletion that cannot be observed anymore can
            // leave its local spinner pending forever.
            let wasCurrentWire = self.wire === wire
            if wasCurrentWire {
                self.wire = nil
                stopDeletionReconciliation()
            }
            await wire.stop()
            if activeEndpointConfiguration == wireConfiguration {
                activeEndpointConfiguration = nil
            }
            guard !Task.isCancelled, isCurrentConnection(configuration, generation: generation) else { return }
            TerminalDiagnostics.log("remote_transport_disconnected", [
                "endpoint": configuration.name,
                "reason": disconnectReason ?? "event_stream_ended",
                "surfaces": String(surfaceManager.retainedSurfaceCount),
            ])
            resetAttachmentState(preserveMountedSurfaces: true)
            publishProjectionIfChanged(projection.withConnectionState(.reconnecting))
            if attempt >= Self.maxReconnectAttempts - 1 {
                failConnection(NSError(
                    domain: "WarrenRemote",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "The connection could not be restored after several attempts."]
                ))
                return
            }
            let delay = Self.reconnectDelay(attempt: attempt)
            attempt += 1
            if await waitBeforeReconnect(milliseconds: delay) { attempt = 0 }
        }
        if isCurrentConnection(configuration, generation: generation) {
            eventTask = nil
            activeEndpointConfiguration = nil
            embeddedSSHTunnel = nil
        }
    }

    func isCurrentConnection(
        _ configuration: WarrenRemoteEndpointConfiguration,
        generation: UInt64
    ) -> Bool {
        connectionGeneration == generation
            && endpointConfiguration?.hasSameRoute(as: configuration) == true
    }

    /// Returns the configuration that can reach the daemon right now. Direct
    /// endpoints are usable as soon as they are selected; SSH endpoints only
    /// become usable after the helper has supplied a live loopback URL/token.
    var liveEndpointConfiguration: WarrenRemoteEndpointConfiguration? {
        if let activeEndpointConfiguration {
            return activeEndpointConfiguration
        }
        guard let endpointConfiguration, endpointConfiguration.ssh == nil else {
            return nil
        }
        return endpointConfiguration
    }

    /// Drops client-side attachment state so the next roster re-attaches the
    /// selected tab on a fresh transport. A transient reconnect keeps the
    /// native surfaces and their last completed frame; an explicit endpoint
    /// teardown still disposes every surface.
    func resetAttachmentState(preserveMountedSurfaces: Bool = false) {
        resetAgentReplicationState()
        retainedSurfaceRebindTask?.cancel()
        retainedSurfaceRebindTask = nil
        let retainedSurfaceIDs: Set<TerminalSessionID>
        if preserveMountedSurfaces {
            let snapshot = surfaceManager.snapshot()
            var ids = snapshot.warmSessionIDs
            if let active = snapshot.activeSessionID {
                ids.append(active)
            }
            retainedSurfaceIDs = Set(ids)
        } else {
            retainedSurfaceIDs = []
        }
        TerminalDiagnostics.log("remote_attachment_reset", [
            "preserveSurfaces": preserveMountedSurfaces ? "true" : "false",
            "surfaces": String(retainedSurfaceIDs.count),
        ])
        pendingRetainedSurfaceRebinds = retainedSurfaceIDs
        reconnectPreservedSessions = preserveMountedSurfaces ? retainedSurfaceIDs : []
        let previousSessionID = selectedSessionID
        attachingSessionID = nil
        selectedSessionID = nil
        attachedSessionID = nil
        focusedSessionID = nil
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        if let previousSessionID {
            inputRouter.discard(for: previousSessionID)
        }
        initialRefreshPending = false
        attachGeneration &+= 1
        outputAnchors = outputAnchors.filter { retainedSurfaceIDs.contains($0.key) }
        suppressFramedAnchorUpdates.removeAll()
        noteOutputSubscriptionsCleared(reason: "resetAttachmentState")
        for task in recoveryFailureTasks.values {
            task.cancel()
        }
        recoveryFailureTasks.removeAll()
        recoveryFailureStreak.clearAll()
        backgroundAttachTokens.removeAll()
        installedAtomicStateAnchors.removeAll()
        cancelAllAtomicRecoveryRetries()
        pendingAtomicRecoveries.removeAll()
        pendingSyncedAnchors.removeAll()
        failedAtomicRecoverySessions.removeAll()
        cancelResizeRequests()
        cancelPassiveResizeRequests()
        visibleSessionIDs.removeAll()
        focusTask?.cancel()
        focusTask = nil
        if !preserveMountedSurfaces {
            shutdownAllMountedSurfaces()
        } else {
            for sessionID in retainedSurfaceIDs {
                surfaceManager.cancelRecovery(
                    for: sessionID,
                    preservingDisplay: reconnectPreservedSessions.contains(sessionID)
                )
            }
        }
    }

    func resetAgentReplicationState() {
        for task in agentSubscriptionTasks.values {
            task.cancel()
        }
        agentSubscriptionTasks.removeAll()
        agentNamespace = nil
        agentSessionByStreamID.removeAll()
        agentSubscribedStreamIDs.removeAll()
        agentQuarantinedStreamIDs.removeAll()
        agentProjectionSequenceByStreamID.removeAll()
        agentPendingProjectionByStreamID.removeAll()
        agentCurrentStepByStreamID.removeAll()
        agentInteractionEventsByStreamID.removeAll()
        agentOpenDecisionByStreamID.removeAll()
        publishPendingDecisions()
    }

    func shutdownAllMountedSurfaces() {
        surfaceManager.shutdown()
        appliedLiveTabSessionIDs.removeAll()
        outputAnchors.removeAll()
        suppressFramedAnchorUpdates.removeAll()
        noteOutputSubscriptionsCleared(reason: "shutdownAllMountedSurfaces")
        for task in recoveryFailureTasks.values {
            task.cancel()
        }
        recoveryFailureTasks.removeAll()
        recoveryFailureStreak.clearAll()
        backgroundAttachTokens.removeAll()
        installedAtomicStateAnchors.removeAll()
        cancelAllAtomicRecoveryRetries()
        pendingAtomicRecoveries.removeAll()
        pendingSyncedAnchors.removeAll()
        failedAtomicRecoverySessions.removeAll()
        cancelPassiveResizeRequests()
        visibleSessionIDs.removeAll()
    }

    func removeMountedSurface(sessionID: TerminalSessionID) {
        surfaceManager.remove(sessionID)
        recoveryFailureStreak.clear(sessionID)
        recoveryFailureTasks.removeValue(forKey: sessionID)?.cancel()
        outputAnchors.removeValue(forKey: sessionID)
        suppressFramedAnchorUpdates.remove(sessionID)
        installedAtomicStateAnchors.removeValue(forKey: sessionID)
        clearAtomicRecoveryState(for: sessionID)
        failedAtomicRecoverySessions.remove(sessionID)
        pendingRetainedSurfaceRebinds.remove(sessionID)
        reconnectPreservedSessions.remove(sessionID)
        noteOutputSubscriptionDropped(sessionID, reason: "removeMountedSurface")
    }

    func clearAtomicRecoveryState(for sessionID: TerminalSessionID) {
        pendingAtomicRecoveries.removeValue(forKey: sessionID)
        pendingSyncedAnchors.removeValue(forKey: sessionID)
        recoveryRetryGenerations[sessionID, default: 0] &+= 1
        recoveryRetryTasks.removeValue(forKey: sessionID)?.cancel()
    }

    func cancelAllAtomicRecoveryRetries() {
        for task in recoveryRetryTasks.values {
            task.cancel()
        }
        recoveryRetryTasks.removeAll()
        for sessionID in recoveryRetryGenerations.keys {
            recoveryRetryGenerations[sessionID, default: 0] &+= 1
        }
    }

    /// Best-effort daemon-side unsubscribe for a disposed surface. The
    /// Records the add and drop of a Session's output subscription.
    ///
    /// Ordinary navigation reparents a retained surface and reuses its
    /// subscription, so a subscription that disappears silently turns the next
    /// selection into a full re-seed (a re-subscribe answers with a complete
    /// atomic state, and installing that repaints the pane). These events name
    /// the call site on both sides so that chain is traceable without guessing.
    func noteOutputSubscriptionAdded(_ sessionID: TerminalSessionID, reason: String) {
        // Deliberately leaves the recovery-failure streak alone: this is only
        // the acknowledgement of a subscribe, and the Host sends it before it
        // builds the recovery payload. Clearing the streak here made a Host
        // that kept failing look freshly attached on every retry, so the
        // bounded retry never exhausted and the pane never showed an error.
        guard !outputSubscriptions.contains(sessionID) else { return }
        outputSubscriptions.insert(sessionID)
        TerminalDiagnostics.log("output_subscription_added", [
            "session": sessionID.description,
            "reason": reason,
            "count": String(outputSubscriptions.count),
        ])
    }

    func noteOutputSubscriptionDropped(_ sessionID: TerminalSessionID, reason: String) {
        guard outputSubscriptions.remove(sessionID) != nil else { return }
        TerminalDiagnostics.log("output_subscription_dropped", [
            "session": sessionID.description,
            "reason": reason,
            "count": String(outputSubscriptions.count),
        ])
    }

    func noteOutputSubscriptionsCleared(reason: String) {
        guard !outputSubscriptions.isEmpty else { return }
        TerminalDiagnostics.log("output_subscriptions_cleared", [
            "reason": reason,
            "count": String(outputSubscriptions.count),
            "sessions": outputSubscriptions.map(\.description).sorted().joined(separator: ","),
        ])
        outputSubscriptions.removeAll()
    }

    /// daemon also cleans up when the session exits or the socket drops, so
    /// failures are deliberately ignored.
    func unsubscribeFromOutput(_ sessionID: TerminalSessionID) {
        guard wire != nil else { return }
        guard outputSubscriptions.contains(sessionID) else { return }
        noteOutputSubscriptionDropped(sessionID, reason: "unsubscribeFromOutput")
        Task { [weak self] in
            _ = try? await self?.wire?.request(
                "session.unsubscribe",
                params: ["id": sessionID.description]
            )
        }
    }

    func clearMaintenance() {
        maintenanceResetTask?.cancel()
        maintenanceResetTask = nil
        maintenanceMessage = nil
    }

    /// Exponential backoff matching the Web client: 500ms doubling to 30s.
    nonisolated static func reconnectDelay(attempt: Int) -> Int {
        let bounded = min(max(attempt, 0), 6)
        return min(30_000, 500 * (1 << bounded))
    }

    func createTask(_ creation: WarrenDesktopTaskCreationRequest) async throws -> TaskID {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let request = WarrenRemoteTaskProtocol.createRequest(creation)
        let data = try await wire.request(request.method, params: request.params)
        return try WarrenRemoteTaskProtocol.taskID(from: data)
    }

    nonisolated static func isPermanentConnectionError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let permanentMarkers = [
            "host key verification failed",
            "known_hosts",
            "known hosts",
            "no ssh authentication method",
            "unable to authenticate",
            "remote authentication failed",
            "rejected the bootstrap token",
            "ssh identity",
            "warren-ssh-tunnel",
            "embedded ssh helper is not installed",
            "warren-headless is not installed",
            "proxyjump",
            "proxycommand",
            "invalid ssh",
            "invalid local ssh",
            "remote warren address",
            "strict host-key verification",
            "remote warren returned an invalid token",
        ]
        return permanentMarkers.contains(where: message.contains)
    }

    nonisolated static func isUpgradeFailure(_ reason: String) -> Bool {
        let message = reason.lowercased()
        return message.contains("protocol mismatch")
            || message.contains("incompatible protocol version:")
            || message.contains("upgrade required:")
            || message.contains("unsupported terminal state format")
    }

    nonisolated static func isConnectionLoss(_ event: WarrenRemoteEvent) -> Bool {
        switch event {
        case .disconnected, .connection(.reconnecting), .connection(.disconnected):
            return true
        default:
            return false
        }
    }

    func failConnection(_ error: Error) {
        connectionError = error.localizedDescription
        presentDiagnostic(error)
        cancelTransientConnectionIssue()
        // A permanent/authentication failure is no longer a reconnect window;
        // release retained native surfaces so a later endpoint selection starts
        // from a clean attachment generation.
        resetAttachmentState()
        if let wire {
            self.wire = nil
            Task { await wire.stop() }
        }
        activeEndpointConfiguration = nil
        isMigratingRuntimeSessions = false
        eventTask = nil
        publishProjectionIfChanged(projection.withConnectionState(.failed))
    }

    func createWorkspace(
        projectID: ProjectID,
        taskID: TaskID? = nil,
        request creation: WorkspaceCreationRequest
    ) async throws {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        _ = try await wire.request(
            "workspace.create",
            params: WarrenRemoteWorkspaceProtocol.createParameters(
                projectID: projectID,
                taskID: taskID,
                creation: creation
            )
        )
    }

    /// Fetches usage stats for the trailing `days` window, optionally scoped to
    /// one detail day.
    ///
    /// Each call replaces the previous result rather than merging: the panel
    /// shows one range at a time, and a stale range blended into a new one
    /// would produce totals that match neither. A response whose generation is
    /// no longer current is dropped, so a range change made while a load is in
    /// flight still ends with the figures the picker describes.
    func loadUsageStats(days: Int, selectedDay: String? = nil, force: Bool = false) {
        guard let wire else {
            usageState = .failed("Not connected to a Host.")
            return
        }
        let request = WarrenUsageStatsRequest.window(days: days, selectedDay: selectedDay)

        if !force, usageLoadedKey == request.cacheKey, let loadedAt = usageLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.usageCacheLifetime {
            return
        }

        usageRequestGeneration += 1
        let generation = usageRequestGeneration
        usageState = .loading

        Task { @MainActor [weak self] in
            do {
                let response: WarrenUsageStatsResponse = try await wire.request(
                    "usage.stats",
                    params: request.parameters
                )
                guard let self, self.usageRequestGeneration == generation else { return }
                self.usageStats = response.model
                self.usageState = .loaded
                self.usageLoadedKey = request.cacheKey
                self.usageLoadedAt = Date()
            } catch {
                guard let self, self.usageRequestGeneration == generation else { return }
                self.usageState = .failed(error.localizedDescription)
            }
        }
    }

    /// Explicitly replaces the Host's derived Usage tables from retained Agent
    /// history. The Host leaves the canonical journal and all other databases
    /// untouched; the settings surface asks for confirmation before calling.
    func rebuildUsageData(
        completion: @escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void = { _ in }
    ) {
        guard let wire else {
            let error = NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not connected to a Host.",
            ])
            completion(.failure(error))
            return
        }
        Task { @MainActor [weak self] in
            do {
                // Historical transcript scans are Host-owned background work;
                // the transport applies the method's no-timeout policy so a
                // healthy rebuild cannot look like a failure after 15 seconds.
                let response: WarrenUsageRebuildResponse = try await wire.request("usage.rebuild")
                completion(.success(response.model))
            } catch {
                self?.present(error)
                completion(.failure(error))
            }
        }
    }

    func loadSettings() {
        guard !settingsLoaded, let wire else { return }
        settingsLoaded = true
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("settings.get")
                self?.applySettingsResponse(data)
            } catch {
                // Settings are not critical; the picker keeps its default.
            }
        }
    }

    func applySettingsResponse(_ data: Data) {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let kind = result["defaultRuntime"] as? String {
            defaultRuntime = kind
        }
        if let enabled = result["autoOpenShell"] as? Bool {
            autoOpenShell = enabled
        }
        if let enabled = result["autoStartAI"] as? Bool {
            autoStartAI = enabled
        }
        if let baseURL = result["openaiBaseURL"] as? String {
            openAIBaseURL = baseURL
        }
        if let model = result["openaiModel"] as? String {
            openAIModel = model
        }
        if let enabled = result["openaiTitleEnabled"] as? Bool {
            openAITitleEnabled = enabled
        }
        if let relay = result["relay"] as? [String: Any] {
            relaySettings = Self.relaySettings(from: relay)
            loadRelayDevices()
        }
        if let pairing = result["pairing"] as? [String: Any] {
            lanPairing = Self.lanPairing(from: pairing)
        }
    }

    static func relaySettings(from value: [String: Any]) -> WarrenDesktopRelaySettings {
        WarrenDesktopRelaySettings(
            enabled: value["enabled"] as? Bool ?? false,
            relayURL: (value["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            hostID: (value["hostID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            routeID: (value["routeID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            relayKeyID: (value["relayKeyID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            relayPublicKey: (value["relayKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            lastError: (value["lastError"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func lanPairing(from value: [String: Any]) -> WarrenDesktopLANPairing {
        let expiresIn: Int
        if let number = value["expiresIn"] as? NSNumber {
            expiresIn = number.intValue
        } else if let integer = value["expiresIn"] as? Int {
            expiresIn = integer
        } else {
            expiresIn = 0
        }
        return WarrenDesktopLANPairing(
            enabled: value["enabled"] as? Bool ?? false,
            pin: (value["pin"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: parseISO8601Date(value["expiresAt"] as? String),
            expiresIn: max(0, expiresIn)
        )
    }

    func setDefaultRuntime(_ kind: String) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["defaultRuntime": kind])
                self?.defaultRuntime = kind
            } catch {
                self?.present(error)
            }
        }
    }

    func setAutoOpenShell(_ enabled: Bool) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["autoOpenShell": enabled ? "true" : "false"])
                self?.autoOpenShell = enabled
            } catch {
                self?.present(error)
            }
        }
    }

    func setAutoStartAI(_ enabled: Bool) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: ["autoStartAI": enabled ? "true" : "false"])
                self?.autoStartAI = enabled
            } catch {
                self?.present(error)
            }
        }
    }

    func enableLANPairing(
        completion: @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void = { _ in }
    ) {
        updateLANPairing(method: "pairing.enable", completion: completion)
    }

    func disableLANPairing(
        completion: @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void = { _ in }
    ) {
        updateLANPairing(method: "pairing.disable", completion: completion)
    }

    func refreshLANPairing(
        completion: @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void = { _ in }
    ) {
        updateLANPairing(method: "pairing.status", completion: completion)
    }

    func updateLANPairing(
        method: String,
        completion: @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void
    ) {
        guard let wire else {
            let error = NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])
            completion(.failure(error))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request(method)
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "WarrenRemote", code: 14, userInfo: [
                        NSLocalizedDescriptionKey: "The daemon returned an invalid LAN pairing status.",
                    ])
                }
                let pairing = Self.lanPairing(from: value)
                self?.lanPairing = pairing
                completion(.success(pairing))
            } catch {
                self?.present(error)
                completion(.failure(error))
            }
        }
    }

    func setOpenAISetting(_ key: String, _ value: String) {
        guard ["openaiBaseURL", "openaiModel", "openaiKey", "openaiTitleEnabled"].contains(key),
              let wire else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("settings.put", params: [key: value])
                guard let self else { return }
                switch key {
                case "openaiBaseURL": self.openAIBaseURL = value
                case "openaiModel": self.openAIModel = value
                case "openaiTitleEnabled": self.openAITitleEnabled = value == "true"
                default: break // The API key is intentionally never retained by clients.
                }
            } catch {
                self?.present(error)
            }
        }
    }

    func loadRelayDevices() {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            // Only attempt to load devices if Relay is configured (URL + Host ID).
            guard let relaySettings = self?.relaySettings,
                  relaySettings.isEnrolled else {
                self?.relayDevices = []
                return
            }
            do {
                let data = try await wire.request("relay.devices.list")
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let values = object["devices"] as? [[String: Any]] else { return }
                self?.relayDevices = values.compactMap { value in
                    guard let id = value["id"] as? String else { return nil }
                    let created = Self.parseISO8601Date(value["created_at"] as? String)
                    let lastSeen = Self.parseISO8601Date(value["last_seen_at"] as? String) ?? created
                    return WarrenDesktopRelayDevice(id: id, clientID: value["client_id"] as? String ?? "", createdAt: created, lastSeenAt: lastSeen)
                }
            } catch { self?.present(error) }
        }
    }

    func revokeRelayDevice(_ deviceID: String, completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard let wire else { completion(.failure(NSError(domain: "WarrenRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected daemon is not connected."]))); return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("relay.devices.revoke", params: ["deviceID": deviceID])
                self?.relayDevices.removeAll { $0.id == deviceID }
                completion(.success(()))
            } catch { self?.present(error); completion(.failure(error)) }
        }
    }

    /// Clears local Relay enrollment and stops the connector. The Host record
    /// on Relay is intentionally not revoked; that operation requires a Relay
    /// administrator token and remains an explicit Relay management action.
    /// Turns the enrolled Relay on or off. Enrollment is kept either way: the
    /// switch is the tunnel's lifecycle, not the Host's membership.
    func setRelayEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard let wire else {
            let error = NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])
            completion(.failure(error))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request(
                    "relay.enabled",
                    params: ["enabled": enabled ? "true" : "false"]
                )
                self?.applySettingsResponse(data)
                completion(.success(()))
            } catch {
                self?.present(error)
                completion(.failure(error))
            }
        }
    }

    // MARK: - Remote access (serverless relay)

    /// Reads the Host's serverless remote access state. Failures are recorded on
    /// the projection rather than presented: this runs whenever the page opens
    /// and after every action, and an old daemon without the API is a state to
    /// show, not a dialog to dismiss.
    func loadRemoteAccess() {
        guard let wire else {
            remoteAccess = WarrenDesktopRemoteAccess()
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("remote.status")
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }
                self?.remoteAccess = Self.remoteAccess(from: value)
            } catch {
                self?.remoteAccess.lastError = error.localizedDescription
            }
        }
    }

    func setRemoteAccessEnabled(_ enabled: Bool) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request(enabled ? "remote.enable" : "remote.disable")
                if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.remoteAccess = Self.remoteAccess(from: value)
                }
            } catch {
                self?.present(error)
            }
            self?.loadRemoteAccess()
        }
    }

    /// Moves serverless remote access to another relay and turns it on:
    /// "default" for the build's relay, or a relay URL the Host should carry.
    func setRemoteRelay(_ relayURL: String) {
        guard let wire else { return }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("remote.enable", params: ["relayUrl": relayURL])
                if let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self?.remoteAccess = Self.remoteAccess(from: value)
                }
            } catch {
                self?.present(error)
            }
            self?.loadRemoteAccess()
        }
    }

    func createRemoteShare(
        completion: @escaping (Result<WarrenDesktopRemoteShare, Error>) -> Void
    ) {
        guard let wire else {
            completion(.failure(NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("remote.share")
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let link = value["link"] as? String,
                      let url = URL(string: link) else {
                    throw NSError(domain: "WarrenRemote", code: 14, userInfo: [
                        NSLocalizedDescriptionKey: "The daemon returned no share link.",
                    ])
                }
                let share = WarrenDesktopRemoteShare(
                    url: url,
                    webURL: (value["webLink"] as? String).flatMap(URL.init(string:)),
                    expiresAt: Self.remoteShareExpiry(value),
                    expiresIn: (value["expiresIn"] as? NSNumber)?.intValue ?? 0
                )
                self?.remoteShare = share
                completion(.success(share))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func rotateRemoteCode(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let wire else {
            completion(.failure(NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])))
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("remote.rotate")
                self?.remoteShare = nil
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
            self?.loadRemoteAccess()
        }
    }

    static func remoteAccess(from value: [String: Any]) -> WarrenDesktopRemoteAccess {
        var projection = WarrenDesktopRemoteAccess()
        projection.enabled = value["enabled"] as? Bool ?? false
        projection.connected = value["connected"] as? Bool ?? false
        projection.state = (value["state"] as? String ?? "disabled")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projection.relayURL = (value["relayURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projection.relaySource = (value["relaySource"] as? String ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projection.configuredRelayURL = (value["configuredRelayURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projection.defaultRelayURL = (value["defaultRelayURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projection.devices = (value["devices"] as? NSNumber)?.intValue ?? 0
        projection.lastError = (value["lastError"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return projection
    }

    static func remoteShareExpiry(_ value: [String: Any]) -> Date? {
        guard let raw = value["expiresAt"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    func resetRelay(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard let configuration = endpointConfiguration else {
            let error = NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No daemon endpoint is selected.",
            ])
            completion(.failure(error))
            return
        }
        guard configuration.type.lowercased() != "relay" else {
            let error = NSError(domain: "WarrenRemote", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Relay enrollment must be reset from the Host daemon, not a Relay endpoint.",
            ])
            completion(.failure(error))
            return
        }
        guard let wire else {
            let error = NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])
            completion(.failure(error))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("relay.reset")
                self?.settingsLoaded = true
                self?.applySettingsResponse(data)
                self?.relaySettings = WarrenDesktopRelaySettings()
                self?.clearPublicAccessAfterRelayReset()
                completion(.success(()))
            } catch {
                self?.present(error)
                completion(.failure(error))
            }
        }
    }

    /// Asks the selected Host daemon to create a reusable client-facing Relay
    /// invite. The daemon keeps the Host Secret and pairing code internal; the
    /// Desktop receives only an opaque URL suitable for copying or QR display.
    func createRelayInvite(
        completion: @escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void = { _ in }
    ) {
        guard let configuration = endpointConfiguration else {
            completion(.failure(NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No daemon endpoint is selected.",
            ])))
            return
        }
        guard configuration.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "relay" else {
            completion(.failure(NSError(domain: "WarrenRemote", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Create a pairing link from the Host daemon, not a Relay endpoint.",
            ])))
            return
        }
        guard let wire else {
            completion(.failure(NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected daemon is not connected.",
            ])))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request("relay.pairing")
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawURL = value["pairing_url"] as? String,
                      let url = URL(string: rawURL),
                      (url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"),
                      url.host != nil else {
                    throw NSError(domain: "WarrenRemote", code: 13, userInfo: [
                        NSLocalizedDescriptionKey: "Relay returned an invalid pairing link.",
                    ])
                }
                let expiresIn: Int
                if let number = value["expires_in"] as? NSNumber {
                    expiresIn = number.intValue
                } else {
                    expiresIn = 0
                }
                let expiresAt = Self.parseISO8601Date(value["expires_at"] as? String)
                completion(.success(WarrenDesktopRelayInvite(url: url, expiresAt: expiresAt, expiresIn: expiresIn)))
            } catch {
                self?.present(error)
                completion(.failure(error))
            }
        }
    }

    // ISO8601DateFormatter is safe to share across threads once configured.
    nonisolated(unsafe) private static let fractionalISO8601DateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601DateFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Relay and daemon timestamps are RFC 3339 values with optional
    /// fractional seconds. Keep one parser so every remote date accepts both
    /// forms and malformed values remain explicitly unknown to the caller.
    nonisolated static func parseISO8601Date(_ rawValue: String?) -> Date? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return fractionalISO8601DateFormatter.date(from: value)
            ?? iso8601DateFormatterWithoutFractionalSeconds.date(from: value)
    }

    func clearPublicAccessAfterRelayReset() {
        webStatus.relayURL = nil
        webStatus.relayHostID = nil
        webStatus.routeID = nil
        webStatus.publicHostname = nil
        webStatus.pathPrefix = nil
        webStatus.authMode = nil
        webStatus.secureURL = nil
        webStatus.publicAccessEnabled = false
        webStatus.publicAccessAuthenticated = false
        webStatus.tunnelRunning = false
        webStatus.publicAccessError = nil
    }

    /// Asks the selected local Headless daemon to claim a Host identity using a
    /// short-lived Relay enrollment key. The daemon owns the Host credential;
    /// Desktop only forwards the URL and bootstrap key.
    func enrollRelay(
        relayURL: String,
        enrollmentKey: String,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard let configuration = endpointConfiguration else {
            let error = NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "No daemon endpoint is selected.",
            ])
            completion(.failure(error))
            return
        }
        guard configuration.type.lowercased() != "relay" else {
            let error = NSError(domain: "WarrenRemote", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Relay enrollment must be started from the Host daemon, not a Relay endpoint.",
            ])
            completion(.failure(error))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.relayEnrollmentRequest(
                    configuration: configuration,
                    relayURL: relayURL,
                    enrollmentKey: enrollmentKey
                )
                self.settingsLoaded = false
                self.loadSettings()
                completion(.success(()))
            } catch {
                self.present(error)
                completion(.failure(error))
            }
        }
    }

    func testOpenAITitle(
        baseURL: String,
        model: String,
        apiKey: String?
    ) async throws {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        var params = [
            "openaiBaseURL": baseURL,
            "openaiModel": model,
        ]
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            params["openaiKey"] = key
        }
        _ = try await wire.request("settings.testOpenAI", params: params)
    }

    func relayEnrollmentRequest(
        configuration: WarrenRemoteEndpointConfiguration,
        relayURL: String,
        enrollmentKey: String
    ) async throws {
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/relay/join") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RelayEnrollmentRequest(
            relayURL: relayURL,
            enrollmentKey: enrollmentKey
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Relay enrollment failed."
            throw NSError(domain: "WarrenRemote", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    struct RelayEnrollmentRequest: Encodable {
        let relayURL: String
        let enrollmentKey: String

        enum CodingKeys: String, CodingKey {
            case relayURL = "relayUrl"
            case enrollmentKey
        }
    }

    func setProjectAutoImportGitWorktrees(_ projectID: ProjectID, enabled: Bool) {
        request("project.autoImportGitWorktrees", params: [
            "project": projectID.description,
            "enabled": enabled ? "true" : "false",
        ])
    }

    func setProjectSetupScript(_ projectID: ProjectID, script: String) {
        request("project.setupScript", params: [
            "project": projectID.description,
            "script": script.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    func listProjectWorktrees(_ projectID: ProjectID) async throws -> [WarrenDesktopWorktreeCandidate] {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let data = try await wire.request("project.worktrees", params: ["project": projectID.description])
        let values = try JSONDecoder().decode([RemoteRoster.WorktreeCandidate].self, from: data)
        return values.compactMap { value in
            guard let workspaceID = value.workspace.flatMap(WorkspaceID.init(uuidString:)) else {
                return WarrenDesktopWorktreeCandidate(
                    path: value.path,
                    name: value.name,
                    branch: value.branch,
                    locked: value.locked ?? false,
                    imported: value.imported,
                    workspaceID: nil
                )
            }
            return WarrenDesktopWorktreeCandidate(
                path: value.path,
                name: value.name,
                branch: value.branch,
                locked: value.locked ?? false,
                imported: value.imported,
                workspaceID: workspaceID
            )
        }
    }

    func importProjectWorktrees(_ projectID: ProjectID, paths: [String]) async throws {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: paths, options: [])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "WarrenRemote", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Unable to encode worktree selection.",
            ])
        }
        _ = try await wire.request("project.worktrees.import", params: [
            "project": projectID.description,
            "paths": encoded,
        ])
        try await refreshRoster(using: wire)
    }

    /// The one field a create answer is read for.
    ///
    /// `session.create` answers with the durable Session and
    /// `browser.session.create` answers with the live browser projection, so the
    /// two shapes differ. The new Session's ID is all either caller needs to
    /// select the tab it just made.
    struct CreatedSession: Decodable {
        let id: String
    }

    /// The Host call that creates one Session in a scope.
    ///
    /// A browser Session owns a Chromium instead of a PTY, so the Host refuses
    /// `kind = "browser"` on `session.create` and creates it through
    /// `browser.session.create` — which takes no command, because the Host
    /// launches the browser itself rather than typing anything into a shell.
    static func createSessionCall(
        workspaceID: String,
        request launch: TerminalSessionLaunchRequest
    ) -> (method: String, params: [String: String]) {
        // Only an explicit user-chosen name becomes the session title. Built-in
        // preset launches leave it nil so the Host keeps the custom-title slot
        // free for automatic AI title generation.
        var params: [String: String] = ["workspace": workspaceID]
        if let title = launch.title {
            params["title"] = title
        }
        guard launch.kind != .browser else {
            return ("browser.session.create", params)
        }
        params["kind"] = launch.kind.rawValue
        if let handler = launch.agentHandler {
            // The Host resolves the provider's ACP server; a terminal launch
            // command would be meaningless here.
            params["agentHandler"] = handler
            return ("session.create", params)
        }
        params["command"] = launch.command ?? ""
        return ("session.create", params)
    }

    // MARK: Inspector

    var inspectors: [WorkspaceID: WarrenInspectorModel] = [:]

    /// The Inspector state for one Workspace, kept across visits so a diff the
}

/// One Agent turn, folded far enough to describe it once it ends.
///
/// The sidebar's resting line is the last thing a Session did. A turn can end
/// without having done anything countable — a reply to a question runs no tools
/// at all — and then the only fact the client holds about that turn is how long
/// it took, which is more than the word "Answered" ever said.
struct WarrenAgentTurnFold: Equatable {
    /// When the turn this fold describes began. Nil before the first
    /// `turn.started` the client saw; a session whose history starts mid-turn
    /// therefore reports no duration rather than a wrong one.
    var startedAt: Date?
    /// How many tool calls the turn settled.
    var settledCalls = 0

    /// What the turn has to say about itself as it ends.
    ///
    /// A turn that settled a call is already described by that call, so its own
    /// line stands. Anything else is described by how long it ran.
    func settledLine(replacing line: String?, at endedAt: Date?) -> String? {
        guard settledCalls == 0,
              let startedAt,
              let endedAt,
              endedAt.timeIntervalSince(startedAt) >= 1
        else { return line }
        return "Worked \(WarrenConversation.formatElapsed(endedAt.timeIntervalSince(startedAt)))"
    }
}

extension Dictionary where Key == String, Value == WarrenRemoteJSONValue {
    /// The payload's string for `key`, with a whole number rendered as its
    /// integer form. Agent payloads mix strings and numbers for the same field,
    /// so one reader has to accept both.
    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let value)?: return value
        case .number(let value)?: return value == value.rounded() ? String(Int(value)) : String(value)
        default: return nil
        }
    }

    func int(_ key: String) -> Int {
        switch self[key] {
        case .number(let value)?: return Int(value)
        case .string(let value)?: return Int(value) ?? 0
        default: return 0
        }
    }
}
