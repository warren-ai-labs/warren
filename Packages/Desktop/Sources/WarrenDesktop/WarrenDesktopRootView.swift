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
    public let webStatus: WarrenDesktopWebStatus
    public let creatingSessionWorkspaceIDs: Set<WorkspaceID>
    public let creatingSessionTerminalGroupIDs: Set<TerminalGroupID>

    private let endpointOptions: [WarrenDesktopEndpointOption]
    private let selectedEndpointID: String
    private let onSelectEndpoint: (String) -> Void

    private let actions: WarrenDesktopActions
    private let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    private let onWebStart: () -> Void
    private let onWebStop: () -> Void
    private let onWebOpenURL: (URL) -> Void
    private let onWebCopyURL: (URL) -> Void
    private let defaultRuntime: String?
    private let onSetRuntime: (String) -> Void
    private let persistenceEnabled: Bool
    private let externalIDEService = WarrenDesktopExternalIDEService.live
    @State private var sidebarState: WarrenDesktopSidebarState
    @State private var sidebarTree: WarrenDesktopSidebarTreeState
    @State private var inspectorVisible: Bool
    @State private var inspectorWasAvailable: Bool
    @State private var commandPalettePresented = false
    @State private var settingsPresented = false
    @State private var navigationBeforeSettings: WarrenDesktopNavigationState?
    @State private var webPresented = false
    @State private var webDismissalNonce = 0
    @State private var pendingRename: WarrenDesktopRenameRequest?
    @State private var renameValue = ""
    @State private var pendingDeletion: WarrenDesktopDeletionRequest?
    @State private var deleteWorkspaceRemoveWorktree = false
    @State private var externalIDEFailure: WarrenDesktopExternalIDEFailure?
    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var terminalTitleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.gnarSharingEnabled)
    private var gnarSharingEnabled = true
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
        actions: WarrenDesktopActions = WarrenDesktopActions(),
        webStatus: WarrenDesktopWebStatus = .init(),
        creatingSessionWorkspaceIDs: Set<WorkspaceID> = [],
        creatingSessionTerminalGroupIDs: Set<TerminalGroupID> = [],
        endpointOptions: [WarrenDesktopEndpointOption] = [
            .init(id: "local", label: "Local", isLocal: true),
        ],
        selectedEndpointID: String = "local",
        onSelectEndpoint: @escaping (String) -> Void = { _ in },
        onWebStart: @escaping () -> Void = {},
        onWebStop: @escaping () -> Void = {},
        onWebOpenURL: @escaping (URL) -> Void = { _ in },
        onWebCopyURL: @escaping (URL) -> Void = { _ in },
        defaultRuntime: String? = nil,
        onSetRuntime: @escaping (String) -> Void = { _ in },
        persistenceEnabled: Bool = true,
        @ViewBuilder terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.projection = projection
        self.navigation = navigation ?? WarrenDesktopNavigationReducer.initial(for: projection)
        self.chromeMode = chromeMode
        self.webStatus = webStatus
        self.creatingSessionWorkspaceIDs = creatingSessionWorkspaceIDs
        self.creatingSessionTerminalGroupIDs = creatingSessionTerminalGroupIDs
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.onSelectEndpoint = onSelectEndpoint
        self.actions = actions
        self.terminalSurface = terminalSurface
        self.onWebStart = onWebStart
        self.onWebStop = onWebStop
        self.onWebOpenURL = onWebOpenURL
        self.onWebCopyURL = onWebCopyURL
        self.defaultRuntime = defaultRuntime
        self.onSetRuntime = onSetRuntime
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
        _inspectorVisible = State(initialValue: projection.inspector != nil)
        _inspectorWasAvailable = State(initialValue: projection.inspector != nil)
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
        let selectedEndpointIsLocal = endpointOptions.first {
            $0.id == selectedEndpointID
        }?.isLocal == true
        let externalIDEOptions = presentation.workspace.map { workspace in
            externalIDEService.options(
                for: workspace,
                isLocalEndpoint: selectedEndpointIsLocal
            )
        }
        let sessionMoveTargets = makeSessionMoveTargets()
        let sessionMoveDestinations = makeSessionMoveDestinations()
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                WarrenDesktopSidebar(
                    projection: projection,
                    sidebarState: $sidebarState,
                    sidebarTree: $sidebarTree,
                    selection: navigation.selection,
                    chromeMode: chromeMode,
                    onAction: dispatch,
                    onCommandPalette: { commandPalettePresented = true },
                    onRequestRename: presentRename,
                    onRequestDeletion: presentDeletion
                )
                .frame(width: sidebarState.renderedWidth)

                VStack(spacing: 0) {
                    if chromeMode.showsIndependentTopBar {
                        WarrenDesktopTopBar(
                            hostName: projection.host.name,
                            isSidebarCollapsed: sidebarState.isCollapsed,
                            hasInspector: projection.inspector != nil,
                            isInspectorVisible: inspectorVisible,
                            onToggleSidebar: toggleSidebar,
                            onToggleInspector: {}
                        )
                    }
                    WarrenDesktopTabBar(
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
                        hasInspector: projection.inspector != nil,
                        isInspectorVisible: inspectorVisible,
                        onToggleSidebar: toggleSidebar,
                        onToggleInspector: toggleInspector,
                        onCommandPalette: { setCommandPalettePresented(true) },
                        onSettings: {
                            setCommandPalettePresented(false)
                            navigationBeforeSettings = navigation
                            // Settings overlays a still-mounted shell so its
                            // Ghostty grid survives the trip; drop keyboard
                            // ownership so keystrokes go to Settings instead
                            // of the hidden terminal.
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            setSettingsPresented(true)
                        },
                        onWeb: { setWebPresented(!webPresented) },
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
                    )
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
                            onAddProject: { dispatch(.addProject) },
                            onImportSuperset: { dispatch(.importSuperset) },
                            terminalSurface: terminalSurface
                        )
                        if inspectorVisible, let inspector = projection.inspector {
                            WarrenDesktopInspectorSlot(content: inspector)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(settingsPresented ? 0 : 1)
            .allowsHitTesting(!settingsPresented)
            .accessibilityHidden(settingsPresented)

            if settingsPresented {
                WarrenDesktopSettingsView(
                    onBack: closeSettings,
                    defaultRuntime: defaultRuntime,
                    onSetRuntime: onSetRuntime
                )
                    .transition(.opacity)
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
        .onChange(of: projection.reconciliationKey) { _, _ in
            reconcileInspector(with: projection)
        }
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
            setCommandPalettePresented(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.newSession)) { _ in
            addSession(in: presentation)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.nextTab)) { _ in
            guard let tabID = WarrenDesktopTabCycler.tabID(
                forward: true,
                in: presentation.tabs,
                selectedTabID: navigation.selectedTabID
            ) else { return }
            dispatch(.selectTab(tabID))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.previousTab)) { _ in
            guard let tabID = WarrenDesktopTabCycler.tabID(
                forward: false,
                in: presentation.tabs,
                selectedTabID: navigation.selectedTabID
            ) else { return }
            dispatch(.selectTab(tabID))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.selectTab)) { note in
            let rawIndex = note.userInfo?[WarrenDesktopCommand.selectTabIndexKey]
            let index = rawIndex as? Int ?? (rawIndex as? NSNumber)?.intValue
            guard let index,
                  let tabID = WarrenDesktopTabSelector.tabID(
                    in: presentation.tabs,
                    number: index
                  ) else { return }
            dispatch(.selectTab(tabID))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.closeTab)) { _ in
            guard let tab = presentation.tab, tab.sessionID != nil else { return }
            dispatch(.closeTab(tab.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.toggleInspector)) { _ in
            toggleInspector()
        }
        .overlay {
            renameDialog
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
                .zIndex(20)
            }
        }
        .overlay(alignment: .topTrailing) {
            if webPresented && !settingsPresented {
                WarrenDesktopWebPanel(
                    status: webStatus,
                    canShare: gnarSharingEnabled,
                    onStart: {
                        onWebStart()
                        refreshWebDismissal()
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
                    }
                )
                .padding(.top, WarrenLayoutMetrics.tabBarHeight + WarrenSpacing.small)
                .padding(.trailing, WarrenSpacing.medium)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: webPresented) { _, isPresented in
            if isPresented {
                refreshWebDismissal()
            }
        }
        .onChange(of: webStatus.tunnelRunning) { _, isRunning in
            // Keep the panel open while sharing so the public address stays
            // visible for copying; it falls back to auto-dismiss after stop.
            if isRunning, webPresented {
                refreshWebDismissal()
            }
        }
        .task(id: webDismissalNonce) {
            guard webPresented else { return }
            try? await Task.sleep(for: WarrenDesktopWebDismissal.interval)
            guard !Task.isCancelled else { return }
            guard !webStatus.tunnelRunning else { return }
            setWebPresented(false)
        }
        .alert(item: $externalIDEFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .warrenSemanticObservationRoot(recorder: semanticRecorder)
    }

    /// Resolve all selection-dependent UI values once per body evaluation.
    /// SwiftUI asks for these values in several branches and closures; keeping
    /// one immutable presentation value avoids repeated graph lookups while
    /// preserving the navigation ownership rules.
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
                externalIDEFailure = WarrenDesktopExternalIDEFailure(
                    ideName: option.ide.name,
                    error: error
                )
            }
        }
    }

    private func dispatch(_ action: WarrenDesktopAction) {
        actions(action)
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

    private func toggleInspector() {
        inspectorVisible.toggle()
        actions(.toggleInspector)
    }

    private func setCommandPalettePresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            commandPalettePresented = presented
        }
    }

    private func setSettingsPresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            settingsPresented = presented
        }
    }

    private func setWebPresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            webPresented = presented
        }
    }

    private func refreshWebDismissal() {
        guard webPresented else { return }
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
            .zIndex(31)
        }
    }

    private func presentDeletion(_ request: WarrenDesktopDeletionRequest) {
        deleteWorkspaceRemoveWorktree = false
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = request
        }
    }

    private func dismissDeletion() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            pendingDeletion = nil
        }
    }

    @ViewBuilder
    private var deletionDialog: some View {
        if let pendingDeletion {
            WarrenModalBackdrop {
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
                        }
                    )
                    .warrenPanelSurface(cornerRadius: WarrenRadius.large)
                case .project(let project, let workspaceCount):
                    WarrenDesktopDeleteProjectConfirmation(
                        project: project,
                        workspaceCount: workspaceCount,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteProject(project.id))
                            dismissDeletion()
                        }
                    )
                    .warrenPanelSurface(cornerRadius: WarrenRadius.large)
                case .terminalGroup(let group, let sessionCount):
                    WarrenDesktopDeleteTerminalGroupConfirmation(
                        group: group,
                        sessionCount: sessionCount,
                        onCancel: dismissDeletion,
                        onConfirm: {
                            dispatch(.deleteTerminalGroup(group.id))
                            dismissDeletion()
                        }
                    )
                    .warrenPanelSurface(cornerRadius: WarrenRadius.large)
                }
            }
            .zIndex(30)
        }
    }

    private func reconcileInspector(with newProjection: WarrenDesktopProjection) {
        if newProjection.inspector == nil {
            inspectorVisible = false
        } else if !inspectorWasAvailable {
            inspectorVisible = true
        }
        inspectorWasAvailable = newProjection.inspector != nil
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
