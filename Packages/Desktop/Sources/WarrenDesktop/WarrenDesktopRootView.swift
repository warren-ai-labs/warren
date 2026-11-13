import AppKit
import SwiftUI
import os
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// Production macOS shell.
///
/// The shell consumes an immutable Host/Client value projection and emits
/// typed intents. It does not start a process, persist layout, or talk to a
/// transport. The terminal is an explicit generic surface slot, so the
/// composition root can inject a real remote SwiftTerm view without type
/// erasure or hidden process ownership.
public struct WarrenDesktopRoot<TerminalSurface: View>: View {
    public let projection: WarrenDesktopProjection
    public let navigation: WarrenDesktopNavigationState
    public let updateStatus: WarrenDesktopUpdateStatus
    /// Set while the Host restarts for an update. It shares the window's one
    /// update notice with the in-app update rather than each terminal drawing
    /// its own.
    public let hostMaintenanceMessage: String?
    public let onUpdateAction: () -> Void
    public let webStatus: WarrenDesktopWebStatus
    public let isMigratingRuntimeSessions: Bool
    public let creatingSessionWorkspaceIDs: Set<WorkspaceID>
    /// The Session each `requestNewSession` produced, keyed by its token.
    public let createdSessionIDsByToken: [UUID: TerminalSessionID]
    public let deletingProjectIDs: Set<ProjectID>
    public let deletingWorkspaceIDs: Set<WorkspaceID>
    public let notices: [WarrenDesktopNotice]
    public let onNoticeAdd: (String, String, String?, WarrenDesktopNotice.Kind) -> Void
    public let onNoticeRead: (WarrenDesktopNotice.ID) -> Void
    public let onNoticeDismiss: (WarrenDesktopNotice.ID) -> Void
    /// Gives AppKit-backed terminal surfaces a chance to park before SwiftUI
    /// commits a mode change that can alter their proposed geometry.
    public let onActiveScreenSessionsWillChange: (Set<TerminalSessionID>) -> Void
    public let onActiveScreenSessionsChanged: (Set<TerminalSessionID>) -> Void
    /// Reports the arrangement a scope should now have. The Host owns the
    /// shape, so the view never stores one: it asks, and the roster answers.
    /// The target names which arrangement the tree replaces, or asks for a new
    /// one; a scope can hold several.
    public let onCommitPaneTree: (WarrenDesktopPaneOwner, PaneNode, WarrenDesktopPaneGroupTarget) -> Void
    /// Records why a split request was issued, applied, or dropped. The split
    /// path crosses an asynchronous Session creation and a Host round trip,
    /// and every early return on it is otherwise silent.
    public let onPaneDiagnostic: (String, [String: String]) -> Void

    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let onSelectEndpoint: (String) -> Void
    let onSetEndpointSidebarVisibility: (String, Bool) -> Void
    let onSetEndpointDisplayName: (String, String?) -> Void
    let onDeleteEndpoint: (String) -> Void
    let sidebarHostProjections: [WarrenDesktopSidebarHostProjection]?
    let usesSidebarHostSections: Bool
    /// The endpoint-scoped counterpart to the active navigation selection.
    /// The composition layer supplies the scope from the controller that owns
    /// the navigation state, which can briefly differ from the requested
    /// endpoint while a Host switch is in flight.
    let sidebarResourceSelection: WarrenDesktopSidebarResourceSelection?
    let displayConfigurationError: String?
    let onSelectSidebarResource: (WarrenDesktopSidebarResourceSelection) -> Void
    let onOpenSidebarWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    let onOpenSidebarSession: (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void
    let onRetrySidebarHost: (String) -> Void
    let onAddSSHHost: () -> Void
    let sshHostPage: WarrenDesktopSSHHostPageModel?
    let onRetryConnection: () -> Void
    let onStopConnection: () -> Void

    let actions: WarrenDesktopActions
    let onCreateTask: @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID
    /// The decisions other Sessions are waiting on, for the approval tray.
    let pendingDecisions: WarrenDesktopPendingDecisions
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    let onWebStart: () -> Void
    let onWebTest: ((String, String) -> Void)?
    let onWebStop: () -> Void
    let onWebReset: (() -> Void)?
    let onRelayEnroll: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    let onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)?
    let lanPairing: WarrenDesktopLANPairing
    let onLANPairing: ((Bool, @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void) -> Void)?
    let relaySettings: WarrenDesktopRelaySettings
    /// Turns the enrolled Relay on or off. Enrollment is kept either way, so
    /// this is the switch on the Settings connection row.
    let onSetRelayEnabled: ((Bool) -> Void)?
    let onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    let relayDevices: [WarrenDesktopRelayDevice]
    let onLoadRelayDevices: (() -> Void)?
    let onRevokeRelayDevice: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    /// Serverless remote access (Bolthole) as the Host reports it.
    private var remoteAccess: WarrenDesktopRemoteAccess = .init()
    private var onLoadRemoteAccess: (() -> Void)?
    private var onSetRemoteEnabled: ((Bool) -> Void)?
    private var onSetRemoteRelay: ((String) -> Void)?
    private var onRemoteShare: ((@escaping (Result<WarrenDesktopRemoteShare, Error>) -> Void) -> Void)?
    private var onRotateRemote: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    let onWebOpenURL: (URL) -> Void
    let onWebCopyURL: (URL) -> Void
    let defaultRuntime: String?
    let onSetRuntime: (String) -> Void
    let autoOpenShell: Bool
    let onSetAutoOpenShell: (Bool) -> Void
    let autoStartAI: Bool
    let onSetAutoStartAI: (Bool) -> Void
    let openAIBaseURL: String
    let openAIModel: String
    let openAITitleEnabled: Bool
    let onSetOpenAISetting: (String, String) -> Void
    let onTestOpenAI: @MainActor (String, String, String?) async throws -> Void
    let onSetProjectSetupScript: (ProjectID, String) -> Void
    let usageStats: WarrenUsageStats
    let usageState: WarrenUsageLoadState
    let onLoadUsage: ((Int, String?, Bool) -> Void)?
    let onRebuildUsage: ((@escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void) -> Void)?
    let embeddedEditorAvailable: Bool
    /// True while the editor region holds the keyboard.
    ///
    /// The region is not a pane and owns no Session (RFC 0020), so nothing in
    /// the arrangement tree can answer this. It arrives from the host because
    /// the region's own surface is the only thing that observes the pointer
    /// crossing into it.
    let editorHasKeyboardFocus: Bool
    /// Whether a browser viewer currently holds the keyboard.
    ///
    /// A viewer is a `WKWebView`, so a click inside its content moves AppKit's
    /// first responder without telling the Terminal. Without this signal,
    /// terminal reconciliation pulls the keyboard straight back out of the
    /// browser pane (RFC 0022 §8.4).
    let browserHasKeyboardFocus: Bool
    let editorSurface: @MainActor (Workspace) -> AnyView
    /// The Inspector beside the terminal; nil where the host offers none. It is
    /// resolved per page, because the right sidebar's tab row owns which page is
    /// showing.
    let inspectorSurface: (@MainActor (Workspace, WarrenDesktopInspectorTab, WarrenDesktopInspectorActivity) -> AnyView)?
    /// Asks the runtime to open one document. Warren drives this exactly once
    /// per editor entry, to restore the Workspace's last document; every other
    /// file selection happens inside code-server and never reaches Warren.
    let onOpenEditorDocument: @MainActor (Workspace, WarrenDesktopEditorDocument) -> Void
    let persistenceEnabled: Bool
    let externalIDEService = WarrenDesktopExternalIDEService.live
    @State var sidebarState: WarrenDesktopSidebarState
    @State var sidebarTree: WarrenDesktopSidebarTreeState
    @State var commandPalettePresented = false
    @State var settingsPresented = false
    /// Bumped when the settings page is asked for, so an already-open window
    /// comes back to the front.
    @State var settingsActivation = 0
    @State var settingsDeepLinkSection: WarrenDesktopSettingsSection?
    @State var settingsPublicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    @State var settingsRelayPrefill: WarrenDesktopRelayPrefill?
    @State var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State var chromePopover: WarrenDesktopChromePopover?
    /// The Host a right-click asked to delete, awaiting confirmation.
    @State var pendingHostDeletion: WarrenDesktopEndpointOption?
    @State var pendingRename: WarrenDesktopRenameRequest?
    /// Resource dialogs capture the Endpoint that owned their row. A dialog
    /// opened on one Host must never submit its bare ID after the user
    /// switches to another Host that may issue the same UUID.
    @State var pendingRenameEndpointID: String?
    @State var isTaskCreatorPresented = false
    @State var taskCreatorEndpointID: String?
    @State var renameValue = ""
    @State var pendingDeletion: WarrenDesktopDeletionRequest?
    @State var pendingDeletionEndpointID: String?
    @State var deleteWorkspaceRemoveWorktree = false
    /// The durable per-Workspace editor markers (RFC 0021 §6.1).
    @State var workspaceEditorStates: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState]
    /// Which Workspaces currently show the editor region in this window.
    ///
    /// Tracks the same intent as the durable marker but is not derived from it:
    /// the marker is what a relaunch reads, while this is what the window draws,
    /// and a Workspace on another Endpoint keeps its marker without being here.
    @State var editorRegionWorkspaceIDs: Set<WorkspaceID>
    /// The Terminal's share of the central width while the editor region is up.
    @State var terminalRatio = WarrenLayoutMetrics.editorSplitDefaultRatio
    /// One switch for every Workspace, like the sidebar: the Inspector is a
    /// way of working, not a property of one checkout.
    @AppStorage("warren.desktop.inspectorOpen") var inspectorOpen = false
    @AppStorage("warren.desktop.inspectorTerminalRatio")
    var inspectorTerminalRatio = WarrenLayoutMetrics.inspectorSplitDefaultRatio
    /// Which page each Workspace's right sidebar last showed. The sidebar's
    /// open switch is global, but the page is remembered per Workspace.
    @State var rightSidebarTabs: [WorkspaceID: WarrenDesktopRightSidebarTab] = [:]
    /// The last Inspector page a Workspace showed, so closing the editor returns
    /// there rather than always to Changes.
    @State var lastInspectorTabs: [WorkspaceID: WarrenDesktopInspectorTab] = [:]
    /// The value the Inspector publishes for the Changes tab's count.
    @StateObject var inspectorActivity = WarrenDesktopInspectorActivity()
    /// The external editor a plain click opens, remembered across launches.
    @AppStorage("warren.desktop.externalIDEID") var externalIDEID = ""
    @State var splitTrees: [String: SplitLayoutTree]
    @State var activePaneIDs: [String: String]
    /// The pane each scope shows alone, from the group shelf's Maximize. The
    /// layout is untouched, so restoring it brings every pane back.
    @State var zoomedPaneIDs: [String: String] = [:]
    /// The pane each scope shows as a rail, folded by pulling its divider past
    /// the minimum. Device-local like zoom: the Host's arrangement keeps the
    /// pane and its ratio, so other devices never see a fold.
    @State var foldedPaneIDs: [String: String] = [:]
    /// The top bar's group hover, shared with the pane cards it previews.
    @StateObject var ownPaneGroupHover = WarrenDesktopPaneGroupHover()
    @StateObject var menuCenter = WarrenDesktopMenuCenter()
    /// The approval tray's rows, kept current for a panel that is already open.
    @StateObject var approvalTray = WarrenDesktopApprovalTrayStore()
    @Environment(\.warrenPaneGroupHover) var outerPaneGroupHover

    /// An embedding view may supply the hover, which is how a preview pins a
    /// lifted or open group.
    var paneGroupHover: WarrenDesktopPaneGroupHover {
        outerPaneGroupHover ?? ownPaneGroupHover
    }
    /// Which arrangement this window renders for a scope. It is per viewer and
    /// never sent to the Host: the Host owns the shape, not the choice.
    @State var activePaneGroupIDs: [String: String]
    /// The last arrangement the Host confirmed, per scope. A local tree that
    /// differs from it is an edit in flight, and it must outlive the Host's
    /// stale answer until the roster echoes the write.
    @State var adoptedPaneTrees: [String: SplitLayoutTree] = [:]
    @State var pendingSplits: [String: PendingSplit]
    /// The Session a split in flight is opening a *new* arrangement around, per
    /// scope. A split that starts a new group has no Host group to echo its
    /// arrival, so this is what recognizes the created group in the roster and
    /// makes it the one this window renders.
    @State var pendingNewGroupVisitTabIDs: [String: String] = [:]
    /// Ticks while a split is waiting for the Session it asked for.
    ///
    /// The completion happens when the roster publishes that Session, and the
    /// publication does not reliably arrive as a change this view observes. The
    /// retry therefore has to re-read the view's current inputs on every tick: a
    /// `Task` started when the request was made would keep the projection it
    /// captured then — which is precisely the projection without the Session it
    /// is waiting for, so every attempt would decide there is nothing new.
    ///
    /// The tick is attached only while a split is pending: its subscriber is a
    /// background view that exists just for that time, so the autoconnected
    /// timer stops with it and an idle window does not wake the main thread
    /// 20 times a second for nothing.
    let pendingSplitTick = Timer
        .publish(every: 0.05, on: .main, in: .common)
        .autoconnect()
    @StateObject var tabDrag = WarrenDesktopTabDrag()
    /// When the collapsed sidebar floats open, and when it goes away.
    @StateObject var sidebarPeek = WarrenDesktopSidebarPeekController()
    @State var emacsChordActive = false
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    var terminalFontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.noticeMuted)
    var notificationsMuted = false
    @State var isNoticePopoverPresented = false
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    var showsTasks = true
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    var splitChordsEnabled = false
    @Environment(\.warrenSemanticRecorder) var semanticRecorder
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.warrenWindowMaterial) var windowMaterial

    var windowTokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
    }
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// The peek only exists in the key window: a background window must not
    /// pop its sidebar open when the pointer crosses it.
    @Environment(\.controlActiveState) var controlActiveState

    struct Presentation {
        let workspace: Workspace?
        let contentWorkspace: Workspace?
        let tab: ClientTab?
        let session: WarrenDesktopSession?
        let tabs: [ClientTab]
    }

    struct PendingSplit: Equatable {
        let targetPaneID: String
        /// The Session the request was made against.
        ///
        /// A split can be requested while the panel is showing a Session that
        /// is not in the stored layout, so the pane the request targets may not
        /// exist in that layout at all. Keeping the Tab ID here lets the
        /// completion rebuild the pane it was asked about.
        let targetTabID: String
        /// Names the `requestNewSession` this split dispatched.
        ///
        /// The model reports the Session that request created under this
        /// token, which is the only thing that identifies it: any actor can
        /// create a Session in the scope while this one is starting.
        let token: UUID
        let axis: SplitAxis
        /// Whether this request opens a new arrangement instead of extending
        /// the scope's current one.
        let createsNewGroup: Bool
    }

    var isUpdating: Bool {
        updateStatus == .updating || hostMaintenanceMessage != nil
    }

    /// The Host's own wording when it gives more than the generic notice.
    var updateHUDDetail: String? {
        guard updateStatus != .updating,
              let hostMaintenanceMessage,
              hostMaintenanceMessage != "Warren is updating"
        else { return nil }
        return hostMaintenanceMessage
    }

    public init(
        projection: WarrenDesktopProjection,
        navigation: WarrenDesktopNavigationState? = nil,
        updateStatus: WarrenDesktopUpdateStatus = .none,
        hostMaintenanceMessage: String? = nil,
        onUpdateAction: @escaping () -> Void = {},
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        onCreateTask: @escaping @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID = { _ in
            throw URLError(.unsupportedURL)
        },
        pendingDecisions: WarrenDesktopPendingDecisions = WarrenDesktopPendingDecisions(),
        webStatus: WarrenDesktopWebStatus = .init(),
        isMigratingRuntimeSessions: Bool = false,
        creatingSessionWorkspaceIDs: Set<WorkspaceID> = [],
        createdSessionIDsByToken: [UUID: TerminalSessionID] = [:],
        deletingProjectIDs: Set<ProjectID> = [],
        deletingWorkspaceIDs: Set<WorkspaceID> = [],
        notices: [WarrenDesktopNotice] = [],
        onNoticeAdd: @escaping (String, String, String?, WarrenDesktopNotice.Kind) -> Void = { _, _, _, _ in },
        onNoticeRead: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        onNoticeDismiss: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        onActiveScreenSessionsWillChange: @escaping (Set<TerminalSessionID>) -> Void = { _ in },
        onActiveScreenSessionsChanged: @escaping (Set<TerminalSessionID>) -> Void = { _ in },
        onCommitPaneTree: @escaping (WarrenDesktopPaneOwner, PaneNode, WarrenDesktopPaneGroupTarget) -> Void = { _, _, _ in },
        onPaneDiagnostic: @escaping (String, [String: String]) -> Void = { _, _ in },
        endpointOptions: [WarrenDesktopEndpointOption] = [
            .init(id: "local", label: "Local", isLocal: true),
        ],
        selectedEndpointID: String = "local",
        endpointCapabilities: WarrenDesktopEndpointCapabilities? = nil,
        onSelectEndpoint: @escaping (String) -> Void = { _ in },
        onSetEndpointSidebarVisibility: @escaping (String, Bool) -> Void = { _, _ in },
        onSetEndpointDisplayName: @escaping (String, String?) -> Void = { _, _ in },
        onDeleteEndpoint: @escaping (String) -> Void = { _ in },
        sidebarHostProjections: [WarrenDesktopSidebarHostProjection]? = nil,
        usesSidebarHostSections: Bool = false,
        sidebarResourceSelection: WarrenDesktopSidebarResourceSelection? = nil,
        displayConfigurationError: String? = nil,
        onSelectSidebarResource: @escaping (WarrenDesktopSidebarResourceSelection) -> Void = { _ in },
        onOpenSidebarWorkspace: @escaping (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void = { _ in },
        onOpenSidebarSession: @escaping (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void = { _ in },
        onRetrySidebarHost: @escaping (String) -> Void = { _ in },
        onAddSSHHost: @escaping () -> Void = {},
        sshHostPage: WarrenDesktopSSHHostPageModel? = nil,
        onRetryConnection: @escaping () -> Void = {},
        onStopConnection: @escaping () -> Void = {},
        onWebStart: @escaping () -> Void = {},
        onWebTest: ((String, String) -> Void)? = nil,
        onWebStop: @escaping () -> Void = {},
        onWebReset: (() -> Void)? = nil,
        onRelayEnroll: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)? = nil,
        lanPairing: WarrenDesktopLANPairing = .init(),
        onLANPairing: ((Bool, @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void) -> Void)? = nil,
        relaySettings: WarrenDesktopRelaySettings = .init(),
        onSetRelayEnabled: ((Bool) -> Void)? = nil,
        onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        relayDevices: [WarrenDesktopRelayDevice] = [],
        onLoadRelayDevices: (() -> Void)? = nil,
        onRevokeRelayDevice: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        remoteAccess: WarrenDesktopRemoteAccess = .init(),
        onLoadRemoteAccess: (() -> Void)? = nil,
        onSetRemoteEnabled: ((Bool) -> Void)? = nil,
        onSetRemoteRelay: ((String) -> Void)? = nil,
        onRemoteShare: ((@escaping (Result<WarrenDesktopRemoteShare, Error>) -> Void) -> Void)? = nil,
        onRotateRemote: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        onWebOpenURL: @escaping (URL) -> Void = { _ in },
        onWebCopyURL: @escaping (URL) -> Void = { _ in },
        defaultRuntime: String? = nil,
        onSetRuntime: @escaping (String) -> Void = { _ in },
        autoOpenShell: Bool = false,
        onSetAutoOpenShell: @escaping (Bool) -> Void = { _ in },
        autoStartAI: Bool = false,
        onSetAutoStartAI: @escaping (Bool) -> Void = { _ in },
        openAIBaseURL: String = "",
        openAIModel: String = "",
        openAITitleEnabled: Bool = false,
        onSetOpenAISetting: @escaping (String, String) -> Void = { _, _ in },
        onTestOpenAI: @escaping @MainActor (String, String, String?) async throws -> Void = { _, _, _ in
            throw URLError(.unsupportedURL)
        },
        onSetProjectSetupScript: @escaping (ProjectID, String) -> Void = { _, _ in },
        usageStats: WarrenUsageStats = WarrenUsageStats(),
        usageState: WarrenUsageLoadState = .idle,
        onLoadUsage: ((Int, String?, Bool) -> Void)? = nil,
        onRebuildUsage: ((@escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void) -> Void)? = nil,
        embeddedEditorAvailable: Bool = false,
        editorHasKeyboardFocus: Bool = false,
        browserHasKeyboardFocus: Bool = false,
        editorSurface: @escaping @MainActor (Workspace) -> AnyView = { _ in AnyView(EmptyView()) },
        onOpenEditorDocument: @escaping @MainActor (Workspace, WarrenDesktopEditorDocument) -> Void = { _, _ in },
        inspectorSurface: (@MainActor (Workspace, WarrenDesktopInspectorTab, WarrenDesktopInspectorActivity) -> AnyView)? = nil,
        persistenceEnabled: Bool = true,
        @ViewBuilder terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? WarrenDesktopNavigationReducer.initial(for: projection)
        self.updateStatus = updateStatus
        self.hostMaintenanceMessage = hostMaintenanceMessage
        self.onUpdateAction = onUpdateAction
        self.webStatus = webStatus
        self.isMigratingRuntimeSessions = isMigratingRuntimeSessions
        self.creatingSessionWorkspaceIDs = creatingSessionWorkspaceIDs
        self.createdSessionIDsByToken = createdSessionIDsByToken
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.notices = notices
        self.onNoticeAdd = onNoticeAdd
        self.onNoticeRead = onNoticeRead
        self.onNoticeDismiss = onNoticeDismiss
        self.endpointOptions = endpointOptions
        self.onActiveScreenSessionsWillChange = onActiveScreenSessionsWillChange
        self.onActiveScreenSessionsChanged = onActiveScreenSessionsChanged
        self.onCommitPaneTree = onCommitPaneTree
        self.onPaneDiagnostic = onPaneDiagnostic
        self.selectedEndpointID = selectedEndpointID
        let resolvedEndpointCapabilities = endpointCapabilities
            ?? endpointOptions.first(where: { $0.id == selectedEndpointID })?.capabilities
            ?? (selectedEndpointID == "local" ? .local : .remote)
        self.endpointCapabilities = resolvedEndpointCapabilities
        self.onSelectEndpoint = onSelectEndpoint
        self.onSetEndpointSidebarVisibility = onSetEndpointSidebarVisibility
        self.onSetEndpointDisplayName = onSetEndpointDisplayName
        self.onDeleteEndpoint = onDeleteEndpoint
        self.sidebarHostProjections = sidebarHostProjections
        self.usesSidebarHostSections = usesSidebarHostSections
        self.sidebarResourceSelection = sidebarResourceSelection
            ?? Self.scopedSidebarSelection(
                self.navigation.selection,
                endpointID: selectedEndpointID
            )
        self.displayConfigurationError = displayConfigurationError
        self.onSelectSidebarResource = onSelectSidebarResource
        self.onOpenSidebarWorkspace = onOpenSidebarWorkspace
        self.onOpenSidebarSession = onOpenSidebarSession
        self.onRetrySidebarHost = onRetrySidebarHost
        self.onAddSSHHost = onAddSSHHost
        self.sshHostPage = sshHostPage
        self.onRetryConnection = onRetryConnection
        self.onStopConnection = onStopConnection
        self.actions = actions
        self.onCreateTask = onCreateTask
        self.pendingDecisions = pendingDecisions
        self.terminalSurface = terminalSurface
        self.onWebStart = onWebStart
        self.onWebTest = onWebTest
        self.onWebStop = onWebStop
        self.onWebReset = onWebReset
        self.onRelayEnroll = onRelayEnroll
        self.onRelayPairing = onRelayPairing
        self.lanPairing = lanPairing
        self.onLANPairing = onLANPairing
        self.relaySettings = relaySettings
        self.onSetRelayEnabled = onSetRelayEnabled
        self.onResetRelay = onResetRelay
        self.relayDevices = relayDevices
        self.onLoadRelayDevices = onLoadRelayDevices
        self.onRevokeRelayDevice = onRevokeRelayDevice
        self.remoteAccess = remoteAccess
        self.onLoadRemoteAccess = onLoadRemoteAccess
        self.onSetRemoteEnabled = onSetRemoteEnabled
        self.onSetRemoteRelay = onSetRemoteRelay
        self.onRemoteShare = onRemoteShare
        self.onRotateRemote = onRotateRemote
        self.onWebOpenURL = onWebOpenURL
        self.onWebCopyURL = onWebCopyURL
        self.defaultRuntime = defaultRuntime
        self.onSetRuntime = onSetRuntime
        self.autoOpenShell = autoOpenShell
        self.onSetAutoOpenShell = onSetAutoOpenShell
        self.autoStartAI = autoStartAI
        self.onSetAutoStartAI = onSetAutoStartAI
        self.openAIBaseURL = openAIBaseURL
        self.openAIModel = openAIModel
        self.openAITitleEnabled = openAITitleEnabled
        self.onSetOpenAISetting = onSetOpenAISetting
        self.onTestOpenAI = onTestOpenAI
        self.onSetProjectSetupScript = onSetProjectSetupScript
        self.usageStats = usageStats
        self.usageState = usageState
        self.onLoadUsage = onLoadUsage
        self.onRebuildUsage = onRebuildUsage
        self.embeddedEditorAvailable = embeddedEditorAvailable
            && resolvedEndpointCapabilities.canUseEmbeddedEditor
        self.editorHasKeyboardFocus = editorHasKeyboardFocus
        self.browserHasKeyboardFocus = browserHasKeyboardFocus
        self.editorSurface = editorSurface
        self.onOpenEditorDocument = onOpenEditorDocument
        self.inspectorSurface = inspectorSurface
        self.persistenceEnabled = persistenceEnabled
        _sidebarState = State(
            initialValue: persistenceEnabled
                ? Self.restoredSidebarState()
                : WarrenDesktopSidebarState()
        )
        _sidebarTree = State(
            initialValue: persistenceEnabled
                ? Self.restoredSidebarTree(scope: selectedEndpointID)
                : WarrenDesktopSidebarTreeState()
        )
        // A marker restored here is what brings the editor region back after a
        // relaunch. Region membership is seeded from the markers rather than
        // persisted separately, so there is one durable answer to "did this
        // Workspace use the editor" and the window state follows from it.
        let restoredEditorStates = persistenceEnabled
            ? WarrenDesktopWorkspaceEditorStateStore.restoreMigratingLegacyContentModes(
                scope: selectedEndpointID
            )
            : [:]
        _workspaceEditorStates = State(initialValue: restoredEditorStates)
        let markedWorkspaceIDs = Self.enabledWorkspaceIDs(
            in: restoredEditorStates,
            hostId: selectedEndpointID
        )
        _editorRegionWorkspaceIDs = State(initialValue: markedWorkspaceIDs)
        // The arrangement is Host state, so there is nothing device-local to
        // restore. A scope with no Host group renders its selected Tab alone.
        _splitTrees = State(initialValue: [:])
        _activePaneIDs = State(initialValue: [:])
        _activePaneGroupIDs = State(initialValue: [:])
        _pendingSplits = State(initialValue: [:])
    }

    public var body: some View {
        let presentation = makePresentation()
        let currentTree = currentSplitTree(presentation: presentation)
        let currentPaneID = currentActivePaneID(presentation: presentation, tree: currentTree)
        // The Terminal is mounted and subscribed whether or not the editor is
        // up, so its visible screens no longer depend on the editor at all.
        let activeVisibleSessions = visibleScreenSessionIDs(
            for: presentation,
            in: currentTree
        )
        let rightSidebarTab = showsRightSidebar(for: presentation.workspace)
            ? selectedRightSidebarTab(for: presentation.workspace)
            : nil
        let tabTitles = Dictionary(uniqueKeysWithValues: presentation.tabs.map { tab in
            let session = tab.sessionID.flatMap { projection.session(id: $0) }
            let workspace = tab.sessionID.flatMap { projection.workspace(for: $0) }
                ?? presentation.workspace
            return (
                tab.id,
                WarrenDesktopTabTitle.displayTitle(
                    tab: tab,
                    session: session,
                    workspace: workspace
                )
            )
        })
        let tabMarks = Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            session.effectiveActivityMark.map { (session.id, $0) }
        })
        let shellMarks = Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            session.shellStatusMark.map { (session.id, $0) }
        })
        // A shell's running command, which a split Tab appends to its title
        // the way the single pane's pill does.
        let tabCommands = Dictionary(uniqueKeysWithValues: presentation.tabs.compactMap { tab -> (String, String)? in
            guard let session = tab.sessionID.flatMap({ projection.session(id: $0) }) else { return nil }
            let workspace = projection.workspace(for: session.id) ?? presentation.workspace
            let command = WarrenDesktopTabTitle.sessionTitle(
                for: session,
                worktreeRoot: workspace?.path ?? ""
            ).runningCommand
            return command.isEmpty ? nil : (tab.id, command)
        })
        let leadSessionIDs = Set(projection.sessions.filter(\.isLead).map(\.id))
        // A stopped Session keeps its Tab; the bar draws it quiet so it does not
        // read as a live pane beside the running ones.
        let stoppedSessionIDs = Set(
            projection.sessions.filter { $0.isStopped }.map(\.id)
        )
        let pinnedSessionIDs = Set(
            projection.sessions.filter(\.pinned).map(\.id)
        )
        let isAddingSession = isAddingSession(in: presentation)
        let sessionMoveTargets = makeSessionMoveTargets()
        let sessionMoveDestinations = makeSessionMoveDestinations()
        let externalIDEOptions = makeExternalIDEOptions(for: presentation)
        let tabBarView = makeTabBarView(
            presentation: presentation,
            tabTitles: tabTitles,
            tabMarks: tabMarks,
            shellMarks: shellMarks,
            tabCommands: tabCommands,
            leadSessionIDs: leadSessionIDs,
            stoppedSessionIDs: stoppedSessionIDs,
            pinnedSessionIDs: pinnedSessionIDs,
            isAddingSession: isAddingSession,
            sessionMoveTargets: sessionMoveTargets,
            sessionMoveDestinations: sessionMoveDestinations,
            externalIDEOptions: externalIDEOptions
        )
        let sidebarView = makeSidebarView(
            presentation: presentation,
            sidebarPresentation: .docked
        )
        let sidebarPeekView = makeSidebarView(
            presentation: presentation,
            sidebarPresentation: .peek
        )
        let workspaceColumn = makeWorkspaceColumn(
            presentation: presentation,
            tabBarView: tabBarView,
            externalIDEOptions: externalIDEOptions,
            isAddingSession: isAddingSession,
            currentTree: currentTree,
            currentPaneID: currentPaneID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        ZStack(alignment: .topLeading) {
            // The window is a dark backdrop with cards on it: the sidebar on
            // the leading side, the tab row and the pane cards beside it. The
            // gutters between them are the backdrop, and also the window's
            // drag area.
            HStack(spacing: WarrenLayoutMetrics.cardGap) {
                if !sidebarState.isCollapsed {
                    sidebarView
                        .warrenCard(fill: windowTokens.workbenchCardFill)
                        // The handle sits inside the card's trailing edge rather
                        // than in the gutter, so grabbing it never shifts either
                        // column and the drag reads as moving the boundary.
                        .overlay(alignment: .trailing) {
                            WarrenDesktopSidebarResizeHandle(
                                width: sidebarState.renderedWidth,
                                onResize: { sidebarState.setWidth($0) },
                                onReset: { sidebarState.restoreExpanded() }
                            )
                        }
                }
                workspaceColumn
            }
            .padding(WarrenLayoutMetrics.windowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    windowTokens.windowBackdrop
                    WarrenDesktopWindowDragRegion(identifier: "warren.window-backdrop")
                }
                .ignoresSafeArea()
            }

            // The settings page is drawn in its own window; this presenter only
            // owns that window, so the main window stays live beside it.
            WarrenDesktopSettingsWindowPresenter(
                isPresented: settingsPresented,
                activation: settingsActivation,
                contentKey: settingsInputs,
                content: { settingsOverlay },
                onClose: { setSettingsPresented(false) }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            // The peek floats over the content card instead of taking width
            // from it, so the terminal never re-lays out while the sidebar is
            // revealed. The strip is the pointer target along the left edge.
            if sidebarState.isCollapsed {
                WarrenDesktopSidebarPeekEdge()
                    .onHover { sidebarPeek.setPointer(.edge, isInside: $0) }
                if sidebarPeek.isPeeking {
                    sidebarPeekView
                        .padding(WarrenLayoutMetrics.windowInset)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .transition(sidebarPeekTransition)
                        .zIndex(1)
                        .onHover { sidebarPeek.setPointer(.panel, isInside: $0) }
                        // A second Esc path for when the panel holds focus, as a
                        // popover does; the key equivalent below covers the
                        // terminal's focus.
                        .onExitCommand {
                            sidebarPeek.dismiss(suppressingUntilPointerLeaves: true)
                        }

                    // Esc belongs to the terminal and the conversation pane
                    // unless the peek is up; this button only exists then.
                    Button("") {
                        sidebarPeek.dismiss(suppressingUntilPointerLeaves: true)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }

            // An in-app update replaces the application bundle and restarts
            // Warren; a Host update restarts the Host under it. Neither
            // navigates the window anywhere: the shell stays exactly as it is
            // behind a slight dim and one card says why it has stopped taking
            // input. There is one per window, never one per terminal. A failed
            // install fades it back out, leaving the window as it was.
            Group {
                if isUpdating {
                    WarrenDesktopUpdateHUD(detail: updateHUDDetail)
                        .transition(.opacity)
                        .zIndex(WarrenPresentationLayer.modal)
                }
            }
            .animation(
                WarrenDesktopLoadingReveal.animation(reduceMotion: reduceMotion),
                value: isUpdating
            )
        }
        .animation(sidebarPeekAnimation, value: sidebarPeek.isPeeking)
        .frame(
            // The editor region widens the window's floor while it is up.
            // Otherwise the region's own floor — code-server's 220pt editor part
            // plus its Explorer — would be met by squeezing the Terminal to
            // nothing, and RFC 0021's open question about narrow windows would
            // become a state users could sit in.
            minWidth: WarrenLayoutMetrics.sidebarExpandedWidth
                + WarrenLayoutMetrics.windowInset * 2
                + WarrenLayoutMetrics.cardGap
                + currentTree.windowMinimumPaneWidth
                + (rightSidebarTab?.inspectorTab != nil
                    ? WarrenLayoutMetrics.inspectorMinimumWidth
                        + WarrenLayoutMetrics.editorSplitDividerWidth
                    : (rightSidebarTab != nil
                        ? WarrenLayoutMetrics.editorRegionMinimumWidth
                            + WarrenLayoutMetrics.editorSplitDividerWidth
                        : 0)),
            minHeight: WarrenLayoutMetrics.windowInset * 2
                + WarrenLayoutMetrics.cardGap
                + WarrenLayoutMetrics.tabBarHeight
                + currentTree.windowMinimumPaneHeight
        )
        .warrenSurface()
        .warrenUnixTextEditing()
        .environment(\.warrenTabDrag, tabDrag)
        .environmentObject(tabDrag)
        .onChange(of: sidebarState) { newState in
            if persistenceEnabled { Self.persist(newState) }
            sidebarPeek.setCollapsed(newState.isCollapsed)
        }
        .onChange(of: controlActiveState) { state in
            sidebarPeek.setWindowKey(state == .key)
        }
        .onChange(of: sidebarTree) { newState in
            if persistenceEnabled { Self.persist(newState, scope: selectedEndpointID) }
        }
        .onChange(of: workspaceEditorStates) { newStates in
            guard persistenceEnabled else { return }
            WarrenDesktopWorkspaceEditorStateStore.save(newStates)
        }
        .onAppear { approvalTray.update(approvalTrayEntries) }
        .onChange(of: approvalTrayEntries) { approvalTray.update($0) }
        .onChange(of: selectedEndpointID) { newEndpointID in
            sidebarTree = persistenceEnabled
                ? Self.restoredSidebarTree(scope: newEndpointID)
                : WarrenDesktopSidebarTreeState()
            // The markers are per Endpoint, so a Host change re-derives which
            // Workspaces have one. Nothing carries over: a path that exists on
            // both Hosts must not inherit the other's editor state.
            let restoredEditorStates = persistenceEnabled
                ? WarrenDesktopWorkspaceEditorStateStore
                    .restoreMigratingLegacyContentModes(scope: newEndpointID)
                : [:]
            let markedWorkspaceIDs = Self.enabledWorkspaceIDs(
                in: restoredEditorStates,
                hostId: newEndpointID
            )
            workspaceEditorStates = restoredEditorStates
            editorRegionWorkspaceIDs = markedWorkspaceIDs
            if !endpointCapabilities.canOpenExternalIDE {
                chromePopover = nil
            }
            // Tasks and rename dialogs are current-Host
            // interactions. Close them when the owner changes so a later
            // confirmation cannot route a bare resource ID to this Host.
            pendingRename = nil
            pendingRenameEndpointID = nil
            isTaskCreatorPresented = false
            taskCreatorEndpointID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.commandPalette)) { _ in
            presentCommandPalette()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.newSession)) { _ in
            handleNewSession(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.nextTab)) { _ in
            handleTabMove(forward: true, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.previousTab)) { _ in
            handleTabMove(forward: false, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.selectTab)) { note in
            handleSelectTab(note, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.peekSidebar)) { _ in
            sidebarPeek.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleInspector)) { _ in
            toggleRightSidebar(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.openSettings)) { note in
            // A deep link names a section; the app menu's Settings item
            // posts none and opens the first one.
            openSettings(note.object as? WarrenDesktopSettingsDeepLink)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.openEmbeddedEditor)) { note in
            let request = note.object as? WarrenDesktopEmbeddedEditorRequest
            let targetWorkspace = request.flatMap { request in
                projection.groups.flatMap(\.workspaces).first {
                    $0.id == request.workspaceID
                }
            } ?? presentation.workspace
            if let targetWorkspace, presentation.workspace?.id != targetWorkspace.id {
                actions(.selectWorkspace(targetWorkspace.id))
            }
            // The runtime has already been asked to open the document, so the
            // marker records what is on screen rather than driving it.
            openEditorRegion(
                for: targetWorkspace,
                restoringLastDocument: false,
                recording: request?.document
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.reviewFile)) { note in
            guard let request = note.object as? WarrenDesktopReviewFileRequest else { return }
            revealReviewFile(request, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.splitBelow)) { _ in
            handleSplitBelow(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.splitRight)) { _ in
            handleSplitRight(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closePane)) { _ in
            handleCloseTab(nil, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.maximizePane)) { _ in
            handleMaximizePane(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.otherPane)) { _ in
            handleOtherPane(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.nextPaneGroup)) { _ in
            selectPaneGroup(id: nil, step: 1, in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.previousPaneGroup)) { _ in
            selectPaneGroup(id: nil, step: -1, in: presentation)
        }
        .onChange(of: activeVisibleSessions) { sessions in
            onActiveScreenSessionsChanged(sessions)
        }
        .background {
            if !pendingSplits.isEmpty {
                Color.clear.onReceive(pendingSplitTick) { _ in
                    // A split waits for the Session it asked for, and that
                    // arrival is not guaranteed to reach this view as a change.
                    // The tick is what keeps the completion from depending on one.
                    reconcilePendingSplitsOnTick()
                }
            }
        }
        .onChange(of: splitTrees) { _ in
            // The strip's order has to follow the layout, because ⌘1-9, tab
            // cycling, and every drag destination read the order rather than
            // the drawing.
            alignTabOrderWithLayout()
        }
        .onChange(of: projection.paneGroups) { paneGroups in
            // The Host is the authority: adopting its arrangements after every
            // roster change is what makes a second client's edit, or a
            // reconciliation on the Host, visible here.
            //
            // The new value is passed in because `projection` still reads the
            // previous roster inside this callback. Reading it there missed a
            // group created and shaped in one roster update, so the window kept
            // rendering the old arrangement under the new one's tree and the
            // next edit was written to the old group.
            adoptHostPaneGroups(paneGroups)
        }
        .onChange(of: projection.tabs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
        }
        .onChange(of: navigation) { navigation in
            // The new value is passed in: `navigation` still reads the previous
            // selection inside this callback.
            showPaneGroup(containing: navigation.selectedTabID)
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
            releaseFoldOfSelectedPane()
        }
        .onChange(of: creatingSessionWorkspaceIDs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
        }
        .onChange(of: createdSessionIDsByToken) { _ in
            reconcilePendingSplitMutations()
        }
        .onAppear {
            sidebarPeek.setCollapsed(sidebarState.isCollapsed)
            sidebarPeek.setWindowKey(controlActiveState == .key)
            reconcilePersistedSplitTree()
            alignTabOrderWithLayout()
            // Prime the manager before the first AppKit layout pass. A
            // workspace restored directly into Editor mode still keeps the
            // terminal branch mounted underneath the editor.
            onActiveScreenSessionsWillChange(activeVisibleSessions)
            onActiveScreenSessionsChanged(activeVisibleSessions)
            // Adopt the Host's arrangements once at mount, so a restored split
            // is on screen before the next roster change arrives.
            adoptHostPaneGroups(projection.paneGroups)
            // The monitor only forwards a command notification. Resolving the
            // current presentation in `.onReceive` avoids retaining the tab
            // and scope captured by the first SwiftUI appearance.
            EmacsSplitChordMonitor.shared.onAction = { action in
                let command: Notification.Name
                switch action {
                case .splitBelow: command = WarrenDesktopCommand.splitBelow
                case .splitRight: command = WarrenDesktopCommand.splitRight
                case .closePane: command = WarrenDesktopCommand.closePane
                case .maximize: command = WarrenDesktopCommand.maximizePane
                case .otherPane: command = WarrenDesktopCommand.otherPane
                }
                NotificationCenter.default.post(name: command, object: nil)
                return true
            }
            EmacsSplitChordMonitor.shared.onChordStateChanged = { inChord in
                emacsChordActive = inChord
            }
            // The chord swallows `C-x` app-wide, so it stays opt-in: the split
            // commands are always reachable from the View menu and its Command
            // shortcuts. Menu equivalents never take a key away from the shell.
            if splitChordsEnabled {
                EmacsSplitChordMonitor.shared.start()
            }
        }
        .onChange(of: splitChordsEnabled) { enabled in
            if enabled {
                EmacsSplitChordMonitor.shared.start()
            } else {
                EmacsSplitChordMonitor.shared.stop()
                emacsChordActive = false
            }
        }
        .onDisappear {
            EmacsSplitChordMonitor.shared.stop()
        }
        .overlay {
            renameDialog
        }
        .overlay {
            taskCreatorDialog
        }
        .overlay {
            deletionDialog
        }
        .overlay {
            hostDeletionDialog
        }
        .overlay {
            if commandPalettePresented {
                GeometryReader { proxy in
                    let panelWidth = min(
                        WarrenLayoutMetrics.commandPaletteWidth,
                        max(0, proxy.size.width - WarrenSpacing.standard * 2)
                    )
                    let resultsMaxHeight = max(
                        0,
                        proxy.size.height * 0.8
                            - WarrenLayoutMetrics.commandInputHeight
                            - WarrenLayoutMetrics.commandPaletteFooterHeight
                            - WarrenSpacing.hairline * 2
                    )
                    ZStack(alignment: .top) {
                        WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial).modalScrim
                            .ignoresSafeArea()
                            .onTapGesture { setCommandPalettePresented(false) }

                        WarrenDesktopCommandPalette(
                            projection: projection,
                            onAction: dispatch,
                            onDismiss: { setCommandPalettePresented(false) },
                            width: panelWidth,
                            resultsMaxHeight: resultsMaxHeight
                        )
                        .padding(.top, max(WarrenSpacing.standard, proxy.size.height * 0.5 - 278))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
                .zIndex(WarrenPresentationLayer.commandSurface)
            }
        }
        .overlay {
            chromePopoverLayer(
                presentation: presentation,
                externalIDEOptions: externalIDEOptions
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if emacsChordActive {
                let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
                Text("C-x-")
                    .font(WarrenTypography.mono.weight(.bold))
                    .foregroundStyle(tokens.hudForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tokens.hudSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(WarrenSpacing.medium)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            noticeToasts
        }
        .overlay(alignment: .bottom) {
            WarrenCopyFeedbackHUD()
                .padding(.bottom, WarrenLayoutMetrics.windowInset + WarrenSpacing.medium)
        }
        .environment(\.warrenPaneGroupHover, paneGroupHover)
        .environment(\.warrenMenuCenter, menuCenter)
        .warrenMenuOverlay(menuCenter)
        .warrenTooltipHost()
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
    }

    /// New notices rise over the sidebar's foot, at the sidebar's width; with
    /// the sidebar hidden they take the same corner of the window.
    var noticeToasts: some View {
        let inset = WarrenLayoutMetrics.windowInset + WarrenDesktopSidebarMetrics.contentHorizontalInset
        let width = sidebarState.isCollapsed
            ? 300
            : sidebarState.width - WarrenDesktopSidebarMetrics.contentHorizontalInset * 2
        return WarrenDesktopNoticeToastStack(
            notices: notices,
            isMuted: notificationsMuted,
            onOpen: {
                // The notice center hangs off the tab bar's bell, which is
                // on screen whether or not the sidebar is.
                withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                    isNoticePopoverPresented = true
                }
            }
        )
        .frame(width: width)
        .padding(.leading, inset)
        .padding(.bottom, inset + WarrenDesktopSidebarMetrics.footerHeight)
    }

    static func scopedSidebarSelection(
        _ selection: WarrenDesktopSidebarSelection?,
        endpointID: String
    ) -> WarrenDesktopSidebarResourceSelection? {
        let scope = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, let selection else { return nil }
        switch selection {
        case .project(let projectID):
            return .project(
                WarrenDesktopHostResourceRef(endpointID: scope, id: projectID)
            )
        case .workspace(let workspaceID):
            return .workspace(
                WarrenDesktopHostResourceRef(endpointID: scope, id: workspaceID)
            )
        }
    }

    /// The sidebar's Host row: the selected execution server's name, where it
    /// is, and how its connection is doing.
    var sidebarHostSummary: WarrenDesktopSidebarHostIdentity {
        let option = endpointOptions.first { $0.id == selectedEndpointID }
        let isLocal = option?.isLocal ?? true
        // With several Hosts in the tree, each section names its own; the
        // row says only that there are several.
        let sidebarHostCount = usesSidebarHostSections ? (sidebarHostProjections?.count ?? 0) : 0
        if sidebarHostCount > 1 {
            return WarrenDesktopSidebarHostIdentity(
                name: "Multiple hosts",
                subtitle: "\(sidebarHostCount) in sidebar",
                isLocal: isLocal,
                connectionState: projection.connectionState
            )
        }
        let names = WarrenDesktopSidebarHostIdentity.names(
            hostName: projection.host.name,
            endpointLabel: option?.label,
            endpointDetail: option?.detail
        )
        return WarrenDesktopSidebarHostIdentity(
            name: names.name,
            subtitle: WarrenDesktopSidebarHostIdentity.subtitle(
                isLocal: isLocal,
                detail: names.detail,
                connectionState: projection.connectionState
            ),
            isLocal: isLocal,
            connectionState: projection.connectionState,
            address: option?.detail
        )
    }

    /// Every other execution server, for the foot of the sidebar. A Host whose
    /// sections this window already loads also reports its connection and the
    /// states of its Sessions; any other Host has only its last probe to go on.
    var sidebarOtherHosts: [WarrenDesktopSidebarOtherHost] {
        let loaded = Dictionary(
            (sidebarHostProjections ?? []).map { ($0.endpointID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return endpointOptions
            .filter { $0.id != selectedEndpointID }
            .map { option in
                let host = loaded[option.id]
                let marks = host?.activeSessionsByWorkspaceID.values
                    .joined()
                    .compactMap { $0.activityMark?.isDrawn == true ? $0.activityMark : nil }
                    .sorted(by: >) ?? []
                return WarrenDesktopSidebarOtherHost(
                    id: option.id,
                    name: option.label,
                    isLocal: option.isLocal,
                    address: WarrenDesktopSidebarOtherHost.address(fromDetail: option.detail),
                    isOnline: host?.connectionState.isConnected ?? !option.probeFailed,
                    marks: marks,
                    isDisplayedInSidebar: option.isDisplayedInSidebar
                )
            }
    }

    /// The window's own Host, for the selected first row of the foot's panel.
    var sidebarCurrentHost: WarrenDesktopSidebarOtherHost? {
        guard let option = endpointOptions.first(where: { $0.id == selectedEndpointID }) else {
            return nil
        }
        return WarrenDesktopSidebarOtherHost(
            id: option.id,
            name: sidebarHostSummary.name,
            isLocal: option.isLocal,
            address: WarrenDesktopSidebarOtherHost.address(fromDetail: option.detail),
            isOnline: projection.connectionState.isConnected,
            isDisplayedInSidebar: true
        )
    }

    /// The dot the collapsed sidebar button carries.
    ///
    /// It is the strongest request among every Session the person is not
    /// already looking at — the current Tab is the one they are looking at —
    /// across this Host and the others. Working and ready Sessions draw
    /// nothing, so the dot stays a request rather than a heartbeat.
    var sidebarAttentionMark: WarrenActivityMark? {
        let currentHostMarks = WarrenDesktopSidebarAttention
            .unattended(projection.sessions, selectedTabID: navigation.selectedTabID)
            .map(\.activityMark)
        let otherHostMarks = sidebarOtherHosts.flatMap(\.marks)
        return WarrenDesktopSidebarAttention.mark(among: currentHostMarks + otherHostMarks)
    }

    /// The approval tray's rows: this Host's other Sessions an Agent has
    /// stopped for, with the decision when this client holds it.
    var approvalTrayEntries: [WarrenDesktopApprovalTrayEntry] {
        WarrenDesktopApprovalTray.entries(
            sessions: projection.sessions,
            selectedTabID: navigation.selectedTabID,
            decisions: pendingDecisions.decisions,
            title: { session in
                let workspace = session.workspaceID.flatMap { projection.workspace(id: $0) }
                return WarrenDesktopTabTitle
                    .sessionTitle(for: session, worktreeRoot: workspace?.path ?? "")
                    .title
            },
            location: { session in
                guard let workspace = session.workspaceID.flatMap({ projection.workspace(id: $0) }) else {
                    return ""
                }
                let project = projection.projectGroup(id: workspace.projectID)?.project.name
                let branch = workspace.branch?.isEmpty == false ? workspace.branch : workspace.name
                return [project, branch].compactMap { $0 }.joined(separator: " \u{00B7} ")
            }
        )
    }

    /// The pill the tab bar carries; it reads its rows from `approvalTray`.
    var approvalTrayPill: AnyView {
        AnyView(WarrenDesktopApprovalTrayPill(
            store: approvalTray,
            onOpen: { dispatch(.openSession($0)) },
            onResolve: pendingDecisions.resolve
        ))
    }

    /// The peek's entry motion: 14pt of travel plus a fade, or a plain fade
    /// when the system asks for less motion.
    var sidebarPeekTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(x: -14))
    }

    /// The peek still fades when motion is reduced; only its travel is dropped.
    var sidebarPeekAnimation: Animation {
        .easeOut(duration: WarrenMotion.stateChangeDuration)
    }

    /// The docked rail's collapse and expand. `.snappy` is macOS 14 and later;
    /// the deployment floor keeps a short ease-out instead.
    var sidebarCollapseAnimation: Animation? {
        guard !reduceMotion else { return nil }
        if #available(macOS 14, *) {
            return .snappy
        }
        return WarrenMotion.animation(.stateChange, reduceMotion: false)
    }

    var selectedEndpointIsLocal: Bool {
        endpointOptions.first { $0.id == selectedEndpointID }?.isLocal == true
    }

    func makeExternalIDEOptions(
        for presentation: Presentation
    ) -> [WarrenDesktopExternalIDEOption]? {
        guard endpointCapabilities.canOpenExternalIDE else { return nil }
        return presentation.workspace.map { workspace in
            externalIDEService.options(
                for: workspace,
                isLocalEndpoint: selectedEndpointIsLocal
            )
        }
    }

    @ViewBuilder
    func chromePopoverLayer(
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> some View {
        // Each surface is its own child, so it comes and goes with its own
        // transition; the layer itself never leaves. The Host picker hangs
        // from the sidebar's Host row, the rest from the top row's trailing
        // capsule.
        let active = chromePopover
        GeometryReader { geo in
            ZStack {
                if active != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { setChromePopover(nil) }
                        .ignoresSafeArea()
                        // Escape closes the surface even while the terminal
                        // keeps the key focus, which it usually does.
                        .background { WarrenDesktopEscapeMonitor { setChromePopover(nil) } }
                }

                ZStack(alignment: .topLeading) {
                    if active == .hostPicker {
                        hostPickerPopover
                            .environment(\.warrenMenuMaxHeight, geo.size.height - hostPickerTop - Self.chromePopoverBottomMargin)
                            .padding(.top, hostPickerTop)
                            .padding(.leading, WarrenLayoutMetrics.windowInset + WarrenDesktopSidebarHostStackMetrics.panelInset)
                            .transition(WarrenDesktopPopMotion.transition(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                ZStack(alignment: .bottomLeading) {
                    if active == .addHost {
                        addHostPopover
                            .environment(\.warrenMenuMaxHeight, geo.size.height - addHostBottom - Self.chromePopoverBottomMargin)
                            .padding(.bottom, addHostBottom)
                            .padding(.leading, WarrenLayoutMetrics.windowInset + WarrenDesktopSidebarHostStackMetrics.panelInset)
                            .transition(WarrenDesktopPopMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                ZStack(alignment: .topTrailing) {
                    if let active, active != .hostPicker, active != .addHost {
                        trailingChromePopover(
                            active,
                            presentation: presentation,
                            externalIDEOptions: externalIDEOptions
                        )
                        .environment(\.warrenMenuMaxHeight, geo.size.height - Self.trailingChromePopoverTop - Self.chromePopoverBottomMargin)
                        .padding(.top, Self.trailingChromePopoverTop)
                        .padding(.trailing, WarrenLayoutMetrics.windowInset)
                        .transition(WarrenDesktopPopMotion.transition(reduceMotion: reduceMotion))
                        .id(active)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// Where the top-right surfaces hang: under the top bar's capsule.
    static var trailingChromePopoverTop: CGFloat {
        WarrenLayoutMetrics.windowInset
            + WarrenLayoutMetrics.tabBarHeight
            + WarrenDesktopMenuMetrics.anchorGap
    }

    /// How close a chrome surface may come to the window's bottom edge
    /// before it scrolls instead.
    static var chromePopoverBottomMargin: CGFloat { WarrenLayoutMetrics.windowInset + 8 }

    /// The top of the Host picker: under the sidebar's traffic-light row and
    /// Host row, a couple of points below the Host button. With the rail
    /// collapsed the button is in the top bar, so the surface hangs below it.
    var hostPickerTop: CGFloat {
        if sidebarState.isCollapsed {
            return WarrenLayoutMetrics.windowInset
                + WarrenLayoutMetrics.tabBarHeight
                + WarrenDesktopMenuMetrics.anchorGap
        }
        return WarrenLayoutMetrics.windowInset
            + WarrenDesktopSidebarMetrics.headerTrafficRowHeight
            + WarrenDesktopSidebarMetrics.headerHostRowHeight
            + 2
    }

    /// The Add SSH Host page rises from the sidebar's foot, where Hosts are
    /// managed; with the rail collapsed there is no foot, so it hangs from
    /// the window's bottom edge at the same place.
    var addHostBottom: CGFloat {
        WarrenLayoutMetrics.windowInset
            + (sidebarState.isCollapsed ? 0 : WarrenDesktopSidebarHostStackMetrics.height)
            + WarrenDesktopSidebarHostStackMetrics.panelGap
    }

    var hostPanelWidth: CGFloat {
        max(sidebarState.renderedWidth - 2 * WarrenDesktopSidebarHostStackMetrics.panelInset, 200)
    }

    var hostPickerPopover: some View {
        WarrenDesktopMenuSurface(width: hostPanelWidth) {
            WarrenDesktopCurrentHostPanel(
                connectionState: projection.connectionState,
                onRetry: onRetryConnection,
                onStop: onStopConnection,
                onDismiss: { setChromePopover(nil) },
                publicAccess: hostPanelPublicAccess,
                onSettings: { openSettings() }
            )
        }
        .onExitCommand { setChromePopover(nil) }
    }

    @ViewBuilder
    var addHostPopover: some View {
        if let sshHostPage {
            WarrenDesktopMenuSurface(width: hostPanelWidth) {
                WarrenDesktopSSHHostListView(model: WarrenDesktopSSHHostPageModel(
                    load: sshHostPage.load,
                    onAdd: { option in
                        sshHostPage.onAdd(option)
                        setChromePopover(nil)
                    },
                    onCopyFallback: sshHostPage.onCopyFallback,
                    onOpenConfig: sshHostPage.onOpenConfig
                ))
            }
            .onExitCommand { setChromePopover(nil) }
        }
    }

    func presentAddHost() {
        guard sshHostPage != nil else {
            setChromePopover(nil)
            onAddSSHHost()
            return
        }
        setChromePopover(.addHost)
    }

    func requestHostDeletion(_ endpointID: String) {
        guard endpointID != "local",
              let endpoint = endpointOptions.first(where: { $0.id == endpointID }) else { return }
        setChromePopover(nil)
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingHostDeletion = endpoint
        }
    }

    func dismissHostDeletion() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingHostDeletion = nil
        }
    }

    @ViewBuilder
    var hostDeletionDialog: some View {
        if let endpoint = pendingHostDeletion {
            WarrenDesktopDeleteHostConfirmation(
                hostName: endpoint.label,
                isWindowHost: endpoint.id == selectedEndpointID,
                onCancel: dismissHostDeletion,
                onConfirm: {
                    onDeleteEndpoint(endpoint.id)
                    dismissHostDeletion()
                }
            )
            .zIndex(WarrenPresentationLayer.modal)
        }
    }

    /// Public Access as the Host panel shows it: the row's state and address,
    /// plus the Web panel page it drills into.
    var hostPanelPublicAccess: WarrenDesktopHostPanelPublicAccess {
        let panel = WarrenDesktopWebPanel(
            status: webStatus,
            canControl: webStatus.canControl,
            canCopyLocalWebURL: endpointCapabilities.canCopyLocalWebURL,
            onStart: onWebStart,
            onOpenSettings: {
                setChromePopover(nil)
                openPublicAccessSettings()
            },
            onStop: onWebStop,
            onOpenURL: onWebOpenURL,
            onCopyURL: onWebCopyURL
        )
        return WarrenDesktopHostPanelPublicAccess(
            isOn: webStatus.tunnelRunning,
            url: WarrenDesktopWebAddressPresentation
                .addresses(for: webStatus, includeLocalURL: false)
                .first(where: { $0.kind == .publicAccess })?.url,
            content: AnyView(panel),
            copy: onWebCopyURL
        )
    }

    @ViewBuilder
    func trailingChromePopover(
        _ chromePopover: WarrenDesktopChromePopover,
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> some View {
        switch chromePopover {
        case .hostPicker, .addHost:
            EmptyView()
        case .externalIDE:
            if let options = externalIDEOptions {
                WarrenDesktopExternalIDEMenu(
                    options: options,
                    currentID: currentExternalIDEID(in: options),
                    onOpen: { option in
                        externalIDEID = option.id
                        openInExternalIDE(option)
                    },
                    onManageEditors: {
                        setChromePopover(nil)
                        openSettings(WarrenDesktopSettingsDeepLink(section: .externalIDEs))
                    },
                    onDismiss: { setChromePopover(nil) }
                )
            }
        case .newSession:
            WarrenDesktopMenuSurface(width: WarrenDesktopPresetBar.menuWidth) {
                WarrenDesktopPresetBar(
                    workspace: presentation.workspace,
                    isBusy: isAddingSession(in: presentation),
                    canUseEmbeddedBrowser: endpointCapabilities.canUseEmbeddedBrowser,
                    onLaunch: { request in
                        launchSession(request, in: presentation)
                    },
                    onDismiss: { setChromePopover(nil) },
                    onCustomize: {
                        openSettings(WarrenDesktopSettingsDeepLink(section: .presets))
                    }
                )
            }
        }
    }

    /// Resolve all selection-dependent UI values once per body evaluation.
    /// SwiftUI asks for these values in several branches and closures; keeping
    /// one immutable presentation value avoids repeated graph lookups while
    /// preserving the navigation ownership rules.
    func makeTabBarView(
        presentation: Presentation,
        tabTitles: [String: String],
        tabMarks: [TerminalSessionID: WarrenActivityMark],
        shellMarks: [TerminalSessionID: WarrenActivityMark] = [:],
        tabCommands: [String: String] = [:],
        leadSessionIDs: Set<TerminalSessionID> = [],
        stoppedSessionIDs: Set<TerminalSessionID> = [],
        pinnedSessionIDs: Set<TerminalSessionID>,
        isAddingSession: Bool,
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> AnyView {
        // The bar draws the tree it is about, and the display mode decides
        // which one that is. Rich mode's tree already lists Sessions, so the bar
        // is a pure pane control: it draws what is on screen, and a Session
        // visited from outside the layout is drawn alone rather than under a
        // group for panes the user cannot see. Compact mode's tree does not list
        // Sessions, so the bar keeps the scope's layout throughout: the group is
        // the only way back into the split while another Session is visited.
        let barTree = workspaceDisplayMode.isRich
            ? currentSplitTree(presentation: presentation)
            : scopeSplitTree(presentation: presentation)
        let paneBar = WarrenDesktopPaneBar.presentation(
            visibleIn: barTree,
            from: presentation.tabs,
            selected: presentation.tab,
            mode: workspaceDisplayMode,
            solo: { entries in
                soloPaneIdentity(
                    entries: entries,
                    presentation: presentation,
                    tabTitles: tabTitles,
                    tabMarks: tabMarks,
                    shellMarks: shellMarks
                )
            }
        )
        return AnyView(WarrenDesktopTabBar(
            presentation: paneBar,
            tabTitles: tabTitles,
            tabMarks: tabMarks,
            shellMarks: shellMarks,
            tabCommands: tabCommands,
            leadSessionIDs: leadSessionIDs,
            stoppedSessionIDs: stoppedSessionIDs,
            pinnedSessionIDs: pinnedSessionIDs,
            selectedTabID: navigation.selectedTabID,
            splitGroups: splitGroups(presentation: presentation),
            onCopyPaneTitle: {
                copySoloPaneTitle(presentation: presentation)
            },
            soloTitleActions: { solo in
                makeSoloTitleActions(
                    solo,
                    presentation: presentation,
                    externalIDEOptions: externalIDEOptions
                )
            },
            isSidebarCollapsed: sidebarState.isCollapsed,
            onToggleSidebar: toggleSidebar,
            sidebarAttentionMark: sidebarAttentionMark,
            onSidebarButtonHover: { sidebarPeek.setPointer(.sidebarButton, isInside: $0) },
            onChromePopover: { popover in
                setChromePopover(chromePopover == popover ? nil : popover)
            },
            rightSidebarOpen: showsRightSidebar(for: presentation.workspace),
            rightSidebarAvailable: rightSidebarAvailable(for: presentation.workspace),
            onToggleRightSidebar: { toggleRightSidebar(in: presentation) },
            collapsedHost: sidebarState.isCollapsed
                ? WarrenDesktopCollapsedHost(
                    name: projection.host.name,
                    reachability: WarrenDesktopHostReachability(projection.connectionState),
                    isPublicAccessOn: webStatus.tunnelRunning,
                    isPickerPresented: chromePopover == .hostPicker,
                    toggle: {
                        setChromePopover(chromePopover == .hostPicker ? nil : .hostPicker)
                    }
                )
                : nil,
            onSelectTab: { selectTabFromTabBar($0, in: presentation) },
            onMoveTab: { tabID, destinationTabID in
                detachPaneLeavingLayout(tabID, before: destinationTabID, in: presentation)
                dispatch(.moveTab(tabID, before: destinationTabID))
            },
            onSplitDrop: { targetPaneID, droppedTabID, target in
                handleSplitDrop(
                    targetPaneID: targetPaneID,
                    droppedTabID: droppedTabID,
                    target: target,
                    in: presentation
                )
            },
            sessionMoveTargets: sessionMoveTargets,
            sessionMoveDestinations: sessionMoveDestinations,
            onMoveSession: { sessionID, destination in
                dispatch(.moveSession(sessionID, to: destination))
            },
            canAddTab: presentation.workspace != nil,
            isAddingTab: isAddingSession,
            onAddTab: {
                handleNewSession(in: presentation)
            },
            hasNewSessionMenu: true,
            onCloseTab: { tabID in
                handleCloseTab(tabID, in: presentation)
            },
            onCloseOtherTabs: { tabID in
                handleCloseOtherTabs(tabID, in: presentation)
            },
            onCloseAllTabs: { tabID in
                handleCloseAllTabs(tabID, in: presentation)
            },
            onRequestRename: presentRename,
            onToggleSessionPin: { sessionID, pinned in
                dispatch(.setSessionPinned(sessionID, pinned))
            },
            onDismissActivity: { sessionID, activity in
                dispatch(.dismissActivity(sessionID, activity))
            },
            zoomedTabID: zoomedPaneID(in: barTree, presentation: presentation)
                .flatMap { barTree.item(for: $0)?.tabID },
            onToggleZoom: { tabID in
                toggleZoom(tabID: tabID, in: presentation)
            },
            onSplitGroup: {
                handleSplitRight(in: presentation)
            },
            onUngroup: {
                handleUngroup(in: presentation)
            },
            onMergeIntoGroup: { tabID in
                handleMergeIntoGroup(tabID, in: presentation)
            },
            trailingAccessory: approvalTrayPill,
            // The bell lives at the sidebar's foot; with the sidebar hidden
            // the top bar carries it so it stays on screen.
            noticeBell: sidebarState.isCollapsed ? noticeBell(panelEdge: .below) : nil
        ))
    }

    /// The bell that opens the notice center. Only one is on screen at a
    /// time (the sidebar's or the top bar's), since both share one binding.
    func noticeBell(panelEdge: WarrenDesktopMenuEdge) -> AnyView {
        AnyView(WarrenDesktopNoticeBell(
            notices: notices,
            isPresented: $isNoticePopoverPresented,
            onRead: onNoticeRead,
            onDismissNotice: onNoticeDismiss,
            onMarkAllRead: markAllNoticesRead,
            panelEdge: panelEdge
        ))
    }

    /// The sidebar card, shared by the docked column and the peek overlay.
    ///
    /// Picking a Session or Workspace retires the peek before the content
    /// changes underneath it; the docked column never has a peek to retire,
    /// so the same callbacks serve both.
    func makeSidebarView(
        presentation: Presentation,
        sidebarPresentation: WarrenDesktopSidebarPresentation
    ) -> some View {
        WarrenDesktopSidebar(
            projection: projection,
            presentation: sidebarPresentation,
            sidebarState: $sidebarState,
            sidebarTree: $sidebarTree,
            selection: navigation.selection,
            selectedTabID: navigation.selectedTabID,
            updateStatus: updateStatus,
            onUpdateAction: onUpdateAction,
            showsTasks: showsTasks,
            deletingProjectIDs: deletingProjectIDs,
            deletingWorkspaceIDs: deletingWorkspaceIDs,
            onRequestTaskCreate: presentTaskCreator,
            endpointCapabilities: endpointCapabilities,
            onAction: { action in
                if action.dismissesSidebarPeek { sidebarPeek.dismiss() }
                dispatch(action)
            },
            onCommandPalette: presentCommandPalette,
            onSettings: openSettings,
            onRequestRename: presentRename,
            onRequestDeletion: presentDeletion,
            activeEndpointID: selectedEndpointID,
            displayConfigurationError: displayConfigurationError,
            sidebarHostProjections: sidebarHostProjections,
            usesSidebarHostSections: usesSidebarHostSections,
            sidebarResourceSelection: sidebarResourceSelection,
            onSelectSidebarResource: { reference in
                sidebarPeek.dismiss()
                onSelectSidebarResource(reference)
            },
            onOpenSidebarWorkspace: onOpenSidebarWorkspace,
            onOpenSidebarSession: { reference in
                sidebarPeek.dismiss()
                onOpenSidebarSession(reference)
            },
            onRetrySidebarHost: onRetrySidebarHost,
            editorActivity: WarrenDesktopEditorActivityOverlay(
                states: workspaceEditorStates
            ),
            // The mark is a way into the editor: land on the Workspace's
            // Session, then put the editor page of the right sidebar on screen.
            onOpenEditor: { workspaceID in
                dispatch(.selectWorkspace(workspaceID))
                if let workspace = projection.workspace(id: workspaceID) {
                    openEditorRegion(for: workspace, restoringLastDocument: true)
                } else {
                    editorRegionWorkspaceIDs.insert(workspaceID)
                }
            },
            // A Session dropped from the tree lands in a pane exactly as a Tab
            // dropped from the strip does: the drag source resolves the pane
            // and the zone, and this performs the same split.
            onSplitDropSession: { paneID, tabID, target in
                handleSplitDrop(
                    targetPaneID: paneID,
                    droppedTabID: tabID,
                    target: target,
                    in: presentation
                )
            },
            hostSummary: sidebarHostSummary,
            isPublicAccessOn: webStatus.tunnelRunning,
            isHostPickerPresented: chromePopover == .hostPicker,
            onToggleHostPicker: {
                setChromePopover(chromePopover == .hostPicker ? nil : .hostPicker)
            },
            otherHosts: sidebarOtherHosts,
            onSelectHost: onSelectEndpoint,
            currentHost: sidebarCurrentHost,
            onAddHost: presentAddHost,
            onSetHostSidebarVisibility: onSetEndpointSidebarVisibility,
            onRenameHost: { id in
                guard let endpoint = endpointOptions.first(where: { $0.id == id }) else { return }
                onCustomizeEndpointDisplayName(endpoint)
            },
            onDeleteHost: requestHostDeletion,
            isCheckingHosts: endpointOptions.contains { $0.probeState == .checking },
            // The peek floats over a collapsed sidebar, when the top bar
            // already carries the bell.
            noticeBell: sidebarPresentation == .docked ? noticeBell(panelEdge: .above) : nil
        )
    }

    func makeWorkspaceColumn(
        presentation: Presentation,
        tabBarView: AnyView,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        isAddingSession: Bool,
        currentTree: SplitLayoutTree,
        currentPaneID: String
    ) -> AnyView {
        let sidebarTab = showsRightSidebar(for: presentation.workspace)
            ? selectedRightSidebarTab(for: presentation.workspace)
            : nil
        return AnyView(
            VStack(spacing: WarrenLayoutMetrics.cardGap) {
                // The presets live behind the tab bar's "+" button, so the
                // chrome above the Terminal is this one row. It sits above the
                // panes so the group shelf it drops is drawn over them.
                tabBarView
                    .zIndex(1)
                // One split whether or not the sidebar is beside the Terminal,
                // so opening or closing it only changes widths and never
                // re-creates the Terminal. The Inspector and the editor share
                // this column, so the page chooses the width it is dragged by.
                let inspectorPage = sidebarTab?.inspectorTab != nil
                WarrenDesktopCentralSplit(
                    terminalRatio: inspectorPage ? $inspectorTerminalRatio : $terminalRatio,
                    trailingMinimumWidth: inspectorPage
                        ? WarrenLayoutMetrics.inspectorMinimumWidth
                        : WarrenLayoutMetrics.editorRegionMinimumWidth,
                    defaultRatio: inspectorPage
                        ? WarrenLayoutMetrics.inspectorSplitDefaultRatio
                        : WarrenLayoutMetrics.editorSplitDefaultRatio,
                    accessibilityName: inspectorPage
                        ? "Terminal and Inspector split"
                        : "Terminal and editor split",
                    terminal: terminalRegion(
                        presentation: presentation,
                        currentTree: currentTree,
                        currentPaneID: currentPaneID
                    ),
                    editor: sidebarTab.map {
                        rightSidebarRegion(
                            tab: $0,
                            presentation: presentation,
                            externalIDEOptions: externalIDEOptions
                        )
                    }
                )
            }
        )
    }

    /// The right sidebar for one page: the Inspector's pages and the embedded
    /// editor are tabs of one card.
    func rightSidebarRegion(
        tab: WarrenDesktopRightSidebarTab,
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> AnyView? {
        guard let workspace = presentation.workspace else { return nil }
        let currentIDE = externalIDEOptions.flatMap { options in
            options.first { $0.id == externalIDEID } ?? options.first
        }
        let externalIDE = externalIDEOptions.map { _ in
            WarrenDesktopRightSidebar.ExternalIDE(
                name: currentIDE?.name,
                icon: currentIDE?.icon,
                canOpen: currentIDE?.isEnabled ?? false,
                isMenuPresented: chromePopover == .externalIDE,
                open: {
                    if let currentIDE { openInExternalIDE(currentIDE) }
                },
                presentMenu: { setChromePopover(.externalIDE) },
                chooseActions: externalIDEChooseActions(externalIDEOptions ?? [])
            )
        }
        return AnyView(WarrenDesktopRightSidebar(
            tab: tab,
            inspectorAvailable: inspectorSurface != nil,
            editorAvailable: editorAvailable(for: workspace),
            editorRunning: showsEditorRegion(for: workspace),
            changeCount: inspectorActivity.changeCount,
            inspectorContent: { inspectorTab in
                AnyView(
                    inspectorSurface?(workspace, inspectorTab, inspectorActivity)
                        ?? AnyView(EmptyView())
                )
            },
            editorContent: { AnyView(editorSurface(workspace)) },
            onSelectTab: { selectRightSidebarTab($0, in: presentation) },
            onCloseEditor: { closeEditorRegion(for: workspace) },
            externalIDE: externalIDE
        ))
    }

    /// Whether the right sidebar is open for this Workspace: the user's switch
    /// is up and the column has something to show.
    func showsRightSidebar(for workspace: Workspace?) -> Bool {
        inspectorOpen && rightSidebarAvailable(for: workspace)
    }

    func rightSidebarAvailable(for workspace: Workspace?) -> Bool {
        inspectorSurface != nil || editorAvailable(for: workspace)
    }

    func editorAvailable(for workspace: Workspace?) -> Bool {
        embeddedEditorAvailable && workspace != nil
    }

    /// The page the sidebar would show, honoring what the Workspace
    /// remembered and falling back when that page no longer exists.
    func selectedRightSidebarTab(
        for workspace: Workspace?
    ) -> WarrenDesktopRightSidebarTab? {
        WarrenDesktopRightSidebarTab.resolve(
            workspace.flatMap { rightSidebarTabs[$0.id] },
            inspectorAvailable: inspectorSurface != nil,
            editorAvailable: editorAvailable(for: workspace)
        )
    }

    /// The Editor a plain click opens: what the user last chose, else the first
    /// installed application.
    func currentExternalIDEID(
        in options: [WarrenDesktopExternalIDEOption]
    ) -> String? {
        options.contains { $0.id == externalIDEID } ? externalIDEID : options.first?.id
    }

    /// The top bar's toggle and the ⌥⌘B command: one switch for the whole
    /// sidebar, not a choice between the Inspector and the editor.
    func toggleRightSidebar(in presentation: Presentation) {
        guard let workspace = presentation.workspace,
              rightSidebarAvailable(for: workspace) else { return }
        if inspectorOpen {
            inspectorOpen = false
            return
        }
        inspectorOpen = true
        if embeddedEditorDefaultIDE, editorAvailable(for: workspace) {
            selectRightSidebarTab(.editor, in: presentation)
        } else if let resolved = selectedRightSidebarTab(for: workspace) {
            selectRightSidebarTab(resolved, in: presentation)
        }
    }

    func selectRightSidebarTab(
        _ tab: WarrenDesktopRightSidebarTab,
        in presentation: Presentation
    ) {
        guard let workspace = presentation.workspace else { return }
        switch tab {
        case .editor:
            rightSidebarTabs[workspace.id] = .editor
            openEditorRegion(for: workspace, restoringLastDocument: true)
        case .inspector(let inspector):
            lastInspectorTabs[workspace.id] = inspector
            rightSidebarTabs[workspace.id] = .inspector(inspector)
        }
    }

    /// The Terminal half of the central area.
    ///
    /// Identical whether or not the editor region is beside it. The old exclusive
    /// mode cross-faded two stacked views and reported an empty screen set on the
    /// way in; the terminal tree is now simply narrower, so nothing about it is
    /// re-created when the editor opens.
    func terminalRegion(
        presentation: Presentation,
        currentTree: SplitLayoutTree,
        currentPaneID: String
    ) -> AnyView {
        AnyView(
            WarrenDesktopWorkspaceContent(
                workspace: presentation.contentWorkspace,
                tab: presentation.tab,
                hasProjects: !projection.groups.isEmpty,
                connectionState: projection.connectionState,
                isMigratingRuntimeSessions: isMigratingRuntimeSessions,
                endpointCapabilities: endpointCapabilities,
                // A per-pane header answers "which of these panes", which
                // only exists in a split. With one pane the top chrome row
                // carries the identity instead, so this band would restate it.
                showsPaneHeader: currentTree.count > 1,
                session: presentation.session,
                hostName: projection.host.name,
                titleTemplate: TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate),
                terminalFont: TerminalFontPreference(
                    family: terminalFontFamily,
                    size: terminalFontSize
                ),
                // Opening the editor region no longer takes focus from
                // the Terminal on every layout pass. Focus follows the
                // click that moved it, which is what returns the control
                // lease when the user clicks back into the Terminal.
                //
                // While the editor holds the keyboard the intent has to say so
                // too. Reconciliation claims focus for the selected pane
                // whenever this is true, so leaving it set let a later layout
                // pass pull the keyboard back out of the editor mid-edit.
                wantsTerminalFocus: !commandPalettePresented
                    && !editorHasKeyboardFocus
                    && !browserHasKeyboardFocus,
                splitTree: currentTree,
                activePaneID: currentPaneID,
                zoomedPaneID: zoomedPaneID(in: currentTree, presentation: presentation),
                foldedPaneID: foldedPaneID(in: currentTree, presentation: presentation),
                allTabs: presentation.tabs,
                sessionLookup: { sessionID in
                    projection.session(id: sessionID)
                },
                onSelectPane: { paneID in
                    handleSelectPane(paneID, in: presentation, tree: currentTree)
                },
                onClosePane: { paneID in
                    handleClosePane(paneID: paneID, in: presentation)
                },
                onMaximizePane: { paneID in
                    handleMaximizePane(paneID: paneID, in: presentation)
                },
                onRestoreLayout: {
                    guard let scope = currentScopeKey(presentation: presentation) else { return }
                    zoomedPaneIDs.removeValue(forKey: scope)
                },
                onResizeSplit: { splitPath, ratio in
                    handleResizeSplit(splitPath: splitPath, ratio: ratio, in: presentation)
                },
                onFoldPane: { paneID, splitPath, restoreRatio in
                    handleFoldPane(
                        paneID,
                        splitPath: splitPath,
                        restoreRatio: restoreRatio,
                        in: presentation
                    )
                },
                onUnfoldPane: { paneID in
                    handleSelectPane(paneID, in: presentation, tree: currentTree)
                },
                onRetryConnection: onRetryConnection,
                // Other Hosts are listed at the sidebar's foot; with the rail
                // collapsed that list is gone, so the card brings it back.
                onSwitchHost: sidebarState.isCollapsed && !sidebarOtherHosts.isEmpty
                    ? { toggleSidebar() }
                    : nil,
                onAddProject: { dispatch(.addProject) },
                onImportSuperset: { dispatch(.importSuperset) },
                terminalSurface: terminalSurface
            )
        )
    }

    // MARK: - Embedded editor rail and region (RFC 0021)

    func editorKey(for workspace: Workspace) -> WarrenDesktopWorkspaceEditorKey {
        WarrenDesktopWorkspaceEditorKey(
            hostId: selectedEndpointID,
            workspaceId: workspace.id
        )
    }

    static func enabledWorkspaceIDs(
        in states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState],
        hostId: String
    ) -> Set<WorkspaceID> {
        Set(
            states
                .filter { $0.key.hostId == hostId && $0.value.enabled }
                .map(\.key.workspaceId)
        )
    }

    func showsEditorRegion(for workspace: Workspace?) -> Bool {
        guard embeddedEditorAvailable, let workspace else { return false }
        return editorRegionWorkspaceIDs.contains(workspace.id)
    }

    /// Opens the region for a Workspace and marks it.
    ///
    /// `restoringLastDocument` asks the runtime to reopen the stored document, so
    /// re-entering a Workspace lands on the file the user left rather than on
    /// code-server's empty editor area — which cannot be collapsed below its
    /// 220pt floor, so an empty area would otherwise occupy real width. The
    /// terminal-link path passes `false`: that request already carries a document
    /// of its own and is opening it directly.
    func openEditorRegion(
        for workspace: Workspace?,
        restoringLastDocument: Bool,
        recording document: WarrenDesktopEditorDocument? = nil
    ) {
        guard embeddedEditorAvailable, let workspace else { return }
        // Selecting the page is what opens the sidebar as well: the terminal
        // link path asks for the editor directly and expects it on screen.
        rightSidebarTabs[workspace.id] = .editor
        inspectorOpen = true
        let key = editorKey(for: workspace)
        var state = workspaceEditorStates[key] ?? WarrenDesktopWorkspaceEditorState(
            hostId: key.hostId,
            workspaceId: key.workspaceId,
            enabled: true
        )
        state.enabled = true
        if let document {
            state.lastRelativeFile = document.relativeFile
            state.lastLine = document.line
            state.lastColumn = document.column
        }
        state.updatedAt = Date()
        workspaceEditorStates[key] = state

        editorRegionWorkspaceIDs.insert(workspace.id)

        if restoringLastDocument, let relativeFile = state.lastRelativeFile {
            onOpenEditorDocument(
                workspace,
                WarrenDesktopEditorDocument(
                    relativeFile: relativeFile,
                    line: state.lastLine,
                    column: state.lastColumn
                )
            )
        }
    }

    /// Closes the region and clears the Workspace's marker.
    ///
    /// One close, not two. RFC 0021 §6.1 originally kept the marker through a
    /// close and asked for a separate `Forget Editor for Workspace`, so closing
    /// the editor and relaunching brought it back — which reads as a bug rather
    /// than as preserved state. Closing now means the user is done with it.
    ///
    /// `hostId` names the Endpoint that owned the row rather than whichever is
    /// selected when the call happens, because a Workspace UUID alone does not
    /// identify a marker. A deletion confirmation is already gated on the two
    /// agreeing; passing the captured Endpoint keeps that from being the only
    /// thing standing between this and another Host's record.
    func closeEditorRegion(for workspace: Workspace, hostId: String? = nil) {
        editorRegionWorkspaceIDs.remove(workspace.id)
        workspaceEditorStates.removeValue(
            forKey: WarrenDesktopWorkspaceEditorKey(
                hostId: hostId ?? selectedEndpointID,
                workspaceId: workspace.id
            )
        )
        // Closing the region keeps the sidebar up; the Editor page falls back to
        // the Inspector page it came from.
        if rightSidebarTabs[workspace.id]?.isEditor == true {
            rightSidebarTabs[workspace.id] = .inspector(
                lastInspectorTabs[workspace.id] ?? .changes
            )
        }
    }

    /// Every value `settingsOverlay` hands the page. Its closures all reach
    /// the app model or this view's state through references, so the page
    /// keeps working when it is not rebuilt; only these values can go stale.
    /// `settingsOverlay` reads its values from here and nowhere else, so a
    /// value cannot reach the page without also rebuilding it when it changes.
    var settingsInputs: WarrenDesktopSettingsInputs {
        WarrenDesktopSettingsInputs(
            hostName: projection.host.name,
            webStatus: webStatus,
            lanPairing: lanPairing,
            relaySettings: relaySettings,
            relayDevices: relayDevices,
            remoteAccess: remoteAccess,
            defaultRuntime: defaultRuntime,
            autoOpenShell: autoOpenShell,
            autoStartAI: autoStartAI,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            openAITitleEnabled: openAITitleEnabled,
            // Projects only: the page never reads a group's Workspaces,
            // and their branch and status churn is not a Settings change.
            projects: projection.groups.map(\.project),
            usageStats: usageStats,
            usageState: usageState,
            initialSettingsSection: settingsDeepLinkSection,
            publicAccessPrefill: settingsPublicAccessPrefill,
            relayPrefill: settingsRelayPrefill,
            hostOptions: endpointOptions,
            selectedHostID: selectedEndpointID
        )
    }

    var settingsOverlay: AnyView {
        let inputs = settingsInputs
        return AnyView(
            WarrenDesktopSettingsView(
                onBack: closeSettings,
                hostName: inputs.hostName,
                webStatus: inputs.webStatus,
                onWebTest: onWebTest,
                onWebStop: onWebStop,
                onWebReset: onWebReset,
                onRelayEnroll: onRelayEnroll,
                onRelayPairing: onRelayPairing,
                lanPairing: inputs.lanPairing,
                onLANPairing: onLANPairing,
                relaySettings: inputs.relaySettings,
                onSetRelayEnabled: onSetRelayEnabled,
                onResetRelay: onResetRelay,
                relayDevices: inputs.relayDevices,
                onLoadRelayDevices: onLoadRelayDevices,
                onRevokeRelayDevice: onRevokeRelayDevice,
                remoteAccess: inputs.remoteAccess,
                onLoadRemoteAccess: onLoadRemoteAccess,
                onSetRemoteEnabled: onSetRemoteEnabled,
                onSetRemoteRelay: onSetRemoteRelay,
                onRemoteShare: onRemoteShare,
                onRotateRemote: onRotateRemote,
                defaultRuntime: inputs.defaultRuntime,
                onSetRuntime: onSetRuntime,
                autoOpenShell: inputs.autoOpenShell,
                onSetAutoOpenShell: onSetAutoOpenShell,
                autoStartAI: inputs.autoStartAI,
                onSetAutoStartAI: onSetAutoStartAI,
                openAIBaseURL: inputs.openAIBaseURL,
                openAIModel: inputs.openAIModel,
                openAITitleEnabled: inputs.openAITitleEnabled,
                onSetOpenAISetting: onSetOpenAISetting,
                onTestOpenAI: onTestOpenAI,
                projects: inputs.projects,
                onSetProjectSetupScript: onSetProjectSetupScript,
                usageStats: inputs.usageStats,
                usageState: inputs.usageState,
                onLoadUsage: onLoadUsage,
                onRebuildUsage: onRebuildUsage,
                initialSettingsSection: inputs.initialSettingsSection,
                publicAccessPrefill: inputs.publicAccessPrefill,
                relayPrefill: inputs.relayPrefill,
                hostOptions: inputs.hostOptions,
                selectedHostID: inputs.selectedHostID,
                onSelectHost: onSelectEndpoint
            )
            .transition(.opacity)
        )
    }

    func makePresentation() -> Presentation {
        let interval = WarrenDesktopPerformance.signposter.beginInterval("SwiftUI Presentation")
        defer { WarrenDesktopPerformance.signposter.endInterval("SwiftUI Presentation", interval) }
        let navigationWorkspace: Workspace?
        switch navigation.selection {
        case .project(let projectID):
            navigationWorkspace = projection.firstWorkspace(in: projectID)
        case .workspace(let workspaceID):
            navigationWorkspace = projection.workspace(id: workspaceID)
        case nil:
            navigationWorkspace = firstWorkspace
        }
        let tabs = projection.tabs(in: navigationWorkspace?.id)
        let tab = navigation.selectedTabID.flatMap { selectedTabID in
            tabs.first { $0.id == selectedTabID }
        }
        let tabWorkspace = tab?.sessionID.flatMap { projection.workspace(for: $0) }
        let workspace = tabWorkspace ?? navigationWorkspace
        let session = tab?.sessionID.flatMap { projection.session(id: $0) }
        return Presentation(
            workspace: workspace,
            contentWorkspace: tabWorkspace ?? workspace,
            tab: tab,
            session: session,
            tabs: tabs
        )
    }

    var firstWorkspace: Workspace? {
        projection.firstWorkspace
    }

    func isAddingSession(in presentation: Presentation) -> Bool {
        if let workspace = presentation.workspace {
            return creatingSessionWorkspaceIDs.contains(workspace.id)
        }
        return false
    }

    func makeSessionMoveTargets() -> [WarrenDesktopSessionMoveTarget] {
        var targets: [WarrenDesktopSessionMoveTarget] = []
        for group in projection.groups {
            for workspace in group.workspaces {
                targets.append(WarrenDesktopSessionMoveTarget(
                    id: "workspace:\(workspace.id.description)",
                    title: "\(group.project.name) / \(workspace.name)",
                    destination: .workspace(workspace.id)
                ))
            }
        }
        return targets
    }

    func makeSessionMoveDestinations() -> [TerminalSessionID: WarrenDesktopSessionMoveDestination] {
        Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            projection.sessionWorkspaceIDs[session.id].map { (session.id, .workspace($0)) }
        })
    }

    func addSession(in presentation: Presentation) {
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id, token: UUID()))
        }
    }

    /// Launches a preset Session.
    ///
    /// Creation through the preset bar is an ordinary new Tab, exactly like the
    /// add control: only the split commands add a pane to the layout on screen.
    func launchSession(
        _ request: TerminalSessionLaunchRequest,
        in presentation: Presentation
    ) {
        if let workspace = presentation.workspace {
            dispatch(.launchSession(workspace.id, request))
        }
    }

    /// The editor button's right-click menu. Choosing an editor opens the
    /// Workspace there and makes it the button's editor, as the old drop-down
    /// did.
    func externalIDEChooseActions(
        _ options: [WarrenDesktopExternalIDEOption]
    ) -> [WarrenDesktopContextMenuAction] {
        let currentID = currentExternalIDEID(in: options)
        var actions: [WarrenDesktopContextMenuAction] = options.map { option in
            .check(title: option.name, isOn: option.id == currentID) {
                externalIDEID = option.id
                openInExternalIDE(option)
            }
        }
        if !actions.isEmpty { actions.append(.divider) }
        actions.append(.button(title: "Manage Editors…") {
            openSettings(WarrenDesktopSettingsDeepLink(section: .externalIDEs))
        })
        return actions
    }

    func openInExternalIDE(_ option: WarrenDesktopExternalIDEOption) {
        guard endpointCapabilities.canOpenExternalIDE else { return }
        Task {
            do {
                try await externalIDEService.open(option)
            } catch {
                onNoticeAdd(
                    "Unable to open \(option.name)",
                    error.localizedDescription,
                    String(reflecting: error),
                    .error
                )
            }
        }
    }

    func dispatch(_ action: WarrenDesktopAction) {
        switch action {
        case .openNotifications:
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                isNoticePopoverPresented.toggle()
            }
            actions(action)
        default:
            actions(action)
        }
    }

    func openSettings() {
        openSettings(nil)
    }

    func openPublicAccessSettings() {
        openSettings(WarrenDesktopSettingsDeepLink(section: .publicAccess))
    }

    func openSettings(_ request: WarrenDesktopSettingsDeepLink?) {
        setCommandPalettePresented(false)
        settingsDeepLinkSection = request?.section
        settingsPublicAccessPrefill = request?.publicAccess
        settingsRelayPrefill = request?.relay
        navigationBeforeSettings = navigation
        // Settings overlays a still-mounted shell so its Ghostty grid
        // survives the trip; drop keyboard ownership so keystrokes go to
        // Settings instead of the hidden terminal.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setChromePopover(nil)
        setSettingsPresented(true)
    }

 
 
 
 
    /// Public Access as the panels menu shows it: on while Relay reports the
    /// public route, with the address it serves.
 
    func markAllNoticesRead() {
        notices
            .filter(\.isUnread)
            .forEach { onNoticeRead($0.id) }
    }

 
    func closeSettings() {
        let previousNavigation = navigationBeforeSettings
        navigationBeforeSettings = nil
        settingsDeepLinkSection = nil
        settingsPublicAccessPrefill = nil
        settingsRelayPrefill = nil
        setSettingsPresented(false)
        if let previousNavigation {
            dispatch(.restoreNavigation(previousNavigation))
        }
        NotificationCenter.default.post(name: WarrenDesktopCommand.settingsDismissed, object: nil)
    }

    /// The Inspector's switch for this workspace, or `nil` when it has none.
 
    /// Matches the sidebar, which always lists Sessions, so the pane bar and
    /// the tree agree about who owns the Session list.
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode { .rich }

    /// The identity the top chrome row shows in place of a pane track.
    ///
    /// Asked only when the pane bar presentation has already decided no track
    /// will be drawn, so `entries` is that same resolution and the two can never
    /// both render.
    func soloPaneIdentity(
        entries: [ClientTab],
        presentation: Presentation,
        tabTitles: [String: String],
        tabMarks: [TerminalSessionID: WarrenActivityMark],
        shellMarks: [TerminalSessionID: WarrenActivityMark] = [:]
    ) -> WarrenDesktopSoloPaneIdentity.Model? {
        guard let tab = entries.first ?? presentation.tab, tab.sessionID != nil else { return nil }
        let session = tab.sessionID.flatMap { projection.session(id: $0) }
        let workspace = tab.sessionID.flatMap { projection.workspace(for: $0) }
            ?? presentation.workspace
        return WarrenDesktopSoloPaneIdentity.Model(
            tabID: tab.id,
            title: tabTitles[tab.id] ?? tab.title,
            runningCommand: session.map {
                WarrenDesktopTabTitle.sessionTitle(
                    for: $0,
                    worktreeRoot: workspace?.path ?? ""
                ).runningCommand
            } ?? "",
            fullTitle: soloPaneFullTitle(presentation: presentation, tab: tab, session: session),
            commandLine: (session?.shellState?.runningCommand).flatMap { $0.isEmpty ? nil : $0 }
                ?? session?.runtimeCommandLine
                ?? "",
            directory: session.flatMap { $0.workingDirectory.isEmpty ? nil : $0.workingDirectory }
                ?? workspace?.path
                ?? "",
            branch: workspace?.branch ?? "",
            kindName: session.map { session in
                session.isAgentSession
                    ? "Agent · \(session.presentedKind.displayName)"
                    : session.presentedKind.displayName
            } ?? TerminalSessionKind.shell.displayName,
            providerPresetID: session.flatMap { session in
                WarrenDesktopSessionPreset.builtIns
                    .first { $0.request.kind == session.presentedKind }?.id
            },
            mark: tab.sessionID.flatMap { tabMarks[$0] },
            shellMark: tab.sessionID.flatMap { shellMarks[$0] },
            isLead: session?.isLead ?? false,
            canClose: true
        )
    }

    func copySoloPaneTitle(presentation: Presentation) {
        guard let tab = presentation.tab else { return }
        let session = tab.sessionID.flatMap { projection.session(id: $0) }
        let title = soloPaneFullTitle(presentation: presentation, tab: tab, session: session)
        WarrenCopyFeedback.shared.copy(title, announcing: "Copied title")
    }

    /// The lone pane's title menu: rename the Session, copy its command or its
    /// directory, or hand the directory to an editor.
    func makeSoloTitleActions(
        _ solo: WarrenDesktopSoloPaneIdentity.Model,
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> [WarrenDesktopContextMenuAction] {
        var actions: [WarrenDesktopContextMenuAction] = []
        if let sessionID = presentation.tabs
            .first(where: { $0.id == solo.tabID })?.sessionID {
            actions.append(.button(title: "Rename Session…") {
                presentRename(.session(sessionID, title: solo.title))
            })
        }
        if !solo.commandLine.isEmpty {
            actions.append(.button(title: "Copy Command") {
                WarrenCopyFeedback.shared.copy(solo.commandLine, announcing: "Copied command")
            })
        }
        if !solo.directory.isEmpty {
            actions.append(.button(title: "Copy Path") {
                WarrenCopyFeedback.shared.copy(solo.directory, announcing: "Copied path")
            })
        }
        if let options = externalIDEOptions, !options.isEmpty {
            actions.append(.menu(title: "Open in Editor", actions: options.map { option in
                .button(title: option.name) { openInExternalIDE(option) }
            }))
        }
        return actions
    }

    /// The same fully rendered title the pane header would show, so copying it
    /// yields the same string in either presentation.
    func soloPaneFullTitle(
        presentation: Presentation,
        tab: ClientTab,
        session: WarrenDesktopSession?
    ) -> String {
        let workspace = tab.sessionID.flatMap { projection.workspace(for: $0) }
            ?? presentation.workspace
        let trimmedCustomTitle = session?.customTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = (trimmedCustomTitle?.isEmpty == false) ? trimmedCustomTitle : nil
        let command = WarrenDesktopTabTitle.resolvedCommand(
            kind: session?.kind ?? tab.kind,
            process: session?.runtimeProcess ?? "",
            commandLine: session?.runtimeCommandLine ?? ""
        )
        let directory = (session?.workingDirectory.isEmpty == false
            ? session?.workingDirectory
            : nil)
            ?? workspace?.path
            ?? ""
        // The generated default name repeats the kind the icon already shows,
        // so it only stands in when the directory and command are both empty.
        let generatedTitle = session?.title ?? tab.title
        return TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate)
            .render(TerminalDisplayTitleContext(
                session: customTitle ?? ((directory.isEmpty && command.isEmpty) ? generatedTitle : ""),
                command: command,
                directory: directory,
                workspace: workspace?.name ?? "",
                branch: workspace?.branch ?? "",
                host: projection.host.name,
                user: NSUserName(),
                os: ProcessInfo.processInfo.operatingSystemVersionString
            ))
    }

    /// Brings the Changes page forward for a file the Conversation pane asked
    /// to reveal. The pane owns the modal reveal through its own inspector
    /// model; this side only switches the Inspector page and follows the file's
    /// Workspace when it lives on another tab.
    func revealReviewFile(
        _ request: WarrenDesktopReviewFileRequest,
        in presentation: Presentation
    ) {
        lastInspectorTabs[request.workspaceID] = .changes
        rightSidebarTabs[request.workspaceID] = .inspector(.changes)
        inspectorOpen = true
        guard let targetWorkspace = projection.groups
            .flatMap(\.workspaces)
            .first(where: { $0.id == request.workspaceID }),
            presentation.workspace?.id != targetWorkspace.id
        else { return }
        actions(.selectWorkspace(targetWorkspace.id))
    }

    func presentCommandPalette() {
        // Release the terminal's AppKit first responder before the overlay
        // mounts so the palette TextField receives the next keystroke.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setCommandPalettePresented(true)
    }

    func setSettingsPresented(_ presented: Bool) {
        if presented { settingsActivation &+= 1 }
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            settingsPresented = presented
        }
    }

    func setChromePopover(_ popover: WarrenDesktopChromePopover?) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            chromePopover = popover
        }
    }

    func presentRename(_ request: WarrenDesktopRenameRequest) {
        renameValue = request.initialValue
        pendingRenameEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = request
        }
    }

    func onCustomizeEndpointDisplayName(
        _ endpoint: WarrenDesktopEndpointOption
    ) {
        presentRename(.endpoint(endpoint.id, name: endpoint.label))
    }

    func dismissRename() {
        pendingRenameEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = nil
        }
    }

    func confirmRename() {
        guard let pendingRename else { return }
        guard pendingRenameEndpointID == selectedEndpointID else {
            dismissRename()
            return
        }
        switch pendingRename {
        case .task(let id, _):
            dispatch(.renameTask(id, renameValue))
        case .project(let id, _):
            dispatch(.renameProject(id, renameValue))
        case .workspace(let id, _):
            dispatch(.renameWorkspace(id, renameValue))
        case .session(let id, _):
            dispatch(.renameSession(id, renameValue))
        case .endpoint(let id, _):
            onSetEndpointDisplayName(
                id,
                renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        dismissRename()
    }

    func presentTaskCreator() {
        guard projection.isConnected else { return }
        taskCreatorEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isTaskCreatorPresented = true
        }
    }

    func dismissTaskCreator() {
        taskCreatorEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isTaskCreatorPresented = false
        }
    }

    @ViewBuilder
    var taskCreatorDialog: some View {
        if isTaskCreatorPresented, taskCreatorEndpointID == selectedEndpointID {
            // The creator draws its own `WarrenDialog`, so it is not wrapped.
            WarrenDesktopTaskCreatorView(
                onCancel: dismissTaskCreator,
                onCreate: onCreateTask,
                onCreated: { taskID in
                    WarrenDesktopTaskCreationPresentation.complete(
                        taskID: taskID,
                        tree: &sidebarTree,
                        onDismiss: dismissTaskCreator
                    )
                }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(WarrenPresentationLayer.modal)
        }
    }

    @ViewBuilder
    var renameDialog: some View {
        if let pendingRename {
            WarrenTextInputDialog(
                title: pendingRename.title,
                message: pendingRename.message,
                fieldLabel: pendingRename.fieldLabel,
                text: $renameValue,
                confirmLabel: pendingRename.confirmLabel,
                onCancel: dismissRename,
                onConfirm: confirmRename
            )
            .zIndex(WarrenPresentationLayer.modal)
        }
    }

    func presentDeletion(_ request: WarrenDesktopDeletionRequest) {
        deleteWorkspaceRemoveWorktree = false
        pendingDeletionEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = request
        }
    }

    func dismissDeletion() {
        pendingDeletionEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = nil
        }
    }

    func deletionValidation(
        for request: WarrenDesktopDeletionRequest
    ) -> (isEnabled: Bool, message: String?) {
        guard pendingDeletionEndpointID == selectedEndpointID else {
            return (false, "The endpoint changed. Close this dialog and choose the resource again.")
        }
        guard projection.isConnected else {
            return (false, "Warren is reconnecting. Try again when the connection is restored.")
        }
        switch request {
        case .task(let task):
            guard projection.taskGroups.contains(where: { $0.task.id == task.id }) else {
                return (false, "This task is no longer available.")
            }
        case .workspace(let workspace, let project):
            guard let liveWorkspace = projection.workspace(id: workspace.id) else {
                return (false, "This workspace is no longer available.")
            }
            guard !deletingWorkspaceIDs.contains(workspace.id) else {
                return (false, "This workspace is already being deleted.")
            }
            if deletingProjectIDs.contains(liveWorkspace.projectID)
                || project.map({ deletingProjectIDs.contains($0.id) }) == true {
                return (false, "Its project is already being deleted.")
            }
        case .project(let project, _):
            guard let liveGroup = projection.groups.first(where: { $0.project.id == project.id }) else {
                return (false, "This project is no longer available.")
            }
            guard !deletingProjectIDs.contains(project.id) else {
                return (false, "This project is already being deleted.")
            }
            if liveGroup.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) }) {
                return (false, "A workspace in this project is already being deleted.")
            }
        }
        return (true, nil)
    }

    @ViewBuilder
    var deletionDialog: some View {
        if let pendingDeletion {
            let validation = deletionValidation(for: pendingDeletion)
            Group {
                switch pendingDeletion {
                case .task(let task):
                    WarrenDesktopDeleteTaskConfirmation(
                        task: task,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteTask(task.id))
                            dismissDeletion()
                        },
                        isConfirmEnabled: validation.isEnabled,
                        validationMessage: validation.message
                    )
                case .workspace(let workspace, let project):
                    WarrenDesktopDeleteWorkspaceConfirmation(
                        workspace: workspace,
                        project: project,
                        removeWorktree: $deleteWorkspaceRemoveWorktree,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteWorkspace(
                                workspace.id,
                                removeLocalWorktree: deleteWorkspaceRemoveWorktree
                            ))
                            // A confirmed deletion prunes the marker. A Host
                            // outage must not, which is why this is done here
                            // rather than by reconciling against the roster.
                            closeEditorRegion(
                                for: workspace,
                                hostId: pendingDeletionEndpointID
                            )
                            dismissDeletion()
                        },
                        isConfirmEnabled: validation.isEnabled,
                        validationMessage: validation.message
                    )
                case .project(let project, let workspaceCount):
                    WarrenDesktopDeleteProjectConfirmation(
                        project: project,
                        workspaceCount: workspaceCount,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteProject(project.id))
                            dismissDeletion()
                        },
                        isConfirmEnabled: validation.isEnabled,
                        validationMessage: validation.message
                    )
                }
            }
            .zIndex(WarrenPresentationLayer.modal)
        }
    }

    static func restoredSidebarState() -> WarrenDesktopSidebarState {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: WarrenDesktopSidebarKeys.width) as? Double
        return WarrenDesktopSidebarState(
            width: storedWidth ?? WarrenLayoutMetrics.sidebarExpandedWidth,
            isCollapsed: defaults.bool(forKey: WarrenDesktopSidebarKeys.collapsed)
        )
    }

    static func persist(_ state: WarrenDesktopSidebarState) {
        UserDefaults.standard.set(state.width, forKey: WarrenDesktopSidebarKeys.width)
        // The widened width no longer encodes a collapse, so the state is now
        // written explicitly and restored alongside it.
        UserDefaults.standard.set(state.isCollapsed, forKey: WarrenDesktopSidebarKeys.collapsed)
    }

    static func restoredSidebarTree(scope: String) -> WarrenDesktopSidebarTreeState {
        var state = WarrenDesktopSidebarTreePersistence.restore(scope: scope)
        // The sidebar no longer offers the active-only filter, so a filter left
        // on by an earlier build would hide rows with no way to show them.
        state.showsActiveOnly = false
        return state
    }

    static func persist(_ state: WarrenDesktopSidebarTreeState, scope: String) {
        WarrenDesktopSidebarTreePersistence.save(state, scope: scope)
    }
}

