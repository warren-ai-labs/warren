import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Projects and Workspaces rendered under one endpoint-owned Host section.
///
/// Workspace selection emits an endpoint-scoped reference and lets the
/// application layer promote that endpoint before invoking the existing
/// single-host terminal flow.
struct WarrenDesktopSidebarHostRows: View {
    let hosts: [WarrenDesktopSidebarHostProjection]
    let showsActiveOnly: Bool
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact
    let selection: WarrenDesktopSidebarResourceSelection?
    let activeEndpointID: String
    /// The open Tab, which only ever belongs to the active endpoint. A
    /// background Host's leaves are navigable but nothing there is open, so they
    /// have no selected row to draw.
    var selectedTabID: String? = nil
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    /// The Desktop-local editor markers, so a Workspace that survives the
    /// `Active only` filter on a marker alone says so (RFC 0021 §7). Applied per
    /// Host section, because a marker names the Endpoint it was written for.
    let editorActivity: WarrenDesktopEditorActivityOverlay
    let onAction: (WarrenDesktopAction) -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    let onSelect: (WarrenDesktopSidebarResourceSelection) -> Void
    let onOpenWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    let onOpenSession: (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void
    let onFocusTask: (TaskID) -> Void
    let onToggleActiveOnly: () -> Void
    let onRetry: (String) -> Void
    /// Drops a Session onto a pane in the arrangement on screen.
    ///
    /// Only the active endpoint's Sessions can be dropped: a pane leaf names a
    /// Session of the endpoint this window is on, so a background Host's row is
    /// routed through `onOpenSession` instead.
    var onSplitDropSession: ((String, String, SplitDropTarget) -> Void)? = nil
    /// Shows a marked Workspace's editor. Only the window's Host runs one.
    var onOpenEditor: ((WorkspaceID) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Projects the user folded away, keyed per Host. Everything starts open.
    @State private var collapsedProjectKeys: Set<String> = []
    @State private var collapsedHostIDs: Set<String> = []
    /// Workspaces whose Session leaves the user folded away, keyed per Host.
    @State private var collapsedWorkspaceKeys: Set<String> = []
    @State private var singleHostProjectsCollapsed = false
    /// Projects, keyed per Host, whose idle-worktrees row the user opened.
    /// That row starts folded.
    @State private var expandedIdleWorkspaceKeys: Set<String> = []
    /// Hosts whose inactive-projects row the user opened.
    @State private var inactiveProjectsExpandedHostIDs: Set<String> = []
    /// Projects held in the active band, keyed per Host; see the current-Host
    /// tree and `WarrenDesktopProjectHold`.
    @State private var projectHold = WarrenDesktopProjectHold()
    @State private var projectActivity = WarrenDesktopProjectHold.Snapshot()
    @Namespace private var projectRowNamespace
    @Environment(\.warrenPointerInsideSidebar) private var pointerInsideSidebar
    @StateObject private var tintAllocator = WarrenDesktopHostTintAllocator()

    init(
        hosts: [WarrenDesktopSidebarHostProjection],
        showsActiveOnly: Bool,
        workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact,
        selection: WarrenDesktopSidebarResourceSelection?,
        activeEndpointID: String,
        selectedTabID: String? = nil,
        deletingProjectIDs: Set<ProjectID>,
        deletingWorkspaceIDs: Set<WorkspaceID>,
        editorActivity: WarrenDesktopEditorActivityOverlay = .init(),
        onAction: @escaping (WarrenDesktopAction) -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onRequestDeletion: @escaping (WarrenDesktopDeletionRequest) -> Void,
        onSelect: @escaping (WarrenDesktopSidebarResourceSelection) -> Void,
        onOpenWorkspace: @escaping (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void,
        onOpenSession: @escaping (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void = { _ in },
        onFocusTask: @escaping (TaskID) -> Void,
        onToggleActiveOnly: @escaping () -> Void,
        onRetry: @escaping (String) -> Void,
        onSplitDropSession: ((String, String, SplitDropTarget) -> Void)? = nil,
        onOpenEditor: ((WorkspaceID) -> Void)? = nil
    ) {
        self.hosts = hosts
        self.showsActiveOnly = showsActiveOnly
        self.workspaceDisplayMode = workspaceDisplayMode
        self.selection = selection
        self.activeEndpointID = activeEndpointID
        self.selectedTabID = selectedTabID
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.editorActivity = editorActivity
        self.onAction = onAction
        self.onRequestRename = onRequestRename
        self.onRequestDeletion = onRequestDeletion
        self.onSelect = onSelect
        self.onOpenWorkspace = onOpenWorkspace
        self.onOpenSession = onOpenSession
        self.onFocusTask = onFocusTask
        self.onToggleActiveOnly = onToggleActiveOnly
        self.onRetry = onRetry
        self.onSplitDropSession = onSplitDropSession
        self.onOpenEditor = onOpenEditor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            if usesHostSectionPresentation {
                WarrenDesktopSidebarHostsSectionHeader(hostCount: hosts.count)
            }
            // Hosts are one list, so the gap between two of them is the section
            // rhythm. The flat single-Host tree keeps its tighter spacing.
            VStack(alignment: .leading, spacing: hostSectionSpacing) {
                ForEach(hosts, id: \.endpointID) { host in
                    hostSection(host)
                        .id(host.endpointID)
                }
            }
        }
        .onChange(of: hosts) { nextHosts in
            let valid = Set(nextHosts.flatMap { host in
                host.projectGroups.map { projectKey(host, $0.project.id) }
            })
            let nextCollapsedProjectKeys = collapsedProjectKeys.filter(valid.contains)
            if nextCollapsedProjectKeys != collapsedProjectKeys {
                collapsedProjectKeys = nextCollapsedProjectKeys
            }
            let nextCollapsedHostIDs = collapsedHostIDs
                .intersection(Set(nextHosts.map(\.endpointID)))
            if nextCollapsedHostIDs != collapsedHostIDs {
                collapsedHostIDs = nextCollapsedHostIDs
            }
            // `onChange` actions close over the prior view value. Resolve the
            // selected resource against the incoming roster, not `hosts`.
            revealSelection(selection, in: nextHosts)
            updateTintAssignments()
        }
        .onAppear {
            projectActivity = currentProjectActivity
            revealSelection(selection, in: hosts)
            updateTintAssignments()
        }
        .onChange(of: selection) { nextSelection in
            revealSelection(nextSelection, in: hosts)
            liftSelectedProject(nextSelection, in: hosts)
        }
        .onChange(of: currentProjectActivity) { activity in
            let previous = projectActivity
            projectActivity = activity
            withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                projectHold.update(from: previous, to: activity, now: Date())
            }
        }
        .task(id: projectHoldClock) {
            await projectHoldClock.run { now, kept in
                // The same travel as the lift, so a row is seen going back.
                withAnimation(WarrenMotion.selection(reduceMotion: reduceMotion)) {
                    _ = projectHold.expire(now: now, keeping: kept)
                }
            }
        }
    }

    @ViewBuilder
    private func hostSection(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        if usesHostSectionPresentation {
            expandedHostSection(host)
        } else {
            singleHostSection(host)
        }
    }

    private var usesHostSectionPresentation: Bool {
        hosts.count > 1
    }

    private var hostSectionSpacing: CGFloat {
        guard usesHostSectionPresentation else {
            return WarrenSpacing.xxs
        }
        return WarrenDesktopSidebarMetrics.sectionSpacing
    }

    private func singleHostSection(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sectionHeaderSpacing) {
            singleHostProjectsHeader(host)
            if !singleHostProjectsCollapsed {
                hostProjectRows(for: host)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func singleHostProjectsHeader(
        _ host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let groups = visibleGroups(for: host)
        let allProjectsExpanded = !groups.isEmpty && groups.allSatisfy {
            isProjectExpanded($0.project.id, in: host)
        }
        return WarrenDesktopSidebarSectionHeader(
            title: "Projects",
            disclosureExpanded: !singleHostProjectsCollapsed,
            actionImage: "plus",
            actionLabel: "Add Project…",
            actionVisible: host.endpointID == activeEndpointID,
            actionEnabled: host.connectionState.isConnected,
            onToggle: toggleSingleHostProjects,
            onAction: { onAction(.addProject) },
            additionalActions: [
                WarrenDesktopSidebarSectionAction(
                    id: "single-host-toggle-all-projects",
                    image: allProjectsExpanded
                        ? "rectangle.compress.vertical"
                        : "rectangle.expand.vertical",
                    label: allProjectsExpanded
                        ? "Collapse all projects"
                        : "Expand all projects",
                    isEnabled: host.connectionState.isConnected && !groups.isEmpty,
                    action: { toggleAllProjects(in: host, groups: groups) }
                ),
            ]
        )
    }

    private func expandedHostSection(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let tintIndex = tintAllocator.assignments[host.endpointID]
            ?? WarrenDesktopHostTint.index(
                for: host.endpointID,
                count: tokens.hostForegroundTints.count
            )
        let tint = WarrenDesktopHostTint.foregroundColor(slot: tintIndex, tokens: tokens)
        let isExpanded = isHostExpanded(host)
        // The rail follows what is on screen, but the "no projects" line speaks
        // to the Host's actual roster: an Active-only filter that hides every
        // project keeps its own explanation.
        let hasVisibleProjects = !visibleGroups(for: host).isEmpty
        let hasProjects = !host.projectGroups.isEmpty
        // A connected Host this window cannot write to and that holds nothing
        // is one line: its heading already says "no projects". A Host this
        // window can write to keeps the Add Project empty state, and an
        // unavailable Host keeps its error and retry.
        let isEmpty = !hasProjects && host.connectionState.isConnected && !canMutate(host)
        return VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            WarrenDesktopSidebarHostHeader(
                host: host,
                isExpanded: isExpanded,
                summary: WarrenDesktopSidebarHostSummary(host),
                marks: hostActivityMarks(host),
                tint: tint,
                isEmpty: isEmpty,
                onToggle: { toggleHost(host.endpointID) },
                onRetry: { onRetry(host.endpointID) },
                // Projects are added to the window's Host; the others are
                // read-only here.
                onAddProject: host.endpointID == activeEndpointID
                    ? { onAction(.addProject) }
                    : nil
            )

            if isExpanded, !isEmpty {
                hostProjectRows(for: host)
                    // A Host's identity is foreground only, so its range is a
                    // short rule in the gutter rather than a plate behind the
                    // rows. It spans the subtree, not the heading.
                    .overlay(alignment: .leading) {
                        if hasVisibleProjects {
                            hostScopeRule(tint: tint)
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host \(host.title)")
    }

    /// The distinct Session states under one Host, most urgent first and ended
    /// Sessions dropped, for the heading's trailing dots.
    private func hostActivityMarks(
        _ host: WarrenDesktopSidebarHostProjection
    ) -> [WarrenActivityMark] {
        let marks = host.activeSessionsByWorkspaceID.values
            .flatMap { $0 }
            .compactMap(\.activityMark)
        return WarrenActivityMark.allCases.reversed().filter {
            $0.isDrawn && marks.contains($0)
        }
    }

    /// The 2pt rule that marks how far a Host's projects reach. It sits just
    /// outside the subtree's leading edge, in the gutter the rows keep, and
    /// stops short of the subtree's last line.
    private func hostScopeRule(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tint.opacity(0.45))
            .frame(width: 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, 2)
            .offset(x: -5)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func hostProjectRows(
        for host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let groups = scopedProjectGroups(for: host)
        if groups.isEmpty {
            if host.connectionState.isSettling, host.projectGroups.isEmpty {
                WarrenDesktopSidebarSkeleton(
                    projectCount: 2,
                    isNestedUnderHost: usesHostSectionPresentation
                )
                .transition(.opacity)
            } else if let reason = emptyReason(for: host) {
                WarrenDesktopSidebarEmptyState(
                    reason: reason,
                    onShowAll: {
                        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                            // The filter is shared by every Host in the
                            // aggregated view, so one escape action restores
                            // the complete roster.
                            onToggleActiveOnly()
                        }
                    },
                    onRetry: { onRetry(host.endpointID) },
                    onAddProject: canMutate(host) ? { onAction(.addProject) } : nil,
                    semanticIDPrefix: "sidebar.empty.host.\(host.endpointID)",
                    isNestedUnderHost: usesHostSectionPresentation
                )
            }
        } else {
            let bands = WarrenDesktopProjectBands(
                groups,
                project: \.group.project,
                isActive: {
                    isProjectActive($0.group, in: host)
                        || projectHold.contains(projectKey(host, $0.group.project.id))
                },
                lastActiveAt: { WarrenDesktopActivityAge.lastActiveAt(of: $0.group.workspaces) },
                activeSince: {
                    projectHold.activeSince(projectKey(host, $0.group.project.id))
                        ?? $0.group.project.activeSince
                }
            )
            let listed = bands.listed
            let showsInactiveRow = !bands.inactive.isEmpty
            ForEach(listed) { scopedGroup in
                let group = scopedGroup.group
                let soloWorkspace = soloWorkspace(of: group, in: host)
                let split = WarrenDesktopWorkspaceSplit(group.workspaces) { isWorkspaceLive($0, in: host) }
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.groupContentSpacing) {
                    hostProjectRow(group, host: host, soloWorkspace: soloWorkspace)
                        .matchedGeometryEffect(
                            id: projectKey(host, group.project.id),
                            in: projectRowNamespace
                        )
                    if isProjectExpanded(group.project.id, in: host) {
                        if let soloWorkspace {
                            // One worktree is no choice, so the project holds
                            // its Sessions directly; see the current-Host tree.
                            VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sessionSpacing) {
                                hostSessionRows(
                                    host.activeSessions(in: soloWorkspace.id),
                                    workspace: soloWorkspace,
                                    project: group.project,
                                    host: host
                                )
                            }
                        } else if split.hasRows {
                            VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.worktreeSpacing) {
                                ForEach(scopedWorkspaces(split.live, host: host)) { scopedWorkspace in
                                    let sessions = workspaceDisplayMode.isRich
                                        && !routesSelectionToTaskRow(scopedWorkspace.workspace, in: host)
                                        && !isWorkspaceLeavesCollapsed(scopedWorkspace.workspace.id, in: host)
                                        ? host.activeSessions(in: scopedWorkspace.workspace.id)
                                        : []
                                    // The same group the single-Host tree draws; see
                                    // WarrenDesktopSessionLeafGroup.
                                    WarrenDesktopSessionLeafGroup(
                                        leafCount: sessions.count
                                    ) {
                                        hostWorkspaceRow(
                                            scopedWorkspace.workspace,
                                            project: group.project,
                                            host: host
                                        )
                                    } leaves: {
                                        hostSessionRows(
                                            sessions,
                                            workspace: scopedWorkspace.workspace,
                                            project: group.project,
                                            host: host
                                        )
                                    }
                                }
                                if split.showsIdleRow {
                                    hostIdleWorkspaceRows(split.idle, project: group.project, host: host)
                                }
                            }
                        }
                    }
                }
                // A hairline frames an open project's subtree; folded
                // projects pack into a compact list.
                .warrenTreeGroupSeparator(
                    of: scopedGroup,
                    in: listed,
                    isFollowed: showsInactiveRow,
                    isFolded: { !isProjectExpanded($0.group.project.id, in: host) }
                )
            }
            if showsInactiveRow {
                hostInactiveProjectRows(bands.inactive.map(\.group), host: host)
                    .warrenTreeGroupSeparator(
                        isFirst: listed.isEmpty,
                        isFolded: !inactiveProjectsExpandedHostIDs.contains(host.endpointID),
                        followsFolded: listed.last.map { !isProjectExpanded($0.group.project.id, in: host) } ?? false,
                        isLast: true
                    )
            }
        }
    }

    /// See the current-Host tree's `isWorkspaceLive`.
    private func isWorkspaceLive(
        _ workspace: Workspace,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        host.activeWorkspaceIDs.contains(workspace.id)
            || !host.activeSessions(in: workspace.id).isEmpty
            || (canMutate(host) && deletingWorkspaceIDs.contains(workspace.id))
            || editorActivity.isEditorMarked(workspace.id, hostId: host.endpointID)
    }

    private func isProjectActive(
        _ group: WarrenDesktopProjectGroup,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        (canMutate(host) && deletingProjectIDs.contains(group.project.id))
            || group.workspaces.contains { isWorkspaceLive($0, in: host) }
    }

    /// The idle-worktrees row at the end of a project, and its list; see the
    /// current-Host tree.
    private func hostIdleWorkspaceRows(
        _ workspaces: [Workspace],
        project: Project,
        host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let key = projectKey(host, project.id)
        let isExpanded = expandedIdleWorkspaceKeys.contains(key)
        let enabled = host.connectionState.isConnected
        let canWrite = canMutate(host)
        return VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sessionSpacing) {
            WarrenDesktopFoldedCountRow(
                count: workspaces.count,
                singular: "idle worktree",
                plural: "idle worktrees",
                height: WarrenDesktopSidebarMetrics.worktreeRowHeight,
                isExpanded: isExpanded,
                semanticID: "\(key).idle-worktrees",
                isEnabled: enabled,
                onToggle: { toggleIdleWorkspaces(key) }
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(workspaces) { workspace in
                        let routesToTask = routesSelectionToTaskRow(workspace, in: host)
                        let isProjectDeleting = canWrite && deletingProjectIDs.contains(project.id)
                        WarrenDesktopIdleWorktreeRow(
                            workspace: workspace,
                            semanticScope: "host.\(host.endpointID)",
                            isSelected: isSelected(workspace: workspace.id, in: host) && !routesToTask,
                            isEnabled: enabled && !isProjectDeleting && !routesToTask,
                            isMutationDisabled: !canWrite,
                            contextMenuActions: WarrenDesktopWorkspaceRow.contextMenuActions(
                                workspace: workspace,
                                isPinned: workspace.pinned,
                                tasks: host.tasks,
                                onTogglePin: {
                                    guard canWrite else { return }
                                    onAction(.setWorkspacePinned(workspace.id, !workspace.pinned))
                                },
                                onRename: {
                                    guard canWrite else { return }
                                    onRequestRename(.workspace(workspace.id, name: workspace.name))
                                },
                                onAttachToTask: { taskID in
                                    guard canWrite else { return }
                                    onAction(.attachWorkspaceToTask(taskID, workspace.id))
                                },
                                onDetachFromTask: { taskID in
                                    guard canWrite else { return }
                                    onAction(.detachWorkspaceFromTask(taskID, workspace.id))
                                },
                                onDelete: {
                                    guard canWrite else { return }
                                    onRequestDeletion(.workspace(workspace, project: project))
                                }
                            ),
                            onSelect: {
                                onSelect(.workspace(host.workspaceReference(workspace.id)))
                            },
                            onDoubleClick: {
                                if workspaceDisplayMode.isRich, canWrite {
                                    onAction(.requestNewSession(workspace.id, token: UUID()))
                                } else {
                                    onOpenWorkspace(host.workspaceReference(workspace.id))
                                }
                            }
                        )
                        .id(workspaceKey(host, workspace.id))
                    }
                }
            }
        }
    }

    /// The inactive-projects row at the end of a Host's projects; see the
    /// current-Host tree.
    private func hostInactiveProjectRows(
        _ inactive: [WarrenDesktopProjectGroup],
        host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let isExpanded = inactiveProjectsExpandedHostIDs.contains(host.endpointID)
        let enabled = host.connectionState.isConnected
        return VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopFoldedCountRow(
                count: inactive.count,
                singular: "inactive project",
                plural: "inactive projects",
                height: WarrenDesktopSidebarMetrics.inactiveProjectsRowHeight,
                isExpanded: isExpanded,
                semanticID: "host.\(host.endpointID).projects-inactive",
                isEnabled: enabled,
                onToggle: { toggleInactiveProjects(host.endpointID) }
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(inactive) { group in
                        WarrenDesktopInactiveProjectRow(
                            project: group.project,
                            lastActiveAt: WarrenDesktopActivityAge.lastActiveAt(of: group.workspaces),
                            semanticID: projectKey(host, group.project.id),
                            isSelected: isSelected(project: group.project.id, in: host),
                            isEnabled: enabled,
                            isMutationDisabled: !canMutate(host),
                            contextMenuActions: projectContextMenuActions(group, host: host),
                            onSelect: { onSelect(.project(host.projectReference(group.project.id))) }
                        )
                        .matchedGeometryEffect(
                            id: projectKey(host, group.project.id),
                            in: projectRowNamespace
                        )
                        .id(projectKey(host, group.project.id))
                    }
                }
                .padding(.top, WarrenDesktopSidebarMetrics.inactiveProjectListSpacing)
            }
        }
    }

    private func toggleIdleWorkspaces(_ key: String) {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if expandedIdleWorkspaceKeys.contains(key) {
                expandedIdleWorkspaceKeys.remove(key)
            } else {
                expandedIdleWorkspaceKeys.insert(key)
            }
        }
    }

    private func toggleInactiveProjects(_ endpointID: String) {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if inactiveProjectsExpandedHostIDs.contains(endpointID) {
                inactiveProjectsExpandedHostIDs.remove(endpointID)
            } else {
                inactiveProjectsExpandedHostIDs.insert(endpointID)
            }
        }
    }


    /// A workspace's Session leaves, drawn under its row or, for a project with
    /// one worktree, under the project itself.
    private func hostSessionRows(
        _ sessions: [WarrenDesktopSession],
        workspace: Workspace,
        project: Project,
        host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        ForEach(sessions) { session in
            WarrenDesktopWorkspaceSessionRow(
                session: session,
                project: project,
                workspace: workspace,
                semanticScope: "host.\(host.endpointID)",
                isSelected: isSelected(session: session, in: host),
                isInteractionDisabled: !host.connectionState.isConnected
                    || deletingProjectIDs.contains(project.id)
                    || deletingWorkspaceIDs.contains(workspace.id),
                onOpen: {
                    onOpenSession(host.sessionReference(session.id))
                },
                // Session mutations target the current Host only; a
                // background Host's leaf stays navigable but read-only, like
                // its workspace row above it.
                onRename: canMutate(host)
                    ? {
                        onRequestRename(.session(
                            session.id,
                            title: session.displayTitle
                        ))
                    }
                    : nil,
                onTogglePin: canMutate(host)
                    ? { onAction(.setSessionPinned(session.id, !session.pinned)) }
                    : nil,
                onEnd: canMutate(host)
                    ? { onAction(.deleteSession(session.id)) }
                    : nil,
                onDismissActivity: canMutate(host)
                    ? session.activityMark.map { mark in
                        { onAction(.dismissActivity(session.id, mark.activityState)) }
                    }
                    : nil,
                // A regeneration asks the Host that owns the Session, so it
                // follows the same read-only rule as every other mutation.
                onRegenerateTitle: canMutate(host)
                    ? { onAction(.regenerateSessionTitle(session.id)) }
                    : nil,
                onSplitDrop: host.endpointID == activeEndpointID
                    ? onSplitDropSession
                    : nil
            )
        }
    }

    /// The project's only Workspace, when the project holds that Workspace's
    /// Sessions directly instead of drawing a row for it. The same rule as the
    /// current-Host tree: the row stays whenever it is the only place
    /// something shows.
    private func soloWorkspace(
        of group: WarrenDesktopProjectGroup,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Workspace? {
        guard workspaceDisplayMode.isRich,
              group.workspaces.count == 1,
              let workspace = group.workspaces.first,
              !routesSelectionToTaskRow(workspace, in: host),
              !host.activeSessions(in: workspace.id).isEmpty,
              !(canMutate(host) && deletingWorkspaceIDs.contains(workspace.id)),
              !editorActivity.isEditorMarked(workspace.id, hostId: host.endpointID)
        else { return nil }
        return workspace
    }

    @ViewBuilder
    private func hostProjectRow(
        _ group: WarrenDesktopProjectGroup,
        host: WarrenDesktopSidebarHostProjection,
        soloWorkspace: Workspace? = nil
    ) -> some View {
        let key = projectKey(host, group.project.id)
        let enabled = host.connectionState.isConnected
        let canWrite = canMutate(host)
        let isDeleting = canWrite && deletingProjectIDs.contains(group.project.id)
        let hasDeletingWorkspace = canWrite && group.workspaces.contains {
            deletingWorkspaceIDs.contains($0.id)
        }
        WarrenDesktopProjectRow(
            project: group.project,
            semanticScope: "host.\(host.endpointID)",
            workspaceCount: group.workspaces.count,
            isSelected: isSelected(project: group.project.id, in: host),
            isExpanded: isProjectExpanded(group.project.id, in: host),
            isPinned: group.project.pinned,
            deletionKind: isDeleting ? .project : nil,
            isInteractionDisabled: !enabled || isDeleting || hasDeletingWorkspace,
            isMutationDisabled: !canWrite,
            onSelect: {
                onSelect(.project(host.projectReference(group.project.id)))
            },
            onToggleExpansion: {
                toggleProject(group.project.id, in: host)
            },
            onAddWorkspace: {
                guard canWrite else { return }
                onAction(.requestNewWorkspace(group.project.id))
            },
            onImportWorktrees: {
                guard canWrite else { return }
                onAction(.requestProjectWorktreeImport(group.project.id))
            },
            onConfigureSetupScript: {
                guard canWrite else { return }
                onAction(.requestProjectSetupScript(group.project.id))
            },
            onToggleAutoImportWorktrees: {
                guard canWrite else { return }
                onAction(.setProjectAutoImportGitWorktrees(
                    group.project.id,
                    !group.project.autoImportGitWorktrees
                ))
            },
            onRename: {
                guard canWrite else { return }
                onRequestRename(.project(group.project.id, name: group.project.name))
            },
            onTogglePin: {
                guard canWrite else { return }
                onAction(.setProjectPinned(group.project.id, !group.project.pinned))
            },
            onDelete: {
                guard canWrite else { return }
                onRequestDeletion(.project(
                    group.project,
                    workspaceCount: group.workspaces.count
                ))
            },
            foldMarks: group.workspaces
                .filter { !routesSelectionToTaskRow($0, in: host) }
                .flatMap { host.activeSessions(in: $0.id) }
                .map(\.activityMark),
            branchName: soloWorkspace.map { $0.branch ?? $0.name },
            workspaceMenu: soloWorkspace.map { workspace in
                WarrenDesktopWorkspaceRow.contextMenuActions(
                    workspace: workspace,
                    isPinned: workspace.pinned,
                    tasks: host.tasks,
                    onTogglePin: {
                        guard canWrite else { return }
                        onAction(.setWorkspacePinned(workspace.id, !workspace.pinned))
                    },
                    onRename: {
                        guard canWrite else { return }
                        onRequestRename(.workspace(workspace.id, name: workspace.name))
                    },
                    onAttachToTask: { taskID in
                        guard canWrite else { return }
                        onAction(.attachWorkspaceToTask(taskID, workspace.id))
                    },
                    onDetachFromTask: { taskID in
                        guard canWrite else { return }
                        onAction(.detachWorkspaceFromTask(taskID, workspace.id))
                    },
                    onDelete: {
                        guard canWrite else { return }
                        onRequestDeletion(.workspace(workspace, project: group.project))
                    }
                )
            } ?? [],
            onDoubleClick: soloWorkspace.map { workspace in
                {
                    // The same gesture the Workspace row would have taken.
                    if canWrite {
                        onAction(.requestNewSession(workspace.id, token: UUID()))
                    } else {
                        onOpenWorkspace(host.workspaceReference(workspace.id))
                    }
                }
            }
        )
        .id(key)
    }

    private func hostWorkspaceRow(
        _ workspace: Workspace,
        project: Project,
        host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let key = workspaceKey(host, workspace.id)
        let summary = host.workspaceActivitySummaries[workspace.id]
        let enabled = host.connectionState.isConnected
        let canWrite = canMutate(host)
        let isProjectDeleting = canWrite && deletingProjectIDs.contains(project.id)
        let isDeleting = canWrite && deletingWorkspaceIDs.contains(workspace.id)
        // A task-linked workspace normally delegates navigation to its Task
        // row. Tasks are current-Host-only in this release, however, so a
        // background Host must leave this row selectable to provide an
        // activation path. Once it becomes current, the existing Task row
        // again owns navigation.
        let isSelectionDisabled = routesSelectionToTaskRow(workspace, in: host)
        let taskName = workspace.taskID.flatMap { taskID in
            host.tasks.first(where: { $0.id == taskID })?.name
        }
        let ownsLeaves = workspaceDisplayMode.isRich && !isSelectionDisabled
        let leafSessions = host.activeSessions(in: workspace.id)
        let isLeavesCollapsed = isWorkspaceLeavesCollapsed(workspace.id, in: host)
        return WarrenDesktopWorkspaceRow(
            workspace: workspace,
            semanticScope: "host.\(host.endpointID)",
            mark: summary?.mark,
            activeTabCount: summary?.activeTabCount ?? 0,
            isSelected: isWorkspaceRowSelected(workspace.id, in: host)
                && !isSelectionDisabled,
            containsSelection: workspaceRowContainsSelection(workspace.id, in: host)
                && !isSelectionDisabled,
            isPinned: workspace.pinned,
            isEditorMarked: editorActivity.isEditorMarked(
                workspace.id,
                hostId: host.endpointID
            ),
            onOpenEditor: host.endpointID == activeEndpointID
                ? onOpenEditor.map { open in { open(workspace.id) } }
                : nil,
            isDeleting: isDeleting,
            isInteractionDisabled: !enabled || isProjectDeleting || isDeleting,
            isMutationDisabled: !canWrite,
            isSelectionDisabled: isSelectionDisabled,
            // Same rule as the current-Host tree: a row that cannot be acted on
            // owns no leaves. The active endpoint's task-linked row routes to
            // its Task copy, which the Tasks section renders with the leaves.
            // The flag also gates click navigation, so it claims a leaf that is
            // actually drawn.
            showsSessionChildren: ownsLeaves
                && !isLeavesCollapsed
                && !leafSessions.isEmpty,
            leafDisclosure: ownsLeaves && !leafSessions.isEmpty
                ? WarrenDesktopLeafDisclosure(
                    isExpanded: !isLeavesCollapsed,
                    marks: leafSessions.map(\.activityMark),
                    toggle: { toggleWorkspaceLeaves(workspace.id, in: host) }
                )
                : nil,
            rowHeight: WarrenDesktopSidebarMetrics.worktreeRowHeight,
            taskName: taskName,
            taskID: workspace.taskID,
            tasks: host.tasks,
            onSelectTask: { taskID in
                guard canWrite else { return }
                onFocusTask(taskID)
            },
            onSelect: {
                onSelect(.workspace(host.workspaceReference(workspace.id)))
            },
            onDoubleClick: {
                // A background Host stays read-only, so its double-click keeps
                // opening instead of creating; see the current-Host tree.
                if workspaceDisplayMode.isRich, canWrite {
                    onAction(.requestNewSession(workspace.id, token: UUID()))
                } else {
                    onOpenWorkspace(host.workspaceReference(workspace.id))
                }
            },
            onRename: {
                guard canWrite else { return }
                onRequestRename(.workspace(workspace.id, name: workspace.name))
            },
            onTogglePin: {
                guard canWrite else { return }
                onAction(.setWorkspacePinned(workspace.id, !workspace.pinned))
            },
            onAttachToTask: { taskID in
                guard canWrite else { return }
                onAction(.attachWorkspaceToTask(taskID, workspace.id))
            },
            onDetachFromTask: { taskID in
                guard canWrite else { return }
                onAction(.detachWorkspaceFromTask(taskID, workspace.id))
            },
            onDelete: {
                guard canWrite else { return }
                onRequestDeletion(.workspace(workspace, project: project))
            }
        )
        .id(key)
    }

    /// Whether a Host's copy of this Workspace is context-only because its Task
    /// row owns navigation.
    ///
    /// A Task-linked Workspace on the active Host routes selection to the Task
    /// row, which the Tasks section renders with the Session leaves. A
    /// background Host keeps its own row as the activation path, so it keeps its
    /// leaves as well.
    private func routesSelectionToTaskRow(
        _ workspace: Workspace,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        workspace.taskID != nil && host.endpointID == activeEndpointID
    }

    private func canMutate(_ host: WarrenDesktopSidebarHostProjection) -> Bool {
        host.endpointID == activeEndpointID
            && host.connectionState.isConnected
    }

    private func projectContextMenuActions(
        _ group: WarrenDesktopProjectGroup,
        host: WarrenDesktopSidebarHostProjection
    ) -> [WarrenDesktopContextMenuAction] {
        guard canMutate(host), !deletingProjectIDs.contains(group.project.id) else {
            return []
        }
        let project = group.project
        return [
            .button(title: "New Workspace", action: {
                guard canMutate(host) else { return }
                onAction(.requestNewWorkspace(project.id))
            }),
            .button(title: isProjectExpanded(project.id, in: host) ? "Collapse Project" : "Expand Project", action: {
                guard canMutate(host) else { return }
                toggleProject(project.id, in: host)
            }),
            .button(title: project.pinned ? "Unpin Project" : "Pin Project", action: {
                guard canMutate(host) else { return }
                onAction(.setProjectPinned(project.id, !project.pinned))
            }),
            .button(title: "Rename Project", action: {
                guard canMutate(host) else { return }
                onRequestRename(.project(project.id, name: project.name))
            }),
            .button(title: "Import Existing Worktrees…", action: {
                guard canMutate(host) else { return }
                onAction(.requestProjectWorktreeImport(project.id))
            }),
            .button(title: "Configure Setup Script…", action: {
                guard canMutate(host) else { return }
                onAction(.requestProjectSetupScript(project.id))
            }),
            .button(
                title: project.autoImportGitWorktrees
                    ? "Disable Automatic Worktree Import"
                    : "Enable Automatic Worktree Import (No Confirmation)",
                action: {
                    guard canMutate(host) else { return }
                    onAction(.setProjectAutoImportGitWorktrees(
                        project.id,
                        !project.autoImportGitWorktrees
                    ))
                }
            ),
            .divider,
            .button(title: "Delete Project…", destructive: true, action: {
                guard canMutate(host) else { return }
                onRequestDeletion(.project(
                    project,
                    workspaceCount: group.workspaces.count
                ))
            }),
        ]
    }

    private func revealSelection(
        _ selection: WarrenDesktopSidebarResourceSelection?,
        in visibleHosts: [WarrenDesktopSidebarHostProjection]
    ) {
        guard let selection else { return }
        switch selection {
        case .project(let reference):
            guard let host = visibleHosts.first(where: { $0.endpointID == reference.endpointID }),
                  host.projectGroups.contains(where: { $0.project.id == reference.id }) else {
                return
            }
            reveal(
                projectKey(host, reference.id),
                in: reference.endpointID
            )
        case .workspace(let reference):
            guard let host = visibleHosts.first(where: { $0.endpointID == reference.endpointID }),
                  let group = host.projectGroups.first(where: {
                      $0.workspaces.contains(where: { $0.id == reference.id })
                  }) else {
                return
            }
            reveal(
                projectKey(host, group.project.id),
                in: reference.endpointID
            )
        }
    }

    /// The selected resource's project, keyed per Host.
    private func selectedProjectKey(
        _ selection: WarrenDesktopSidebarResourceSelection?,
        in visibleHosts: [WarrenDesktopSidebarHostProjection]
    ) -> (key: String, group: WarrenDesktopProjectGroup, host: WarrenDesktopSidebarHostProjection)? {
        let endpointID: String
        let match: (WarrenDesktopProjectGroup) -> Bool
        switch selection {
        case .project(let reference)?:
            endpointID = reference.endpointID
            match = { $0.project.id == reference.id }
        case .workspace(let reference)?:
            endpointID = reference.endpointID
            match = { $0.workspaces.contains { $0.id == reference.id } }
        case nil:
            return nil
        }
        guard let host = visibleHosts.first(where: { $0.endpointID == endpointID }),
              let group = host.projectGroups.first(where: match) else { return nil }
        return (projectKey(host, group.project.id), group, host)
    }

    /// Lifts a selected project out of the folded row; see the current-Host
    /// tree's `revealFoldedRows`.
    private func liftSelectedProject(
        _ selection: WarrenDesktopSidebarResourceSelection?,
        in visibleHosts: [WarrenDesktopSidebarHostProjection]
    ) {
        guard let selected = selectedProjectKey(selection, in: visibleHosts),
              !selected.group.project.pinned,
              !isProjectActive(selected.group, in: selected.host),
              !projectHold.contains(selected.key) else { return }
        withAnimation(WarrenMotion.selection(reduceMotion: reduceMotion)) {
            projectHold.lift(selected.key, now: Date())
        }
    }

    private var currentProjectActivity: WarrenDesktopProjectHold.Snapshot {
        var snapshot = WarrenDesktopProjectHold.Snapshot()
        for host in hosts {
            for group in host.projectGroups {
                let key = projectKey(host, group.project.id)
                snapshot.existing.insert(key)
                if isProjectActive(group, in: host) {
                    snapshot.active[key] = group.project.activeSince
                }
            }
        }
        return snapshot
    }

    private var projectHoldClock: WarrenDesktopProjectHoldClock {
        WarrenDesktopProjectHoldClock(
            nextExpiry: projectHold.nextExpiry,
            pointerInsideSidebar: pointerInsideSidebar,
            kept: Set([selectedProjectKey(selection, in: hosts)?.key].compactMap { $0 })
        )
    }

    private func reveal(_ projectKey: String, in endpointID: String) {
        if collapsedHostIDs.contains(endpointID) {
            collapsedHostIDs.remove(endpointID)
        }
        if collapsedProjectKeys.contains(projectKey) {
            collapsedProjectKeys.remove(projectKey)
        }
    }

    private func updateTintAssignments() {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        tintAllocator.update(
            endpointIDs: hosts.map(\.endpointID),
            paletteCount: tokens.hostForegroundTints.count
        )
    }

    private func visibleGroups(
        for host: WarrenDesktopSidebarHostProjection
    ) -> [WarrenDesktopProjectGroup] {
        guard showsActiveOnly else { return host.projectGroups }
        return host.projectGroups.compactMap { group in
            let workspaces = group.workspaces.filter {
                host.activeWorkspaceIDs.contains($0.id)
            }
            guard !workspaces.isEmpty else { return nil }
            return WarrenDesktopProjectGroup(project: group.project, workspaces: workspaces)
        }
    }

    private func scopedProjectGroups(
        for host: WarrenDesktopSidebarHostProjection
    ) -> [ScopedProjectGroup] {
        visibleGroups(for: host).map { group in
            ScopedProjectGroup(
                id: projectKey(host, group.project.id),
                group: group
            )
        }
    }

    private func scopedWorkspaces(
        _ workspaces: [Workspace],
        host: WarrenDesktopSidebarHostProjection
    ) -> [ScopedWorkspace] {
        workspaces.map { workspace in
            ScopedWorkspace(
                id: workspaceKey(host, workspace.id),
                workspace: workspace
            )
        }
    }

    private func emptyReason(
        for host: WarrenDesktopSidebarHostProjection
    ) -> WarrenDesktopSidebarEmptyReason? {
        switch host.connectionState {
        case .connecting, .reconnecting:
            // The skeleton stands in for the tree; a message would report the
            // same transient state the Host header's spinner already does.
            return nil
        case .failed, .disconnected:
            let error = host.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .hostUnavailable(
                isFailed: host.connectionState == .failed,
                detail: error.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            )
        case .attached:
            guard showsActiveOnly, !host.projectGroups.isEmpty else {
                return .noProjects(
                    canAddProject: canMutate(host),
                    hostName: host.title
                )
            }
            return .filteredByActiveOnly(
                hiddenWorkspaceCount: host.projectGroups.reduce(0) { total, group in
                    total + group.workspaces.reduce(0) { count, workspace in
                        count + (host.activeWorkspaceIDs.contains(workspace.id) ? 0 : 1)
                    }
                }
            )
        }
    }

    private func projectKey(
        _ host: WarrenDesktopSidebarHostProjection,
        _ projectID: ProjectID
    ) -> String {
        "host.\(host.endpointID).project.\(projectID.description)"
    }

    private func workspaceKey(
        _ host: WarrenDesktopSidebarHostProjection,
        _ workspaceID: WorkspaceID
    ) -> String {
        "host.\(host.endpointID).workspace.\(workspaceID.description)"
    }

    private func isWorkspaceLeavesCollapsed(
        _ workspaceID: WorkspaceID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        collapsedWorkspaceKeys.contains(workspaceKey(host, workspaceID))
    }

    private func toggleWorkspaceLeaves(
        _ workspaceID: WorkspaceID,
        in host: WarrenDesktopSidebarHostProjection
    ) {
        let key = workspaceKey(host, workspaceID)
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if collapsedWorkspaceKeys.contains(key) {
                collapsedWorkspaceKeys.remove(key)
            } else {
                collapsedWorkspaceKeys.insert(key)
            }
        }
    }

    private func isProjectExpanded(
        _ projectID: ProjectID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        !collapsedProjectKeys.contains(projectKey(host, projectID))
    }

    private func toggleProject(
        _ projectID: ProjectID,
        in host: WarrenDesktopSidebarHostProjection
    ) {
        let key = projectKey(host, projectID)
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if collapsedProjectKeys.contains(key) {
                collapsedProjectKeys.remove(key)
            } else {
                collapsedProjectKeys.insert(key)
            }
        }
    }

    private func toggleSingleHostProjects() {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            singleHostProjectsCollapsed.toggle()
        }
    }

    private func toggleAllProjects(
        in host: WarrenDesktopSidebarHostProjection,
        groups: [WarrenDesktopProjectGroup]
    ) {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            let keys = groups.map { projectKey(host, $0.project.id) }
            if !keys.contains(where: collapsedProjectKeys.contains) {
                collapsedProjectKeys.formUnion(keys)
            } else {
                collapsedProjectKeys.subtract(keys)
            }
        }
    }

    private func isHostExpanded(_ host: WarrenDesktopSidebarHostProjection) -> Bool {
        !collapsedHostIDs.contains(host.endpointID)
    }

    private func toggleHost(_ endpointID: String) {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if collapsedHostIDs.contains(endpointID) {
                collapsedHostIDs.remove(endpointID)
            } else {
                collapsedHostIDs.insert(endpointID)
            }
        }
    }

    private func isSelected(
        project projectID: ProjectID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        guard case .project(let reference) = selection else { return false }
        return reference.endpointID == host.endpointID && reference.id == projectID
    }

    private func isSelected(
        workspace workspaceID: WorkspaceID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        guard case .workspace(let reference) = selection else { return false }
        return reference.endpointID == host.endpointID && reference.id == workspaceID
    }

    private func isSelected(
        session: WarrenDesktopSession,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        guard host.endpointID == activeEndpointID, let selectedTabID else { return false }
        return session.tabID == selectedTabID
    }

    /// Whether the workspace row itself carries the selection fill.
    ///
    /// Opening a Session keeps its workspace selected, so both rows match. The
    /// leaf is the row the user clicked and the more specific answer, so it wins
    /// and the workspace states containment instead.
    private func isWorkspaceRowSelected(
        _ workspaceID: WorkspaceID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        guard isSelected(workspace: workspaceID, in: host) else { return false }
        // A folded row takes the fill back: the leaf that would carry it is
        // out of sight.
        guard workspaceDisplayMode.isRich,
              !isWorkspaceLeavesCollapsed(workspaceID, in: host)
        else { return true }
        return !host.activeSessions(in: workspaceID).contains {
            isSelected(session: $0, in: host)
        }
    }

    private func workspaceRowContainsSelection(
        _ workspaceID: WorkspaceID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        isSelected(workspace: workspaceID, in: host)
            && !isWorkspaceRowSelected(workspaceID, in: host)
    }

    private struct ScopedProjectGroup: Identifiable {
        let id: String
        let group: WarrenDesktopProjectGroup
    }

    private struct ScopedWorkspace: Identifiable {
        let id: String
        let workspace: Workspace
    }
}

