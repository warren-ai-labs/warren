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
    public let creatingSessionTerminalGroupIDs: Set<TerminalGroupID>
    public let deletingProjectIDs: Set<ProjectID>
    public let deletingWorkspaceIDs: Set<WorkspaceID>
    public let notices: [WarrenDesktopNotice]
    public let onNoticeAdd: (String, String, String?, WarrenDesktopNotice.Kind) -> Void
    public let onNoticeRead: (WarrenDesktopNotice.ID) -> Void
    public let onNoticeDismiss: (WarrenDesktopNotice.ID) -> Void
    public let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]
    /// Gives AppKit-backed terminal surfaces a chance to park before SwiftUI
    /// commits a mode change that can alter their proposed geometry.
    public let onActiveScreenSessionsWillChange: (Set<TerminalSessionID>) -> Void
    public let onActiveScreenSessionsChanged: (Set<TerminalSessionID>) -> Void
    /// Reports the arrangement a scope should now have. The Host owns the
    /// shape, so the view never stores one: it asks, and the roster answers.
    public let onCommitPaneTree: (WarrenDesktopPaneOwner, PaneNode) -> Void

    private let endpointOptions: [WarrenDesktopEndpointOption]
    private let selectedEndpointID: String
    private let endpointCapabilities: WarrenDesktopEndpointCapabilities
    private let onSelectEndpoint: (String) -> Void
    private let onSetEndpointSidebarVisibility: (String, Bool) -> Void
    private let onSetEndpointDisplayName: (String, String?) -> Void
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
    private let onRetryConnection: () -> Void
    private let onStopConnection: () -> Void

    private let actions: WarrenDesktopActions
    private let onCreateTask: @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID
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
    private let editorSurface: @MainActor (Workspace) -> AnyView
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
    @State private var settingsDeepLinkSection: WarrenDesktopSettingsSection?
    @State private var settingsPublicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    @State private var settingsRelayPrefill: WarrenDesktopRelayPrefill?
    @State private var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State private var chromePopover: WarrenDesktopChromePopover?
    @State private var webDismissalNonce = 0
    @State private var pendingRename: WarrenDesktopRenameRequest?
    /// Resource dialogs capture the Endpoint that owned their row. A dialog
    /// opened on one Host must never submit its bare ID after the user
    /// switches to another Host that may issue the same UUID.
    @State private var pendingRenameEndpointID: String?
    @State private var isTaskCreatorPresented = false
    @State private var taskCreatorEndpointID: String?
    @State private var renameValue = ""
    @State private var pendingTerminalGroupEditor: WarrenDesktopTerminalGroupEditorMode?
    @State private var pendingTerminalGroupEditorEndpointID: String?
    @State private var terminalGroupName = ""
    @State private var terminalGroupHome = ""
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
    @State private var splitTrees: [String: SplitLayoutTree]
    @State private var activePaneIDs: [String: String]
    /// Which arrangement this window renders for a scope. It is per viewer and
    /// never sent to the Host: the Host owns the shape, not the choice.
    @State private var activePaneGroupIDs: [String: String]
    /// The last arrangement the Host confirmed, per scope. A local tree that
    /// differs from it is an edit in flight, and it must outlive the Host's
    /// stale answer until the roster echoes the write.
    @State private var adoptedPaneTrees: [String: SplitLayoutTree] = [:]
    @State private var pendingSplits: [String: PendingSplit]
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
    /// Mirrors the sidebar's own preference so the pane bar can resolve which
    /// surface lists Sessions. See `WarrenDesktopPaneBar.presentation(...)`.
    @AppStorage(WarrenPreferenceKey.sidebarWorkspaceDisplayMode)
    private var workspaceDisplayModeRawValue = WarrenDesktopWorkspaceDisplayMode.rich.rawValue
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    private var splitChordsEnabled = false
    @Environment(\.warrenSemanticRecorder) private var semanticRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private struct Presentation {
        let workspace: Workspace?
        let terminalGroup: TerminalGroup?
        let contentWorkspace: Workspace?
        let contentTerminalGroup: TerminalGroup?
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
        webStatus: WarrenDesktopWebStatus = .init(),
        isMigratingRuntimeSessions: Bool = false,
        creatingSessionWorkspaceIDs: Set<WorkspaceID> = [],
        creatingSessionTerminalGroupIDs: Set<TerminalGroupID> = [],
        deletingProjectIDs: Set<ProjectID> = [],
        deletingWorkspaceIDs: Set<WorkspaceID> = [],
        notices: [WarrenDesktopNotice] = [],
        onNoticeAdd: @escaping (String, String, String?, WarrenDesktopNotice.Kind) -> Void = { _, _, _, _ in },
        onNoticeRead: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        onNoticeDismiss: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl] = WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
        onActiveScreenSessionsWillChange: @escaping (Set<TerminalSessionID>) -> Void = { _ in },
        onActiveScreenSessionsChanged: @escaping (Set<TerminalSessionID>) -> Void = { _ in },
        onCommitPaneTree: @escaping (WarrenDesktopPaneOwner, PaneNode) -> Void = { _, _ in },
        endpointOptions: [WarrenDesktopEndpointOption] = [
            .init(id: "local", label: "Local", isLocal: true),
        ],
        selectedEndpointID: String = "local",
        endpointCapabilities: WarrenDesktopEndpointCapabilities? = nil,
        onSelectEndpoint: @escaping (String) -> Void = { _ in },
        onSetEndpointSidebarVisibility: @escaping (String, Bool) -> Void = { _, _ in },
        onSetEndpointDisplayName: @escaping (String, String?) -> Void = { _, _ in },
        sidebarHostProjections: [WarrenDesktopSidebarHostProjection]? = nil,
        usesSidebarHostSections: Bool = false,
        sidebarResourceSelection: WarrenDesktopSidebarResourceSelection? = nil,
        displayConfigurationError: String? = nil,
        onSelectSidebarResource: @escaping (WarrenDesktopSidebarResourceSelection) -> Void = { _ in },
        onOpenSidebarWorkspace: @escaping (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void = { _ in },
        onOpenSidebarSession: @escaping (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void = { _ in },
        onRetrySidebarHost: @escaping (String) -> Void = { _ in },
        onAddSSHHost: @escaping () -> Void = {},
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
        editorSurface: @escaping @MainActor (Workspace) -> AnyView = { _ in AnyView(EmptyView()) },
        onOpenEditorDocument: @escaping @MainActor (Workspace, WarrenDesktopEditorDocument) -> Void = { _, _ in },
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
        self.creatingSessionTerminalGroupIDs = creatingSessionTerminalGroupIDs
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.notices = notices
        self.onNoticeAdd = onNoticeAdd
        self.onNoticeRead = onNoticeRead
        self.onNoticeDismiss = onNoticeDismiss
        self.endpointOptions = endpointOptions
        self.externallyVisibleControls = WarrenDesktopWorkspaceTabTrailingControl.controlsForEndpointCount(
            externallyVisibleControls,
            endpointCount: endpointOptions.count
        )
        self.onActiveScreenSessionsWillChange = onActiveScreenSessionsWillChange
        self.onActiveScreenSessionsChanged = onActiveScreenSessionsChanged
        self.onCommitPaneTree = onCommitPaneTree
        self.selectedEndpointID = selectedEndpointID
        let resolvedEndpointCapabilities = endpointCapabilities
            ?? endpointOptions.first(where: { $0.id == selectedEndpointID })?.capabilities
            ?? (selectedEndpointID == "local" ? .local : .remote)
        self.endpointCapabilities = resolvedEndpointCapabilities
        self.onSelectEndpoint = onSelectEndpoint
        self.onSetEndpointSidebarVisibility = onSetEndpointSidebarVisibility
        self.onSetEndpointDisplayName = onSetEndpointDisplayName
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
        self.onRetryConnection = onRetryConnection
        self.onStopConnection = onStopConnection
        self.actions = actions
        self.onCreateTask = onCreateTask
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
        self.editorSurface = editorSurface
        self.onOpenEditorDocument = onOpenEditorDocument
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
        let showsEditorRegion = showsEditorRegion(for: presentation.workspace)
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
        let tabActivities = Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            session.activity.map { (session.id, $0) }
        })
        let pinnedSessionIDs = Set(
            projection.sessions.filter(\.pinned).map(\.id)
        )
        let isAddingSession = isAddingSession(in: presentation)
        let sessionMoveTargets = makeSessionMoveTargets()
        let sessionMoveDestinations = makeSessionMoveDestinations()
        let externalIDEOptions = makeExternalIDEOptions(for: presentation)
        let embeddedEditorChromeAvailable = embeddedEditorAvailable
            && externalIDEOptions != nil
        let availableTrailingControls = WarrenDesktopWorkspaceTabTrailingControl.available(
            externalIDEOptions: externalIDEOptions,
            embeddedEditorAvailable: embeddedEditorChromeAvailable
        )
        let trailingControlLayout = WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: externallyVisibleControls,
            availableControls: availableTrailingControls
        )
        let tabBarView = makeTabBarView(
            presentation: presentation,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            isAddingSession: isAddingSession,
            sessionMoveTargets: sessionMoveTargets,
            sessionMoveDestinations: sessionMoveDestinations,
            externalIDEOptions: externalIDEOptions,
            embeddedEditorChromeAvailable: embeddedEditorChromeAvailable
        )
        let sidebarView = WarrenDesktopSidebar(
            projection: projection,
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
            onAction: dispatch,
            onCommandPalette: presentCommandPalette,
            onSettings: openSettings,
            notices: notices,
            isNoticePopoverPresented: $isNoticePopoverPresented,
            onDismissNoticePopover: { isNoticePopoverPresented = false },
            onNoticeRead: onNoticeRead,
            onNoticeDismiss: onNoticeDismiss,
            onMarkAllNoticesRead: markAllNoticesRead,
            onRequestRename: presentRename,
            onRequestDeletion: presentDeletion,
            onRequestTerminalGroupCreate: presentTerminalGroupCreate,
            onRequestTerminalGroupEdit: presentTerminalGroupEdit,
            activeEndpointID: selectedEndpointID,
            displayConfigurationError: displayConfigurationError,
            sidebarHostProjections: sidebarHostProjections,
            usesSidebarHostSections: usesSidebarHostSections,
            sidebarResourceSelection: sidebarResourceSelection,
            onSelectSidebarResource: onSelectSidebarResource,
            onOpenSidebarWorkspace: onOpenSidebarWorkspace,
            onOpenSidebarSession: onOpenSidebarSession,
            onRetrySidebarHost: onRetrySidebarHost,
            editorActivity: WarrenDesktopEditorActivityOverlay(
                states: workspaceEditorStates
            ),
            // The marker already put the Workspace in the region set, so this is
            // navigation: it brings up the column that draws the editor. The
            // insert keeps the entry honest if the two ever diverge.
            onOpenEditor: { workspaceID in
                editorRegionWorkspaceIDs.insert(workspaceID)
                dispatch(.selectWorkspace(workspaceID))
            }
        )
        .frame(width: sidebarState.renderedWidth)
        let workspaceColumn = makeWorkspaceColumn(
            presentation: presentation,
            tabBarView: tabBarView,
            showsEditorRegion: showsEditorRegion,
            isAddingSession: isAddingSession,
            currentTree: currentTree,
            currentPaneID: currentPaneID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                sidebarView
                    // The handle sits inside the rail's trailing edge rather
                    // than between the columns, so grabbing it never shifts
                    // either one and the drag reads as moving the boundary.
                    .overlay(alignment: .trailing) {
                        if !sidebarState.isCollapsed {
                            WarrenDesktopSidebarResizeHandle(
                                width: sidebarState.renderedWidth,
                                onResize: { sidebarState.setWidth($0) },
                                onReset: { sidebarState.restoreExpanded() }
                            )
                        }
                    }
                workspaceColumn
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(settingsPresented ? 0 : 1)
            .allowsHitTesting(!settingsPresented)
            .accessibilityHidden(settingsPresented)

            if settingsPresented {
                settingsOverlay
            }
        }
        .frame(
            // The editor region widens the window's floor while it is up.
            // Otherwise the region's own floor — code-server's 220pt editor part
            // plus its Explorer — would be met by squeezing the Terminal to
            // nothing, and RFC 0021's open question about narrow windows would
            // become a state users could sit in.
            minWidth: WarrenLayoutMetrics.sidebarExpandedWidth
                + currentTree.windowMinimumPaneWidth
                + (showsEditorRegion
                    ? WarrenLayoutMetrics.editorRegionMinimumWidth
                        + WarrenLayoutMetrics.editorSplitDividerWidth
                    : 0),
            minHeight: (chromeMode.showsIndependentTopBar ? WarrenLayoutMetrics.topBarHeight : 0)
                + WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + currentTree.windowMinimumPaneHeight
        )
        .denSurface()
        .warrenUnixTextEditing()
        .environment(\.warrenTabDrag, tabDrag)
        .environmentObject(tabDrag)
        .onChange(of: sidebarState) { newState in
            if persistenceEnabled { Self.persist(newState) }
        }
        .onChange(of: sidebarTree) { newState in
            if persistenceEnabled { Self.persist(newState, scope: selectedEndpointID) }
        }
        .onChange(of: workspaceEditorStates) { newStates in
            guard persistenceEnabled else { return }
            WarrenDesktopWorkspaceEditorStateStore.save(newStates)
        }
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
            // Tasks, terminal groups, and rename dialogs are current-Host
            // interactions. Close them when the owner changes so a later
            // confirmation cannot route a bare resource ID to this Host.
            pendingRename = nil
            pendingRenameEndpointID = nil
            pendingTerminalGroupEditor = nil
            pendingTerminalGroupEditorEndpointID = nil
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
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.openSettings)) { note in
            guard let request = note.object as? WarrenDesktopSettingsDeepLink else { return }
            openSettings(request)
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
        }
        .onChange(of: creatingSessionWorkspaceIDs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
        }
        .onChange(of: creatingSessionTerminalGroupIDs) { _ in
            reconcilePendingSplitMutations()
            reconcilePersistedSplitTree()
        }
        .onAppear {
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
            terminalGroupEditorDialog
        }
        .overlay {
            deletionDialog
        }
        .overlay {
            if commandPalettePresented && !settingsPresented {
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
                        WarrenColorTokens.resolved(for: colorScheme).modalScrim
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
                externalIDEOptions: externalIDEOptions,
                embeddedEditorChromeAvailable: embeddedEditorChromeAvailable,
                overflowControls: trailingControlLayout.overflow
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if emacsChordActive {
                let tokens = WarrenColorTokens.resolved(for: colorScheme)
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
        .onChange(of: chromePopover) { popover in
            guard case .web? = popover else { return }
            refreshWebDismissal()
        }
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
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
        case .terminalGroup:
            return nil
        }
    }

    private var selectedEndpointIsLocal: Bool {
        endpointOptions.first { $0.id == selectedEndpointID }?.isLocal == true
    }

    private var isWebChromePopover: Bool {
        chromePopover == .web
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
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool,
        overflowControls: [WarrenDesktopWorkspaceTabTrailingControl]
    ) -> some View {
        if let chromePopover, !settingsPresented {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { setChromePopover(nil) }
                    .ignoresSafeArea()

                switch chromePopover {
                case .web:
                    WarrenDesktopWebPanel(
                        status: webStatus,
                        canControl: webStatus.canControl,
                        canCopyLocalWebURL: endpointCapabilities.canCopyLocalWebURL,
                        onStart: {
                            onWebStart()
                            refreshWebDismissal()
                        },
                        onOpenSettings: {
                            setChromePopover(nil)
                            openPublicAccessSettings()
                        },
                        onStop: {
                            onWebStop()
                            refreshWebDismissal()
                        },
                        onOpenURL: { url in
                            onWebOpenURL(url)
                            refreshWebDismissal()
                        },
                        onCopyURL: { url in
                            onWebCopyURL(url)
                            refreshWebDismissal()
                        },
                        onDismiss: { setChromePopover(nil) }
                    )
                case .endpoint:
                    WarrenDesktopEndpointPopover(
                        connectionState: projection.connectionState,
                        endpoints: endpointOptions,
                        selectedID: selectedEndpointID,
                        onSelect: onSelectEndpoint,
                        onSetSidebarVisibility: onSetEndpointSidebarVisibility,
                        onCustomizeDisplayName: { endpoint in
                            setChromePopover(nil)
                            onCustomizeEndpointDisplayName(endpoint)
                        },
                        onAddSSHHost: onAddSSHHost,
                        onRetry: onRetryConnection,
                        onStop: onStopConnection,
                        onDismiss: { setChromePopover(nil) }
                    )
                case .externalIDE:
                    if let options = externalIDEOptions {
                        WarrenDesktopExternalIDEPopover(
                            options: options,
                            embeddedEditorAvailable: embeddedEditorChromeAvailable,
                            embeddedEditorDefault: embeddedEditorDefaultIDE,
                            isEditorOpen: showsEditorRegion(
                                for: presentation.workspace
                            ),
                            onOpenEmbeddedEditor: {
                                openEditorRegion(
                                    for: presentation.workspace,
                                    restoringLastDocument: true
                                )
                            },
                            onCloseEmbeddedEditor: {
                                guard let workspace = presentation.workspace else { return }
                                closeEditorRegion(for: workspace)
                            },
                            onSetEmbeddedEditorDefault: {
                                embeddedEditorDefaultIDE = $0
                            },
                            onOpen: openInExternalIDE,
                            onDismiss: { setChromePopover(nil) }
                        )
                    }
                case .overflow:
                    WarrenDesktopOverflowPopover(
                        controls: overflowControls,
                        detail: { control in
                            overflowControlDetail(
                                control,
                                workspace: presentation.workspace,
                                externalIDEOptions: externalIDEOptions,
                                embeddedEditorChromeAvailable: embeddedEditorChromeAvailable
                            )
                        },
                        supportsSecondary: { control in
                            overflowControlSupportsSecondary(
                                control,
                                externalIDEOptions: externalIDEOptions,
                                embeddedEditorChromeAvailable: embeddedEditorChromeAvailable
                            )
                        },
                        secondaryContent: { control, onBack in
                            overflowSecondaryContent(
                                control,
                                onBack: onBack,
                                presentation: presentation,
                                externalIDEOptions: externalIDEOptions,
                                embeddedEditorChromeAvailable: embeddedEditorChromeAvailable
                            )
                        },
                        secondaryTitleAccessory: overflowSecondaryTitleAccessory,
                        onSelect: { control in
                            selectOverflowControl(
                                control,
                                presentation: presentation,
                                externalIDEOptions: externalIDEOptions,
                                embeddedEditorChromeAvailable: embeddedEditorChromeAvailable
                            )
                        },
                        onDismiss: { setChromePopover(nil) }
                    )
                }
            }
            .padding(.top, WarrenLayoutMetrics.tabBarHeight + WarrenSpacing.small)
            .padding(.trailing, WarrenSpacing.medium)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(
                WarrenMotion.animation(.overlay, reduceMotion: reduceMotion),
                value: chromePopover
            )
            .onChange(of: webStatus.tunnelRunning) { isRunning in
                // Keep the panel open while Public Access is enabled so the public endpoint
                // stays visible for copying; it falls back to auto-dismiss
                // after stop.
                if isRunning, isWebChromePopover {
                    refreshWebDismissal()
                }
            }
            .task(id: webDismissalNonce) {
                guard isWebChromePopover else { return }
                try? await Task.sleep(for: WarrenDesktopWebDismissal.interval)
                guard !Task.isCancelled else { return }
                guard !webStatus.tunnelRunning else { return }
                setChromePopover(nil)
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
        tabActivities: [TerminalSessionID: AgentActivityState],
        pinnedSessionIDs: Set<TerminalSessionID>,
        isAddingSession: Bool,
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
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
                    tabActivities: tabActivities
                )
            }
        )
        return AnyView(WarrenDesktopTabBar(
            presentation: paneBar,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            selectedTabID: navigation.selectedTabID,
            splitGroup: splitGroup(tree: barTree, presentation: presentation),
            onCopyPaneTitle: {
                copySoloPaneTitle(presentation: presentation)
            },
            chromeMode: chromeMode,
            isSidebarCollapsed: sidebarState.isCollapsed,
            connectionState: projection.connectionState,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            webStatus: webStatus,
            externalIDEOptions: externalIDEOptions,
            embeddedEditorAvailable: embeddedEditorChromeAvailable
                && presentation.workspace != nil,
            // The control's checked state is "the editor region is up", not
            // "the editor replaced the terminal". There is no longer a mode for
            // it to report.
            embeddedEditorSelected: showsEditorRegion(for: presentation.workspace),
            embeddedEditorDefault: embeddedEditorDefaultIDE,
            externallyVisibleControls: externallyVisibleControls,
            isOverflowPresented: chromePopover == .overflow,
            onToggleSidebar: toggleSidebar,
            onSettings: openSettings,
            onChromePopover: { popover in
                setChromePopover(chromePopover == popover ? nil : popover)
            },
            onOpenInExternalIDE: openInExternalIDE,
            onOpenEmbeddedEditor: {
                openEditorRegion(
                    for: presentation.workspace,
                    restoringLastDocument: true
                )
            },
            onCloseEmbeddedEditor: {
                guard let workspace = presentation.workspace else { return }
                closeEditorRegion(for: workspace)
            },
            onSelectEndpoint: onSelectEndpoint,
            onRetryConnection: onRetryConnection,
            onStopConnection: onStopConnection,
            onSelectTab: { selectTabFromTabBar($0, in: presentation) },
            onMoveTab: { tabID, destinationTabID in
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
            canAddTab: presentation.workspace != nil || presentation.terminalGroup != nil,
            isAddingTab: isAddingSession,
            onAddTab: {
                handleNewSession(in: presentation)
            },
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
            }
        ))
    }

    private func makeWorkspaceColumn(
        presentation: Presentation,
        tabBarView: AnyView,
        showsEditorRegion: Bool,
        isAddingSession: Bool,
        currentTree: SplitLayoutTree,
        currentPaneID: String
    ) -> AnyView {
        return AnyView(
            VStack(spacing: 0) {
                if chromeMode.showsIndependentTopBar {
                    WarrenDesktopTopBar(
                        hostName: projection.host.name,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        onToggleSidebar: toggleSidebar
                    )
                }
                tabBarView
                // The preset bar used to be gated on the terminal-only content
                // mode, so opening the editor removed it. The Terminal is now
                // always on screen, so its launchers stay with it.
                WarrenDesktopPresetBar(
                    workspace: presentation.workspace,
                    terminalGroup: presentation.terminalGroup,
                    isBusy: isAddingSession,
                    onLaunch: { request in
                        launchSession(request, in: presentation)
                    }
                )
                if showsEditorRegion, let workspace = presentation.workspace {
                    WarrenDesktopCentralSplit(
                        terminalRatio: $terminalRatio,
                        terminal: terminalRegion(
                            presentation: presentation,
                            currentTree: currentTree,
                            currentPaneID: currentPaneID
                        ),
                        editor: WarrenDesktopEmbeddedEditorPane(
                            workspace: workspace,
                            surface: editorSurface(workspace)
                        )
                    )
                } else {
                    terminalRegion(
                        presentation: presentation,
                        currentTree: currentTree,
                        currentPaneID: currentPaneID
                    )
                }
            }
        )
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
                terminalGroup: presentation.contentTerminalGroup,
                tab: presentation.tab,
                hasProjects: !projection.groups.isEmpty,
                connectionState: projection.connectionState,
                isMigratingRuntimeSessions: isMigratingRuntimeSessions,
                endpointCapabilities: endpointCapabilities,
                // The lone pane's identity is drawn exactly once. A
                // split needs a header per pane to answer "which of
                // these"; with one pane the top chrome row carries it
                // instead — unless compact mode handed that row to the
                // Session list, which leaves the header as the only
                // place the title can live.
                showsPaneHeader: currentTree.count > 1
                    || workspaceDisplayMode.paneBarListsEverySession,
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
                    && !settingsPresented
                    && !editorHasKeyboardFocus,
                splitTree: currentTree,
                activePaneID: currentPaneID,
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

    /// Whether the code-server region is beside the Terminal for this Workspace.
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
                relayPrefill: settingsRelayPrefill
            )
            .transition(.opacity)
        )
    }

    private func makePresentation() -> Presentation {
        let interval = WarrenDesktopPerformance.signposter.beginInterval("SwiftUI Presentation")
        defer { WarrenDesktopPerformance.signposter.endInterval("SwiftUI Presentation", interval) }
        let navigationWorkspace: Workspace?
        let navigationTerminalGroup: TerminalGroup?
        switch navigation.selection {
        case .project(let projectID):
            navigationWorkspace = projection.firstWorkspace(in: projectID)
            navigationTerminalGroup = nil
        case .workspace(let workspaceID):
            navigationWorkspace = projection.workspace(id: workspaceID)
            navigationTerminalGroup = nil
        case .terminalGroup(let groupID):
            navigationWorkspace = nil
            navigationTerminalGroup = projection.terminalGroup(id: groupID)
        case nil:
            navigationWorkspace = firstWorkspace
            navigationTerminalGroup = nil
        }
        let tabs: [ClientTab]
        if let navigationWorkspace {
            tabs = projection.tabs(in: navigationWorkspace.id)
        } else if let navigationTerminalGroup {
            tabs = projection.tabs(in: navigationTerminalGroup.id)
        } else {
            tabs = []
        }
        let tab = navigation.selectedTabID.flatMap { selectedTabID in
            tabs.first { $0.id == selectedTabID }
        }
        let tabWorkspace = tab?.sessionID.flatMap { projection.workspace(for: $0) }
        let workspace = tabWorkspace ?? navigationWorkspace
        let tabTerminalGroup = tab?.sessionID.flatMap { projection.terminalGroup(for: $0) }
        let terminalGroup = tabTerminalGroup ?? navigationTerminalGroup
        let session = tab?.sessionID.flatMap { projection.session(id: $0) }
        return Presentation(
            workspace: workspace,
            terminalGroup: terminalGroup,
            contentWorkspace: tabWorkspace ?? workspace,
            contentTerminalGroup: tabTerminalGroup ?? terminalGroup,
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
        if let terminalGroup = presentation.terminalGroup {
            return creatingSessionTerminalGroupIDs.contains(terminalGroup.id)
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
        for group in projection.terminalGroups {
            targets.append(WarrenDesktopSessionMoveTarget(
                id: "terminalGroup:\(group.id.description)",
                title: group.name,
                destination: .terminalGroup(group.id)
            ))
        }
        return targets
    }

    private func makeSessionMoveDestinations() -> [TerminalSessionID: WarrenDesktopSessionMoveDestination] {
        Dictionary(uniqueKeysWithValues: projection.sessions.compactMap { session in
            if let workspaceID = projection.sessionWorkspaceIDs[session.id] {
                return (session.id, .workspace(workspaceID))
            }
            if let groupID = projection.sessionTerminalGroupIDs[session.id] {
                return (session.id, .terminalGroup(groupID))
            }
            return nil
        })
    }

    private func addSession(in presentation: Presentation) {
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id))
        } else if let terminalGroup = presentation.terminalGroup {
            dispatch(.requestNewTerminalGroupSession(terminalGroup.id))
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
        } else if let terminalGroup = presentation.terminalGroup {
            dispatch(.launchTerminalGroupSession(terminalGroup.id, request))
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

    private func overflowControlDetail(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        workspace: Workspace?,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
    ) -> String? {
        switch control {
        case .externalIDE:
            if embeddedEditorChromeAvailable {
                if showsEditorRegion(for: workspace) {
                    return "Editor open"
                }
                return embeddedEditorDefaultIDE
                    ? "Embedded editor default"
                    : "Choose an IDE"
            }
            return externalIDEOptions?.first?.name
        case .endpoint:
            return endpointOptions.first { $0.id == selectedEndpointID }?.label
        case .web:
            if webStatus.tunnelRunning {
                return "Public Access on"
            }
            return webStatus.isRunning ? "Web running" : "Web stopped"
        case .settings:
            return nil
        }
    }

    private func overflowControlSupportsSecondary(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
    ) -> Bool {
        switch control {
        case .externalIDE:
            if embeddedEditorChromeAvailable, embeddedEditorDefaultIDE {
                return false
            }
            return embeddedEditorChromeAvailable
                || !(externalIDEOptions?.isEmpty ?? true)
        case .endpoint, .web:
            return true
        case .settings:
            return false
        }
    }

    private func overflowSecondaryContent(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        onBack: @escaping () -> Void,
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
    ) -> AnyView? {
        switch control {
        case .externalIDE:
            guard let options = externalIDEOptions else { return nil }
            return AnyView(
                WarrenDesktopExternalIDEPopoverContent(
                    options: options,
                    embeddedEditorAvailable: embeddedEditorChromeAvailable,
                    embeddedEditorDefault: embeddedEditorDefaultIDE,
                    isEditorOpen: showsEditorRegion(for: presentation.workspace),
                    onOpenEmbeddedEditor: {
                        openEditorRegion(
                            for: presentation.workspace,
                            restoringLastDocument: true
                        )
                    },
                    onCloseEmbeddedEditor: {
                        guard let workspace = presentation.workspace else { return }
                        closeEditorRegion(for: workspace)
                    },
                    onSetEmbeddedEditorDefault: {
                        embeddedEditorDefaultIDE = $0
                    },
                    onOpen: { option in
                        openInExternalIDE(option)
                    },
                    onDismiss: onBack
                )
            )
        case .endpoint:
            return AnyView(
                WarrenDesktopEndpointPopoverContent(
                    connectionState: projection.connectionState,
                    endpoints: endpointOptions,
                    selectedID: selectedEndpointID,
                    onSelect: { endpointID in
                        onSelectEndpoint(endpointID)
                        onBack()
                    },
                    onSetSidebarVisibility: onSetEndpointSidebarVisibility,
                    onCustomizeDisplayName: { endpoint in
                        onBack()
                        onCustomizeEndpointDisplayName(endpoint)
                    },
                    onAddSSHHost: {
                        onAddSSHHost()
                        onBack()
                    },
                    onRetry: {
                        onRetryConnection()
                        onBack()
                    },
                    onStop: {
                        onStopConnection()
                        onBack()
                    },
                    onDismiss: onBack
                )
            )
        case .web:
            let panel = WarrenDesktopWebPanel(
                status: webStatus,
                canControl: webStatus.canControl,
                canCopyLocalWebURL: endpointCapabilities.canCopyLocalWebURL,
                onStart: {
                    onWebStart()
                    refreshWebDismissal()
                },
                onOpenSettings: openPublicAccessSettings,
                onStop: {
                    onWebStop()
                    refreshWebDismissal()
                },
                onOpenURL: onWebOpenURL,
                onCopyURL: onWebCopyURL,
                onDismiss: onBack
            )
            return AnyView(panel.inlineContent)
        case .settings:
            return nil
        }
    }

    private func overflowSecondaryTitleAccessory(
        _ control: WarrenDesktopWorkspaceTabTrailingControl
    ) -> AnyView? {
        return nil
    }

    private func markAllNoticesRead() {
        notices
            .filter(\.isUnread)
            .forEach { onNoticeRead($0.id) }
    }

    private func selectOverflowControl(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        presentation: Presentation,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
    ) {
        switch control {
        case .externalIDE:
            // Same resolution as the direct control, so the overflow copy cannot
            // disagree with it about what one click does.
            switch WarrenDesktopIDEPrimaryAction.resolve(
                embeddedEditorDefault: embeddedEditorChromeAvailable
                    && embeddedEditorDefaultIDE,
                embeddedEditorSelected: embeddedEditorChromeAvailable
                    && showsEditorRegion(for: presentation.workspace)
            ) {
            case .openEmbeddedEditor:
                openEditorRegion(
                    for: presentation.workspace,
                    restoringLastDocument: true
                )
                setChromePopover(nil)
            case .closeEmbeddedEditor:
                guard let workspace = presentation.workspace else { return }
                closeEditorRegion(for: workspace)
                setChromePopover(nil)
            case .presentChoices:
                guard externalIDEOptions != nil else { return }
                setChromePopover(.externalIDE)
            }
        case .endpoint:
            setChromePopover(.endpoint)
        case .web:
            setChromePopover(.web)
        case .settings:
            setChromePopover(nil)
            openSettings()
        }
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

    private func toggleSidebar() {
        // Resizing this boundary animates the AppKit terminal viewport on
        // every frame. Switch geometry once and reserve motion for overlays.
        sidebarState.toggleCollapsed()
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
        } else if let terminalGroup = presentation.terminalGroup {
            return endpointScope + "terminalGroup-\(terminalGroup.id.rawValue.uuidString)"
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

    /// The pane group the bar labels, or nil when the tree it is given is not
    /// split.
    ///
    /// The tree comes from the caller, which is what makes the group follow the
    /// display mode: rich mode hands over the tree on screen, so a visit draws
    /// no group; compact mode hands over the scope's layout, so the group stays
    /// on the strip as the way back into the split. One pane is not a group:
    /// there is no second pane to bind it to, and no mark to draw.
    private func splitGroup(
        tree: SplitLayoutTree,
        presentation: Presentation
    ) -> WarrenDesktopSplitGroup? {
        guard let scope = currentScopeKey(presentation: presentation),
              tree.count > 1 else { return nil }
        return WarrenDesktopSplitGroup(scopeKey: scope, tree: tree)
    }

    /// The moves that bring a scope's Tab order back in line with its layout.
    ///
    /// Called whenever the layout changes, and once on appear so a restored
    /// layout is matched by a restored order. An unchanged order costs nothing,
    /// which matters because a divider drag also lands here.
    private func alignTabOrderWithLayout() {
        let presentation = makePresentation()
        let layout = scopeSplitTree(presentation: presentation)
        guard layout.count > 1 else { return }
        let order: [String]
        if let workspaceID = presentation.workspace?.id {
            order = projection.tabs(in: workspaceID).map(\.id)
        } else if let groupID = presentation.terminalGroup?.id {
            order = projection.tabs(in: groupID).map(\.id)
        } else {
            return
        }
        let target = WarrenDesktopTabOrdering.membersFirst(order, members: layout.allTabIDs)
        for move in WarrenDesktopTabOrdering.moves(from: order, to: target) {
            dispatch(.moveTab(move.tabID, before: move.before))
        }
    }

    private func setSplitTree(_ tree: SplitLayoutTree, for scope: String) {
        splitTrees[scope] = tree
        commitSplitTree(tree, for: scope)
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
        if let terminalGroup = presentation.terminalGroup {
            return projection.paneGroups(in: terminalGroup.id)
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
        if let terminalGroup = presentation.terminalGroup {
            return .terminalGroup(terminalGroup.id)
        }
        return nil
    }

    /// Sends one local arrangement to the Host. The Host assigns pane identity
    /// and rejects a tree it cannot validate, so the local value is only an
    /// optimistic head start: the roster's answer replaces it.
    private func commitSplitTree(_ tree: SplitLayoutTree, for scope: String) {
        let presentation = makePresentation()
        guard currentScopeKey(presentation: presentation) == scope,
              let owner = paneOwner(for: presentation),
              let node = WarrenDesktopPaneGroupMapping.paneNode(
                  from: tree,
                  sessionIDForTabID: { WarrenDesktopPaneGroupMapping.sessionID(forTabID: $0) }
              ) else { return }
        // A split whose Session the Host has not published yet would be rejected
        // as an unknown Session. The pending-split path calls back here once the
        // roster confirms it, so skipping is what keeps the two in step.
        let live = Set(projection.sessions.map(\.id))
        guard node.sessionIDs.allSatisfy({ live.contains($0) }) else { return }
        onCommitPaneTree(owner, node)
    }

    /// Adopts the Host's arrangements after a roster change, so a summary of
    /// every scope that gained, changed, or lost a group is reflected locally.
    private func adoptHostPaneGroups() {
        let endpointPrefix = "endpoint-\(selectedEndpointID)-"
        var ownedScopes: Set<String> = []
        for group in projection.paneGroups {
            guard let scope = paneGroupScopeKey(for: group) else { continue }
            ownedScopes.insert(scope)
            let adopted = WarrenDesktopPaneGroupMapping.tree(from: group)
            // A roster can still carry the arrangement from before a local edit,
            // so adopting it here would collapse the split until the Host's own
            // answer arrives. Keep the edit and let the confirming tree land.
            guard WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: splitTrees[scope],
                adopted: adoptedPaneTrees[scope],
                host: adopted
            ) else { continue }
            if splitTrees[scope] != adopted {
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
        if let terminalGroupID = group.terminalGroupID {
            return "endpoint-\(selectedEndpointID)-terminalGroup-\(terminalGroupID.rawValue.uuidString)"
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
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
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

    /// Arrangements are keyed by endpoint and scope, so a deleted Workspace or
    /// Terminal Group would otherwise keep a local tree forever. Only the current
    /// endpoint's scopes are evaluated: another endpoint's Workspaces are absent
    /// from this projection and are not deleted.
    private func pruneSplitTreesForDeletedScopes() {
        var liveScopeKeys: Set<String> = []
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        for workspace in projection.groups.flatMap(\.workspaces) {
            liveScopeKeys.insert(endpointScope + "workspace-\(workspace.id.rawValue.uuidString)")
        }
        for terminalGroup in projection.terminalGroups {
            liveScopeKeys.insert(endpointScope + "terminalGroup-\(terminalGroup.id.rawValue.uuidString)")
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
            pendingSplits.removeValue(forKey: scope)
        }
    }

    private func visibleScreenSessionIDs(
        for presentation: Presentation,
        in tree: SplitLayoutTree
    ) -> Set<TerminalSessionID> {
        let tabsByID = Dictionary(presentation.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessionIDs = tree.leaves.compactMap { leaf in
            tabsByID[leaf.tabID]?.sessionID
        }
        if sessionIDs.isEmpty, let fallback = presentation.tab?.sessionID {
            return [fallback]
        }
        return Set(sessionIDs)
    }

    private func selectTabFromTabBar(_ tabID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else {
            selectTab(tabID, in: presentation)
            return
        }
        let tree = currentSplitTree(presentation: presentation)
        if let existingItem = tree.item(forTabID: tabID) {
            activePaneIDs[scope] = existingItem.id
            selectTab(tabID, in: presentation)
            return
        }
        // A Session outside the split is a visit, not an exit. The stored
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
    /// showing on its own — it takes a pane of its own first, beside the pane
    /// the user was last working in, so the new Session lands next to the one
    /// that asked for it and every Session already in the layout keeps its
    /// place. The alternative, splitting whatever pane the layout happened to
    /// mark active, put the new Session next to a Session the user was not
    /// looking at, and left the Session they were looking at out of the split
    /// entirely.
    private func handleSplit(axis: SplitAxis, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let openedTab = navigation.selectedTabID.flatMap { id in
            presentation.tabs.first { $0.id == id }
        }
        let layout = scopeSplitTree(presentation: presentation)
        let activePaneID = currentActivePaneID(presentation: presentation, tree: layout)
        // A Session the layout does not hold yet needs a pane before the one
        // this request creates can sit beside it.
        let adoptsOpenedSession = openedTab.map { tab in
            tab.sessionID != nil && !layout.contains(tabID: tab.id)
        } ?? false
        guard layout.count + (adoptsOpenedSession ? 2 : 1) <= SplitLayoutTree.maxPanes else {
            return
        }
        let isCreating = presentation.workspace.map {
            creatingSessionWorkspaceIDs.contains($0.id)
        } ?? presentation.terminalGroup.map {
            creatingSessionTerminalGroupIDs.contains($0.id)
        } ?? false
        guard !isCreating, pendingSplits[scope] == nil else { return }

        var tree = layout
        if adoptsOpenedSession, let openedTab {
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
            guard tree.contains(tabID: openedTab.id) else { return }
            setSplitTree(tree, for: scope)
        }

        let targetPaneID = openedTab.flatMap { tree.item(forTabID: $0.id)?.id }
            ?? activePaneID
        guard let targetItem = tree.item(for: targetPaneID),
              let targetTab = presentation.tabs.first(where: { $0.id == targetItem.tabID }),
              targetTab.sessionID != nil else { return }
        activePaneIDs[scope] = targetPaneID

        pendingSplits[scope] = PendingSplit(
            targetPaneID: targetPaneID,
            targetTabID: targetTab.id,
            existingTabIDs: Set(presentation.tabs.map(\.id)),
            axis: axis
        )
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id))
        } else if let terminalGroup = presentation.terminalGroup {
            dispatch(.requestNewTerminalGroupSession(terminalGroup.id))
        } else {
            pendingSplits.removeValue(forKey: scope)
            return
        }

        // Creation is asynchronous and the roster may be delayed. Keep the
        // captured target alive only for a bounded interval; a failed request
        // must not make all future split commands inert.
        let captured = pendingSplits[scope]
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard self.pendingSplits[scope] == captured else { return }
            self.pendingSplits.removeValue(forKey: scope)
        }
        reconcilePendingSplitsOnTick()
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
                  ?? presentation.terminalGroup.map { projection.terminalGroupID(forTabID: droppedTabID) == $0.id }
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
            let newTree = tree.split(
                targetPaneID: targetPaneID,
                newTabID: newTab.id,
                axis: pending.axis,
                placeAfter: true
            )
            guard newTree.count == tree.count + 1 else {
                pendingSplits.removeValue(forKey: scope)
                continue
            }
            setSplitTree(newTree, for: scope)
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

    /// The display mode, read from the same preference the sidebar reads so the
    /// two surfaces cannot disagree about who owns the Session list.
    private var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode {
        WarrenDesktopWorkspaceDisplayMode(rawValue: workspaceDisplayModeRawValue) ?? .compact
    }

    /// The identity the top chrome row shows in place of a pane track.
    ///
    /// Asked only when the pane bar presentation has already decided no track
    /// will be drawn, so `entries` is that same resolution and the two can never
    /// both render.
    private func soloPaneIdentity(
        entries: [ClientTab],
        presentation: Presentation,
        tabTitles: [String: String],
        tabActivities: [TerminalSessionID: AgentActivityState]
    ) -> WarrenDesktopSoloPaneIdentity.Model? {
        guard let tab = entries.first ?? presentation.tab, tab.sessionID != nil else { return nil }
        let session = tab.sessionID.flatMap { projection.session(id: $0) }
        return WarrenDesktopSoloPaneIdentity.Model(
            tabID: tab.id,
            title: tabTitles[tab.id] ?? tab.title,
            fullTitle: soloPaneFullTitle(presentation: presentation, tab: tab, session: session),
            providerPresetID: session.flatMap { session in
                WarrenDesktopSessionPreset.builtIns
                    .first { $0.request.kind == session.presentedKind }?.id
            },
            activity: tab.sessionID.flatMap { tabActivities[$0] },
            canClose: true
        )
    }

    private func copySoloPaneTitle(presentation: Presentation) {
        guard let tab = presentation.tab else { return }
        let session = tab.sessionID.flatMap { projection.session(id: $0) }
        let title = soloPaneFullTitle(presentation: presentation, tab: tab, session: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
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
            ?? presentation.terminalGroup?.home
            ?? ""
        // The generated default name repeats the kind the icon already shows,
        // so it only stands in when the directory and command are both empty.
        let generatedTitle = session?.title ?? tab.title
        return TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate)
            .render(TerminalDisplayTitleContext(
                session: customTitle ?? ((directory.isEmpty && command.isEmpty) ? generatedTitle : ""),
                command: command,
                directory: directory,
                workspace: workspace?.name ?? presentation.terminalGroup?.name ?? "",
                branch: workspace?.branch ?? "",
                host: projection.host.name,
                user: NSUserName(),
                os: ProcessInfo.processInfo.operatingSystemVersionString
            ))
    }

    private func presentCommandPalette() {
        // Release the terminal's AppKit first responder before the overlay
        // mounts so the palette TextField receives the next keystroke.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setCommandPalettePresented(true)
    }

    private func setSettingsPresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            settingsPresented = presented
        }
    }

    private func setChromePopover(_ popover: WarrenDesktopChromePopover?) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            chromePopover = popover
        }
    }

    private func refreshWebDismissal() {
        guard isWebChromePopover else { return }
        webDismissalNonce += 1
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

    private func presentTerminalGroupCreate() {
        terminalGroupName = ""
        terminalGroupHome = ""
        pendingTerminalGroupEditorEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = .create
        }
    }

    private func presentTerminalGroupEdit(_ group: TerminalGroup) {
        terminalGroupName = group.name
        terminalGroupHome = group.home ?? ""
        pendingTerminalGroupEditorEndpointID = selectedEndpointID
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = .edit(group.id)
        }
    }

    private func dismissTerminalGroupEditor() {
        pendingTerminalGroupEditorEndpointID = nil
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = nil
        }
    }

    private func confirmTerminalGroupEditor() {
        guard let pendingTerminalGroupEditor else { return }
        guard pendingTerminalGroupEditorEndpointID == selectedEndpointID else {
            dismissTerminalGroupEditor()
            return
        }
        let name = terminalGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let home = normalizedTerminalGroupHome(terminalGroupHome)
        switch pendingTerminalGroupEditor {
        case .create:
            dispatch(.createTerminalGroup(name, home: home))
        case .edit(let groupID):
            dispatch(.renameTerminalGroup(groupID, name))
            dispatch(.setTerminalGroupHome(groupID, home))
        }
        dismissTerminalGroupEditor()
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
            WarrenModalSurface {
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
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(WarrenPresentationLayer.modal)
        }
    }

    private func normalizedTerminalGroupHome(_ home: String) -> String? {
        let value = home.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @ViewBuilder
    private var terminalGroupEditorDialog: some View {
        if let pendingTerminalGroupEditor {
            WarrenModalSurface {
                WarrenDesktopTerminalGroupEditor(
                    title: pendingTerminalGroupEditor.title,
                    name: $terminalGroupName,
                    home: $terminalGroupHome,
                    onCancel: dismissTerminalGroupEditor,
                    onConfirm: confirmTerminalGroupEditor
                )
            }
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
        case .terminalGroup(let group, _):
            guard projection.terminalGroup(id: group.id) != nil else {
                return (false, "This terminal group is no longer available.")
            }
        }
        return (true, nil)
    }

    @ViewBuilder
    private var deletionDialog: some View {
        if let pendingDeletion {
            let validation = deletionValidation(for: pendingDeletion)
            WarrenModalSurface {
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
                case .terminalGroup(let group, let sessionCount):
                    WarrenDesktopDeleteTerminalGroupConfirmation(
                        group: group,
                        sessionCount: sessionCount,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteTerminalGroup(group.id))
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
    }

    private static func restoredSidebarTree(scope: String) -> WarrenDesktopSidebarTreeState {
        WarrenDesktopSidebarTreePersistence.restore(scope: scope)
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

private enum WarrenDesktopWebDismissal {
    static let interval: Duration = .seconds(3)
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
