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
    public let creatingSessionWorkspaceIDs: Set<WorkspaceID>
    public let creatingSessionTerminalGroupIDs: Set<TerminalGroupID>
    public let deletingProjectIDs: Set<ProjectID>
    public let deletingWorkspaceIDs: Set<WorkspaceID>
    public let notices: [WarrenDesktopNotice]
    public let onNoticeAdd: (String, String, String?, WarrenDesktopNotice.Kind) -> Void
    public let onNoticeRead: (WarrenDesktopNotice.ID) -> Void
    public let onNoticeDismiss: (WarrenDesktopNotice.ID) -> Void
    public let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]

    private let endpointOptions: [WarrenDesktopEndpointOption]
    private let selectedEndpointID: String
    private let onSelectEndpoint: (String) -> Void

    private let actions: WarrenDesktopActions
    private let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    private let onWebStart: () -> Void
    private let onWebTest: ((String, String, String, String) -> Void)?
    private let onWebStop: () -> Void
    private let onWebOpenURL: (URL) -> Void
    private let onWebCopyURL: (URL) -> Void
    private let defaultRuntime: String?
    private let onSetRuntime: (String) -> Void
    private let autoOpenShell: Bool
    private let onSetAutoOpenShell: (Bool) -> Void
    private let autoStartAI: Bool
    private let onSetAutoStartAI: (Bool) -> Void
    private let persistenceEnabled: Bool
    private let externalIDEService = WarrenDesktopExternalIDEService.live
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var sidebarTree: WarrenDesktopSidebarTreeState
    @State private var commandPalettePresented = false
    @State private var settingsPresented = false
    @State private var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State private var chromePopover: WarrenDesktopChromePopover?
    @State private var webDismissalNonce = 0
    @State private var pendingRename: WarrenDesktopRenameRequest?
    @State private var renameValue = ""
    @State private var pendingTerminalGroupEditor: WarrenDesktopTerminalGroupEditorMode?
    @State private var terminalGroupName = ""
    @State private var terminalGroupHome = ""
    @State private var pendingDeletion: WarrenDesktopDeletionRequest?
    @State private var pendingDeletionEndpointID: String?
    @State private var deleteWorkspaceRemoveWorktree = false
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.noticeMuted)
    private var notificationsMuted = false
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

    public init(
        projection: WarrenDesktopProjection,
        navigation: WarrenDesktopNavigationState? = nil,
        chromeMode: WarrenDesktopChromeMode = .workspace,
        updateStatus: WarrenDesktopUpdateStatus = .none,
        onUpdateAction: @escaping () -> Void = {},
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        webStatus: WarrenDesktopWebStatus = .init(),
        creatingSessionWorkspaceIDs: Set<WorkspaceID> = [],
        creatingSessionTerminalGroupIDs: Set<TerminalGroupID> = [],
        deletingProjectIDs: Set<ProjectID> = [],
        deletingWorkspaceIDs: Set<WorkspaceID> = [],
        notices: [WarrenDesktopNotice] = [],
        onNoticeAdd: @escaping (String, String, String?, WarrenDesktopNotice.Kind) -> Void = { _, _, _, _ in },
        onNoticeRead: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        onNoticeDismiss: @escaping (WarrenDesktopNotice.ID) -> Void = { _ in },
        externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl] = WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
        endpointOptions: [WarrenDesktopEndpointOption] = [
            .init(id: "local", label: "Local", isLocal: true),
        ],
        selectedEndpointID: String = "local",
        onSelectEndpoint: @escaping (String) -> Void = { _ in },
        onWebStart: @escaping () -> Void = {},
        onWebTest: ((String, String, String, String) -> Void)? = nil,
        onWebStop: @escaping () -> Void = {},
        onWebOpenURL: @escaping (URL) -> Void = { _ in },
        onWebCopyURL: @escaping (URL) -> Void = { _ in },
        defaultRuntime: String? = nil,
        onSetRuntime: @escaping (String) -> Void = { _ in },
        autoOpenShell: Bool = false,
        onSetAutoOpenShell: @escaping (Bool) -> Void = { _ in },
        autoStartAI: Bool = false,
        onSetAutoStartAI: @escaping (Bool) -> Void = { _ in },
        persistenceEnabled: Bool = true,
        @ViewBuilder terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? WarrenDesktopNavigationReducer.initial(for: projection)
        self.chromeMode = chromeMode
        self.updateStatus = updateStatus
        self.onUpdateAction = onUpdateAction
        self.webStatus = webStatus
        self.creatingSessionWorkspaceIDs = creatingSessionWorkspaceIDs
        self.creatingSessionTerminalGroupIDs = creatingSessionTerminalGroupIDs
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.notices = notices
        self.onNoticeAdd = onNoticeAdd
        self.onNoticeRead = onNoticeRead
        self.onNoticeDismiss = onNoticeDismiss
        self.externallyVisibleControls = WarrenDesktopWorkspaceTabTrailingControl.normalizedExternalControls(
            externallyVisibleControls
        )
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.onSelectEndpoint = onSelectEndpoint
        self.actions = actions
        self.terminalSurface = terminalSurface
        self.onWebStart = onWebStart
        self.onWebTest = onWebTest
        self.onWebStop = onWebStop
        self.onWebOpenURL = onWebOpenURL
        self.onWebCopyURL = onWebCopyURL
        self.defaultRuntime = defaultRuntime
        self.onSetRuntime = onSetRuntime
        self.autoOpenShell = autoOpenShell
        self.onSetAutoOpenShell = onSetAutoOpenShell
        self.autoStartAI = autoStartAI
        self.onSetAutoStartAI = onSetAutoStartAI
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
    }

    public var body: some View {
        let presentation = makePresentation()
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
        let tabBarView = makeTabBarView(
            presentation: presentation,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            isAddingSession: isAddingSession,
            sessionMoveTargets: sessionMoveTargets,
            sessionMoveDestinations: sessionMoveDestinations
        )
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                WarrenDesktopSidebar(
                    projection: projection,
                    sidebarState: $sidebarState,
                    sidebarTree: $sidebarTree,
                    selection: navigation.selection,
                    chromeMode: chromeMode,
                    updateStatus: updateStatus,
                    onUpdateAction: onUpdateAction,
                    deletingProjectIDs: deletingProjectIDs,
                    deletingWorkspaceIDs: deletingWorkspaceIDs,
                    onAction: dispatch,
                    onCommandPalette: presentCommandPalette,
                    onRequestRename: presentRename,
                    onRequestDeletion: presentDeletion,
                    onRequestTerminalGroupCreate: presentTerminalGroupCreate,
                    onRequestTerminalGroupEdit: presentTerminalGroupEdit
                )
                .frame(width: sidebarState.renderedWidth)

                makeWorkspaceColumn(
                    presentation: presentation,
                    tabBarView: tabBarView,
                    isAddingSession: isAddingSession
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                + WarrenLayoutMetrics.paneMinimumWidth,
            minHeight: (chromeMode.showsIndependentTopBar ? WarrenLayoutMetrics.topBarHeight : 0)
                + WarrenLayoutMetrics.tabBarHeight
                + WarrenLayoutMetrics.presetBarHeight
                + WarrenLayoutMetrics.paneHeaderHeight
                + WarrenLayoutMetrics.paneMinimumHeight
        )
        .denSurface()
        .warrenUnixTextEditing()
        .onChange(of: sidebarState) { _, newState in
            if persistenceEnabled { Self.persist(newState) }
        }
        .onChange(of: sidebarTree) { _, newState in
            if persistenceEnabled { Self.persist(newState, scope: selectedEndpointID) }
        }
        .onChange(of: selectedEndpointID) { _, newEndpointID in
            sidebarTree = persistenceEnabled
                ? Self.restoredSidebarTree(scope: newEndpointID)
                : WarrenDesktopSidebarTreeState()
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
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closeTab)) { _ in
            handleCloseTab(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .overlay {
            renameDialog
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
            chromePopoverLayer
        }
        .onChange(of: chromePopover) { _, popover in
            guard case .web? = popover else { return }
            refreshWebDismissal()
        }
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
    }

    private var selectedEndpointIsLocal: Bool {
        endpointOptions.first { $0.id == selectedEndpointID }?.isLocal == true
    }

    private var isWebChromePopover: Bool {
        chromePopover == .web
    }

    private var availableTrailingControls: [WarrenDesktopWorkspaceTabTrailingControl] {
        WarrenDesktopWorkspaceTabTrailingControl.available(
            externalIDEOptions: externalIDEOptions
        )
    }

    private var trailingControlLayout: (direct: [WarrenDesktopWorkspaceTabTrailingControl], overflow: [WarrenDesktopWorkspaceTabTrailingControl]) {
        WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: externallyVisibleControls,
            availableControls: availableTrailingControls
        )
    }

    private var externalIDEOptions: [WarrenDesktopExternalIDEOption]? {
        makePresentation().workspace.map { workspace in
            externalIDEService.options(
                for: workspace,
                isLocalEndpoint: selectedEndpointIsLocal
            )
        }
    }

    @ViewBuilder
    private var chromePopoverLayer: some View {
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
                        onStart: {
                            onWebStart()
                            refreshWebDismissal()
                        },
                        onOpenSettings: {
                            setChromePopover(nil)
                            openSettings()
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
                        onDismiss: { setChromePopover(nil) }
                    )
                case .externalIDE:
                    if let options = externalIDEOptions {
                        WarrenDesktopExternalIDEPopover(
                            options: options,
                            onOpen: openInExternalIDE,
                            onDismiss: { setChromePopover(nil) }
                        )
                    }
                case .notices:
                    WarrenDesktopNoticePopover(
                        notices: notices,
                        onRead: onNoticeRead,
                        onDismissNotice: onNoticeDismiss,
                        isMuted: $notificationsMuted,
                        onMarkAllRead: markAllNoticesRead,
                        onDismiss: { setChromePopover(nil) }
                    )
                case .overflow:
                    WarrenDesktopOverflowPopover(
                        controls: trailingControlLayout.overflow,
                        detail: overflowControlDetail,
                        supportsSecondary: overflowControlSupportsSecondary,
                        secondaryContent: overflowSecondaryContent,
                        secondaryTitleAccessory: overflowSecondaryTitleAccessory,
                        onSelect: selectOverflowControl,
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
            .onChange(of: webStatus.tunnelRunning) { _, isRunning in
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
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination]
    ) -> AnyView {
        AnyView(WarrenDesktopTabBar(
            tabs: presentation.tabs,
            tabTitles: tabTitles,
            tabActivities: tabActivities,
            pinnedSessionIDs: pinnedSessionIDs,
            selectedTabID: navigation.selectedTabID,
            chromeMode: chromeMode,
            isSidebarCollapsed: sidebarState.isCollapsed,
            connectionState: projection.connectionState,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            webStatus: webStatus,
            externalIDEOptions: externalIDEOptions,
            notices: notices,
            notificationsMuted: notificationsMuted,
            externallyVisibleControls: externallyVisibleControls,
            isOverflowPresented: chromePopover == .overflow,
            isNoticePresented: chromePopover == .notices,
            onToggleSidebar: toggleSidebar,
            onSettings: openSettings,
            onChromePopover: { popover in
                setChromePopover(chromePopover == popover ? nil : popover)
            },
            onOpenInExternalIDE: openInExternalIDE,
            onSelectEndpoint: onSelectEndpoint,
            onSelectTab: { dispatch(.selectTab($0)) },
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
                addSession(in: presentation)
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
        isAddingSession: Bool
    ) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                if chromeMode.showsIndependentTopBar {
                    WarrenDesktopTopBar(
                        hostName: projection.host.name,
                        isSidebarCollapsed: sidebarState.isCollapsed,
                        onToggleSidebar: toggleSidebar
                    )
                }
                tabBarView
                WarrenDesktopPresetBar(
                    workspace: presentation.workspace,
                    terminalGroup: presentation.terminalGroup,
                    isBusy: isAddingSession,
                    onLaunch: { request in
                        launchSession(request, in: presentation)
                    }
                )
                HStack(spacing: 0) {
                    WarrenDesktopWorkspaceContent(
                        workspace: presentation.contentWorkspace,
                        terminalGroup: presentation.contentTerminalGroup,
                        tab: presentation.tab,
                        hasProjects: !projection.groups.isEmpty,
                        connectionState: projection.connectionState,
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
                        wantsTerminalFocus: !commandPalettePresented && !settingsPresented,
                        onAddProject: { dispatch(.addProject) },
                        onImportSuperset: { dispatch(.importSuperset) },
                        terminalSurface: terminalSurface
                    )
                }
            }
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
                defaultRuntime: defaultRuntime,
                onSetRuntime: onSetRuntime,
                autoOpenShell: autoOpenShell,
                onSetAutoOpenShell: onSetAutoOpenShell,
                autoStartAI: autoStartAI,
                onSetAutoStartAI: onSetAutoStartAI
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
        actions(action)
    }

    private func openSettings() {
        setCommandPalettePresented(false)
        navigationBeforeSettings = navigation
        // Settings overlays a still-mounted shell so its Ghostty grid
        // survives the trip; drop keyboard ownership so keystrokes go to
        // Settings instead of the hidden terminal.
        NSApp.keyWindow?.makeFirstResponder(nil)
        setChromePopover(nil)
        setSettingsPresented(true)
    }

    private func overflowControlDetail(
        _ control: WarrenDesktopWorkspaceTabTrailingControl
    ) -> String? {
        switch control {
        case .externalIDE:
            return externalIDEOptions?.first?.name
        case .endpoint:
            return endpointOptions.first { $0.id == selectedEndpointID }?.label
        case .web:
            if webStatus.tunnelRunning {
                return "Public Access on"
            }
            return webStatus.isRunning ? "Web running" : "Web stopped"
        case .notifications:
            if notificationsMuted {
                return "Muted"
            }
            let unreadCount = notices.filter(\.isUnread).count
            return unreadCount > 0 ? "\(unreadCount) unread" : "No unread notifications"
        case .settings:
            return nil
        }
    }

    private func overflowControlSupportsSecondary(
        _ control: WarrenDesktopWorkspaceTabTrailingControl
    ) -> Bool {
        switch control {
        case .externalIDE:
            return !(externalIDEOptions?.isEmpty ?? true)
        case .endpoint, .web, .notifications:
            return true
        case .settings:
            return false
        }
    }

    private func overflowSecondaryContent(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        onBack: @escaping () -> Void
    ) -> AnyView? {
        switch control {
        case .externalIDE:
            guard let options = externalIDEOptions, !options.isEmpty else { return nil }
            return AnyView(
                WarrenDesktopExternalIDEPopoverContent(
                    options: options,
                    onOpen: { option in
                        openInExternalIDE(option)
                        onBack()
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
                    onDismiss: onBack
                )
            )
        case .web:
            let panel = WarrenDesktopWebPanel(
                status: webStatus,
                canControl: webStatus.canControl,
                onStart: {
                    onWebStart()
                    refreshWebDismissal()
                },
                onOpenSettings: openSettings,
                onStop: {
                    onWebStop()
                    refreshWebDismissal()
                },
                onOpenURL: onWebOpenURL,
                onCopyURL: onWebCopyURL,
                onDismiss: onBack
            )
            return AnyView(panel.inlineContent)
        case .notifications:
            return AnyView(
                WarrenDesktopNoticeInlineContent(
                    notices: notices,
                    onRead: onNoticeRead,
                    onDismissNotice: onNoticeDismiss,
                    onDismiss: onBack
                )
            )
        case .settings:
            return nil
        }
    }

    private func overflowSecondaryTitleAccessory(
        _ control: WarrenDesktopWorkspaceTabTrailingControl
    ) -> AnyView? {
        guard control == .notifications else { return nil }
        return AnyView(
            WarrenDesktopNoticeTitleActions(
                unreadCount: notices.filter(\.isUnread).count,
                isMuted: $notificationsMuted,
                onMarkAllRead: markAllNoticesRead
            )
        )
    }

    private func markAllNoticesRead() {
        notices
            .filter(\.isUnread)
            .forEach { onNoticeRead($0.id) }
    }

    private func selectOverflowControl(
        _ control: WarrenDesktopWorkspaceTabTrailingControl
    ) {
        switch control {
        case .externalIDE:
            guard externalIDEOptions != nil else { return }
            setChromePopover(.externalIDE)
        case .endpoint:
            setChromePopover(.endpoint)
        case .web:
            setChromePopover(.web)
        case .notifications:
            setChromePopover(.notices)
        case .settings:
            setChromePopover(nil)
            openSettings()
        }
    }

    private func closeSettings() {
        let previousNavigation = navigationBeforeSettings
        navigationBeforeSettings = nil
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

    private func handleTabMove(forward: Bool, in presentation: Presentation) {
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
              let tabID = WarrenDesktopTabSelector.tabID(
                in: presentation.tabs,
                number: index
              ) else { return }
        dispatch(.selectTab(tabID))
    }

    private func handleCloseTab(in presentation: Presentation) {
        guard let tab = presentation.tab, tab.sessionID != nil else { return }
        dispatch(.closeTab(tab.id))
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
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = request
        }
    }

    private func dismissRename() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingRename = nil
        }
    }

    private func confirmRename() {
        guard let pendingRename else { return }
        switch pendingRename {
        case .project(let id, _):
            dispatch(.renameProject(id, renameValue))
        case .workspace(let id, _):
            dispatch(.renameWorkspace(id, renameValue))
        case .session(let id, _):
            dispatch(.renameSession(id, renameValue))
        }
        dismissRename()
    }

    private func presentTerminalGroupCreate() {
        terminalGroupName = ""
        terminalGroupHome = ""
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = .create
        }
    }

    private func presentTerminalGroupEdit(_ group: TerminalGroup) {
        terminalGroupName = group.name
        terminalGroupHome = group.home ?? ""
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = .edit(group.id)
        }
    }

    private func dismissTerminalGroupEditor() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingTerminalGroupEditor = nil
        }
    }

    private func confirmTerminalGroupEditor() {
        guard let pendingTerminalGroupEditor else { return }
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
                confirmLabel: "Rename",
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