enum WarrenDesktopSidebarHostsSectionPresentation {
    static func title(hostCount: Int, isHovered: Bool) -> String {
        isHovered ? "PROJECTS · \(hostCount)" : "PROJECTS · HOSTS"
    }

    static func accessibilityLabel(hostCount: Int) -> String {
        "Projects, \(hostCount) \(hostCount == 1 ? "host" : "hosts")"
    }
}

private struct WarrenDesktopSidebarHostsSectionHeader: View {
    let hostCount: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Text(WarrenDesktopSidebarHostsSectionPresentation.title(
            hostCount: hostCount,
            isHovered: isHovered
        ))
        .font(WarrenDesktopSidebarSectionHeader.titleFont)
        .tracking(WarrenDesktopSidebarSectionHeader.titleTracking)
        .foregroundStyle(tokens.treeQuietText)
        .lineLimit(1)
        // The count replaces the word in place; the two cross-fade.
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isHovered
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: WarrenDesktopSidebarMetrics.sectionHeaderHeight)
        // A Host heading shares the section labels' leading edge:
        // TASKS, PROJECTS, and every Host line up on one column.
        .padding(.leading, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .padding(.trailing, WarrenSpacing.compact)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            WarrenDesktopSidebarHostsSectionPresentation.accessibilityLabel(
                hostCount: hostCount
            )
        )
        .warrenSemanticElement(
            id: "sidebar.projects.hosts",
            role: .group,
            label: "Projects",
            value: "\(hostCount) \(hostCount == 1 ? "host" : "hosts")"
        )
    }
}

