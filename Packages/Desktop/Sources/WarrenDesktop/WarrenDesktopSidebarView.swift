import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct NotificationBellButton: View {
    let unreadCount: Int
    let isMuted: Bool
    let action: () -> Void
    let tokens: WarrenColorTokens
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        let bellColor = isMuted
            ? tokens.mutedForeground
            : (unreadCount > 0 ? tokens.highlight.opacity(0.78) : tokens.mutedForeground)
        
        Button(action: action) {
            Image(systemName: isMuted ? "bell.slash" : "bell")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(bellColor)
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .focused($isFocused)
        .help(isMuted ? "Notifications muted" : "Notifications")
        .accessibilityLabel("Notifications")
        .accessibilityValue(
            isMuted
                ? "Muted"
                : (unreadCount > 0 ? "\(unreadCount) unread" : "No unread notifications")
        )
        .accessibilityHint("See system messages and Agent task completion notices")
    }
}

struct WarrenDesktopSidebar: View {
    let projection: WarrenDesktopProjection
    @Binding var sidebarState: WarrenDesktopSidebarState
    @Binding var sidebarTree: WarrenDesktopSidebarTreeState
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
    let chromeMode: WarrenDesktopChromeMode
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let showsTasks: Bool
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let onRequestTaskCreate: () -> Void
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let onAction: (WarrenDesktopAction) -> Void
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let notices: [WarrenDesktopNotice]
    @Binding var isNoticePopoverPresented: Bool
    let onDismissNoticePopover: () -> Void
    let onNoticeRead: (WarrenDesktopNotice.ID) -> Void
    let onNoticeDismiss: (WarrenDesktopNotice.ID) -> Void
    let onMarkAllNoticesRead: () -> Void
    
