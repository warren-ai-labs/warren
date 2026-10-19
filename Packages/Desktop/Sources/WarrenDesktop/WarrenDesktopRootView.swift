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
    public let chromeMode: WarrenDesktopChromeMode
    public let updateStatus: WarrenDesktopUpdateStatus
    public let onUpdateAction: () -> Void
    public let webStatus: WarrenDesktopWebStatus
    public let isMigratingRuntimeSessions: Bool
    public let creatingSessionWorkspaceIDs: Set<WorkspaceID>
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

    private let endpointOptions: [WarrenDesktopEndpointOption]
    private let selectedEndpointID: String
    private let endpointCapabilities: WarrenDesktopEndpointCapabilities
    private let onSelectEndpoint: (String) -> Void
    private let onSetEndpointSidebarVisibility: (String, Bool) -> Void
    private let onSetEndpointDisplayName: (String, String?) -> Void
    private let onDeleteEndpoint: (String) -> Void
    private let sidebarHostProjections: [WarrenDesktopSidebarHostProjection]?
    private let usesSidebarHostSections: Bool
    /// The endpoint-scoped counterpart to the active navigation selection.
    /// The composition layer supplies the scope from the controller that owns
    /// the navigation state, which can briefly differ from the requested
    /// endpoint while a Host switch is in flight.
    private let sidebarResourceSelection: WarrenDesktopSidebarResourceSelection?
    private let displayConfigurationError: String?
    private let onSelectSidebarResource: (WarrenDesktopSidebarResourceSelection) -> Void
    private let onOpenSidebarWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    private let onOpenSidebarSession: (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void
    private let onRetrySidebarHost: (String) -> Void
    private let onAddSSHHost: () -> Void
    private let sshHostPage: WarrenDesktopSSHHostPageModel?
    private let onRetryConnection: () -> Void
    private let onStopConnection: () -> Void

    private let actions: WarrenDesktopActions
    private let onCreateTask: @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID
    /// The decisions other Sessions are waiting on, for the approval tray.
    private let pendingDecisions: WarrenDesktopPendingDecisions
    private let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    private let onWebStart: () -> Void
    private let onWebTest: ((String, String) -> Void)?
    private let onWebStop: () -> Void
    private let onWebReset: (() -> Void)?
    private let onRelayEnroll: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private let onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)?
    private let lanPairing: WarrenDesktopLANPairing
    private let onLANPairing: ((Bool, @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void) -> Void)?
    private let relaySettings: WarrenDesktopRelaySettings
    /// Turns the enrolled Relay on or off. Enrollment is kept either way, so
    /// this is the switch on the Settings connection row.
    private let onSetRelayEnabled: ((Bool) -> Void)?
    private let onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    private let relayDevices: [WarrenDesktopRelayDevice]
    private let onLoadRelayDevices: (() -> Void)?
    private let onRevokeRelayDevice: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private let onWebOpenURL: (URL) -> Void
    private let onWebCopyURL: (URL) -> Void
    private let defaultRuntime: String?
    private let onSetRuntime: (String) -> Void
    private let autoOpenShell: Bool
    private let onSetAutoOpenShell: (Bool) -> Void
    private let autoStartAI: Bool
    private let onSetAutoStartAI: (Bool) -> Void
    private let openAIBaseURL: String
    private let openAIModel: String
    private let openAITitleEnabled: Bool
    private let onSetOpenAISetting: (String, String) -> Void
    private let onTestOpenAI: @MainActor (String, String, String?) async throws -> Void
    private let onSetProjectSetupScript: (ProjectID, String) -> Void
    private let usageStats: WarrenUsageStats
    private let usageState: WarrenUsageLoadState
    private let onLoadUsage: ((Int, String?, Bool) -> Void)?
    private let onRebuildUsage: ((@escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void) -> Void)?
    private let embeddedEditorAvailable: Bool
    /// True while the editor region holds the keyboard.
    ///
    /// The region is not a pane and owns no Session (RFC 0020), so nothing in
    /// the arrangement tree can answer this. It arrives from the host because
    /// the region's own surface is the only thing that observes the pointer
    /// crossing into it.
    private let editorHasKeyboardFocus: Bool
    /// Whether a browser viewer currently holds the keyboard.
    ///
    /// A viewer is a `WKWebView`, so a click inside its content moves AppKit's
    /// first responder without telling the Terminal. Without this signal,
    /// terminal reconciliation pulls the keyboard straight back out of the
    /// browser pane (RFC 0022 §8.4).
    private let browserHasKeyboardFocus: Bool
    private let editorSurface: @MainActor (Workspace) -> AnyView
    /// The Inspector beside the terminal; nil where the host offers none. It is
    /// resolved per page, because the right sidebar's tab row owns which page is
    /// showing.
    private let inspectorSurface: (@MainActor (Workspace, WarrenDesktopInspectorTab, WarrenDesktopInspectorActivity) -> AnyView)?
    /// Asks the runtime to open one document. Warren drives this exactly once
    /// per editor entry, to restore the Workspace's last document; every other
    /// file selection happens inside code-server and never reaches Warren.
    private let onOpenEditorDocument: @MainActor (Workspace, WarrenDesktopEditorDocument) -> Void
    private let persistenceEnabled: Bool
    private let externalIDEService = WarrenDesktopExternalIDEService.live
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var sidebarTree: WarrenDesktopSidebarTreeState
    @State private var commandPalettePresented = false
    @State private var settingsPresented = false
    /// Bumped when the settings page is asked for, so an already-open window
    /// comes back to the front.
    @State private var settingsActivation = 0
    @State private var settingsDeepLinkSection: WarrenDesktopSettingsSection?
    @State private var settingsPublicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    @State private var settingsRelayPrefill: WarrenDesktopRelayPrefill?
    @State private var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State private var chromePopover: WarrenDesktopChromePopover?
    /// The Host a right-click asked to delete, awaiting confirmation.
    @State private var pendingHostDeletion: WarrenDesktopEndpointOption?
    @State private var pendingRename: WarrenDesktopRenameRequest?
    /// Resource dialogs capture the Endpoint that owned their row. A dialog
    /// opened on one Host must never submit its bare ID after the user
    /// switches to another Host that may issue the same UUID.
    @State private var pendingRenameEndpointID: String?
    @State private var isTaskCreatorPresented = false
    @State private var taskCreatorEndpointID: String?
    @State private var renameValue = ""
    @State private var pendingDeletion: WarrenDesktopDeletionRequest?
    @State private var pendingDeletionEndpointID: String?
    @State private var deleteWorkspaceRemoveWorktree = false
    /// The durable per-Workspace editor markers (RFC 0021 §6.1).
    @State private var workspaceEditorStates: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState]
    /// Which Workspaces currently show the editor region in this window.
    ///
    /// Tracks the same intent as the durable marker but is not derived from it:
    /// the marker is what a relaunch reads, while this is what the window draws,
    /// and a Workspace on another Endpoint keeps its marker without being here.
    @State private var editorRegionWorkspaceIDs: Set<WorkspaceID>
    /// The Terminal's share of the central width while the editor region is up.
    @State private var terminalRatio = WarrenLayoutMetrics.editorSplitDefaultRatio
    /// One switch for every Workspace, like the sidebar: the Inspector is a
    /// way of working, not a property of one checkout.
    @AppStorage("warren.desktop.inspectorOpen") private var inspectorOpen = false
    @AppStorage("warren.desktop.inspectorTerminalRatio")
    private var inspectorTerminalRatio = WarrenLayoutMetrics.inspectorSplitDefaultRatio
    /// Which page each Workspace's right sidebar last showed. The sidebar's
    /// open switch is global, but the page is remembered per Workspace.
    @State private var rightSidebarTabs: [WorkspaceID: WarrenDesktopRightSidebarTab] = [:]
    /// The last Inspector page a Workspace showed, so closing the editor returns
    /// there rather than always to Changes.
    @State private var lastInspectorTabs: [WorkspaceID: WarrenDesktopInspectorTab] = [:]
    /// The value the Inspector publishes for the Changes tab's count.
    @StateObject private var inspectorActivity = WarrenDesktopInspectorActivity()
    /// The external editor a plain click opens, remembered across launches.
    @AppStorage("warren.desktop.externalIDEID") private var externalIDEID = ""
    @State private var splitTrees: [String: SplitLayoutTree]
    @State private var activePaneIDs: [String: String]
    /// The pane each scope shows alone, from the group shelf's Maximize. The
    /// layout is untouched, so restoring it brings every pane back.
    @State private var zoomedPaneIDs: [String: String] = [:]
    /// The pane each scope shows as a rail, folded by pulling its divider past
    /// the minimum. Device-local like zoom: the Host's arrangement keeps the
    /// pane and its ratio, so other devices never see a fold.
    @State private var foldedPaneIDs: [String: String] = [:]
    /// The top bar's group hover, shared with the pane cards it previews.
    @StateObject private var ownPaneGroupHover = WarrenDesktopPaneGroupHover()
    @StateObject private var menuCenter = WarrenDesktopMenuCenter()
    /// The approval tray's rows, kept current for a panel that is already open.
    @StateObject private var approvalTray = WarrenDesktopApprovalTrayStore()
    @Environment(\.warrenPaneGroupHover) private var outerPaneGroupHover

    /// An embedding view may supply the hover, which is how a preview pins a
    /// lifted or open group.
    private var paneGroupHover: WarrenDesktopPaneGroupHover {
        outerPaneGroupHover ?? ownPaneGroupHover
    }
    /// Which arrangement this window renders for a scope. It is per viewer and
    /// never sent to the Host: the Host owns the shape, not the choice.
    @State private var activePaneGroupIDs: [String: String]
    /// The last arrangement the Host confirmed, per scope. A local tree that
    /// differs from it is an edit in flight, and it must outlive the Host's
    /// stale answer until the roster echoes the write.
    @State private var adoptedPaneTrees: [String: SplitLayoutTree] = [:]
    @State private var pendingSplits: [String: PendingSplit]
    /// The Session a split in flight is opening a *new* arrangement around, per
    /// scope. A split that starts a new group has no Host group to echo its
    /// arrival, so this is what recognizes the created group in the roster and
    /// makes it the one this window renders.
    @State private var pendingNewGroupVisitTabIDs: [String: String] = [:]
    /// Ticks while a split is waiting for the Session it asked for.
    ///
    /// The completion happens when the roster publishes that Session, and the
    /// publication does not reliably arrive as a change this view observes. The
    /// retry therefore has to re-read the view's current inputs on every tick: a
    /// `Task` started when the request was made would keep the projection it
    /// captured then — which is precisely the projection without the Session it
    /// is waiting for, so every attempt would decide there is nothing new.
    private let pendingSplitTick = Timer
        .publish(every: 0.05, on: .main, in: .common)
        .autoconnect()
    @StateObject private var tabDrag = WarrenDesktopTabDrag()
    /// When the collapsed sidebar floats open, and when it goes away.
    @StateObject private var sidebarPeek = WarrenDesktopSidebarPeekController()
    @State private var emacsChordActive = false
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.noticeMuted)
    private var notificationsMuted = false
    @State private var isNoticePopoverPresented = false
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    private var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    private var showsTasks = true
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    private var splitChordsEnabled = false
    @Environment(\.warrenSemanticRecorder) private var semanticRecorder
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private var windowTokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The peek only exists in the key window: a background window must not
    /// pop its sidebar open when the pointer crosses it.
    @Environment(\.controlActiveState) private var controlActiveState

    private struct Presentation {
        let workspace: Workspace?
        let contentWorkspace: Workspace?
        let tab: ClientTab?
        let session: WarrenDesktopSession?
        let tabs: [ClientTab]
    }

    private struct PendingSplit: Equatable {
        let targetPaneID: String
        /// The Session the request was made against.
        ///
        /// A split can be requested while the panel is showing a Session that
        /// is not in the stored layout, so the pane the request targets may not
        /// exist in that layout at all. Keeping the Tab ID here lets the
        /// completion rebuild the pane it was asked about.
        let targetTabID: String
        /// Every Tab the scope already had when the request was made.
        ///
        /// The Session this request creates is the only one that can be missing
        /// from it, which is what identifies that Session when it arrives —
        /// including a Tab that was on screen without being in the layout.
        let existingTabIDs: Set<String>
        let axis: SplitAxis
        /// Whether this request opens a new arrangement instead of extending
        /// the scope's current one.
        let createsNewGroup: Bool
    }

    public init(
        projection: WarrenDesktopProjection,
        navigation: WarrenDesktopNavigationState? = nil,
        chromeMode: WarrenDesktopChromeMode = .workspace,
        updateStatus: WarrenDesktopUpdateStatus = .none,
        onUpdateAction: @escaping () -> Void = {},
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        onCreateTask: @escaping @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID = { _ in
            throw URLError(.unsupportedURL)
        },
        pendingDecisions: WarrenDesktopPendingDecisions = WarrenDesktopPendingDecisions(),
        webStatus: WarrenDesktopWebStatus = .init(),
        isMigratingRuntimeSessions: Bool = false,
        creatingSessionWorkspaceIDs: Set<WorkspaceID> = [],
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
        self.chromeMode = chromeMode
        self.updateStatus = updateStatus
        self.onUpdateAction = onUpdateAction
        self.webStatus = webStatus
        self.isMigratingRuntimeSessions = isMigratingRuntimeSessions
        self.creatingSessionWorkspaceIDs = creatingSessionWorkspaceIDs
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
            session.activityMark.map { (session.id, $0) }
        })
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
                content: settingsOverlay,
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
            minHeight: (chromeMode.showsIndependentTopBar ? WarrenLayoutMetrics.topBarHeight : 0)
                + WarrenLayoutMetrics.windowInset * 2
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
        .onReceive(pendingSplitTick) { _ in
            // A split waits for the Session it asked for, and that arrival is
            // not guaranteed to reach this view as a change. The tick is what
            // keeps the completion from depending on one.
            reconcilePendingSplitsOnTick()
        }
        .onChange(of: splitTrees) { _ in
            // The strip's order has to follow the layout, because ⌘1-9, tab
            // cycling, and every drag destination read the order rather than
            // the drawing.
            alignTabOrderWithLayout()
        }
        .onChange(of: projection.paneGroups) { _ in
            // The Host is the authority: adopting its arrangements after every
            // roster change is what makes a second client's edit, or a
            // reconciliation on the Host, visible here.
            adoptHostPaneGroups()
        }
        .onChange(of: projection.tabs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
        }
        .onChange(of: navigation) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
            releaseFoldOfSelectedPane()
        }
        .onChange(of: creatingSessionWorkspaceIDs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
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
            adoptHostPaneGroups()
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
                            - WarrenSpacing.hairline
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
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
    private var noticeToasts: some View {
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

    private static func scopedSidebarSelection(
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
    private var sidebarHostSummary: WarrenDesktopSidebarHostIdentity {
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
            connectionState: projection.connectionState
        )
    }

    /// Every other execution server, for the foot of the sidebar. A Host whose
    /// sections this window already loads also reports its connection and the
    /// states of its Sessions; any other Host has only its last probe to go on.
    private var sidebarOtherHosts: [WarrenDesktopSidebarOtherHost] {
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
    private var sidebarCurrentHost: WarrenDesktopSidebarOtherHost? {
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
    private var sidebarAttentionMark: WarrenActivityMark? {
        let currentHostMarks = WarrenDesktopSidebarAttention
            .unattended(projection.sessions, selectedTabID: navigation.selectedTabID)
            .map(\.activityMark)
        let otherHostMarks = sidebarOtherHosts.flatMap(\.marks)
        return WarrenDesktopSidebarAttention.mark(among: currentHostMarks + otherHostMarks)
    }

    /// The approval tray's rows: this Host's other Sessions an Agent has
    /// stopped for, with the decision when this client holds it.
    private var approvalTrayEntries: [WarrenDesktopApprovalTrayEntry] {
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
    private var approvalTrayPill: AnyView {
        AnyView(WarrenDesktopApprovalTrayPill(
            store: approvalTray,
            onOpen: { dispatch(.openSession($0)) },
            onResolve: pendingDecisions.resolve
        ))
    }

    /// The peek's entry motion: 14pt of travel plus a fade, or a plain fade
    /// when the system asks for less motion.
    private var sidebarPeekTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(x: -14))
    }

    /// The peek still fades when motion is reduced; only its travel is dropped.
    private var sidebarPeekAnimation: Animation {
        .easeOut(duration: WarrenMotion.stateChangeDuration)
    }

    /// The docked rail's collapse and expand. `.snappy` is macOS 14 and later;
    /// the deployment floor keeps a short ease-out instead.
    private var sidebarCollapseAnimation: Animation? {
        guard !reduceMotion else { return nil }
        if #available(macOS 14, *) {
            return .snappy
        }
        return WarrenMotion.animation(.stateChange, reduceMotion: false)
    }

    private var selectedEndpointIsLocal: Bool {
        endpointOptions.first { $0.id == selectedEndpointID }?.isLocal == true
    }

    private func makeExternalIDEOptions(
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
    private func chromePopoverLayer(
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
    private static var trailingChromePopoverTop: CGFloat {
        WarrenLayoutMetrics.windowInset
            + WarrenLayoutMetrics.tabBarHeight
            + WarrenDesktopMenuMetrics.anchorGap
    }

    /// How close a chrome surface may come to the window's bottom edge
    /// before it scrolls instead.
    private static var chromePopoverBottomMargin: CGFloat { WarrenLayoutMetrics.windowInset + 8 }

    /// The top of the Host picker: under the sidebar's traffic-light row and
    /// Host row, a couple of points below the Host button. With the rail
    /// collapsed the button is in the top bar, so the surface hangs below it.
    private var hostPickerTop: CGFloat {
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
    private var addHostBottom: CGFloat {
        WarrenLayoutMetrics.windowInset
            + (sidebarState.isCollapsed ? 0 : WarrenDesktopSidebarHostStackMetrics.height)
            + WarrenDesktopSidebarHostStackMetrics.panelGap
    }

    private var hostPanelWidth: CGFloat {
        max(sidebarState.renderedWidth - 2 * WarrenDesktopSidebarHostStackMetrics.panelInset, 200)
    }

    private var hostPickerPopover: some View {
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
    private var addHostPopover: some View {
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

    private func presentAddHost() {
        guard sshHostPage != nil else {
            setChromePopover(nil)
            onAddSSHHost()
            return
        }
        setChromePopover(.addHost)
    }

    private func requestHostDeletion(_ endpointID: String) {
        guard endpointID != "local",
              let endpoint = endpointOptions.first(where: { $0.id == endpointID }) else { return }
        setChromePopover(nil)
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingHostDeletion = endpoint
        }
    }

    private func dismissHostDeletion() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingHostDeletion = nil
        }
    }

    @ViewBuilder
    private var hostDeletionDialog: some View {
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
    private var hostPanelPublicAccess: WarrenDesktopHostPanelPublicAccess {
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
    private func trailingChromePopover(
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
    private func makeTabBarView(
        presentation: Presentation,
        tabTitles: [String: String],
        tabMarks: [TerminalSessionID: WarrenActivityMark],
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
                    tabMarks: tabMarks
                )
            }
        )
        return AnyView(WarrenDesktopTabBar(
            presentation: paneBar,
            tabTitles: tabTitles,
            tabMarks: tabMarks,
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
            chromeMode: chromeMode,
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
            collapsedHost: chromeMode == .workspace && sidebarState.isCollapsed
                ? WarrenDesktopCollapsedHost(
                    name: projection.host.name,
                    initial: String(projection.host.name.prefix(1)).lowercased(),
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
    private func noticeBell(panelEdge: WarrenDesktopMenuEdge) -> AnyView {
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
    private func makeSidebarView(
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
            chromeMode: chromeMode,
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

    private func makeWorkspaceColumn(
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
                if chromeMode.showsIndependentTopBar {
                    WarrenDesktopTopBar(
                        hostName: projection.host.name,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        onToggleSidebar: toggleSidebar,
                        sidebarAttentionMark: sidebarAttentionMark,
                        onSidebarButtonHover: { sidebarPeek.setPointer(.sidebarButton, isInside: $0) }
                    )
                }
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
    private func rightSidebarRegion(
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
                canOpen: currentIDE?.isEnabled ?? false,
                isMenuPresented: chromePopover == .externalIDE,
                open: {
                    if let currentIDE { openInExternalIDE(currentIDE) }
                },
                presentMenu: { setChromePopover(.externalIDE) }
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
    private func showsRightSidebar(for workspace: Workspace?) -> Bool {
        inspectorOpen && rightSidebarAvailable(for: workspace)
    }

    private func rightSidebarAvailable(for workspace: Workspace?) -> Bool {
        inspectorSurface != nil || editorAvailable(for: workspace)
    }

    private func editorAvailable(for workspace: Workspace?) -> Bool {
        embeddedEditorAvailable && workspace != nil
    }

    /// The page the sidebar would show, honoring what the Workspace
    /// remembered and falling back when that page no longer exists.
    private func selectedRightSidebarTab(
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
    private func currentExternalIDEID(
        in options: [WarrenDesktopExternalIDEOption]
    ) -> String? {
        options.contains { $0.id == externalIDEID } ? externalIDEID : options.first?.id
    }

    /// The top bar's toggle and the ⌥⌘B command: one switch for the whole
    /// sidebar, not a choice between the Inspector and the editor.
    private func toggleRightSidebar(in presentation: Presentation) {
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

    private func selectRightSidebarTab(
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
    private func terminalRegion(
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
                onAddProject: { dispatch(.addProject) },
                onImportSuperset: { dispatch(.importSuperset) },
                terminalSurface: terminalSurface
            )
        )
    }

    // MARK: - Embedded editor rail and region (RFC 0021)

    private func editorKey(for workspace: Workspace) -> WarrenDesktopWorkspaceEditorKey {
        WarrenDesktopWorkspaceEditorKey(
            hostId: selectedEndpointID,
            workspaceId: workspace.id
        )
    }

    private static func enabledWorkspaceIDs(
        in states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState],
        hostId: String
    ) -> Set<WorkspaceID> {
        Set(
            states
                .filter { $0.key.hostId == hostId && $0.value.enabled }
                .map(\.key.workspaceId)
        )
    }

    private func showsEditorRegion(for workspace: Workspace?) -> Bool {
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
    private func openEditorRegion(
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
    private func closeEditorRegion(for workspace: Workspace, hostId: String? = nil) {
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

    private var settingsOverlay: AnyView {
        AnyView(
            WarrenDesktopSettingsView(
                onBack: closeSettings,
                hostName: projection.host.name,
                webStatus: webStatus,
                onWebTest: onWebTest,
                onWebStop: onWebStop,
                onWebReset: onWebReset,
                onRelayEnroll: onRelayEnroll,
                onRelayPairing: onRelayPairing,
                lanPairing: lanPairing,
                onLANPairing: onLANPairing,
                relaySettings: relaySettings,
                onSetRelayEnabled: onSetRelayEnabled,
                onResetRelay: onResetRelay,
                relayDevices: relayDevices,
                onLoadRelayDevices: onLoadRelayDevices,
                onRevokeRelayDevice: onRevokeRelayDevice,
                defaultRuntime: defaultRuntime,
                onSetRuntime: onSetRuntime,
                autoOpenShell: autoOpenShell,
                onSetAutoOpenShell: onSetAutoOpenShell,
                autoStartAI: autoStartAI,
                onSetAutoStartAI: onSetAutoStartAI,
                openAIBaseURL: openAIBaseURL,
                openAIModel: openAIModel,
                openAITitleEnabled: openAITitleEnabled,
                onSetOpenAISetting: onSetOpenAISetting,
                onTestOpenAI: onTestOpenAI,
                projects: projection.groups.map(\.project),
                projectGroups: projection.groups,
                onSetProjectSetupScript: onSetProjectSetupScript,
                usageStats: usageStats,
                usageState: usageState,
                onLoadUsage: onLoadUsage,
                onRebuildUsage: onRebuildUsage,
                initialSettingsSection: settingsDeepLinkSection,
                publicAccessPrefill: settingsPublicAccessPrefill,
                relayPrefill: settingsRelayPrefill,
                hostOptions: endpointOptions,
                selectedHostID: selectedEndpointID,
                onSelectHost: onSelectEndpoint
            )
            .transition(.opacity)
        )
    }

    private func makePresentation() -> Presentation {
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

    private var firstWorkspace: Workspace? {
        projection.firstWorkspace
    }

    private func isAddingSession(in presentation: Presentation) -> Bool {
        if let workspace = presentation.workspace {
            return creatingSessionWorkspaceIDs.contains(workspace.id)
        }
        return false
    }

    private func makeSessionMoveTargets() -> [WarrenDesktopSessionMoveTarget] {
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

    private func makeSessionMoveDestinations() -> [TerminalSessionID: WarrenDesktopSessionMoveDestination] {
        Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            projection.sessionWorkspaceIDs[session.id].map { (session.id, .workspace($0)) }
        })
    }

    private func addSession(in presentation: Presentation) {
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id))
        }
    }

    /// Launches a preset Session.
    ///
    /// Creation through the preset bar is an ordinary new Tab, exactly like the
    /// add control: only the split commands add a pane to the layout on screen.
    private func launchSession(
        _ request: TerminalSessionLaunchRequest,
        in presentation: Presentation
    ) {
        if let workspace = presentation.workspace {
            dispatch(.launchSession(workspace.id, request))
        }
    }

    private func openInExternalIDE(_ option: WarrenDesktopExternalIDEOption) {
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

    private func dispatch(_ action: WarrenDesktopAction) {
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

    private func openSettings() {
        openSettings(nil)
    }

    private func openPublicAccessSettings() {
        openSettings(WarrenDesktopSettingsDeepLink(section: .publicAccess))
    }

    private func openSettings(_ request: WarrenDesktopSettingsDeepLink?) {
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
 
    private func markAllNoticesRead() {
        notices
            .filter(\.isUnread)
            .forEach { onNoticeRead($0.id) }
    }

 
    private func closeSettings() {
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
 
    private func toggleSidebar() {
        // The rail's width is its own animation; the terminal only sees the
        // final geometry once the card is gone.
        withAnimation(sidebarCollapseAnimation) {
            sidebarState.toggleCollapsed()
        }
        actions(.toggleSidebar)
    }

    private func setCommandPalettePresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            commandPalettePresented = presented
        }
    }

    private func tabIndex(from rawValue: Any?) -> Int? {
        if let index = rawValue as? Int {
            return index
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func handleNewSession(in presentation: Presentation) {
        addSession(in: presentation)
    }

    /// Cycles Sessions only.
    ///
    /// The editor used to be the track's last stop, so cycling past the final
    /// Session opened it and cycling out of it returned to a Session. It is no
    /// longer a Tab — it is a region beside the whole track — so the cycle is
    /// once again exactly the Sessions.
    private func handleTabMove(forward: Bool, in presentation: Presentation) {
        guard let tabID = WarrenDesktopTabCycler.tabID(
            forward: forward,
            in: presentation.tabs,
            selectedTabID: navigation.selectedTabID
        ) else { return }
        selectTab(tabID, in: presentation)
    }

    private func handleSelectTab(
        _ note: Notification,
        in presentation: Presentation
    ) {
        let rawIndex = note.userInfo?[WarrenDesktopCommand.selectTabIndexKey]
        guard let index = tabIndex(from: rawIndex),
              let tabID = WarrenDesktopTabSelector.tabID(
                in: presentation.tabs,
                number: index
              ) else { return }
        selectTab(tabID, in: presentation)
    }

    private func currentScopeKey(presentation: Presentation) -> String? {
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        if let workspace = presentation.workspace {
            return endpointScope + "workspace-\(workspace.id.rawValue.uuidString)"
        }
        return nil
    }

    /// The scope's layout: what the store holds, reconciled against the roster.
    ///
    /// This is the layout the panel belongs to, whether or not it is the one on
    /// screen — a Session selected from outside it is a visit, and the layout
    /// survives it so the split can be returned to.
    private func scopeSplitTree(presentation: Presentation) -> SplitLayoutTree {
        guard let scope = currentScopeKey(presentation: presentation) else {
            return WarrenDesktopSplitProjection.lonePane(
                tabID: presentation.tab?.id ?? "default"
            )
        }
        let validTabIDs = Set(presentation.tabs.map(\.id))
        // The only Session a scope may fall back to is the selected one. Falling
        // back to the workspace's first Tab used to resurrect a Session the user
        // had just cleared: closing the last pane emptied the content but the
        // pane bar redrew that Session's identity, so the close read as a no-op.
        let fallbackTabID = presentation.tab?.id
        // A split in flight pins the base to the Session it was aimed at. The
        // Session it creates is selected as soon as the roster publishes it, so
        // a lone-pane fallback that followed the live selection would move to
        // that Session before the pending request could consume it; the scope
        // has no tree yet to hold through the window, so the fallback is the
        // only thing that can. `rendered(isHoldingForCreation:)` is the same
        // guard for a scope that already has one.
        let baseTabID = WarrenDesktopSplitProjection.baseTabID(
            selectedTabID: fallbackTabID,
            pendingTargetTabID: pendingSplits[scope]?.targetTabID,
            emptyTabID: Self.emptyPaneTabID
        )
        // The Host's arrangement is the shape, whether or not this client has
        // caught up with a local edit yet. Only a scope the Host does not own a
        // group for falls through to the local value and the lone-pane fallback.
        let local = splitTrees[scope]
        let isEditInFlight = local != nil && local != adoptedPaneTrees[scope]
        if let group = hostPaneGroup(for: presentation), !isEditInFlight {
            if let reconciled = WarrenDesktopSplitProjection.stored(
                WarrenDesktopPaneGroupMapping.tree(from: group),
                validTabIDs: validTabIDs,
                fallbackTabID: fallbackTabID
            ) {
                return reconciled
            }
            return WarrenDesktopSplitProjection.lonePane(
                tabID: baseTabID
            )
        }
        if let existing = splitTrees[scope],
           let reconciled = WarrenDesktopSplitProjection.stored(
               existing,
               validTabIDs: validTabIDs,
               fallbackTabID: fallbackTabID
           ) {
            return reconciled
        }
        return WarrenDesktopSplitProjection.lonePane(
            tabID: baseTabID
        )
    }

    /// The layout the panel draws, which is the scope's layout unless the
    /// selection is visiting a Session outside it.
    private func currentSplitTree(presentation: Presentation) -> SplitLayoutTree {
        let isHoldingForCreation = currentScopeKey(presentation: presentation)
            .map { pendingSplits[$0] != nil } ?? false
        return WarrenDesktopSplitProjection.rendered(
            scopeSplitTree(presentation: presentation),
            selectedTabID: navigation.selectedTabID,
            validTabIDs: Set(presentation.tabs.map(\.id)),
            isHoldingForCreation: isHoldingForCreation
        )
    }

    /// Leaf identity for a scope with nothing on screen. It names no Session, so
    /// the pane bar filters it out and the content renders the empty state while
    /// the workspace's Sessions keep running in the tree.
    ///
    /// Computed rather than stored: a generic view type cannot hold static
    /// storage.
    private static var emptyPaneTabID: String { "empty" }

    private func currentActivePaneID(presentation: Presentation, tree: SplitLayoutTree) -> String {
        let scope = currentScopeKey(presentation: presentation)
        // Navigation changes can select the successor tab synchronously when
        // a pane is closing, before the Host roster removes the old leaf.
        // Prefer the selected tab whenever it is already represented so the
        // control/focus intent follows that pane instead of briefly targeting
        // the session that is being deleted.
        return WarrenDesktopSplitProjection.splitTargetPaneID(
            in: tree,
            selectedTabID: navigation.selectedTabID,
            rememberedPaneID: scope.flatMap { activePaneIDs[$0] }
        ) ?? "pane-default"
    }

    /// The arrangements the bar labels, in the order it draws them.
    ///
    /// Which arrangements that is follows the display mode. Rich mode's sidebar
    /// lists Sessions, so the bar is a pane control for what is on screen and
    /// only the rendered arrangement earns a mark — a visit draws none. Compact
    /// mode's bar *is* the Session list, so every arrangement of the scope is
    /// gathered into its own run and stays reachable. One pane is not a group:
    /// there is no second pane to bind it to, and no mark to draw.
    private func splitGroups(presentation: Presentation) -> [WarrenDesktopSplitGroup] {
        guard let scope = currentScopeKey(presentation: presentation) else { return [] }
        if workspaceDisplayMode.isRich {
            let tree = currentSplitTree(presentation: presentation)
            guard tree.count > 1 else { return [] }
            let group = hostPaneGroup(for: presentation)
            return [
                splitGroup(
                    id: group?.id.description,
                    name: group?.name,
                    scope: scope,
                    tree: tree,
                    presentation: presentation
                )
            ]
        }
        return hostPaneGroups(for: presentation).compactMap { group in
            let tree = WarrenDesktopPaneGroupMapping.tree(from: group)
            guard tree.count > 1 else { return nil }
            return splitGroup(
                id: group.id.description,
                name: group.name,
                scope: scope,
                tree: tree,
                presentation: presentation
            )
        }
    }

    /// One Host arrangement with the title, context and per-Tab activity the
    /// bar and its shelf read.
    private func splitGroup(
        id: String?,
        name: String?,
        scope: String,
        tree: SplitLayoutTree,
        presentation: Presentation
    ) -> WarrenDesktopSplitGroup {
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        var activity: [String: String] = [:]
        var icons: [String: WarrenDesktopAppIcon] = [:]
        for tab in presentation.tabs where tree.contains(tabID: tab.id) {
            let session = tab.sessionID.flatMap { projection.session(id: $0) }
            activity[tab.id] = session.map(Self.paneActivityLine) ?? ""
            icons[tab.id] = session.map(WarrenDesktopAppIcon.resolve) ?? WarrenDesktopAppIcon(kind: tab.kind)
        }
        return WarrenDesktopSplitGroup(
            id: id,
            scopeKey: scope,
            tree: tree,
            title: paneGroupTitle(name: name, presentation: presentation),
            context: paneGroupContext(presentation: presentation),
            activeTabID: tree.item(for: activePaneID)?.tabID,
            activity: activity,
            icons: icons
        )
    }

    /// The group's name: the Host arrangement's own name when it has one,
    /// otherwise the scope it belongs to.
    private func paneGroupTitle(name: String?, presentation: Presentation) -> String {
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        return presentation.workspace?.name ?? ""
    }

    /// Where the group lives: the project and the branch.
    private func paneGroupContext(presentation: Presentation) -> String {
        if let workspace = presentation.workspace {
            let project = projection.projectGroup(id: workspace.projectID)?.project.name
            let branch = workspace.branch?.isEmpty == false ? workspace.branch : workspace.name
            return [project, branch].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        return ""
    }

    /// One line on what a pane's Session is doing: the question it is waiting
    /// on, else the command it runs, else its state.
    static func paneActivityLine(_ session: WarrenDesktopSession) -> String {
        if let reason = session.agentStatus?.attention?.reason
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return reason
        }
        // The raw command line, not the command label: for an Agent the label
        // is the Agent's own name, which the icon beside the line already says.
        let command = session.runtimeCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { return command }
        switch session.activity {
        case .working: return "Working"
        case .blocked: return "Waiting for you"
        case .failed: return "Failed"
        case .ready: return "Ready"
        case .exited: return "Exited"
        case nil: return session.workingDirectory
        }
    }

    /// The moves that bring a scope's Tab order back in line with its layout.
    ///
    /// Called whenever the layout changes, and once on appear so a restored
    /// layout is matched by a restored order. An unchanged order costs nothing,
    /// which matters because a divider drag also lands here.
    private func alignTabOrderWithLayout() {
        let presentation = makePresentation()
        // The members the bar leads with are exactly the ones its runs hold, so
        // the stored order has to match whichever arrangements it draws: the
        // rendered one in rich mode, every drawn one in compact mode.
        let members: [String]
        if workspaceDisplayMode.isRich {
            let layout = scopeSplitTree(presentation: presentation)
            guard layout.count > 1 else { return }
            members = layout.allTabIDs
        } else {
            members = hostPaneGroups(for: presentation)
                .map { WarrenDesktopPaneGroupMapping.tree(from: $0) }
                .filter { $0.count > 1 }
                .flatMap(\.allTabIDs)
            guard !members.isEmpty else { return }
        }
        guard let workspaceID = presentation.workspace?.id else { return }
        let order = projection.tabs(in: workspaceID).map(\.id)
        let target = WarrenDesktopTabOrdering.membersFirst(order, members: members)
        for move in WarrenDesktopTabOrdering.moves(from: order, to: target) {
            dispatch(.moveTab(move.tabID, before: move.before))
        }
    }

    private func setSplitTree(_ tree: SplitLayoutTree, for scope: String, asNewGroup: Bool = false) {
        splitTrees[scope] = tree
        commitSplitTree(tree, for: scope, asNewGroup: asNewGroup)
    }

    /// The arrangement the Host owns for the current presentation, if any. The
    /// first group in draw order is the one on screen: pane geometry is relative
    /// to the whole content area, so a client renders exactly one arrangement.
    private func hostPaneGroup(for presentation: Presentation) -> PaneGroup? {
        let groups = hostPaneGroups(for: presentation)
        guard !groups.isEmpty else { return nil }
        guard let scope = currentScopeKey(presentation: presentation),
              let selected = activePaneGroupIDs[scope],
              let match = groups.first(where: { $0.id.description == selected }) else {
            return groups.first
        }
        return match
    }

    /// Every arrangement of the current scope, in the Host's draw order. More
    /// than one means the top bar has something to switch between.
    private func hostPaneGroups(for presentation: Presentation) -> [PaneGroup] {
        if let workspace = presentation.workspace {
            return projection.paneGroups(in: workspace.id)
        }
        return []
    }

    /// Selects the arrangement this window renders, or steps to the next one.
    private func selectPaneGroup(id: PaneGroupID?, step: Int = 0, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let groups = hostPaneGroups(for: presentation)
        guard !groups.isEmpty else { return }
        if let id {
            activePaneGroupIDs[scope] = id.description
            return
        }
        let current = hostPaneGroup(for: presentation)?.id
        let index = groups.firstIndex { $0.id == current } ?? -1
        let next = ((index + step) % groups.count + groups.count) % groups.count
        activePaneGroupIDs[scope] = groups[next].id.description
    }

    private func paneOwner(for presentation: Presentation) -> WarrenDesktopPaneOwner? {
        if let workspace = presentation.workspace {
            return .workspace(workspace.id)
        }
        return nil
    }

    /// Sends one local arrangement to the Host. The Host assigns pane identity
    /// and rejects a tree it cannot validate, so the local value is only an
    /// optimistic head start: the roster's answer replaces it.
    private func commitSplitTree(
        _ tree: SplitLayoutTree,
        for scope: String,
        asNewGroup: Bool = false
    ) {
        let presentation = makePresentation()
        guard currentScopeKey(presentation: presentation) == scope,
              let owner = paneOwner(for: presentation),
              let node = WarrenDesktopPaneGroupMapping.paneNode(
                  from: tree,
                  sessionIDForTabID: { WarrenDesktopPaneGroupMapping.sessionID(forTabID: $0) }
              ) else {
            paneDiagnostic("pane_commit_skipped", scope: scope, [
                "reason": currentScopeKey(presentation: presentation) == scope ? "unmappable" : "scopeChanged",
                "tabs": Self.diagnosticTabs(tree.allTabIDs),
            ])
            return
        }
        // A split whose Session the Host has not published yet would be rejected
        // as an unknown Session. The pending-split path calls back here once the
        // roster confirms it, so skipping is what keeps the two in step.
        let live = Set(projection.sessions.map(\.id))
        guard node.sessionIDs.allSatisfy({ live.contains($0) }) else {
            paneDiagnostic("pane_commit_skipped", scope: scope, [
                "reason": "sessionNotLive",
                "tabs": Self.diagnosticTabs(tree.allTabIDs),
            ])
            return
        }
        // A scope can hold several arrangements. An edit replaces the one this
        // window renders, so the write names it rather than reaching for the
        // first group the scope happens to have. A scope with no group yet — or
        // a split that deliberately starts a new one — asks for a new group.
        let target: WarrenDesktopPaneGroupTarget
        if !asNewGroup, let group = hostPaneGroup(for: presentation) {
            target = .group(group.id)
        } else {
            target = .newGroup
        }
        paneDiagnostic("pane_commit", scope: scope, [
            "tabs": Self.diagnosticTabs(tree.allTabIDs),
            "target": asNewGroup ? "new" : (hostPaneGroup(for: presentation).map { String($0.id.description.prefix(8)) } ?? "new"),
        ])
        onCommitPaneTree(owner, node, target)
    }

    private func paneDiagnostic(_ event: String, scope: String?, _ fields: [String: String] = [:]) {
        var fields = fields
        if let scope {
            fields["scope"] = String(scope.suffix(8))
        }
        onPaneDiagnostic(event, fields)
    }

    /// Tab IDs shortened to the Session prefix, in pane order.
    private static func diagnosticTabs(_ tabIDs: [String]) -> String {
        tabIDs.map { String($0.replacingOccurrences(of: "remote-", with: "").prefix(8)) }
            .joined(separator: ",")
    }

    private static func diagnosticTab(_ tabID: String?) -> String {
        tabID.map { diagnosticTabs([$0]) } ?? "nil"
    }

    /// Adopts the Host's arrangements after a roster change, so a summary of
    /// every scope that gained, changed, or lost a group is reflected locally.
    private func adoptHostPaneGroups() {
        let endpointPrefix = "endpoint-\(selectedEndpointID)-"
        var groupsByScope: [String: [PaneGroup]] = [:]
        for group in projection.paneGroups {
            guard let scope = paneGroupScopeKey(for: group) else { continue }
            groupsByScope[scope, default: []].append(group)
        }
        // A split that opened a new arrangement becomes the one this window
        // renders the moment the roster carries it. The Session it was started
        // around is the marker: the new group is the one that holds it, and no
        // other group of the scope does.
        for (scope, groups) in groupsByScope {
            guard let visitTabID = pendingNewGroupVisitTabIDs[scope] else { continue }
            guard let created = groups.first(where: {
                WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: visitTabID)
            }) else { continue }
            activePaneGroupIDs[scope] = created.id.description
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
        }
        // Only the rendered arrangement is cached locally; every other group of
        // the scope is derived from the projection once it becomes active.
        // Adopting all of them would leave `splitTrees[scope]` holding whichever
        // came last, which is not the one the window draws.
        var ownedScopes: Set<String> = []
        for (scope, groups) in groupsByScope {
            ownedScopes.insert(scope)
            let active: PaneGroup
            if let selected = activePaneGroupIDs[scope],
               let match = groups.first(where: { $0.id.description == selected }) {
                active = match
            } else {
                active = groups[0]
            }
            let adopted = WarrenDesktopPaneGroupMapping.tree(from: active)
            // A roster can still carry the arrangement from before a local edit,
            // so adopting it here would collapse the split until the Host's own
            // answer arrives. Keep the edit and let the confirming tree land.
            guard WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: splitTrees[scope],
                adopted: adoptedPaneTrees[scope],
                host: adopted
            ) else {
                paneDiagnostic("pane_adopt_held", scope: scope, [
                    "local": splitTrees[scope].map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
                    "host": Self.diagnosticTabs(adopted.allTabIDs),
                    "hostRevision": String(active.revision),
                ])
                continue
            }
            if splitTrees[scope] != adopted {
                if adoptedPaneTrees[scope]?.allTabIDs != adopted.allTabIDs {
                    paneDiagnostic("pane_adopt", scope: scope, [
                        "local": splitTrees[scope].map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
                        "host": Self.diagnosticTabs(adopted.allTabIDs),
                        "hostRevision": String(active.revision),
                    ])
                }
                splitTrees[scope] = adopted
            }
            adoptedPaneTrees[scope] = adopted
        }
        // A scope the Host no longer owns has no arrangement; a local tree left
        // behind is the remnant of one removed on the Host, and keeping it made
        // the next split adopt one of its surviving Sessions instead of the
        // Session being split. An edit still in flight is the exception — the
        // Host has simply not echoed it yet — and the endpoint prefix keeps
        // another Host's arrangements out of this window's cleanup.
        let staleScopes = splitTrees.compactMap { scope, local -> String? in
            guard scope.hasPrefix(endpointPrefix),
                  !ownedScopes.contains(scope),
                  adoptedPaneTrees[scope] == local else { return nil }
            return scope
        }
        for scope in staleScopes {
            paneDiagnostic("pane_adopt_removed", scope: scope)
            splitTrees.removeValue(forKey: scope)
            adoptedPaneTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
        }
    }

    /// The scope key a Host arrangement belongs to, for this window's endpoint.
    private func paneGroupScopeKey(for group: PaneGroup) -> String? {
        if let workspaceID = group.workspaceID {
            return "endpoint-\(selectedEndpointID)-workspace-\(workspaceID.rawValue.uuidString)"
        }
        return nil
    }

    /// Persist the same reconciled tree that the renderer uses. Keeping this
    /// out of `body` avoids mutating SwiftUI state during view evaluation,
    /// while still removing ended/foreign leaves instead of carrying them
    /// across the next launch.
    private func reconcilePersistedSplitTree() {
        let presentation = makePresentation()
        guard let scope = currentScopeKey(presentation: presentation),
              let existing = splitTrees[scope] else { return }
        let validTabIDs = Set(presentation.tabs.map(\.id))
        let fallbackTabID = presentation.tab?.id
        guard let reconciled = WarrenDesktopSplitProjection.stored(
            existing,
            validTabIDs: validTabIDs,
            fallbackTabID: fallbackTabID
        ) else {
            // Nothing survived, which is a real answer only when the scope still
            // lists Sessions. An empty or not-yet-refreshed roster says nothing
            // about the panes, and dropping the layout on it would lose a split
            // the user never closed.
            guard !presentation.tabs.isEmpty else { return }
            paneDiagnostic("pane_layout_cleared", scope: scope, [
                "local": Self.diagnosticTabs(existing.allTabIDs),
            ])
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            return
        }
        // Only the layout is written back, never the current selection's view
        // of it. Persisting the aligned projection is what used to turn a
        // glance at another Session into a permanent exit from the split.
        if splitTrees[scope] != reconciled {
            splitTrees[scope] = reconciled
        }
        if let activePaneID = activePaneIDs[scope], !reconciled.contains(paneID: activePaneID) {
            activePaneIDs[scope] = reconciled.item(forTabID: navigation.selectedTabID ?? "")?.id
                ?? reconciled.allPaneIDs.first
        }
        pruneSplitTreesForDeletedScopes()
    }

    /// Arrangements are keyed by endpoint and scope, so a deleted Workspace
    /// would otherwise keep a local tree forever. Only the current
    /// endpoint's scopes are evaluated: another endpoint's Workspaces are absent
    /// from this projection and are not deleted.
    private func pruneSplitTreesForDeletedScopes() {
        var liveScopeKeys: Set<String> = []
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        for workspace in projection.groups.flatMap(\.workspaces) {
            liveScopeKeys.insert(endpointScope + "workspace-\(workspace.id.rawValue.uuidString)")
        }
        let pruned = splitTrees.filter { key, _ in
            guard key.hasPrefix("endpoint-\(selectedEndpointID)-") else { return true }
            return liveScopeKeys.contains(key)
        }
        guard pruned.count != splitTrees.count else { return }
        let removed = Set(splitTrees.keys).subtracting(pruned.keys)
        splitTrees = pruned
        for scope in removed {
            activePaneIDs.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            if pendingSplits.removeValue(forKey: scope) != nil {
                paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "scopePruned"])
            }
        }
    }

    private func visibleScreenSessionIDs(
        for presentation: Presentation,
        in tree: SplitLayoutTree
    ) -> Set<TerminalSessionID> {
        let tabsByID = Dictionary(presentation.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A browser pane is a pane like any other, but its Session has no PTY:
        // there is nothing to subscribe, size, or recover for it, and only the
        // viewer page renders it (RFC 0022 §3).
        let sessionIDs = tree.leaves.compactMap { leaf -> TerminalSessionID? in
            guard let sessionID = tabsByID[leaf.tabID]?.sessionID else { return nil }
            return projection.session(id: sessionID)?.kind == .browser ? nil : sessionID
        }
        if sessionIDs.isEmpty,
           let fallback = presentation.tab?.sessionID,
           projection.session(id: fallback)?.kind != .browser {
            return [fallback]
        }
        return Set(sessionIDs)
    }

    private func selectTabFromTabBar(_ tabID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else {
            selectTab(tabID, in: presentation)
            return
        }
        // A run in the bar is one arrangement, so selecting one of its panes
        // selects that arrangement: compact mode lists every arrangement's
        // panes, and a Tab from a background one has to swap the screen to the
        // arrangement it lives in rather than visit it alone.
        if let group = hostPaneGroups(for: presentation).first(where: {
            WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: tabID)
        }) {
            if activePaneGroupIDs[scope] != group.id.description {
                activePaneGroupIDs[scope] = group.id.description
            }
            if let item = WarrenDesktopPaneGroupMapping.tree(from: group).item(forTabID: tabID) {
                restoreZoom(unlessShowing: item.id, scope: scope)
                restoreFold(ifFolded: item.id, scope: scope)
                activePaneIDs[scope] = item.id
            }
            selectTab(tabID, in: presentation)
            return
        }
        // A Session in no arrangement is a visit, not an exit. The stored
        // layout survives the visit, so returning to one of its panes restores
        // the split; the next action that reshapes the panel — a split, a drop,
        // a maximized pane — is what retires it.
        selectTab(tabID, in: presentation)
    }

    private func handleSelectPane(_ paneID: String, in presentation: Presentation, tree: SplitLayoutTree) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        // Selecting the pane that is already active is not a change. `selectTab`
        // drops the redundant dispatch; this only has to avoid rewriting the
        // remembered pane, which would make the next split forget the one the
        // user was working in.
        if activePaneIDs[scope] == paneID,
           let item = tree.item(for: paneID),
           navigation.selectedTabID == item.tabID {
            return
        }
        restoreZoom(unlessShowing: paneID, scope: scope)
        restoreFold(ifFolded: paneID, scope: scope)
        activePaneIDs[scope] = paneID
        if let item = tree.item(for: paneID) {
            selectTab(item.tabID, in: presentation)
        }
    }

    private func handleSplitBelow(in presentation: Presentation) {
        handleSplit(axis: .vertical, in: presentation)
    }

    private func handleSplitRight(in presentation: Presentation) {
        handleSplit(axis: .horizontal, in: presentation)
    }

    /// Splits the pane the user is working in, filling the new one with a
    /// Session the Host creates.
    ///
    /// The Session the user is looking at decides where the new pane goes. When
    /// that Session already has a pane, the split extends that pane in place.
    /// When it does not — a Session opened from the sidebar, or one the panel is
    /// showing on its own — it does not belong to the arrangement on screen, so
    /// the split opens a *new* arrangement around it instead of joining one the
    /// user is not looking at. The Session this request creates then splits that
    /// new arrangement, so the two panes land together and every arrangement
    /// already in the scope keeps its own shape.
    ///
    /// The one exception is a scope with no arrangement at all: there the lone
    /// pane *is* the scope's layout, so the split extends it as before.
    private func handleSplit(axis: SplitAxis, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let openedTab = navigation.selectedTabID.flatMap { id in
            presentation.tabs.first { $0.id == id }
        }
        let groups = hostPaneGroups(for: presentation)
        // A Session shown on its own may belong to a background arrangement; if
        // it does, that arrangement is the one the split extends, so render it
        // before reading the layout.
        if let openedTab,
           let containing = groups.first(where: {
               WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: openedTab.id)
           }),
           activePaneGroupIDs[scope] != containing.id.description {
            activePaneGroupIDs[scope] = containing.id.description
        }
        let layout = scopeSplitTree(presentation: presentation)
        let activePaneID = currentActivePaneID(presentation: presentation, tree: layout)
        // A Session the layout does not hold is not in the arrangement on
        // screen. When the scope has one, the split opens a second arrangement
        // around the visited Session rather than folding it into a layout the
        // user is not looking at.
        let adoptsOpenedSession = openedTab.map { tab in
            tab.sessionID != nil && !layout.contains(tabID: tab.id)
        } ?? false
        let startsNewGroup = adoptsOpenedSession
            && openedTab?.sessionID != nil
            && !groups.isEmpty
        let isCreating = presentation.workspace.map {
            creatingSessionWorkspaceIDs.contains($0.id)
        } ?? false
        let local = splitTrees[scope]
        paneDiagnostic("pane_split_request", scope: scope, [
            "axis": axis.rawValue,
            "selected": Self.diagnosticTab(navigation.selectedTabID),
            "layout": Self.diagnosticTabs(layout.allTabIDs),
            "host": hostPaneGroup(for: presentation).map {
                Self.diagnosticTabs(WarrenDesktopPaneGroupMapping.tree(from: $0).allTabIDs)
            } ?? "none",
            "hostRevision": hostPaneGroup(for: presentation).map { String($0.revision) } ?? "none",
            "local": local.map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
            "editInFlight": String(local != nil && local != adoptedPaneTrees[scope]),
            "adoptsOpened": String(adoptsOpenedSession),
            "newGroup": String(startsNewGroup),
            "creating": String(isCreating),
            "pending": String(pendingSplits[scope] != nil),
        ])
        // A new arrangement starts at one pane around the visited Session; every
        // other split starts from the arrangement it extends.
        let baseCount = startsNewGroup ? 1 : layout.count
        let addedCount = (startsNewGroup || !adoptsOpenedSession) ? 1 : 2
        guard baseCount + addedCount <= SplitLayoutTree.maxPanes else {
            paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "paneLimit"])
            return
        }
        guard !isCreating, pendingSplits[scope] == nil else {
            paneDiagnostic("pane_split_dropped", scope: scope, [
                "reason": isCreating ? "creatingSession" : "splitPending",
            ])
            return
        }

        var tree = layout
        if startsNewGroup, let openedTab {
            // A fresh arrangement: the visited Session is its only pane so far.
            // The arrangement it is leaving stays in the roster, untouched.
            tree = WarrenDesktopSplitProjection.lonePane(tabID: openedTab.id)
            // Cached but not committed yet: the complete tree is written once the
            // Session this request creates has arrived, so the new group is
            // created with its final shape instead of in two competing writes.
            splitTrees[scope] = tree
        } else if adoptsOpenedSession, let openedTab {
            // The pane the layout already has an identity for is reused when the
            // Session is the one the panel draws alone, so adopting it does not
            // re-create the terminal the user is looking at.
            tree = tree.split(
                targetPaneID: activePaneID,
                newTabID: openedTab.id,
                axis: axis,
                placeAfter: true,
                newPaneID: SplitPaneItem.fallbackID(forTabID: openedTab.id)
            )
            guard tree.contains(tabID: openedTab.id) else {
                paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "adoptFailed"])
                return
            }
            setSplitTree(tree, for: scope)
        }

        let targetPaneID = openedTab.flatMap { tree.item(forTabID: $0.id)?.id }
            ?? activePaneID
        guard let targetItem = tree.item(for: targetPaneID),
              let targetTab = presentation.tabs.first(where: { $0.id == targetItem.tabID }),
              targetTab.sessionID != nil else {
            paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "noTarget"])
            return
        }
        activePaneIDs[scope] = targetPaneID

        pendingSplits[scope] = PendingSplit(
            targetPaneID: targetPaneID,
            targetTabID: targetTab.id,
            existingTabIDs: Set(presentation.tabs.map(\.id)),
            axis: axis,
            createsNewGroup: startsNewGroup
        )
        if startsNewGroup, let openedTab {
            pendingNewGroupVisitTabIDs[scope] = openedTab.id
        }
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id))
        } else {
            pendingSplits.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            return
        }

        // Creation is asynchronous and the roster may be delayed. Keep the
        // captured target alive only for a bounded interval; a failed request
        // must not make all future split commands inert.
        paneDiagnostic("pane_split_pending", scope: scope, [
            "target": Self.diagnosticTab(targetTab.id),
            "newGroup": String(startsNewGroup),
            "tree": Self.diagnosticTabs(tree.allTabIDs),
        ])
        let captured = pendingSplits[scope]
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard self.pendingSplits[scope] == captured else { return }
            self.pendingSplits.removeValue(forKey: scope)
            if captured?.createsNewGroup == true { self.discardUncommittedNewGroupEdit(scope) }
            self.paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "timeout"])
        }
        reconcilePendingSplitsOnTick()
    }

    /// Reverts a split that opened a new arrangement but never wrote it, so a
    /// failed or timed-out request leaves the scope on the arrangement it was
    /// showing instead of a local edit the Host never received.
    private func discardUncommittedNewGroupEdit(_ scope: String) {
        pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
        if let adopted = adoptedPaneTrees[scope] {
            splitTrees[scope] = adopted
        } else {
            splitTrees.removeValue(forKey: scope)
        }
    }

    /// Re-runs the completion while a split is waiting for its Session.
    ///
    /// Called from a tick rather than from a change notification, and bounded by
    /// the pending itself: the moment the split lands, or the request times out,
    /// there is nothing left to retry.
    private func reconcilePendingSplitsOnTick() {
        guard !pendingSplits.isEmpty else { return }
        reconcilePendingSplitMutations()
    }
    ///
    /// Closing is a Session command: the Host owns process lifetime, so the
    /// pane's Session is terminated rather than merely taken off screen. The
    /// scope then follows the Session list — a split collapses to its surviving
    /// pane, and the last pane leaves the Session list to choose what shows next
    /// Closes one Tab: the pane it owns, or the Session itself.
    ///
    /// A Tab that is a pane of the scope's layout closes as a pane — the layout
    /// loses that pane and the pane's Session ends with it. A Tab that is not a
    /// pane has none to close, so only its Session ends. That distinction is why
    /// a close is named by a Tab rather than by "the active pane": with the
    /// split on screen, a stray Tab's close control used to take a pane of the
    /// split with it, and a two-pane split read as if closing an unrelated
    /// Session had thrown the split away.
    ///
    /// `tabID` of nil means the selected Tab, which is what the keyboard
    /// shortcut asks for.
    private func handleCloseTab(_ tabID: String?, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation),
              let targetTabID = tabID ?? navigation.selectedTabID else { return }
        if let item = scopeSplitTree(presentation: presentation).item(forTabID: targetTabID) {
            handleClosePane(paneID: item.id, in: presentation)
            return
        }
        // Not a pane: the Tab is its own Session, so that is all there is to
        // end. The layout keeps the pane focus it had.
        guard let sessionID = presentation.tabs
            .first(where: { $0.id == targetTabID })?.sessionID else { return }
        dispatch(.deleteSession(sessionID))
    }

    /// Closes every other pane of the layout and ends its Session, leaving this
    /// one alone.
    ///
    /// A Tab that is not a pane has no other panes to close, so the command is a
    /// no-op for one: it must never reshape a layout the Tab does not own.
    private func handleCloseOtherTabs(_ tabID: String, in presentation: Presentation) {
        guard let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) else {
            return
        }
        handleCloseOtherPanes(paneID: item.id, in: presentation)
    }

    /// Closes every pane of one layout and ends the Sessions in them.
    ///
    /// A Tab that is not a pane stands for one Session and no pane, so only that
    /// Session ends and the layout is left alone.
    private func handleCloseAllTabs(_ tabID: String, in presentation: Presentation) {
        if let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) {
            handleCloseAllPanes(paneID: item.id, in: presentation)
            return
        }
        guard let sessionID = presentation.tabs
            .first(where: { $0.id == tabID })?.sessionID else { return }
        dispatch(.deleteSession(sessionID))
    }

    /// (the next Session, or nothing when the workspace is now empty).
    ///
    /// The layout change applies immediately; deleting the Session still waits
    /// for the Host to confirm it, so a failed delete cannot hide a running
    /// process.
    private func handleClosePane(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        // A close names the pane it applies to. The scope's layout owns the
        // panes, so the named pane decides which tree is being closed — and a
        // close that is not about the layout must leave it exactly as it was,
        // which is what the `shapesTheLayout` test below guards.
        let scopeTree = scopeSplitTree(presentation: presentation)
        let renderedTree = currentSplitTree(presentation: presentation)
        let tree = paneID.map { scopeTree.contains(paneID: $0) } == true ? scopeTree : renderedTree
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: tree)
        guard let item = tree.item(for: targetPaneID) else { return }
        let sessionID = presentation.tabs.first(where: { $0.id == item.tabID })?.sessionID
        let shapesTheLayout = scopeTree.contains(paneID: targetPaneID)

        if shapesTheLayout, let newTree = tree.remove(paneID: targetPaneID) {
            setSplitTree(newTree, for: scope)
            let survivorID = newTree.allPaneIDs.first
            activePaneIDs[scope] = survivorID
            if let survivorID, let survivor = newTree.item(for: survivorID) {
                selectTab(survivor.tabID, in: presentation)
            }
        } else if shapesTheLayout {
            // The last pane is gone. Drop the stored layout and selection so the
            // Session list decides what shows next; nothing is left to clear.
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
        }

        if let sessionID {
            dispatch(.deleteSession(sessionID))
        }
    }

    /// Closes every other pane of the layout and ends its Session, leaving this
    /// one alone.
    private func handleCloseOtherPanes(paneID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let scopeTree = scopeSplitTree(presentation: presentation)
        guard scopeTree.contains(paneID: paneID),
              let item = scopeTree.item(for: paneID) else { return }
        let tree = scopeTree
        let targetPaneID = paneID
        let otherSessionIDs = tree.leaves
            .filter { $0.id != targetPaneID }
            .compactMap { leaf in presentation.tabs.first(where: { $0.id == leaf.tabID })?.sessionID }
        setSplitTree(.leaf(item), for: scope)
        activePaneIDs[scope] = item.id
        selectTab(item.tabID, in: presentation)
        for sessionID in otherSessionIDs {
            dispatch(.deleteSession(sessionID))
        }
    }

    /// Closes every pane of one layout and ends the Sessions in it.
    private func handleCloseAllPanes(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let scopeTree = scopeSplitTree(presentation: presentation)
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: scopeTree)
        let sessionIDs = scopeTree.leaves.compactMap { leaf in
            presentation.tabs.first(where: { $0.id == leaf.tabID })?.sessionID
        }
        if scopeTree.contains(paneID: targetPaneID) {
            clearSelectedPane(for: scope)
        }
        for sessionID in sessionIDs {
            dispatch(.deleteSession(sessionID))
        }
    }

    private func clearSelectedPane(for scope: String) {
        splitTrees.removeValue(forKey: scope)
        activePaneIDs.removeValue(forKey: scope)
        dispatch(.clearSelectedTab)
    }

    private func handleMaximizePane(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.count > 1 else { return }
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: tree)
        let newTree = tree.maximize(paneID: targetPaneID)
        setSplitTree(newTree, for: scope)
    }

    /// The pane a scope shows alone, while it is still one of the layout's.
    private func zoomedPaneID(in tree: SplitLayoutTree, presentation: Presentation) -> String? {
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = zoomedPaneIDs[scope],
              tree.count > 1,
              tree.contains(paneID: paneID) else { return nil }
        return paneID
    }

    /// Shows one member alone, or restores the layout when it already is.
    private func toggleZoom(tabID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation),
              let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) else { return }
        if zoomedPaneIDs[scope] == item.id {
            zoomedPaneIDs.removeValue(forKey: scope)
            return
        }
        zoomedPaneIDs[scope] = item.id
        activePaneIDs[scope] = item.id
        selectTab(tabID, in: presentation)
    }

    /// The pane a scope shows as a rail, while it can still fold: it is one
    /// of the layout's leaves, beside a divider, and not the pane being worked
    /// in. A folded pane's terminal is parked out of sight, so the selected
    /// pane is never drawn folded whatever path selected it.
    private func foldedPaneID(in tree: SplitLayoutTree, presentation: Presentation) -> String? {
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = foldedPaneIDs[scope],
              tree.count > 1,
              tree.canFold(paneID: paneID),
              currentActivePaneID(presentation: presentation, tree: tree) != paneID else { return nil }
        return paneID
    }

    /// Folds a pane into a rail.
    ///
    /// The drag that folds held the divider at the minimum on its way past it,
    /// and each step was a ratio the Host stored. Putting back the ratio the
    /// drag started from is what lets the rail restore the balance the pane
    /// had, and leaves other devices — which never see the fold — with the
    /// layout as it was. The keyboard moves to another pane, because the
    /// folded one's terminal is out of sight.
    private func handleFoldPane(
        _ paneID: String,
        splitPath: [Bool],
        restoreRatio: Double?,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.count > 1, tree.canFold(paneID: paneID) else { return }
        if let restoreRatio {
            setSplitTree(tree.updateRatio(path: splitPath, ratio: restoreRatio), for: scope)
        }
        foldedPaneIDs[scope] = paneID
        guard currentActivePaneID(presentation: presentation, tree: tree) == paneID,
              let nextID = tree.nextPaneID(after: paneID, forward: true),
              nextID != paneID,
              let next = tree.item(for: nextID) else { return }
        activePaneIDs[scope] = nextID
        selectTab(next.tabID, in: presentation)
    }

    /// Selecting a folded pane brings it back.
    private func restoreFold(ifFolded paneID: String, scope: String) {
        guard foldedPaneIDs[scope] == paneID else { return }
        foldedPaneIDs.removeValue(forKey: scope)
    }

    /// A folded pane whose Session became the selection — from the sidebar, a
    /// shortcut, or anything else that does not pass through a pane — is
    /// unfolded for good, so selecting another pane later does not fold it
    /// again behind the user's back.
    private func releaseFoldOfSelectedPane() {
        let presentation = makePresentation()
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = foldedPaneIDs[scope] else { return }
        // The scope's layout rather than the one on screen: a visit to a
        // Session outside the layout leaves the layout, and its fold, intact.
        let tree = scopeSplitTree(presentation: presentation)
        guard let item = tree.item(for: paneID) else {
            foldedPaneIDs.removeValue(forKey: scope)
            return
        }
        if navigation.selectedTabID == item.tabID {
            foldedPaneIDs.removeValue(forKey: scope)
        }
    }

    /// Focusing another pane of a zoomed layout brings the layout back, so the
    /// pane that was asked for is on screen.
    private func restoreZoom(unlessShowing paneID: String, scope: String) {
        guard let zoomed = zoomedPaneIDs[scope], zoomed != paneID else { return }
        zoomedPaneIDs.removeValue(forKey: scope)
    }

    /// Dissolves the group: the focused pane stays on screen and every other
    /// member becomes a Tab of its own. No Session ends.
    private func handleUngroup(in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1 else { return }
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        let kept = tree.maximize(paneID: activePaneID)
        zoomedPaneIDs.removeValue(forKey: scope)
        setSplitTree(kept, for: scope)
        if let item = kept.item(for: activePaneID) {
            activePaneIDs[scope] = item.id
            selectTab(item.tabID, in: presentation)
        }
    }

    /// A Tab dropped on the group pill joins the group beside its focused pane.
    private func handleMergeIntoGroup(_ tabID: String, in presentation: Presentation) {
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1, !tree.contains(tabID: tabID) else { return }
        handleSplitDrop(
            targetPaneID: currentActivePaneID(presentation: presentation, tree: tree),
            droppedTabID: tabID,
            target: .right,
            in: presentation
        )
    }

    /// A member dragged out of the group onto the strip becomes a Tab of its
    /// own: its pane leaves the layout and its Session keeps running.
    private func detachPaneLeavingLayout(
        _ tabID: String,
        before destinationTabID: String?,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1,
              let item = tree.item(forTabID: tabID),
              destinationTabID.map({ !tree.contains(tabID: $0) }) ?? true,
              let remaining = tree.remove(paneID: item.id) else { return }
        if zoomedPaneIDs[scope] == item.id {
            zoomedPaneIDs.removeValue(forKey: scope)
        }
        setSplitTree(remaining, for: scope)
        if activePaneIDs[scope] == item.id {
            activePaneIDs[scope] = remaining.allPaneIDs.first
        }
    }

    private func handleOtherPane(in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        if let nextID = tree.nextPaneID(after: activePaneID, forward: true) {
            activePaneIDs[scope] = nextID
            if let item = tree.item(for: nextID) {
                selectTab(item.tabID, in: presentation)
            }
        }
    }

    /// Places a dragged Tab into the scope's layout.
    ///
    /// The drop is a split command, so it acts on the layout even while the
    /// panel is showing a Session that is only being visited: the drop markers
    /// belong to whatever pane is on screen, and a marker that belongs to a
    /// visit cannot name a place in a layout that is not on screen. When the
    /// named pane is not part of the layout, the Tab joins at the pane the user
    /// was last working in — the same target a split command uses.
    private func handleSplitDrop(
        targetPaneID: String,
        droppedTabID: String,
        target: SplitDropTarget,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        let resolvedPaneID = tree.contains(paneID: targetPaneID)
            ? targetPaneID
            : currentActivePaneID(presentation: presentation, tree: tree)
        guard tree.contains(paneID: resolvedPaneID),
              let droppedTab = presentation.tabs.first(where: { $0.id == droppedTabID }),
              droppedTab.sessionID != nil,
              projection.tabs.contains(where: { $0.id == droppedTabID }),
              (presentation.workspace.map { projection.workspaceID(forTabID: droppedTabID) == $0.id }
                  ?? false),
              pendingSplits[scope] == nil else { return }
        if tree.contains(tabID: droppedTabID), tree.item(for: resolvedPaneID)?.tabID != droppedTabID {
            // Moving a tab between existing panes needs an explicit reorder
            // operation. Rejecting it here prevents duplicate Session IDs.
            return
        }
        let newTree: SplitLayoutTree
        switch target {
        case .top:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: false)
        case .bottom:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: true)
        case .left:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: false)
        case .right:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: true)
        case .center:
            newTree = tree.replace(paneID: resolvedPaneID, withTabID: droppedTabID)
        }
        setSplitTree(newTree, for: scope)
        if let item = newTree.item(forTabID: droppedTabID) {
            activePaneIDs[scope] = item.id
            selectTab(droppedTabID, in: presentation)
        }
    }

    /// Applies asynchronous split/close requests only after the Host roster
    /// confirms the corresponding Session transition. This keeps the layout
    /// tree and process lifecycle in lockstep even when a request races a
    /// roster update or another client.
    private func reconcilePendingSplitMutations() {
        let presentation = makePresentation()

        for (scope, pending) in Array(pendingSplits) {
            guard currentScopeKey(presentation: presentation) == scope else { continue }
            // The request named a pane of the scope's layout. Any divider the
            // user moved while the Session was starting survives, because the
            // layout itself is the base — and if the pane is gone, the user has
            // reshaped the split since, so the request is dropped rather than
            // applied to whatever happens to be on screen now.
            //
            // The pane is named by the Tab it holds, not by its pane ID.
            // Adopting a visited Session creates that pane under a local ID,
            // and the Host's echo of the adoption replaces the ID before this
            // Session arrives; matching only the ID dropped the request and
            // left the split at the adopted pair with no new pane.
            let tree = currentSplitTree(presentation: presentation)
            let targetPaneID = tree.item(forTabID: pending.targetTabID)?.id
                ?? (tree.contains(paneID: pending.targetPaneID) ? pending.targetPaneID : nil)
            guard let targetPaneID else {
                pendingSplits.removeValue(forKey: scope)
                if pending.createsNewGroup { discardUncommittedNewGroupEdit(scope) }
                paneDiagnostic("pane_split_dropped", scope: scope, [
                    "reason": "targetGone",
                    "target": Self.diagnosticTab(pending.targetTabID),
                    "tree": Self.diagnosticTabs(tree.allTabIDs),
                    "selected": Self.diagnosticTab(navigation.selectedTabID),
                ])
                continue
            }
            // The Session this request created is the scope's only new Tab.
            // Its selection is preferred but not required: waiting for the
            // selection to arrive delayed the split behind a render pass that
            // could be seconds late, and the Session's pane is what its terminal
            // attach is waiting for. A request that is answered late must not
            // leave the panel without the pane it asked for.
            let arrivals = presentation.tabs.filter {
                !pending.existingTabIDs.contains($0.id) && $0.sessionID != nil
            }
            guard let newTab = arrivals.first(where: { $0.id == navigation.selectedTabID })
                ?? arrivals.first else {
                // The roster has not published the Session yet. Keep the pending
                // intent; a failed request is released by the timeout below.
                continue
            }
            // More than one arrival means this request cannot be told apart from
            // a Tab that appeared for another reason, so which one it consumed
            // has to be recorded.
            paneDiagnostic("pane_split_arrivals", scope: scope, [
                "arrivals": arrivals.map { Self.diagnosticTabs([$0.id]) }.joined(separator: ","),
                "picked": Self.diagnosticTab(newTab.id),
                "selected": Self.diagnosticTab(navigation.selectedTabID),
                "target": Self.diagnosticTab(pending.targetTabID),
            ])
            let newTree = tree.split(
                targetPaneID: targetPaneID,
                newTabID: newTab.id,
                axis: pending.axis,
                placeAfter: true
            )
            guard newTree.count == tree.count + 1 else {
                pendingSplits.removeValue(forKey: scope)
                if pending.createsNewGroup { discardUncommittedNewGroupEdit(scope) }
                paneDiagnostic("pane_split_dropped", scope: scope, [
                    "reason": "splitRejected",
                    "new": Self.diagnosticTab(newTab.id),
                    "tree": Self.diagnosticTabs(tree.allTabIDs),
                ])
                continue
            }
            paneDiagnostic("pane_split_applied", scope: scope, [
                "new": Self.diagnosticTab(newTab.id),
                "newGroup": String(pending.createsNewGroup),
                "tree": Self.diagnosticTabs(newTree.allTabIDs),
            ])
            // A request that opened a new arrangement writes it as a new group;
            // the arrangement on screen keeps its own shape.
            setSplitTree(newTree, for: scope, asNewGroup: pending.createsNewGroup)
            if let item = newTree.item(forTabID: newTab.id) {
                activePaneIDs[scope] = item.id
                selectTab(newTab.id, in: presentation)
            }
            pendingSplits.removeValue(forKey: scope)
        }
    }

    private func handleResizeSplit(splitPath: [Bool], ratio: Double, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let newTree = tree.updateRatio(path: splitPath, ratio: ratio)
        setSplitTree(newTree, for: scope)
    }

    /// Selects a Tab.
    ///
    /// Re-selecting what is already selected is not navigation: the dispatch
    /// reaches the model as a selection, which re-presents the Session and
    /// replaces the pane's grid, so a full-screen TUI repaints end to end for a
    /// click that changed nothing. A click inside a pane — the whole pane carries
    /// the tap gesture, the terminal body included — and a click on the already
    /// selected chip both arrive here, which is why that repaint was easy to
    /// trigger without doing anything. Selecting a Tab no longer has to leave an
    /// editor mode on the way, so a click on the selected Tab now dispatches
    /// nothing at all.
    private func selectTab(_ tabID: String, in presentation: Presentation) {
        guard navigation.selectedTabID != tabID else { return }
        dispatch(.selectTab(tabID))
    }

    /// Matches the sidebar, which always lists Sessions, so the pane bar and
    /// the tree agree about who owns the Session list.
    private var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode { .rich }

    /// The identity the top chrome row shows in place of a pane track.
    ///
    /// Asked only when the pane bar presentation has already decided no track
    /// will be drawn, so `entries` is that same resolution and the two can never
    /// both render.
    private func soloPaneIdentity(
        entries: [ClientTab],
        presentation: Presentation,
        tabTitles: [String: String],
        tabMarks: [TerminalSessionID: WarrenActivityMark]
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
            canClose: true
        )
    }

    private func copySoloPaneTitle(presentation: Presentation) {
        guard let tab = presentation.tab else { return }
        let session = tab.sessionID.flatMap { projection.session(id: $0) }
        let title = soloPaneFullTitle(presentation: presentation, tab: tab, session: session)
        WarrenCopyFeedback.shared.copy(title, announcing: "Copied title")
    }

    /// The lone pane's title menu: rename the Session, copy its command or its
    /// directory, or hand the directory to an editor.
    private func makeSoloTitleActions(
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
    private func soloPaneFullTitle(
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
    private func revealReviewFile(
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

    private func presentCommandPalette() {
        // Release the terminal's AppKit first responder before the overlay
        // mounts so the palette TextField receives the next keystroke.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setCommandPalettePresented(true)
    }

    private func setSettingsPresented(_ presented: Bool) {
        if presented { settingsActivation &+= 1 }
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            settingsPresented = presented
        }
    }

    private func setChromePopover(_ popover: WarrenDesktopChromePopover?) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            chromePopover = popover
        }
    }

    private func presentRename(_ request: WarrenDesktopRenameRequest) {
        renameValue = request.initialValue
        pendingRenameEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = request
        }
    }

    private func onCustomizeEndpointDisplayName(
        _ endpoint: WarrenDesktopEndpointOption
    ) {
        presentRename(.endpoint(endpoint.id, name: endpoint.label))
    }

    private func dismissRename() {
        pendingRenameEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = nil
        }
    }

    private func confirmRename() {
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

    private func presentTaskCreator() {
        guard projection.isConnected else { return }
        taskCreatorEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isTaskCreatorPresented = true
        }
    }

    private func dismissTaskCreator() {
        taskCreatorEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isTaskCreatorPresented = false
        }
    }

    @ViewBuilder
    private var taskCreatorDialog: some View {
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
    private var renameDialog: some View {
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

    private func presentDeletion(_ request: WarrenDesktopDeletionRequest) {
        deleteWorkspaceRemoveWorktree = false
        pendingDeletionEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = request
        }
    }

    private func dismissDeletion() {
        pendingDeletionEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = nil
        }
    }

    private func deletionValidation(
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
    private var deletionDialog: some View {
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

    private static func restoredSidebarState() -> WarrenDesktopSidebarState {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: WarrenDesktopSidebarKeys.width) as? Double
        return WarrenDesktopSidebarState(
            width: storedWidth ?? WarrenLayoutMetrics.sidebarExpandedWidth,
            isCollapsed: defaults.bool(forKey: WarrenDesktopSidebarKeys.collapsed)
        )
    }

    private static func persist(_ state: WarrenDesktopSidebarState) {
        UserDefaults.standard.set(state.width, forKey: WarrenDesktopSidebarKeys.width)
        // The widened width no longer encodes a collapse, so the state is now
        // written explicitly and restored alongside it.
        UserDefaults.standard.set(state.isCollapsed, forKey: WarrenDesktopSidebarKeys.collapsed)
    }

    private static func restoredSidebarTree(scope: String) -> WarrenDesktopSidebarTreeState {
        var state = WarrenDesktopSidebarTreePersistence.restore(scope: scope)
        // The sidebar no longer offers the active-only filter, so a filter left
        // on by an earlier build would hide rows with no way to show them.
        state.showsActiveOnly = false
        return state
    }

    private static func persist(_ state: WarrenDesktopSidebarTreeState, scope: String) {
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

private enum WarrenDesktopPerformance {
    static let signposter = OSSignposter(
        subsystem: "com.abcdlsj.warren",
        category: "UI Performance"
    )
}

private enum WarrenDesktopSidebarKeys {
    static let width = "warren.desktop.sidebarWidth"
    static let collapsed = "warren.desktop.sidebarCollapsed"
}
