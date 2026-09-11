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
    public let onActiveScreenSessionsChanged: (Set<TerminalSessionID>) -> Void

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
    private let onLoadUsage: ((Int) -> Void)?
    private let onRebuildUsage: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    private let embeddedEditorAvailable: Bool
    private let editorSurface: @MainActor (Workspace) -> AnyView
    private let persistenceEnabled: Bool
    private let externalIDEService = WarrenDesktopExternalIDEService.live
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var sidebarTree: WarrenDesktopSidebarTreeState
    @State private var commandPalettePresented = false
    @State private var activeSessionsPresented = false
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
    @State private var workspaceContentModes: [WorkspaceID: WarrenDesktopWorkspaceContentMode]
    @State private var splitTrees: [String: SplitLayoutTree]
    @State private var activePaneIDs: [String: String]
    @State private var pendingSplits: [String: PendingSplit]
    @State private var pendingPaneClosures: [String: PendingPaneClosure]
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let existingTabIDs: Set<String>
        let axis: SplitAxis
    }

    private struct PendingPaneClosure: Equatable {
        let paneID: String
        let tabID: String
        let replacementPaneID: String?
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
        onActiveScreenSessionsChanged: @escaping (Set<TerminalSessionID>) -> Void = { _ in },
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
        onLoadUsage: ((Int) -> Void)? = nil,
        onRebuildUsage: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        embeddedEditorAvailable: Bool = false,
        editorSurface: @escaping @MainActor (Workspace) -> AnyView = { _ in AnyView(EmptyView()) },
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
        self.onActiveScreenSessionsChanged = onActiveScreenSessionsChanged
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
        self.editorSurface = editorSurface
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
        _workspaceContentModes = State(
            initialValue: persistenceEnabled
                ? WarrenDesktopWorkspaceContentModePersistence.restore(
                    scope: selectedEndpointID
                )
                : [:]
        )
        _splitTrees = State(
            initialValue: persistenceEnabled
                ? WarrenDesktopSplitLayoutPersistence.restore()
                : [:]
        )
        _activePaneIDs = State(initialValue: [:])
        _pendingSplits = State(initialValue: [:])
        _pendingPaneClosures = State(initialValue: [:])
    }

    public var body: some View {
        let presentation = makePresentation()
        let currentTree = currentSplitTree(presentation: presentation)
        let currentPaneID = currentActivePaneID(presentation: presentation, tree: currentTree)
        let contentMode = workspaceContentMode(for: presentation.workspace)
        let activeVisibleSessions = contentMode == .terminal
            ? visibleScreenSessionIDs(for: presentation, in: currentTree)
            : []
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
            contentMode: contentMode,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            isAddingSession: isAddingSession,
            sessionMoveTargets: sessionMoveTargets,
            sessionMoveDestinations: sessionMoveDestinations,
            externalIDEOptions: externalIDEOptions,
            embeddedEditorChromeAvailable: embeddedEditorChromeAvailable,
            currentTree: currentTree
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
            onRetrySidebarHost: onRetrySidebarHost
        )
        .frame(width: sidebarState.renderedWidth)
        let workspaceColumn = makeWorkspaceColumn(
            presentation: presentation,
            tabBarView: tabBarView,
            contentMode: contentMode,
            isAddingSession: isAddingSession,
            currentTree: currentTree,
            currentPaneID: currentPaneID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                sidebarView
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
            minWidth: WarrenLayoutMetrics.sidebarExpandedWidth
                + currentTree.windowMinimumPaneWidth,
            minHeight: (chromeMode.showsIndependentTopBar ? WarrenLayoutMetrics.topBarHeight : 0)
                + WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + currentTree.windowMinimumPaneHeight
        )
        .denSurface()
        .warrenUnixTextEditing()
        .onChange(of: sidebarState) { newState in
            if persistenceEnabled { Self.persist(newState) }
        }
        .onChange(of: sidebarTree) { newState in
            if persistenceEnabled { Self.persist(newState, scope: selectedEndpointID) }
        }
        .onChange(of: workspaceContentModes) { newModes in
            guard persistenceEnabled else { return }
            WarrenDesktopWorkspaceContentModePersistence.save(
                newModes,
                scope: selectedEndpointID,
                validWorkspaceIDs: Set(projection.groups.flatMap(\.workspaces).map(\.id))
            )
        }
        .onChange(of: selectedEndpointID) { newEndpointID in
            sidebarTree = persistenceEnabled
                ? Self.restoredSidebarTree(scope: newEndpointID)
                : WarrenDesktopSidebarTreeState()
            workspaceContentModes = persistenceEnabled
                ? WarrenDesktopWorkspaceContentModePersistence.restore(
                    scope: newEndpointID
                )
                : [:]
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
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.activeSessions)) { _ in
            presentActiveSessions()
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
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closeTab)) { _ in
            handleCloseTab(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.openSettings)) { note in
            guard let request = note.object as? WarrenDesktopSettingsDeepLink else { return }
            openSettings(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.openEmbeddedEditor)) { note in
            let targetWorkspace = (note.object as? WorkspaceID).flatMap { id in
                projection.groups.flatMap(\.workspaces).first { $0.id == id }
            } ?? presentation.workspace
            if let targetWorkspace, presentation.workspace?.id != targetWorkspace.id {
                actions(.selectWorkspace(targetWorkspace.id))
            }
            setWorkspaceContentMode(.editor, for: targetWorkspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.splitBelow)) { _ in
            handleSplitBelow(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.splitRight)) { _ in
            handleSplitRight(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closePane)) { _ in
            handleClosePane(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.maximizePane)) { _ in
            handleMaximizePane(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.otherPane)) { _ in
            handleOtherPane(in: presentation)
        }
        .onChange(of: activeVisibleSessions) { sessions in
            onActiveScreenSessionsChanged(sessions)
        }
        .onChange(of: splitTrees) { newTrees in
            // A divider drag rewrites the ratio on every pointer event.
            // Coalesce those writes so dragging does not run a JSON encode
            // plus a UserDefaults write per frame.
            if persistenceEnabled {
                WarrenDesktopSplitLayoutPersistence.scheduleSave(newTrees)
            }
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
            onActiveScreenSessionsChanged(activeVisibleSessions)
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
                        Color.black.opacity(0.5)
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
            activeSessionsOverlay
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
                Text("C-x-")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.85))
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
                            onOpenEmbeddedEditor: {
                                setWorkspaceContentMode(
                                    .editor,
                                    for: presentation.workspace
                                )
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

    @ViewBuilder
    private var activeSessionsOverlay: some View {
        if activeSessionsPresented && !settingsPresented && !commandPalettePresented {
            GeometryReader { proxy in
                let panelWidth = min(
                    WarrenLayoutMetrics.activeSessionsPopoverWidth,
                    max(0, proxy.size.width - WarrenSpacing.standard * 2)
                )
                let resultsMaxHeight = min(
                    WarrenLayoutMetrics.activeSessionsPopoverResultsMaxHeight,
                    max(0, proxy.size.height - WarrenSpacing.large * 2)
                )
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { setActiveSessionsPresented(false) }

                    WarrenDesktopActiveSessionsPopover(
                        projection: projection,
                        onAction: { action in
                            dispatch(action)
                            setActiveSessionsPresented(false)
                        },
                        onDismiss: { setActiveSessionsPresented(false) },
                        width: panelWidth,
                        resultsMaxHeight: resultsMaxHeight
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
            .zIndex(WarrenPresentationLayer.commandSurface)
        }
    }

    /// Resolve all selection-dependent UI values once per body evaluation.
    /// SwiftUI asks for these values in several branches and closures; keeping
    /// one immutable presentation value avoids repeated graph lookups while
    /// preserving the navigation ownership rules.
    private func makeTabBarView(
        presentation: Presentation,
        contentMode: WarrenDesktopWorkspaceContentMode,
        tabTitles: [String: String],
        tabActivities: [TerminalSessionID: AgentActivityState],
        pinnedSessionIDs: Set<TerminalSessionID>,
        isAddingSession: Bool,
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool,
        currentTree: SplitLayoutTree
    ) -> AnyView {
        AnyView(WarrenDesktopTabBar(
            tabs: presentation.tabs,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            selectedTabID: navigation.selectedTabID,
            splitTabIDs: Set(currentTree.allTabIDs),
            chromeMode: chromeMode,
            isSidebarCollapsed: sidebarState.isCollapsed,
            connectionState: projection.connectionState,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            webStatus: webStatus,
            externalIDEOptions: externalIDEOptions,
            embeddedEditorAvailable: embeddedEditorChromeAvailable
                && presentation.workspace != nil,
            embeddedEditorTabVisible: hasEmbeddedEditorTab(for: presentation.workspace),
            embeddedEditorSelected: contentMode == .editor,
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
                setWorkspaceContentMode(.editor, for: presentation.workspace)
            },
            onCloseEmbeddedEditor: {
                closeEmbeddedEditor(for: presentation.workspace)
            },
            onSelectEndpoint: onSelectEndpoint,
            onRetryConnection: onRetryConnection,
            onStopConnection: onStopConnection,
            onSelectTab: { selectTabFromTabBar($0, in: presentation) },
            onMoveTab: { tabID, destinationTabID in
                dispatch(.moveTab(tabID, before: destinationTabID))
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
            onCloseTab: { dispatch(.closeTab($0)) },
            onCloseOtherTabs: { dispatch(.closeOtherTabs($0)) },
            onCloseAllTabs: { dispatch(.closeAllTabs) },
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
        contentMode: WarrenDesktopWorkspaceContentMode,
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
                if contentMode == .terminal {
                    WarrenDesktopPresetBar(
                        workspace: presentation.workspace,
                        terminalGroup: presentation.terminalGroup,
                        isBusy: isAddingSession,
                        onLaunch: { request in
                            launchSession(request, in: presentation)
                        }
                    )
                }
                ZStack {
                    WarrenDesktopWorkspaceContent(
                        workspace: presentation.contentWorkspace,
                        terminalGroup: presentation.contentTerminalGroup,
                        tab: presentation.tab,
                        hasProjects: !projection.groups.isEmpty,
                        connectionState: projection.connectionState,
                        isMigratingRuntimeSessions: isMigratingRuntimeSessions,
                        endpointCapabilities: endpointCapabilities,
                        // Superset keeps the 28pt pane toolbar in workspace
                        // mode too. It is pane chrome, not a duplicate top bar.
                        showsPaneHeader: true,
                        session: presentation.session,
                        hostName: projection.host.name,
                        titleTemplate: TerminalDisplayTitleTemplate(rawValue: terminalTitleTemplate),
                        terminalFont: TerminalFontPreference(
                            family: terminalFontFamily,
                            size: terminalFontSize
                        ),
                        wantsTerminalFocus: contentMode == .terminal
                            && !commandPalettePresented
                            && !activeSessionsPresented
                            && !settingsPresented,
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
                        onSplitDrop: { targetPaneID, droppedTabID, target in
                            handleSplitDrop(targetPaneID: targetPaneID, droppedTabID: droppedTabID, target: target, in: presentation)
                        },
                        onResizeSplit: { splitPath, ratio in
                            handleResizeSplit(splitPath: splitPath, ratio: ratio, in: presentation)
                        },
                        onAddProject: { dispatch(.addProject) },
                        onImportSuperset: { dispatch(.importSuperset) },
                        terminalSurface: terminalSurface
                    )
                    .opacity(contentMode == .terminal ? 1 : 0)
                    .allowsHitTesting(contentMode == .terminal)
                    .accessibilityHidden(contentMode != .terminal)

                    if let workspace = presentation.workspace,
                       workspaceContentModes[workspace.id] != nil,
                       embeddedEditorAvailable {
                        WarrenDesktopEmbeddedEditorPane(
                            workspace: workspace,
                            surface: editorSurface(workspace)
                        )
                        .opacity(contentMode == .editor ? 1 : 0)
                        .allowsHitTesting(contentMode == .editor)
                        .accessibilityHidden(contentMode != .editor)
                    }
                }
            }
        )
    }

    private func workspaceContentMode(
        for workspace: Workspace?
    ) -> WarrenDesktopWorkspaceContentMode {
        guard embeddedEditorAvailable,
              let workspace else {
            return .terminal
        }
        return workspaceContentModes[workspace.id] ?? .terminal
    }

    private func setWorkspaceContentMode(
        _ mode: WarrenDesktopWorkspaceContentMode,
        for workspace: Workspace?
    ) {
        guard embeddedEditorAvailable, let workspace else { return }
        guard workspaceContentMode(for: workspace) != mode else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        workspaceContentModes[workspace.id] = mode
    }

    private func hasEmbeddedEditorTab(for workspace: Workspace?) -> Bool {
        guard embeddedEditorAvailable, let workspace else { return false }
        return workspaceContentModes[workspace.id] != nil
    }

    private func closeEmbeddedEditor(for workspace: Workspace?) {
        guard embeddedEditorAvailable,
              let workspace,
              workspaceContentModes[workspace.id] != nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        workspaceContentModes.removeValue(forKey: workspace.id)
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
        setActiveSessionsPresented(false)
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
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorChromeAvailable: Bool
    ) -> String? {
        switch control {
        case .externalIDE:
            if embeddedEditorChromeAvailable, embeddedEditorDefaultIDE {
                return "Embedded editor default"
            }
            if embeddedEditorChromeAvailable {
                return "Choose an IDE"
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
                    onOpenEmbeddedEditor: {
                        setWorkspaceContentMode(
                            .editor,
                            for: presentation.workspace
                        )
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
            if embeddedEditorChromeAvailable, embeddedEditorDefaultIDE {
                setWorkspaceContentMode(.editor, for: presentation.workspace)
                setChromePopover(nil)
                return
            }
            guard externalIDEOptions != nil else { return }
            setChromePopover(.externalIDE)
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

    private func setActiveSessionsPresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            activeSessionsPresented = presented
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
        setWorkspaceContentMode(.terminal, for: presentation.workspace)
        addSession(in: presentation)
    }

    private func handleTabMove(forward: Bool, in presentation: Presentation) {
        if hasEmbeddedEditorTab(for: presentation.workspace) {
            let mode = workspaceContentMode(for: presentation.workspace)
            if mode == .editor {
                guard let tabID = forward
                    ? presentation.tabs.first?.id
                    : presentation.tabs.last?.id else { return }
                selectTab(tabID, in: presentation)
                return
            }
            if let selectedTabID = navigation.selectedTabID,
               let selectedIndex = presentation.tabs.firstIndex(where: {
                   $0.id == selectedTabID
               }) {
                let isBoundary = forward
                    ? selectedIndex == presentation.tabs.indices.last
                    : selectedIndex == presentation.tabs.indices.first
                if isBoundary {
                    setWorkspaceContentMode(.editor, for: presentation.workspace)
                    return
                }
            }
        }
        guard let tabID = WarrenDesktopTabCycler.tabID(
            forward: forward,
            in: presentation.tabs,
            selectedTabID: navigation.selectedTabID
        ) else { return }
        dispatch(.selectTab(tabID))
    }

    private func handleSelectTab(
        _ note: Notification,
        in presentation: Presentation
    ) {
        let rawIndex = note.userInfo?[WarrenDesktopCommand.selectTabIndexKey]
        guard let index = tabIndex(from: rawIndex),
              let selection = WarrenDesktopTabSelector.selection(
                in: presentation.tabs,
                includesEditor: hasEmbeddedEditorTab(for: presentation.workspace),
                number: index
              ) else { return }
        switch selection {
        case .tab(let tabID):
            selectTab(tabID, in: presentation)
        case .editor:
            setWorkspaceContentMode(.editor, for: presentation.workspace)
        }
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

    private func currentSplitTree(presentation: Presentation) -> SplitLayoutTree {
        guard let scope = currentScopeKey(presentation: presentation) else {
            let defaultTabID = presentation.tab?.id ?? "default"
            return .leaf(
                SplitPaneItem(
                    id: SplitPaneItem.fallbackID(forTabID: defaultTabID),
                    tabID: defaultTabID
                )
            )
        }
        let validTabIDs = Set(presentation.tabs.map(\.id))
        let fallbackTabID = presentation.tab?.id ?? presentation.tabs.first?.id
        if let existing = splitTrees[scope] {
            if let reconciled = existing.reconcile(validTabIDs: validTabIDs, fallbackTabID: fallbackTabID) {
                return treeAlignedWithSelection(
                    reconciled,
                    validTabIDs: validTabIDs,
                    scope: scope
                )
            }
        }
        let tabID = presentation.tab?.id ?? fallbackTabID ?? "empty"
        return .leaf(
            SplitPaneItem(
                id: SplitPaneItem.fallbackID(forTabID: tabID),
                tabID: tabID
            )
        )
    }

    private func currentActivePaneID(presentation: Presentation, tree: SplitLayoutTree) -> String {
        guard let scope = currentScopeKey(presentation: presentation) else {
            return tree.allPaneIDs.first ?? "pane-default"
        }
        // Navigation changes can select the successor tab synchronously when
        // a pane is closing, before the Host roster removes the old leaf.
        // Prefer the selected tab whenever it is already represented so the
        // control/focus intent follows that pane instead of briefly targeting
        // the session that is being deleted.
        if let selectedTabID = navigation.selectedTabID,
           let item = tree.item(forTabID: selectedTabID) {
            return item.id
        }
        if let existingID = activePaneIDs[scope], tree.contains(paneID: existingID) {
            return existingID
        }
        return tree.allPaneIDs.first ?? "pane-default"
    }

    private func setSplitTree(_ tree: SplitLayoutTree, for scope: String) {
        splitTrees[scope] = tree
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
        let fallbackTabID = presentation.tab?.id ?? presentation.tabs.first?.id
        guard let reconciled = existing.reconcile(
            validTabIDs: validTabIDs,
            fallbackTabID: fallbackTabID
        ) else {
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
            return
        }
        let canonical = treeAlignedWithSelection(
            reconciled,
            validTabIDs: validTabIDs,
            scope: scope
        )
        if splitTrees[scope] != canonical {
            splitTrees[scope] = canonical
        }
        if let activePaneID = activePaneIDs[scope], !canonical.contains(paneID: activePaneID) {
            activePaneIDs[scope] = canonical.item(forTabID: navigation.selectedTabID ?? "")?.id
                ?? canonical.allPaneIDs.first
        }
        pruneSplitTreesForDeletedScopes()
    }

    /// Layouts are keyed by endpoint and scope, so a deleted Workspace or
    /// Terminal Group would otherwise keep its tree in UserDefaults forever.
    /// Only the current endpoint's scopes are evaluated: another endpoint's
    /// Workspaces are absent from this projection and are not deleted.
    private func pruneSplitTreesForDeletedScopes() {
        var liveScopeKeys: Set<String> = []
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        for workspace in projection.groups.flatMap(\.workspaces) {
            liveScopeKeys.insert(endpointScope + "workspace-\(workspace.id.rawValue.uuidString)")
        }
        for terminalGroup in projection.terminalGroups {
            liveScopeKeys.insert(endpointScope + "terminalGroup-\(terminalGroup.id.rawValue.uuidString)")
        }
        let pruned = WarrenDesktopSplitLayoutPersistence.pruned(
            splitTrees,
            endpointID: selectedEndpointID,
            liveScopeKeys: liveScopeKeys
        )
        guard pruned.count != splitTrees.count else { return }
        let removed = Set(splitTrees.keys).subtracting(pruned.keys)
        splitTrees = pruned
        for scope in removed {
            activePaneIDs.removeValue(forKey: scope)
            pendingSplits.removeValue(forKey: scope)
            pendingPaneClosures.removeValue(forKey: scope)
        }
    }

    /// A window-level split is tied to the current tab selection. If an
    /// external selection points at a tab that is not in the restored tree,
    /// render that tab as the sole pane until the persisted state catches up.
    /// The pending split exception is important: creation selects its new tab
    /// before the roster callback can insert it into the captured tree.
    private func treeAlignedWithSelection(
        _ tree: SplitLayoutTree,
        validTabIDs: Set<String>,
        scope: String
    ) -> SplitLayoutTree {
        guard pendingSplits[scope] == nil,
              let selectedTabID = navigation.selectedTabID,
              validTabIDs.contains(selectedTabID),
              !tree.contains(tabID: selectedTabID) else {
            return tree
        }
        return .leaf(
            SplitPaneItem(
                id: SplitPaneItem.fallbackID(forTabID: selectedTabID),
                tabID: selectedTabID
            )
        )
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
        // A split window is a coherent placement, not a bag of slots.
        // Selecting an unrelated tab exits that split window instead of
        // silently replacing one leaf and leaving the other sessions visible
        // under the wrong tab selection.
        let nextTree = SplitLayoutTree.leaf(
            SplitPaneItem(
                id: SplitPaneItem.fallbackID(forTabID: tabID),
                tabID: tabID
            )
        )
        setSplitTree(nextTree, for: scope)
        activePaneIDs[scope] = nextTree.allPaneIDs.first
        selectTab(tabID, in: presentation)
    }

    private func handleSelectPane(_ paneID: String, in presentation: Presentation, tree: SplitLayoutTree) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
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

    private func handleSplit(axis: SplitAxis, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.count < SplitLayoutTree.maxPanes else { return }
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        let isCreating = presentation.workspace.map {
            creatingSessionWorkspaceIDs.contains($0.id)
        } ?? presentation.terminalGroup.map {
            creatingSessionTerminalGroupIDs.contains($0.id)
        } ?? false
        guard !isCreating else { return }
        guard let activeItem = tree.item(for: activePaneID),
              let activeTab = presentation.tabs.first(where: { $0.id == activeItem.tabID }),
              activeTab.sessionID != nil,
              pendingSplits[scope] == nil,
              pendingPaneClosures[scope] == nil else { return }

        pendingSplits[scope] = PendingSplit(
            targetPaneID: activePaneID,
            existingTabIDs: Set(tree.allTabIDs),
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
    }

    private func handleClosePane(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: tree)
        if tree.count > 1 {
            guard pendingPaneClosures[scope] == nil,
                  let item = tree.item(for: targetPaneID) else { return }
            pendingPaneClosures[scope] = PendingPaneClosure(
                paneID: targetPaneID,
                tabID: item.tabID,
                replacementPaneID: tree.nextPaneID(after: targetPaneID)
            )
            if let tab = presentation.tabs.first(where: { $0.id == item.tabID }),
               tab.sessionID != nil {
                // The Host owns Session termination. Keep the leaf mounted
                // until the roster confirms deletion so a failed delete does
                // not leave a hidden running process or a misleading layout.
                dispatch(.closeTab(item.tabID))
                let captured = pendingPaneClosures[scope]
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    guard self.pendingPaneClosures[scope] == captured else { return }
                    self.pendingPaneClosures.removeValue(forKey: scope)
                }
            } else {
                reconcilePendingSplitMutations()
            }
        } else {
            handleCloseTab(in: presentation)
        }
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

    private func handleSplitDrop(
        targetPaneID: String,
        droppedTabID: String,
        target: SplitDropTarget,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.contains(paneID: targetPaneID),
              let droppedTab = presentation.tabs.first(where: { $0.id == droppedTabID }),
              droppedTab.sessionID != nil,
              projection.tabs.contains(where: { $0.id == droppedTabID }),
              (presentation.workspace.map { projection.workspaceID(forTabID: droppedTabID) == $0.id }
                  ?? presentation.terminalGroup.map { projection.terminalGroupID(forTabID: droppedTabID) == $0.id }
                  ?? false),
              pendingSplits[scope] == nil,
              pendingPaneClosures[scope] == nil else { return }
        if tree.contains(tabID: droppedTabID), tree.item(for: targetPaneID)?.tabID != droppedTabID {
            // Moving a tab between existing panes needs an explicit reorder
            // operation. Rejecting it here prevents duplicate Session IDs.
            return
        }
        let newTree: SplitLayoutTree
        switch target {
        case .top:
            newTree = tree.split(targetPaneID: targetPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: false)
        case .bottom:
            newTree = tree.split(targetPaneID: targetPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: true)
        case .left:
            newTree = tree.split(targetPaneID: targetPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: false)
        case .right:
            newTree = tree.split(targetPaneID: targetPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: true)
        case .center:
            newTree = tree.replace(paneID: targetPaneID, withTabID: droppedTabID)
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
            let tree = currentSplitTree(presentation: presentation)
            guard tree.contains(paneID: pending.targetPaneID) else {
                pendingSplits.removeValue(forKey: scope)
                continue
            }
            guard let newTab = presentation.tabs.first(where: {
                !pending.existingTabIDs.contains($0.id)
                    && $0.sessionID != nil
                    && $0.id == navigation.selectedTabID
            }) else {
                // Creation clears its spinner before publishing the selected
                // Tab. Keep the pending intent through that brief ordering
                // window; a failed request is released by the timeout below.
                continue
            }
            let newTree = tree.split(
                targetPaneID: pending.targetPaneID,
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

        for (scope, pending) in Array(pendingPaneClosures) {
            guard currentScopeKey(presentation: presentation) == scope else { continue }
            guard !presentation.tabs.contains(where: { $0.id == pending.tabID }) else { continue }
            let tree = currentSplitTree(presentation: presentation)
            guard let newTree = tree.remove(paneID: pending.paneID) else {
                pendingPaneClosures.removeValue(forKey: scope)
                continue
            }
            setSplitTree(newTree, for: scope)
            let nextPaneID = pending.replacementPaneID.flatMap { replacement in
                newTree.contains(paneID: replacement) ? replacement : nil
            } ?? newTree.allPaneIDs.first
            activePaneIDs[scope] = nextPaneID
            if let nextPaneID, let item = newTree.item(for: nextPaneID) {
                selectTab(item.tabID, in: presentation)
            }
            pendingPaneClosures.removeValue(forKey: scope)
        }
    }

    private func handleResizeSplit(splitPath: [Bool], ratio: Double, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let newTree = tree.updateRatio(path: splitPath, ratio: ratio)
        setSplitTree(newTree, for: scope)
    }

    private func selectTab(_ tabID: String, in presentation: Presentation) {
        setWorkspaceContentMode(.terminal, for: presentation.workspace)
        dispatch(.selectTab(tabID))
    }

    private func handleCloseTab(in presentation: Presentation) {
        if workspaceContentMode(for: presentation.workspace) == .editor {
            closeEmbeddedEditor(for: presentation.workspace)
            return
        }
        guard let tab = presentation.tab, tab.sessionID != nil else { return }
        dispatch(.closeTab(tab.id))
    }

    private func presentCommandPalette() {
        // Release the terminal's AppKit first responder before the overlay
        // mounts so the palette TextField receives the next keystroke.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setActiveSessionsPresented(false)
        setCommandPalettePresented(true)
    }

    private func presentActiveSessions() {
        guard !settingsPresented else { return }
        // The search field owns the next keystroke; do not leave the terminal
        // AppKit responder attached while the switcher is being mounted.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setCommandPalettePresented(false)
        setChromePopover(nil)
        setActiveSessionsPresented(true)
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
enum WarrenDesktopTabSelector {
    enum Selection: Equatable {
        case tab(String)
        case editor
    }

    static func selection(
        in tabs: [ClientTab],
        includesEditor: Bool,
        number: Int
    ) -> Selection? {
        if let tabID = tabID(in: tabs, number: number) {
            return .tab(tabID)
        }
        guard includesEditor, number == tabs.count + 1 else { return nil }
        return .editor
    }

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