/// Pure tab-cycling rule for the ⌘X / ⇧⌘X shortcuts. A workspace must have
/// more than one open tab; without a current selection the first tab wins.
enum WarrenDesktopTabCycler {
    static func tabID(
        forward: Bool,
        in tabs: [ClientTab],
        selectedTabID: String?
    ) -> String? {
        guard tabs.count > 1 else { return nil }
        guard let selectedTabID,
              let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            return tabs.first?.id
        }
        let nextIndex = (
            selectedIndex + (forward ? 1 : -1) + tabs.count
        ) % tabs.count
        return tabs[nextIndex].id
    }
}

/// Pure rule for the ⌘1…⌘9 menu shortcuts: the number is a 1-based position
/// inside the active workspace's tab track.
///
/// The track holds Sessions and nothing else. The embedded editor used to
/// occupy the position after the last Session, which made ⌘N's meaning depend on
/// whether a Workspace had ever opened it.
enum WarrenDesktopTabSelector {
    static func tabID(in tabs: [ClientTab], number: Int) -> String? {
        guard number >= 1, tabs.indices.contains(number - 1) else { return nil }
        return tabs[number - 1].id
    }
}

/// Which Session entering an arrangement should make active.
///
/// A group step has no Tab of its own, so the choice follows the same
/// precedence the panel uses for a visited Tab: the current selection when the
/// arrangement holds it, then the pane the user last worked in, then the
/// arrangement's first pane. Entering a group must still land somewhere rather
/// than leaving the keyboard in the arrangement that was just parked.
enum WarrenDesktopPaneGroupEntry {
    static func tabID(
        in tree: SplitLayoutTree,
        selectedTabID: String?,
        rememberedPaneID: String?
    ) -> String? {
        if let selectedTabID, tree.contains(tabID: selectedTabID) {
            return selectedTabID
        }
        if let rememberedPaneID, let item = tree.item(for: rememberedPaneID) {
            return item.tabID
        }
        return tree.leaves.first?.tabID
    }
}