/// What a Host heading says about the subtree it can hide.
struct WarrenDesktopSidebarHostSummary: Equatable {
    let projectCount: Int
    /// The most actionable mark anywhere on the Host, so collapsing a Host
    /// never hides an Agent that is waiting on someone. An exited Session asks
    /// for nothing and is left out.
    let mark: WarrenActivityMark?

    init(_ host: WarrenDesktopSidebarHostProjection) {
        projectCount = host.projectGroups.count
        mark = host.workspaceActivitySummaries.values
            .compactMap(\.mark)
            .filter { $0 != .exited }
            .max()
    }

    var countLabel: String {
        "\(projectCount) \(projectCount == 1 ? "project" : "projects")"
    }
}

private struct WarrenDesktopSidebarHostHeader: View {
    let host: WarrenDesktopSidebarHostProjection
    let isExpanded: Bool
    let summary: WarrenDesktopSidebarHostSummary
    /// The distinct Session states under this Host, most urgent first, drawn as
    /// the heading's trailing dots.
    let marks: [WarrenActivityMark]
    /// The Host's pale identity hue. It colours only the foreground here, never
    /// a fill.
    let tint: Color
    /// A connected Host this window cannot write to and that holds nothing: the
    /// row says so and has nothing to disclose.
    let isEmpty: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    /// Adds a Project to this Host, or `nil` when this window cannot.
    var onAddProject: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isToggleFocused: Bool
    @FocusState private var isRetryFocused: Bool
    @FocusState private var isAddFocused: Bool