    @AppStorage("notificationsMuted")
    private var notificationsMuted = false
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    let onRequestTerminalGroupCreate: () -> Void
    let onRequestTerminalGroupEdit: (TerminalGroup) -> Void
    let activeEndpointID: String
    let displayConfigurationError: String?
    /// Optional ordered Host sections. When present, the Projects/Workspaces
    /// portion uses the endpoint-scoped read model while the footer and
    /// current-host controls remain unchanged.
    let sidebarHostProjections: [WarrenDesktopSidebarHostProjection]?
    /// An explicit display configuration uses the Host-scoped tree even for
    /// one Host. A missing configuration retains the legacy current-Host
    /// sidebar instead.
    let usesSidebarHostSections: Bool
    /// Selection with the endpoint scope owned by the navigation controller.
    /// It is supplied separately from `activeEndpointID` because a Host switch
    /// can briefly render the old navigation state under a new requested Host.
    let sidebarResourceSelection: WarrenDesktopSidebarResourceSelection?
    let onSelectSidebarResource: (WarrenDesktopSidebarResourceSelection) -> Void
    let onOpenSidebarWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    let onRetrySidebarHost: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            WarrenDesktopSidebarHeader(
                isCollapsed: sidebarState.isCollapsed,
                chromeMode: chromeMode,
                updateStatus: updateStatus,
                onUpdateAction: onUpdateAction,
                onToggle: toggleSidebar,
                onCommandPalette: onCommandPalette,
                showsActiveOnly: sidebarTree.showsActiveOnly,
                onToggleActiveOnly: toggleActiveOnly
            )
            if let displayConfigurationError {
                displayConfigurationNotice(displayConfigurationError, tokens: tokens)
            }
            ScrollViewReader { proxy in
                WarrenOverflowFadeScrollView(
                    .vertical,
                    fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                    surface: tokens.sidebarSurface
                ) {
                    Group {
                        if let sidebarHostProjections, usesSidebarHostSections {
                            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                // Tasks and Terminal Groups remain current-host
                                // features in the first multi-host release. Reuse
                                // the existing rows for those sections while the
                                // scoped Host view owns only Projects/Workspaces.
                                WarrenDesktopSidebarRows(
                                    taskGroups: projection.taskGroups,
                                    groups: projection.groups,
                                    terminalGroups: projection.terminalGroups.map {
                                        WarrenDesktopTerminalGroup(
                                            group: $0,
                                            sessions: projection.sessions(in: $0.id)
                                        )
                                    },
                                    workspaceActivitySummaries: projection.workspaceActivitySummaries,
                                    activeWorkspaceIDs: projection.activeWorkspaceIDs,
                                    // Active Sessions lives in the dedicated shortcut
                                    // switcher; the sidebar stays focused on navigation.
                                    showsActiveSessions: false,
                                    showsTasks: showsTasks,
                                    showsProjects: false,
                                    tree: $sidebarTree,
                                    isCollapsed: sidebarState.isCollapsed,
                                    selection: selection,
                                    selectedTabID: selectedTabID,
                                    deletingProjectIDs: deletingProjectIDs,
                                    deletingWorkspaceIDs: deletingWorkspaceIDs,
                                    endpointCapabilities: endpointCapabilities,
                                    isInteractionDisabled: !projection.isConnected,
                                    onAddProject: { onAction(.addProject) },
                                    onRequestTaskCreate: onRequestTaskCreate,
                                    onFocusTask: { taskID in
                                        Self.revealTask(taskID, in: &sidebarTree)
                                        DispatchQueue.main.async {
                                            withAnimation(WarrenMotion.animation(
                                                .stateChange,
                                                reduceMotion: reduceMotion
                                            )) {
                                                proxy.scrollTo("task.\(taskID.description)")
                                            }
                                        }
                                    },
                                    onRequestTerminalGroupCreate: onRequestTerminalGroupCreate,
                                    onRequestTerminalGroupEdit: onRequestTerminalGroupEdit,
                                    onAction: onAction,
                                    onRequestRename: onRequestRename,
                                    onRequestDeletion: onRequestDeletion
                                )
                                WarrenDesktopSidebarHostRows(
                                    hosts: sidebarHostProjections,
                                    showsActiveOnly: sidebarTree.showsActiveOnly,
                                    isCollapsed: sidebarState.isCollapsed,
                                    selection: sidebarResourceSelection,
                                    activeEndpointID: activeEndpointID,
                                    deletingProjectIDs: deletingProjectIDs,
                                    deletingWorkspaceIDs: deletingWorkspaceIDs,
                                    onAction: onAction,
                                    onRequestRename: onRequestRename,
                                    onRequestDeletion: onRequestDeletion,
                                    onSelect: onSelectSidebarResource,
                                    onOpenWorkspace: onOpenSidebarWorkspace,
                                    onFocusTask: { taskID in
                                        Self.revealTask(taskID, in: &sidebarTree)
                                        DispatchQueue.main.async {
                                            withAnimation(WarrenMotion.animation(
                                                .stateChange,
                                                reduceMotion: reduceMotion
                                            )) {
                                                proxy.scrollTo("task.\(taskID.description)")
                                            }
                                        }
                                    },
                                    onToggleActiveOnly: toggleActiveOnly,
                                    onRetry: onRetrySidebarHost
                                )
                            }
                        } else {
                            WarrenDesktopSidebarRows(
                            taskGroups: projection.taskGroups,
                            groups: projection.groups,
                            terminalGroups: projection.terminalGroups.map {
                                WarrenDesktopTerminalGroup(
                                    group: $0,
                                    sessions: projection.sessions(in: $0.id)
                                )
                            },
                            workspaceActivitySummaries: projection.workspaceActivitySummaries,
                            activeWorkspaceIDs: projection.activeWorkspaceIDs,
                            // Active Sessions lives in the dedicated shortcut
                            // switcher; the sidebar stays focused on navigation.
                            showsActiveSessions: false,
                            showsTasks: showsTasks,
                            tree: $sidebarTree,
                            isCollapsed: sidebarState.isCollapsed,
                            selection: selection,
                            selectedTabID: selectedTabID,
                            deletingProjectIDs: deletingProjectIDs,
                            deletingWorkspaceIDs: deletingWorkspaceIDs,
                            endpointCapabilities: endpointCapabilities,
                            isInteractionDisabled: !projection.isConnected,
                            onAddProject: { onAction(.addProject) },
                            onRequestTaskCreate: onRequestTaskCreate,
                            onFocusTask: { taskID in
                                Self.revealTask(taskID, in: &sidebarTree)
                                DispatchQueue.main.async {
                                    withAnimation(WarrenMotion.animation(
                                        .stateChange,
                                        reduceMotion: reduceMotion
                                    )) {
                                        proxy.scrollTo(
                                            "task.\(taskID.description)"
                                        )
                                    }
                                }
                            },
                            onRequestTerminalGroupCreate: onRequestTerminalGroupCreate,
                            onRequestTerminalGroupEdit: onRequestTerminalGroupEdit,
                            onAction: onAction,
                            onRequestRename: onRequestRename,
                            onRequestDeletion: onRequestDeletion
                            )
                        }
                    }
                    .padding(.vertical, WarrenSpacing.compact)
                }
                .onChange(of: sidebarResourceSelection) { newSelection in
                    guard usesSidebarHostSections,
                          case let .workspace(reference)? = newSelection else {
                        return
                    }
                    // A task-linked workspace is navigated from its Task row.
                    // The Host tree renders that row unselectable, so scrolling
                    // into the Projects subtree would land on a row the user
                    // cannot act on while the usable row sits in Tasks.
                    let owningTaskID = currentHostTaskID(for: reference)
                    if let owningTaskID {
                        // Task rows exist only while the Task is expanded, so
                        // reveal it before asking for the scroll.
                        Self.revealTask(owningTaskID, in: &sidebarTree)
                    }
                    let targetID = Self.hostWorkspaceScrollTarget(
                        endpointID: reference.endpointID,
                        workspaceID: reference.id,
                        owningTaskID: owningTaskID
                    )
                    // A nil anchor asks ScrollViewReader to make an off-screen
                    // row visible with the smallest required movement. It
                    // leaves an already visible row where it is instead of
                    // recentering the sidebar for every selection change.
                    DispatchQueue.main.async {
                        withAnimation(WarrenMotion.animation(
                            .stateChange,
                            reduceMotion: reduceMotion
                        )) {
                            proxy.scrollTo(targetID)
                        }
                    }
                }
                .onChange(of: selection) { newSelection in
                    guard !usesSidebarHostSections,
                          case let .workspace(workspaceID)? = newSelection else {
                        return
                    }
                    let workspace = projection.groups
                        .flatMap(\.workspaces)
                        .first(where: { $0.id == workspaceID })
                    // `workspaceScrollTarget` already points a task-linked
                    // workspace at its Task row, but that row is only mounted
                    // while the Task is expanded. Reveal it first so the scroll
                    // has a target instead of silently doing nothing.
                    if showsTasks, let owningTaskID = workspace?.taskID {
                        Self.revealTask(owningTaskID, in: &sidebarTree)
                    }
                    let targetID = workspace.map(Self.workspaceScrollTarget)
                        ?? "workspace.project-list.\(workspaceID.description)"
                    // A nil anchor asks ScrollViewReader to make an off-screen
                    // row visible with the smallest required movement. It
                    // leaves an already visible row where it is instead of
                    // recentering the sidebar for every selection change.
                    DispatchQueue.main.async {
                        withAnimation(WarrenMotion.animation(
                            .stateChange,
                            reduceMotion: reduceMotion
                        )) {
                            proxy.scrollTo(targetID)
                        }
                    }
                }
            }
            sidebarFooter(tokens: tokens)
        }
        .frame(maxHeight: .infinity)
        .background(tokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tokens.chromeDivider)
                .frame(width: WarrenSpacing.hairline)
                .zIndex(2)
        }
    }

    @ViewBuilder
    private func displayConfigurationNotice(
        _ message: String,
        tokens: WarrenColorTokens
    ) -> some View {
        if sidebarState.isCollapsed {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.warning)
                .frame(width: 32, height: 28)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(message)
                .accessibilityLabel("Display configuration warning")
                .accessibilityValue(message)
        } else {
            HStack(alignment: .top, spacing: WarrenSpacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.vertical, WarrenSpacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Display configuration warning")
            .accessibilityValue(message)
        }
    }

    static func revealTask(
        _ taskID: TaskID,
        in tree: inout WarrenDesktopSidebarTreeState
    ) {
        tree.tasksCollapsed = false
        tree.expandedTaskIDs.insert(taskID)
    }

    static func workspaceScrollTarget(for workspace: Workspace) -> String {
        let scope = workspace.taskID == nil ? "project-list" : "task-list"
        return "workspace.\(scope).\(workspace.id.description)"
    }

    /// The scroll target for a workspace selected in the Host-scoped tree.
    ///
    /// A task-linked workspace resolves to its Task row, because the Host tree
    /// deliberately renders that row unselectable and the Projects subtree
    /// therefore holds no target the user can act on. Everything else resolves
    /// to its Host row.
    static func hostWorkspaceScrollTarget(
        endpointID: String,
        workspaceID: WorkspaceID,
        owningTaskID: TaskID?
    ) -> String {
        owningTaskID == nil
            ? "host.\(endpointID).workspace.\(workspaceID.description)"
            : "workspace.task-list.\(workspaceID.description)"
    }

    /// The Task that owns a selected workspace, when the Task row is the
    /// navigation target rather than the Host's Projects subtree.
    ///
    /// Tasks are current-Host-only in this release, so a workspace on a
    /// background Host keeps its Host row as the only activation path — which
    /// is also why that row stays selectable there.
    private func currentHostTaskID(
        for reference: WarrenDesktopHostResourceRef<WorkspaceID>
    ) -> TaskID? {
        guard showsTasks, reference.endpointID == activeEndpointID else { return nil }
        return projection.groups
            .flatMap(\.workspaces)
            .first(where: { $0.id == reference.id })?
            .taskID
    }

    private func toggleSidebar() {
        sidebarState.toggleCollapsed()
        onAction(.toggleSidebar)
    }

    private func toggleActiveOnly() {
        withAnimation(WarrenMotion.animation(
            .stateChange,
            reduceMotion: reduceMotion
        )) {
            sidebarTree.showsActiveOnly.toggle()
            if sidebarTree.showsActiveOnly {
                sidebarTree.expandedProjectIDs.formUnion(projection.groups.map(\.project.id))
            }
        }
    }

    private func sidebarFooter(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            if sidebarState.isCollapsed {
                VStack(spacing: WarrenSpacing.xs) {
                    if endpointCapabilities.canAddProject {
                        addProjectButton(tokens: tokens, showsLabel: false)
                    }
                    if updateStatus != .none {
                        updateButton(tokens: tokens)
                    }
                    // Show notification bell before settings button in collapsed mode
                    NotificationBellButton(
                        unreadCount: projection.unreadNoticeCount,
                        isMuted: notificationsMuted,
                        action: { onAction(.openNotifications) },
                        tokens: tokens
                    )
                    settingsButton(tokens: tokens)
                }
                .padding(.vertical, WarrenSpacing.xs)
            } else {
                HStack(spacing: WarrenSpacing.xs) {
                    if endpointCapabilities.canAddProject {
                        addProjectButton(tokens: tokens, showsLabel: true)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if updateStatus != .none {
                        WarrenDesktopBuildBadge(
                            updateStatus: updateStatus,
                            showsBuildMarker: false,
                            onUpdateAction: onUpdateAction
                        )
                    }
                    // Show notification bell before settings button in the bottom bar
                    NotificationBellButton(
                        unreadCount: projection.unreadNoticeCount,
                        isMuted: notificationsMuted,
                        action: { onAction(.openNotifications) },
                        tokens: tokens
                    )
                    settingsButton(tokens: tokens)
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.vertical, WarrenSpacing.xs)
            }
        }
        .popover(
            isPresented: Binding(
                get: { isNoticePopoverPresented },
                set: { _ in onDismissNoticePopover() }
            ),
            content: {
                WarrenDesktopNoticePopover(
                    notices: notices,
                    onRead: onNoticeRead,
                    onDismissNotice: onNoticeDismiss,
                    isMuted: $notificationsMuted,
                    onMarkAllRead: onMarkAllNoticesRead,
                    onDismiss: onDismissNoticePopover
                )
            }
        )
    }

    private func addProjectButton(tokens: WarrenColorTokens, showsLabel: Bool) -> some View {
        Button { onAction(.addProject) } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                if showsLabel {
                        Text("Add project")
                            .font(WarrenTypography.navigationItemLight)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(tokens.mutedForeground)
            .frame(maxWidth: showsLabel ? .infinity : nil, minHeight: 32, alignment: .leading)
            .frame(width: showsLabel ? nil : 32)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .disabled(!endpointCapabilities.canAddProject || !projection.isConnected)
        .help("Add project")
        .accessibilityLabel("Add project")
        .accessibilityIdentifier("sidebar.add-project")
    }

    private func settingsButton(tokens: WarrenColorTokens) -> some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(tokens.mutedForeground)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .help("Open Warren settings")
        .accessibilityLabel("Open Warren settings")
        .accessibilityIdentifier("sidebar.settings")
    }

    private func updateButton(tokens: WarrenColorTokens) -> some View {
        Button(action: onUpdateAction) {
            Group {
                switch updateStatus {
                case .updating:
                    WarrenBrailleSpinner(size: 10, accessibilityLabel: "Updating Warren")
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                case .available:
                    Image(systemName: "arrow.down.circle")
                case .none:
                    EmptyView()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(updateStatus == .failed ? tokens.destructive : tokens.info)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .disabled(!updateStatus.isActionable)
        .help(updateStatus.helpText ?? "Warren is up to date")
        .accessibilityLabel(updateStatus.accessibilityLabel ?? "Warren update")
    }

}