enum WarrenDesktopPerformance {
    static let signposter = OSSignposter(
        subsystem: "com.abcdlsj.warren",
        category: "UI Performance"
    )
}

enum WarrenDesktopSidebarKeys {
    static let width = "warren.desktop.sidebarWidth"
    static let collapsed = "warren.desktop.sidebarCollapsed"
}

/// The values the settings page is drawn from, compared to decide whether its
/// window needs a new root view. Closures are left out on purpose: they are
/// rebuilt on every render and can never compare equal.
struct WarrenDesktopSettingsInputs: Equatable {
    var hostName = ""
    var webStatus = WarrenDesktopWebStatus()
    var lanPairing = WarrenDesktopLANPairing()
    var relaySettings = WarrenDesktopRelaySettings()
    var relayDevices: [WarrenDesktopRelayDevice] = []
    var remoteAccess = WarrenDesktopRemoteAccess()
    var defaultRuntime: String?
    var autoOpenShell = false
    var autoStartAI = false
    var openAIBaseURL = ""
    var openAIModel = ""
    var openAITitleEnabled = false
    var projects: [Project] = []
    var usageStats = WarrenUsageStats()
    var usageState: WarrenUsageLoadState = .idle
    var initialSettingsSection: WarrenDesktopSettingsSection?
    var publicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    var relayPrefill: WarrenDesktopRelayPrefill?
    var hostOptions: [WarrenDesktopEndpointOption] = []
    var selectedHostID = ""
}