    private var accessibilityValue: String {
        let count = summary.countLabel
        if isEmpty { return "No projects" }
        return isExpanded ? "Expanded, \(count)" : "Collapsed, \(count)"
    }

    /// The name is written once. A Host is known by the name it reports, and
    /// the alias that reached it (`Local`, an SSH target, an address) lives in
    /// the tooltip, so two aliases for one machine never read as two names.
    private var displayName: String {
        host.hostName ?? host.endpointLabel
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let isEngaged = isHovered || isToggleFocused
        HStack(spacing: WarrenSpacing.small) {
            if isEmpty {
                // Nothing to disclose, so the row is not a control.
                rowContent(tokens: tokens, isEngaged: isEngaged)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(host.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Host \(host.title)")
                    .accessibilityValue(accessibilityValue)
                    .warrenSemanticElement(
                        id: "host.\(host.endpointID).empty",
                        role: .group,
                        label: "Host \(host.title)",
                        value: accessibilityValue
                    )
            } else {
                Button(action: onToggle) {
                    rowContent(
                        tokens: tokens,
                        isEngaged: isEngaged,
                        includesChevron: onAddProject == nil
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .focused($isToggleFocused)
                .help(host.title)
                .accessibilityLabel("Host \(host.title)")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Show or hide this Host's projects and workspaces")
                .warrenSemanticElement(
                    id: "host.\(host.endpointID).toggle",
                    role: .button,
                    label: "Host \(host.title)",
                    value: accessibilityValue,
                    action: onToggle
                )
            }

            if let onAddProject {
                // The add entry sits before the chevron, so the chevron
                // leaves the toggle's label and toggles on its own.
                addProjectButton(onAddProject, tokens: tokens)
                if !isEmpty {
                    Button(action: onToggle) {
                        chevron(tokens: tokens, isEngaged: isEngaged)
                            .frame(maxHeight: .infinity)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            connectionAccessory(tokens: tokens)
        }
        .frame(height: WarrenLayoutMetrics.sidebarHostHeaderHeight)
        .padding(.leading, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }

    /// The one shape no other row uses: a hollow tile, the hostname, the rule
    /// that runs to the trailing edge, then the Session dots and the disclosure
    /// chevron. A Host reads as a labelled rule before a word of it is read.
    private func rowContent(
        tokens: WarrenColorTokens,
        isEngaged: Bool,
        includesChevron: Bool = true
    ) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            hostTile(tokens: tokens)
            Text(displayName)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if isEmpty {
                Text("no projects")
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.sidebarMetaText)
                    .lineLimit(1)
                    .fixedSize()
            }
            rule(isEngaged: isEngaged)
            if !marks.isEmpty {
                HStack(spacing: WarrenSpacing.xxs) {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        WarrenDesktopActivityIndicator(mark: mark, dotSize: 6)
                    }
                }
                .accessibilityHidden(true)
            }
            if !isEmpty, includesChevron {
                chevron(tokens: tokens, isEngaged: isEngaged)
            }
        }
    }

    /// The tree's own disclosure chevron, so a Host folds with the same
    /// glyph and turn as every other collapsible row.
    private func chevron(tokens: WarrenColorTokens, isEngaged: Bool) -> some View {
        WarrenDesktopTreeChevron(
            isExpanded: isExpanded,
            color: isEngaged ? tokens.sidebarMetaTextActive : tokens.sidebarMetaText
        )
    }

    /// The Host's tile: a hollow square ringed in the Host's own hue with its
    /// lowercase initial in the monospaced face, and a link dot on the corner.
    /// A project wears a filled colour square with a bold capital, so the two
    /// never read as one another.
    private func hostTile(tokens: WarrenColorTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Text(String(displayName.prefix(1)).lowercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 16, height: 16)
            .background {
                shape.strokeBorder(tint.opacity(0.55), lineWidth: WarrenSpacing.hairline)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(WarrenDesktopHostReachability(host.connectionState).color(tokens))
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle().strokeBorder(tokens.workbenchCardFill, lineWidth: 1.5)
                    }
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
    }

    /// The title rule. It reaches the trailing cluster instead of stopping at
    /// the name, which is what makes the heading read as a divider.
    private func rule(isEngaged: Bool) -> some View {
        Rectangle()
            .fill(tint.opacity(isEngaged ? 0.40 : 0.22))
            .frame(height: WarrenSpacing.hairline)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// The Host's add entry, just before its disclosure chevron and sized to
    /// the heading so the row keeps one height.
    private func addProjectButton(
        _ action: @escaping () -> Void,
        tokens: WarrenColorTokens
    ) -> some View {
        let height = WarrenLayoutMetrics.sidebarHostHeaderHeight
        return Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: height, height: height)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isAddFocused))
        .foregroundStyle(tokens.sidebarMetaText)
        .focused($isAddFocused)
        .disabled(!host.connectionState.isConnected)
        .warrenTooltip("Add Project…")
        .accessibilityLabel("Add Project to \(host.title)")
        .warrenSemanticElement(
            id: "host.\(host.endpointID).add-project",
            role: .button,
            label: "Add Project",
            isEnabled: host.connectionState.isConnected,
            action: action
        )
    }

    @ViewBuilder
    private func connectionAccessory(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(host.connectionState)
        switch host.connectionState {
        case .attached:
            EmptyView()
        case .connecting, .reconnecting:
            WarrenBrailleSpinner(size: 10, accessibilityLabel: presentation.label)
        case .failed, .disconnected:
            Text(presentation.label)
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(connectionColor(presentation, tokens: tokens))
                .lineLimit(1)
                .accessibilityLabel(presentation.label)
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isRetryFocused))
            .focused($isRetryFocused)
            .warrenTooltip("Retry \(host.title)")
            .accessibilityLabel("Retry \(host.title)")
        }
    }

    private func connectionColor(
        _ presentation: WarrenDesktopConnectionPresentation,
        tokens: WarrenColorTokens
    ) -> Color {
        switch presentation.tone {
        case .success: return tokens.success
        case .info: return tokens.info
        case .warning: return tokens.warning
        case .destructive: return tokens.destructive
        }
    }
}
