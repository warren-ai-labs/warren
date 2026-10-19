import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

enum WarrenDesktopDeletionRequest {
    case task(WarrenTask)
    case workspace(Workspace, project: Project?)
    case project(Project, workspaceCount: Int)
}

struct WarrenDesktopSidebarRows: View {
    let taskGroups: [WarrenDesktopTaskGroup]
    let groups: [WarrenDesktopProjectGroup]
    let workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    let activeWorkspaceIDs: Set<WorkspaceID>
    /// Workspaces whose activity comes from a local editor marker rather than a
    /// running Session, so the row can say which it is (RFC 0021 §7).
    let editorMarkedWorkspaceIDs: Set<WorkspaceID>
    /// Live Sessions per Workspace, used as the tree's leaves in rich mode.
    let activeSessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]]
    let workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode
    let showsTasks: Bool
    /// Controls whether the current-host Projects/Workspaces tree is shown.
    /// Multi-host mode reuses this view for the current-host-only Tasks section
    /// and renders the scoped project tree separately.
    let showsProjects: Bool
    @Binding var tree: WarrenDesktopSidebarTreeState
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let isInteractionDisabled: Bool
    /// The Host's connection, which decides what an empty roster means.
    let connectionState: WarrenDesktopConnectionState
    let onAddProject: () -> Void
    let onRequestTaskCreate: () -> Void
    let onFocusTask: (TaskID) -> Void
    let onAction: (WarrenDesktopAction) -> Void
    /// Drops a Session onto a pane. `nil` when no pane can accept one, which is
    /// every sidebar that is not mounted beside an arrangement.
    let onSplitDropSession: ((String, String, SplitDropTarget) -> Void)?
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    /// Reveals a marked Workspace's editor. Supplied only by the current Host's
    /// tree, because the marker is stored per Endpoint.
    let onOpenEditor: (WorkspaceID) -> Void

    init(
        taskGroups: [WarrenDesktopTaskGroup],
        groups: [WarrenDesktopProjectGroup],
        workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary],
        activeWorkspaceIDs: Set<WorkspaceID> = [],
        editorMarkedWorkspaceIDs: Set<WorkspaceID> = [],
        activeSessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]] = [:],
        workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact,
        showsTasks: Bool = true,
        showsProjects: Bool = true,
        tree: Binding<WarrenDesktopSidebarTreeState>,
        selection: WarrenDesktopSidebarSelection?,
        selectedTabID: String? = nil,
        deletingProjectIDs: Set<ProjectID>,
        deletingWorkspaceIDs: Set<WorkspaceID>,
        endpointCapabilities: WarrenDesktopEndpointCapabilities,
        isInteractionDisabled: Bool,
        connectionState: WarrenDesktopConnectionState = .attached,
        onAddProject: @escaping () -> Void,
        onRequestTaskCreate: @escaping () -> Void,
        onFocusTask: @escaping (TaskID) -> Void,
        onAction: @escaping (WarrenDesktopAction) -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onRequestDeletion: @escaping (WarrenDesktopDeletionRequest) -> Void,
        onOpenEditor: @escaping (WorkspaceID) -> Void = { _ in },
        onSplitDropSession: ((String, String, SplitDropTarget) -> Void)? = nil
    ) {
        self.taskGroups = taskGroups
        self.groups = groups
        self.workspaceActivitySummaries = workspaceActivitySummaries
        self.activeWorkspaceIDs = activeWorkspaceIDs
        self.editorMarkedWorkspaceIDs = editorMarkedWorkspaceIDs
        self.activeSessionsByWorkspaceID = activeSessionsByWorkspaceID
        self.workspaceDisplayMode = workspaceDisplayMode
        self.showsTasks = showsTasks
        self.showsProjects = showsProjects
        self._tree = tree
        self.selection = selection
        self.selectedTabID = selectedTabID
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.endpointCapabilities = endpointCapabilities
        self.isInteractionDisabled = isInteractionDisabled
        self.connectionState = connectionState
        self.onAddProject = onAddProject
        self.onRequestTaskCreate = onRequestTaskCreate
        self.onFocusTask = onFocusTask
        self.onAction = onAction
        self.onOpenEditor = onOpenEditor
        self.onSplitDropSession = onSplitDropSession
        self.onRequestRename = onRequestRename
        self.onRequestDeletion = onRequestDeletion
    }

    @State private var dragSession = WarrenDesktopSidebarDragSession()
    /// Ephemeral presentation state; persisted expansion preferences remain untouched.
    @State private var dragAutoCollapse: WarrenSidebarDragAutoCollapse?
    @State private var dragSourceRowID: String?
    @State private var isDragMeasurementEnabled = false
    @State private var previousGroups: [WarrenDesktopProjectGroup] = []
    @State private var previousTaskGroups: [WarrenDesktopTaskGroup] = []
    /// Projects held in the active band; see `WarrenDesktopProjectHold`.
    @State private var projectHold = WarrenDesktopProjectHold()
    @State private var projectActivity = WarrenDesktopProjectHold.Snapshot()
    /// Carries a project's row between the folded list and the active band, so
    /// a lifted project is seen rising into its place rather than reappearing.
    @Namespace private var projectRowNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.warrenPointerInsideSidebar) private var pointerInsideSidebar

    var body: some View {
        // This list is bounded by the sidebar scroll view and also hosts
        // optional drag-frame measurement. Eager layout keeps geometry
        // feedback out of LazyVStack's placement cache during navigation.
        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sectionSpacing) {
            if showsTasks {
                tasksSection
            }
            if showsProjects {
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sectionHeaderSpacing) {
                    projectsSectionHeader
                    if groups.isEmpty, connectionState.isSettling {
                        WarrenDesktopSidebarSkeleton()
                            .transition(.opacity)
                    } else if groups.isEmpty, !connectionState.isConnected {
                        WarrenDesktopSidebarEmptyState(
                            reason: .hostUnavailable(
                                isFailed: connectionState == .failed,
                                detail: nil
                            )
                        )
                    } else if groups.isEmpty {
                        noProjectsMessage
                    } else if tree.showsActiveOnly && visibleProjectGroups.isEmpty {
                        noActiveWorkspacesMessage
                    }
                    if !tree.projectsCollapsed || hasPendingProjectDeletion {
                        let bands = projectBands
                        // Inactive projects fold into one row at the end of
                        // the section.
                        let listed = bands.listed
                        let showsInactiveRow = !bands.inactive.isEmpty
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(listed) { group in
                                let soloWorkspace = soloWorkspace(of: group)
                                let split = workspaceSplit(of: group)
                                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.groupContentSpacing) {
                                    projectRow(for: group, soloWorkspace: soloWorkspace)
                                        .matchedGeometryEffect(
                                            id: group.project.id,
                                            in: projectRowNamespace
                                        )
                                    if let soloWorkspace, isProjectExpanded(group.project.id) {
                                        // One worktree is no choice, so the
                                        // project holds its Sessions directly.
                                        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sessionSpacing) {
                                            workspaceSessionRows(
                                                for: soloWorkspace,
                                                project: group.project,
                                                semanticScope: "project-list"
                                            )
                                        }
                                    } else if soloWorkspace == nil, split.hasRows,
                                        isProjectExpanded(group.project.id)
                                        || hasDeletingWorkspace(in: group.project.id) {
                                        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.worktreeSpacing) {
                                            ForEach(split.live) { workspace in
                                                WarrenDesktopSessionLeafGroup(
                                                    leafCount: showsSessionLeaves(
                                                        workspace,
                                                        semanticScope: "project-list"
                                                    ) ? activeSessions(in: workspace.id).count : 0
                                                ) {
                                                    workspaceRow(
                                                        workspace,
                                                        in: group,
                                                        taskName: taskName(for: workspace)
                                                    )
                                                } leaves: {
                                                    workspaceSessionRows(
                                                        for: workspace,
                                                        project: group.project,
                                                        semanticScope: "project-list"
                                                    )
                                                }
                                            }
                                            if split.showsIdleRow {
                                                idleWorkspaceRows(split.idle, in: group)
                                            }
                                        }
                                    }
                                }
                                .warrenTreeGroupSeparator(
                                    of: group,
                                    in: listed,
                                    isFollowed: showsInactiveRow
                                ) {
                                    isProjectFolded($0)
                                }
                            }
                            if showsInactiveRow {
                                inactiveProjectRows(bands.inactive)
                                    .warrenTreeGroupSeparator(
                                        isFirst: listed.isEmpty,
                                        isFolded: !tree.inactiveProjectsExpanded,
                                        followsFolded: listed.last.map(isProjectFolded) ?? false,
                                        isLast: true
                                    )
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .coordinateSpace(name: WarrenSidebarRowsDragCoordinateSpace.name)
        .overlayPreferenceValue(WarrenSidebarRowDragFramesKey.self) { frames in
            let availableFrames = frames.filter { !isDragDisabled($0.value.info) }
            WarrenDesktopSidebarDragOverlay(
                session: dragSession,
                rows: isDragMeasurementEnabled ? availableFrames : [:],
                onDropProject: { payload, beforeProjectID in
                    dropProject(payload, before: beforeProjectID)
                },
                onDropWorkspace: { payload, beforeWorkspaceID, projectID in
                    dropWorkspace(
                        payload,
                        before: beforeWorkspaceID,
                        inProject: projectID
                    )
                },
                onDragAutoCollapseChanged: setDragAutoCollapse,
                onDragSourceChanged: { id in
                    dragSourceRowID = id
                },
                onMeasurementNeededChanged: { isNeeded in
                    setDragMeasurementEnabled(isNeeded)
                }
            )
        }
        .onChange(of: selection) { newSelection in
            revealFoldedRows(for: newSelection)
            guard case .workspace(let workspaceID)? = newSelection,
                  let workspace = groups
                    .flatMap(\.workspaces)
                    .first(where: { $0.id == workspaceID })
            else { return }
            withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.collapsedProjectIDs.remove(workspace.projectID)
                if let taskID = workspace.taskID {
                    tree.collapsedTaskIDs.remove(taskID)
                }
            }
        }
        .onAppear {
            previousGroups = groups
            previousTaskGroups = taskGroups
            projectActivity = currentProjectActivity
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
        .onChange(of: groups) { newGroups in
            let oldGroups = previousGroups
            previousGroups = newGroups
            var grownProjectIDs: Set<ProjectID> = []
            let allProjectIDs = Set(oldGroups.map(\.project.id) + newGroups.map(\.project.id))
            for projectID in allProjectIDs {
                let oldCount = workspaceCount(for: projectID, in: oldGroups)
                let newCount = workspaceCount(for: projectID, in: newGroups)
                if newCount > oldCount {
                    grownProjectIDs.insert(projectID)
                }
            }
            guard !grownProjectIDs.isEmpty else { return }
            withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.collapsedProjectIDs.subtract(grownProjectIDs)
                // If a workspace was created under a task, also expand that task.
                for projectID in grownProjectIDs {
                    if let newWorkspace = newGroups.first(where: { $0.project.id == projectID })?.workspaces.last,
                       let taskID = newWorkspace.taskID {
                        tree.collapsedTaskIDs.remove(taskID)
                        tree.tasksCollapsed = false
                    }
                }
            }
        }
        .onChange(of: taskGroups) { newGroups in
            let oldGroups = previousTaskGroups
            previousTaskGroups = newGroups
            var grownTaskIDs: Set<TaskID> = []
            let allTaskIDs = Set(oldGroups.map(\.task.id) + newGroups.map(\.task.id))
            for taskID in allTaskIDs {
                let oldCount = oldGroups.first(where: { $0.task.id == taskID })?.workspaces.count ?? 0
                let newCount = newGroups.first(where: { $0.task.id == taskID })?.workspaces.count ?? 0
                if newCount > oldCount {
                    grownTaskIDs.insert(taskID)
                }
                // New task inserted
                if oldGroups.first(where: { $0.task.id == taskID }) == nil,
                   newGroups.first(where: { $0.task.id == taskID }) != nil {
                    grownTaskIDs.insert(taskID)
                }
            }
            guard !grownTaskIDs.isEmpty else { return }
            withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.collapsedTaskIDs.subtract(grownTaskIDs)
                tree.tasksCollapsed = false
            }
        }
        .onChange(of: tree.showsActiveOnly) { showsActiveOnly in
            if showsActiveOnly {
                revealProjects(Self.projectIDsToReveal(
                    filteringToActiveOnly: true,
                    in: groups,
                    activeWorkspaceIDs: activeWorkspaceIDs
                ))
            }
        }
        .onChange(of: workspaceDisplayMode) { mode in
            // Turning the Sessions on has no visible effect while the projects
            // that own them are closed, so the control appears to do nothing.
            // Open the ones that have Sessions to show, exactly as the
            // active-only filter opens the ones that survive it.
            if mode.isRich {
                revealProjects(Self.projectIDsToReveal(
                    filteringToActiveOnly: false,
                    in: groups,
                    activeWorkspaceIDs: activeWorkspaceIDs
                ))
            }
        }
    }

    /// Opens the folded row a selection would otherwise be hidden in: the
    /// inactive-projects row for a project in it, and a project's idle row
    /// for a worktree in it.
    private func revealFoldedRows(for selection: WarrenDesktopSidebarSelection?) {
        let projectID: ProjectID?
        var idleWorkspace: Workspace?
        switch selection {
        case .project(let id):
            projectID = id
        case .workspace(let workspaceID):
            let workspace = groups.flatMap(\.workspaces).first { $0.id == workspaceID }
            projectID = workspace?.projectID
            if let workspace, !isWorkspaceLive(workspace) {
                idleWorkspace = workspace
            }
        case nil:
            projectID = nil
        }
        guard let projectID,
              let group = groups.first(where: { $0.project.id == projectID })
        else { return }
        // A project in the folded row is lifted into the active band instead
        // of the row being opened around it.
        let lifts = !group.project.pinned && !isProjectActive(group)
            && !projectHold.contains(projectID.description)
        let opensIdle = idleWorkspace.map { workspace in
            !tree.expandedIdleWorkspaceProjectIDs.contains(projectID)
                && projectListWorkspaces(of: group).contains { $0.id == workspace.id }
        } ?? false
        if lifts {
            // Slow enough to read as travel: the row rises out of the folded
            // list into its place rather than blinking there.
            withAnimation(WarrenMotion.selection(reduceMotion: reduceMotion)) {
                projectHold.lift(projectID.description, now: Date())
            }
        }
        guard opensIdle else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.expandedIdleWorkspaceProjectIDs.insert(projectID)
        }
    }

    /// Which projects a state change should open.
    ///
    /// The active-only filter has already dropped every workspace it hides, so
    /// whatever remains is worth opening. Turning on the Sessions is narrower:
    /// only the projects that actually own a live Session gain a row, so opening
    /// the rest would just add empty depth to the rail.
    static func projectIDsToReveal(
        filteringToActiveOnly: Bool,
        in groups: [WarrenDesktopProjectGroup],
        activeWorkspaceIDs: Set<WorkspaceID>
    ) -> Set<ProjectID> {
        if filteringToActiveOnly {
            return Set(groups.map(\.project.id))
        }
        return Set(
            groups
                .filter { group in
                    group.workspaces.contains { activeWorkspaceIDs.contains($0.id) }
                }
                .map(\.project.id)
        )
    }

    private func revealProjects(_ projectIDs: Set<ProjectID>) {
        guard !projectIDs.isEmpty else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.collapsedProjectIDs.subtract(projectIDs)
            tree.projectsCollapsed = false
        }
    }

    private var projectsSectionHeader: some View {
        let allProjectsExpanded = areAllProjectsExpanded
        return WarrenDesktopSidebarSectionHeader(
            title: "Projects",
            disclosureExpanded: !tree.projectsCollapsed,
            actionImage: "plus",
            actionLabel: "Add Project…",
            actionVisible: endpointCapabilities.canAddProject,
            actionEnabled: !isInteractionDisabled,
            onToggle: toggleProjects,
            onAction: onAddProject,
            additionalActions: [
                WarrenDesktopSidebarSectionAction(
                    id: "toggle-all-projects",
                    image: allProjectsExpanded
                        ? "rectangle.compress.vertical"
                        : "rectangle.expand.vertical",
                    label: allProjectsExpanded
                        ? "Collapse all projects"
                        : "Expand all projects",
                    isEnabled: !isInteractionDisabled && !groups.isEmpty,
                    action: toggleAllProjects
                ),
            ],
            foldMarks: visibleProjectGroups
                .flatMap(\.workspaces)
                .flatMap { activeSessions(in: $0.id) }
                .map(\.activityMark)
        )
    }
    private var noProjectsMessage: some View {
        WarrenDesktopSidebarEmptyState(
            reason: .noProjects(
                canAddProject: endpointCapabilities.canAddProject,
                hostName: nil
            ),
            onAddProject: endpointCapabilities.canAddProject ? onAddProject : nil
        )
    }

    private var noActiveWorkspacesMessage: some View {
        let hiddenWorkspaceCount = groups.reduce(0) { total, group in
            total + group.workspaces.reduce(0) { count, workspace in
                count + (activeWorkspaceIDs.contains(workspace.id) ? 0 : 1)
            }
        }
        return WarrenDesktopSidebarEmptyState(
            reason: .filteredByActiveOnly(hiddenWorkspaceCount: hiddenWorkspaceCount),
            onShowAll: {
                withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                    tree.showsActiveOnly = false
                }
            }
        )
    }

    private func isSessionSelected(
        _ session: WarrenDesktopSession
    ) -> Bool {
        guard let selectedTabID, session.tabID == selectedTabID else { return false }
        switch selection {
        case .workspace(let workspaceID):
            return session.workspaceID == workspaceID
        case .project, nil:
            return false
        }
    }

    /// Whether a workspace's Session leaves belong to the copy rendered in
    /// `semanticScope`.
    ///
    /// Leaves follow navigation: a Task-linked workspace routes selection to its
    /// Task copy, so the Projects copy stays context-only. The row and both call
    /// sites ask this one question, so the leaf count and the leaf rows cannot
    /// disagree.
    private var showsSessionRows: Bool {
        workspaceDisplayMode.isRich
    }
    private func ownsSessionLeaves(
        _ workspace: Workspace,
        semanticScope: String
    ) -> Bool {
        showsSessionRows && !routesSelectionToTaskRow(workspace, semanticScope: semanticScope)
    }

    /// Whether a workspace's leaves are listed in this copy right now: it owns
    /// them and the user has not folded them away.
    private func showsSessionLeaves(
        _ workspace: Workspace,
        semanticScope: String
    ) -> Bool {
        ownsSessionLeaves(workspace, semanticScope: semanticScope)
            && !tree.collapsedWorkspaceIDs.contains(workspace.id)
    }

    private func toggleWorkspaceLeaves(_ workspaceID: WorkspaceID) {
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.collapsedWorkspaceIDs.contains(workspaceID) {
                tree.collapsedWorkspaceIDs.remove(workspaceID)
            } else {
                tree.collapsedWorkspaceIDs.insert(workspaceID)
            }
        }
    }

    /// The Workspaces a project lists. One that belongs to a Task the tree
    /// shows is listed under that Task alone, so it is not drawn twice.
    private func projectListWorkspaces(
        of group: WarrenDesktopProjectGroup
    ) -> [Workspace] {
        guard showsTasks else { return group.workspaces }
        let taskIDs = Set(taskGroups.map(\.task.id))
        return group.workspaces.filter { workspace in
            guard let taskID = workspace.taskID else { return true }
            return !taskIDs.contains(taskID)
        }
    }

    /// Whether a worktree keeps its own row rather than folding into its
    /// project's idle row: it has a Session, or its row is the only place
    /// something about it shows (a deletion in progress, an editor marker).
    private func isWorkspaceLive(_ workspace: Workspace) -> Bool {
        activeWorkspaceIDs.contains(workspace.id)
            || !activeSessions(in: workspace.id).isEmpty
            || deletingWorkspaceIDs.contains(workspace.id)
            || editorMarkedWorkspaceIDs.contains(workspace.id)
    }

    /// A project's listed worktrees, split.
    private func workspaceSplit(of group: WarrenDesktopProjectGroup) -> WarrenDesktopWorkspaceSplit {
        let listed = projectListWorkspaces(of: group)
        return WarrenDesktopWorkspaceSplit(listed, isLive: isWorkspaceLive)
    }

    /// Whether a project belongs to the active band. Every one of its
    /// worktrees counts, including those listed under a Task, and a project
    /// mid-deletion stays where its progress can be seen.
    private func isProjectActive(_ group: WarrenDesktopProjectGroup) -> Bool {
        deletingProjectIDs.contains(group.project.id)
            || group.workspaces.contains(where: isWorkspaceLive)
    }

    private var projectBands: WarrenDesktopProjectBands<WarrenDesktopProjectGroup> {
        WarrenDesktopProjectBands(
            visibleProjectGroups,
            project: \.project,
            isActive: { isProjectActive($0) || projectHold.contains($0.project.id.description) },
            lastActiveAt: { WarrenDesktopActivityAge.lastActiveAt(of: $0.workspaces) },
            activeSince: {
                projectHold.activeSince($0.project.id.description) ?? $0.project.activeSince
            }
        )
    }

    private var currentProjectActivity: WarrenDesktopProjectHold.Snapshot {
        var snapshot = WarrenDesktopProjectHold.Snapshot()
        for group in groups {
            let key = group.project.id.description
            snapshot.existing.insert(key)
            if isProjectActive(group) {
                snapshot.active[key] = group.project.activeSince
            }
        }
        return snapshot
    }

    private var projectHoldClock: WarrenDesktopProjectHoldClock {
        WarrenDesktopProjectHoldClock(
            nextExpiry: projectHold.nextExpiry,
            pointerInsideSidebar: pointerInsideSidebar,
            kept: Set([selectedProjectID?.description].compactMap { $0 })
        )
    }

    /// The idle-worktrees row at the end of a project, and its list.
    private func idleWorkspaceRows(
        _ workspaces: [Workspace],
        in group: WarrenDesktopProjectGroup
    ) -> some View {
        let projectID = group.project.id
        let isExpanded = tree.expandedIdleWorkspaceProjectIDs.contains(projectID)
        return VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sessionSpacing) {
            WarrenDesktopFoldedCountRow(
                count: workspaces.count,
                singular: "idle worktree",
                plural: "idle worktrees",
                height: WarrenDesktopSidebarMetrics.worktreeRowHeight,
                isExpanded: isExpanded,
                semanticID: "project-idle-worktrees.\(projectID.description)",
                isEnabled: !isInteractionDisabled,
                onToggle: { toggleIdleWorkspaces(projectID) }
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(workspaces) { workspace in
                        let isProjectDeleting = deletingProjectIDs.contains(projectID)
                        let routesToTask = routesSelectionToTaskRow(workspace, semanticScope: "project-list")
                        WarrenDesktopIdleWorktreeRow(
                            workspace: workspace,
                            semanticScope: "project-list",
                            isSelected: selection == .workspace(workspace.id) && !routesToTask,
                            isEnabled: !isInteractionDisabled && !isProjectDeleting && !routesToTask,
                            contextMenuActions: workspaceContextMenuActions(workspace, project: group.project),
                            onSelect: { select(.workspace(workspace.id)) },
                            onDoubleClick: {
                                onAction(workspaceDisplayMode.isRich
                                    ? .requestNewSession(workspace.id)
                                    : .openWorkspace(workspace.id))
                            }
                        )
                        .id("workspace.project-list.\(workspace.id.description)")
                    }
                }
            }
        }
    }

    /// The inactive-projects row at the end of the section, and its list.
    private func inactiveProjectRows(_ inactive: [WarrenDesktopProjectGroup]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopFoldedCountRow(
                count: inactive.count,
                singular: "inactive project",
                plural: "inactive projects",
                height: WarrenDesktopSidebarMetrics.inactiveProjectsRowHeight,
                isExpanded: tree.inactiveProjectsExpanded,
                semanticID: "projects-inactive",
                isEnabled: !isInteractionDisabled,
                onToggle: toggleInactiveProjects
            )
            if tree.inactiveProjectsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(inactive) { group in
                        WarrenDesktopInactiveProjectRow(
                            project: group.project,
                            lastActiveAt: WarrenDesktopActivityAge.lastActiveAt(of: group.workspaces),
                            semanticID: "project.\(group.project.id.description)",
                            isSelected: selectedProjectID == group.project.id,
                            isEnabled: !isInteractionDisabled,
                            contextMenuActions: projectContextMenuActions(group),
                            onSelect: { select(.project(group.project.id)) }
                        )
                        .matchedGeometryEffect(id: group.project.id, in: projectRowNamespace)
                        .id("project.\(group.project.id.description)")
                    }
                }
                .padding(.top, WarrenDesktopSidebarMetrics.inactiveProjectListSpacing)
            }
        }
    }

    private func projectContextMenuActions(
        _ group: WarrenDesktopProjectGroup
    ) -> [WarrenDesktopContextMenuAction] {
        WarrenDesktopProjectRow.contextMenuActions(
            project: group.project,
            isPinned: group.project.pinned,
            onImportWorktrees: { onAction(.requestProjectWorktreeImport(group.project.id)) },
            onConfigureSetupScript: { onAction(.requestProjectSetupScript(group.project.id)) },
            onToggleAutoImportWorktrees: {
                onAction(.setProjectAutoImportGitWorktrees(
                    group.project.id,
                    !group.project.autoImportGitWorktrees
                ))
            },
            onRename: { onRequestRename(.project(group.project.id, name: group.project.name)) },
            onTogglePin: { onAction(.setProjectPinned(group.project.id, !group.project.pinned)) },
            onDelete: {
                onRequestDeletion(.project(group.project, workspaceCount: group.workspaces.count))
            }
        )
    }

    private func workspaceContextMenuActions(
        _ workspace: Workspace,
        project: Project
    ) -> [WarrenDesktopContextMenuAction] {
        WarrenDesktopWorkspaceRow.contextMenuActions(
            workspace: workspace,
            isPinned: workspace.pinned,
            tasks: taskGroups.map(\.task),
            onTogglePin: { onAction(.setWorkspacePinned(workspace.id, !workspace.pinned)) },
            onRename: { onRequestRename(.workspace(workspace.id, name: workspace.name)) },
            onAttachToTask: { taskID in onAction(.attachWorkspaceToTask(taskID, workspace.id)) },
            onDetachFromTask: { taskID in onAction(.detachWorkspaceFromTask(taskID, workspace.id)) },
            onDelete: { onRequestDeletion(.workspace(workspace, project: project)) }
        )
    }

    private func toggleIdleWorkspaces(_ projectID: ProjectID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.expandedIdleWorkspaceProjectIDs.contains(projectID) {
                tree.expandedIdleWorkspaceProjectIDs.remove(projectID)
            } else {
                tree.expandedIdleWorkspaceProjectIDs.insert(projectID)
            }
        }
    }

    private func toggleInactiveProjects() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.inactiveProjectsExpanded.toggle()
        }
    }

    /// The project's only listed Workspace, when the project holds that
    /// Workspace's Sessions directly instead of drawing a row for it.
    ///
    /// A Workspace keeps its row whenever the row is the only place something
    /// shows: no Sessions (the row is then what selects it), a deletion in
    /// progress, or an open editor marker.
    private func soloWorkspace(of group: WarrenDesktopProjectGroup) -> Workspace? {
        let listed = projectListWorkspaces(of: group)
        guard listed.count == 1, let workspace = listed.first,
              ownsSessionLeaves(workspace, semanticScope: "project-list"),
              !activeSessions(in: workspace.id).isEmpty,
              !deletingWorkspaceIDs.contains(workspace.id),
              !editorMarkedWorkspaceIDs.contains(workspace.id)
        else { return nil }
        return workspace
    }

    /// Whether this copy is context-only because the Task copy owns navigation.
    private func routesSelectionToTaskRow(
        _ workspace: Workspace,
        semanticScope: String
    ) -> Bool {
        semanticScope == "project-list" && workspace.taskID != nil
    }

    /// Whether the workspace row itself carries the selection fill.
    ///
    /// Opening a Session keeps its workspace as the navigation scope, so both
    /// rows match the selection. The leaf is the row the user clicked and the
    /// more specific answer, so it wins; the workspace states containment
    /// instead. A copy that owns no leaf has nothing more specific to defer to,
    /// so it keeps the fill for itself.
    private func isWorkspaceRowSelected(
        _ workspace: Workspace,
        ownsSessionLeaves: Bool
    ) -> Bool {
        guard selection == .workspace(workspace.id) else { return false }
        guard ownsSessionLeaves else { return true }
        return !activeSessions(in: workspace.id).contains(where: isSessionSelected)
    }

    private func workspaceRowContainsSelection(
        _ workspace: Workspace,
        ownsSessionLeaves: Bool
    ) -> Bool {
        guard selection == .workspace(workspace.id) else { return false }
        return !isWorkspaceRowSelected(workspace, ownsSessionLeaves: ownsSessionLeaves)
    }

    private var visibleTaskGroups: [WarrenDesktopTaskGroup] {
        guard tree.showsActiveOnly else { return taskGroups }
        // The active-only switch filters workspace children, not the task
        // heading itself. A task with no active workspace still needs to stay
        // visible so users can inspect or attach workspaces to it.
        return taskGroups.map { group in
            WarrenDesktopTaskGroup(
                task: group.task,
                workspaces: group.workspaces.filter { activeWorkspaceIDs.contains($0.id) }
            )
        }
    }

    private var tasksSection: some View {
        Group {
            if !tree.showsActiveOnly || !visibleTaskGroups.isEmpty {
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.sectionHeaderSpacing) {
                    WarrenDesktopSidebarSectionHeader(
                        title: "Tasks",
                        disclosureExpanded: !tree.tasksCollapsed,
                        actionImage: "plus",
                        actionLabel: "New Task…",
                        actionEnabled: !isInteractionDisabled,
                        onToggle: toggleTasks,
                        onAction: onRequestTaskCreate,
                        additionalActions: [],
                        foldMarks: visibleTaskGroups
                            .flatMap(\.workspaces)
                            .flatMap { activeSessions(in: $0.id) }
                            .map(\.activityMark)
                    )
                    // An empty section states its own emptiness by having no
                    // rows. Placeholder copy repeats that at full row cost, and
                    // the section header's own "+" already says what to do
                    // about it. The body is skipped outright when there is no
                    // row, so an empty section keeps one heading gap whether
                    // it is folded away or opened.
                    if !tree.tasksCollapsed && !visibleTaskGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleTaskGroups) { group in
                                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.groupContentSpacing) {
                                    taskRow(group)
                                    if !tree.collapsedTaskIDs.contains(group.task.id) {
                                        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.worktreeSpacing) {
                                            ForEach(group.workspaces) { workspace in
                                                if let project = groups.first(where: { $0.project.id == workspace.projectID }) {
                                                    WarrenDesktopSessionLeafGroup(
                                                        leafCount: showsSessionLeaves(
                                                            workspace,
                                                            semanticScope: "task-list"
                                                        ) ? activeSessions(in: workspace.id).count : 0
                                                    ) {
                                                        // A task's worktrees name their project,
                                                        // since one task can span several.
                                                        workspaceRow(
                                                            workspace,
                                                            in: project,
                                                            semanticScope: "task-list",
                                                            displayName: "\(project.project.name) · \(workspace.name)"
                                                        )
                                                    } leaves: {
                                                        workspaceSessionRows(
                                                            for: workspace,
                                                            project: project.project,
                                                            semanticScope: "task-list"
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .warrenTreeGroupSeparator(of: group, in: visibleTaskGroups) {
                                    tree.collapsedTaskIDs.contains($0.task.id)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func taskRow(_ group: WarrenDesktopTaskGroup) -> some View {
        WarrenDesktopTaskRow(
            task: group.task,
            workspaceCount: group.workspaces.count,
            availableProjectGroups: groups,
            isExpanded: !tree.collapsedTaskIDs.contains(group.task.id),
            isInteractionDisabled: isInteractionDisabled,
            onToggleExpansion: { toggleTask(group.task.id) },
            onAttachWorkspace: { workspaceID in
                onAction(.attachWorkspaceToTask(group.task.id, workspaceID))
            },
            onCreateWorkspace: { projectID in
                onAction(.requestNewWorkspace(projectID, taskID: group.task.id))
            },
            onRename: {
                onRequestRename(.task(group.task.id, name: group.task.name))
            },
            onTogglePin: {
                onAction(.setTaskPinned(group.task.id, !group.task.pinned))
            },
            onDelete: {
                onRequestDeletion(.task(group.task))
            },
            foldMarks: group.workspaces
                .flatMap { activeSessions(in: $0.id) }
                .map(\.activityMark)
        )
        .id("task.\(group.task.id.description)")
    }

    private var selectedProjectID: ProjectID? {
        switch selection {
        case .project(let projectID):
            return projectID
        case .workspace(let workspaceID):
            return groups.first { $0.workspaces.contains { $0.id == workspaceID } }?.project.id
        case nil:
            return nil
        }
    }

    private func workspaceCount(
        for projectID: ProjectID,
        in groups: [WarrenDesktopProjectGroup]
    ) -> Int {
        groups.first { $0.project.id == projectID }?.workspaces.count ?? 0
    }

    private var hasPendingProjectDeletion: Bool {
        groups.contains { group in
            deletingProjectIDs.contains(group.project.id)
                || hasDeletingWorkspace(in: group.project.id)
        }
    }

    private var visibleProjectGroups: [WarrenDesktopProjectGroup] {
        let baseGroups: [WarrenDesktopProjectGroup]
        if tree.showsActiveOnly {
            baseGroups = groups.compactMap { group in
                let activeWorkspaces = group.workspaces.filter { workspace in
                    activeWorkspaceIDs.contains(workspace.id)
                        || deletingWorkspaceIDs.contains(workspace.id)
                }
                guard !activeWorkspaces.isEmpty || deletingProjectIDs.contains(group.project.id) else {
                    return nil
                }
                return WarrenDesktopProjectGroup(
                    project: group.project,
                    workspaces: activeWorkspaces
                )
            }
        } else {
            baseGroups = groups
        }

        guard !tree.projectsCollapsed else {
            return baseGroups.filter { group in
                deletingProjectIDs.contains(group.project.id)
                    || hasDeletingWorkspace(in: group.project.id)
            }
        }
        return baseGroups
    }

    private func select(_ newSelection: WarrenDesktopSidebarSelection) {
        guard !isInteractionDisabled else { return }
        switch newSelection {
        case .project(let projectID):
            onAction(.selectProject(projectID))
        case .workspace(let workspaceID):
            onAction(.selectWorkspace(workspaceID))
        }
    }

    private func toggleProject(_ projectID: ProjectID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.collapsedProjectIDs.contains(projectID) {
                tree.collapsedProjectIDs.remove(projectID)
            } else {
                tree.collapsedProjectIDs.insert(projectID)
            }
        }
    }

    /// Whether a project shows only its own row: folded, and with no
    /// worktree mid-deletion holding its worktree rows open.
    private func isProjectFolded(_ group: WarrenDesktopProjectGroup) -> Bool {
        !isProjectExpanded(group.project.id)
            && (soloWorkspace(of: group) != nil || !hasDeletingWorkspace(in: group.project.id))
    }

    private func isProjectExpanded(_ projectID: ProjectID) -> Bool {
        WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedCollapses: tree.collapsedProjectIDs,
            autoCollapse: dragAutoCollapse
        )
    }

    private func setDragAutoCollapse(_ autoCollapse: WarrenSidebarDragAutoCollapse?) {
        guard autoCollapse == nil else { return }
        guard dragAutoCollapse != autoCollapse else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragAutoCollapse = autoCollapse
        }
    }

    private func toggleProjects() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.projectsCollapsed.toggle()
        }
    }

    private var areAllProjectsExpanded: Bool {
        !groups.isEmpty
            && groups.allSatisfy { !tree.collapsedProjectIDs.contains($0.project.id) }
    }

    private func toggleAllProjects() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if areAllProjectsExpanded {
                tree.collapsedProjectIDs.formUnion(groups.map(\.project.id))
            } else {
                tree.collapsedProjectIDs.subtract(groups.map(\.project.id))
            }
        }
    }

    private func toggleTasks() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.tasksCollapsed.toggle()
        }
    }

    private func toggleTask(_ taskID: TaskID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.collapsedTaskIDs.contains(taskID) {
                tree.collapsedTaskIDs.remove(taskID)
            } else {
                tree.collapsedTaskIDs.insert(taskID)
            }
        }
    }

    @ViewBuilder
    private func projectRow(
        for group: WarrenDesktopProjectGroup,
        soloWorkspace: Workspace? = nil
    ) -> some View {
        let isProjectDeleting = deletingProjectIDs.contains(group.project.id)
        let hasDeletingWorkspace = group.workspaces.contains {
            deletingWorkspaceIDs.contains($0.id)
        }
        // Workspace deletion is rendered on the workspace row only. Keep the
        // project row unavailable while its child is being removed, but do
        // not make the project look as if the project itself is deleting.
        let deletionKind: WarrenDesktopProjectDeletionKind? = isProjectDeleting
            ? .project
            : nil
        ZStack {
            WarrenDesktopProjectRow(
                project: group.project,
                workspaceCount: group.workspaces.count,
                isSelected: selection == .project(group.project.id),
                isExpanded: isProjectExpanded(group.project.id),
                isPinned: group.project.pinned,
                deletionKind: deletionKind,
                isInteractionDisabled: isInteractionDisabled
                    || deletionKind != nil
                    || hasDeletingWorkspace,
                onSelect: { select(.project(group.project.id)) },
                onToggleExpansion: { toggleProject(group.project.id) },
                onAddWorkspace: {
                    onAction(.requestNewWorkspace(group.project.id))
                },
                onImportWorktrees: {
                    onAction(.requestProjectWorktreeImport(group.project.id))
                },
                onConfigureSetupScript: {
                    onAction(.requestProjectSetupScript(group.project.id))
                },
                onToggleAutoImportWorktrees: {
                    onAction(.setProjectAutoImportGitWorktrees(
                        group.project.id,
                        !group.project.autoImportGitWorktrees
                    ))
                },
                onRename: {
                    onRequestRename(.project(group.project.id, name: group.project.name))
                },
                onTogglePin: {
                    onAction(.setProjectPinned(
                        group.project.id,
                        !group.project.pinned
                    ))
                },
                onDelete: {
                    onRequestDeletion(.project(
                        group.project,
                        workspaceCount: group.workspaces.count
                    ))
                },
                foldMarks: projectListWorkspaces(of: group)
                    .flatMap { activeSessions(in: $0.id) }
                    .map(\.activityMark),
                branchName: soloWorkspace.map { $0.branch ?? $0.name },
                workspaceMenu: soloWorkspace.map { workspace in
                    WarrenDesktopWorkspaceRow.contextMenuActions(
                        workspace: workspace,
                        isPinned: workspace.pinned,
                        tasks: taskGroups.map(\.task),
                        onTogglePin: {
                            onAction(.setWorkspacePinned(workspace.id, !workspace.pinned))
                        },
                        onRename: {
                            onRequestRename(.workspace(workspace.id, name: workspace.name))
                        },
                        onAttachToTask: { taskID in
                            onAction(.attachWorkspaceToTask(taskID, workspace.id))
                        },
                        onDetachFromTask: { taskID in
                            onAction(.detachWorkspaceFromTask(taskID, workspace.id))
                        },
                        onDelete: {
                            onRequestDeletion(.workspace(workspace, project: group.project))
                        }
                    )
                } ?? [],
                onDoubleClick: soloWorkspace.map { workspace in
                    { onAction(.requestNewSession(workspace.id)) }
                }
            )
        }
        .background {
            if isDragMeasurementEnabled {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WarrenSidebarRowDragFramesKey.self,
                        value: [
                            group.project.id.description: WarrenSidebarRowDragFrame(
                                info: WarrenSidebarRowDragInfo(
                                    id: group.project.id.description,
                                    kind: .project(group.project.id),
                                    name: group.project.name,
                                    isLastOfList: group.project.id
                                        == groups.last(where: \.project.pinned)?.project.id
                                ),
                                frame: proxy.frame(
                                    in: .named(WarrenSidebarRowsDragCoordinateSpace.name)
                                )
                            ),
                        ]
                    )
                }
            }
        }
        .opacity(dragSourceRowID == group.project.id.description ? 0.2 : 1)
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: dragSourceRowID
        )
    }

    @ViewBuilder
    private func workspaceRow(
        _ workspace: Workspace,
        in group: WarrenDesktopProjectGroup,
        semanticScope: String = "project-list",
        displayName: String? = nil,
        taskName: String? = nil
    ) -> some View {
        let presentedWorkspace = displayName.map { name in
            var value = workspace
            value.name = name
            return value
        } ?? workspace
        let rowID = "workspace.\(semanticScope).\(workspace.id.description)"
        let isProjectDeleting = deletingProjectIDs.contains(group.project.id)
        let isDeleting = deletingWorkspaceIDs.contains(workspace.id)
        let isSelectionDisabled = routesSelectionToTaskRow(
            workspace,
            semanticScope: semanticScope
        )
        // Leaves belong to the copy that owns navigation: a row the user cannot
        // act on must not list the only rows they can.
        let ownsLeaves = ownsSessionLeaves(workspace, semanticScope: semanticScope)
        let sessions = ownsLeaves ? activeSessions(in: workspace.id) : []
        // A folded row hands the selection fill back to itself: the leaf that
        // would carry it is out of sight.
        let showsLeaves = showsSessionLeaves(workspace, semanticScope: semanticScope)
        let leafCount = showsLeaves ? sessions.count : 0
        ZStack {
            let activitySummary = workspaceActivitySummary(workspace.id)
            WarrenDesktopWorkspaceRow(
                workspace: presentedWorkspace,
                semanticScope: semanticScope,
                mark: activitySummary?.mark,
                activeTabCount: activitySummary?.activeTabCount ?? 0,
                isSelected: isWorkspaceRowSelected(
                    workspace,
                    ownsSessionLeaves: showsLeaves
                ) && !isSelectionDisabled,
                containsSelection: workspaceRowContainsSelection(
                    workspace,
                    ownsSessionLeaves: showsLeaves
                ) && !isSelectionDisabled,
                isPinned: workspace.pinned,
                isEditorMarked: editorMarkedWorkspaceIDs.contains(workspace.id),
                onOpenEditor: { onOpenEditor(workspace.id) },
                isDeleting: isDeleting,
                isInteractionDisabled: isInteractionDisabled || isProjectDeleting || isDeleting,
                isMutationDisabled: false,
                isSelectionDisabled: isSelectionDisabled,
                showsSessionChildren: leafCount > 0,
                leafDisclosure: sessions.isEmpty ? nil : WarrenDesktopLeafDisclosure(
                    isExpanded: showsLeaves,
                    marks: sessions.map(\.activityMark),
                    toggle: { toggleWorkspaceLeaves(workspace.id) }
                ),
                rowHeight: WarrenDesktopSidebarMetrics.worktreeRowHeight,
                taskName: taskName,
                taskID: workspace.taskID,
                tasks: taskGroups.map(\.task),
                onSelectTask: onFocusTask,
                onSelect: { select(.workspace(workspace.id)) },
                onDoubleClick: {
                    // Rich mode already lists the Sessions, so the gesture that
                    // opens a workspace in compact mode becomes the new-Session
                    // gesture the add control gives every scope. Compact mode
                    // keeps the switch-driven open it has always had.
                    onAction(workspaceDisplayMode.isRich
                        ? .requestNewSession(workspace.id)
                        : .openWorkspace(workspace.id))
                },
                onRename: {
                    onRequestRename(.workspace(workspace.id, name: workspace.name))
                },
                onTogglePin: {
                    onAction(.setWorkspacePinned(
                        workspace.id,
                        !workspace.pinned
                    ))
                },
                onAttachToTask: { taskID in
                    onAction(.attachWorkspaceToTask(taskID, workspace.id))
                },
                onDetachFromTask: { taskID in
                    onAction(.detachWorkspaceFromTask(taskID, workspace.id))
                },
                onDelete: {
                    onRequestDeletion(.workspace(
                        workspace,
                        project: group.project
                    ))
                }
            )
        }
        .id(rowID)
        .transition(.opacity)
        .background {
            if isDragMeasurementEnabled {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WarrenSidebarRowDragFramesKey.self,
                        value: [
                            workspace.id.description: WarrenSidebarRowDragFrame(
                                info: WarrenSidebarRowDragInfo(
                                    id: workspace.id.description,
                                    kind: .workspace(
                                        workspace.id,
                                        projectID: group.project.id
                                    ),
                                    name: workspace.name,
                                    isLastOfList: workspace.id == group.workspaces.last?.id
                                ),
                                frame: proxy.frame(
                                    in: .named(WarrenSidebarRowsDragCoordinateSpace.name)
                                )
                            ),
                        ]
                    )
                }
            }
        }
        .opacity(dragSourceRowID == workspace.id.description ? 0.2 : 1)
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: dragSourceRowID
        )
    }

    private func taskName(for workspace: Workspace) -> String? {
        guard let taskID = workspace.taskID else { return nil }
        return taskGroups.first { $0.task.id == taskID }?.task.name
    }

    private func workspaceActivitySummary(
        _ workspaceID: WorkspaceID
    ) -> WarrenDesktopWorkspaceActivitySummary? {
        workspaceActivitySummaries[workspaceID]
    }

    /// A Task-linked workspace is rendered twice: once in the Projects tree and
    /// once beneath its Task heading. Session leaves belong to the Task copy,
    /// because that is the row selection routes to (`workspaceScrollTarget`) and
    /// the only copy the user can act on; the Projects copy is context-only, so
    /// leaves under it would hang off a row that cannot be clicked.
    ///
    /// The cost is explicit: collapsing the Tasks section hides those Sessions,
    /// exactly as collapsing Projects hides the ones that copy owns.
    @ViewBuilder
    private func workspaceSessionRows(
        for workspace: Workspace,
        project: Project,
        semanticScope: String
    ) -> some View {
        ForEach(activeSessions(in: workspace.id)) { session in
            let isExpanded = tree.expandedSubagentSessionIDs.contains(session.id)
            WarrenDesktopWorkspaceSessionRow(
                session: session,
                project: project,
                workspace: workspace,
                semanticScope: semanticScope,
                isSelected: isSessionSelected(session),
                isInteractionDisabled: isInteractionDisabled
                    || deletingProjectIDs.contains(project.id)
                    || deletingWorkspaceIDs.contains(workspace.id),
                onOpen: { onAction(.openSession(session.id)) },
                onRename: {
                    onRequestRename(.session(session.id, title: session.displayTitle))
                },
                onTogglePin: {
                    onAction(.setSessionPinned(session.id, !session.pinned))
                },
                onEnd: { onAction(.deleteSession(session.id)) },
                onSplitDrop: onSplitDropSession,
                isSubagentsExpanded: isExpanded,
                isSubagentsDoneExpanded: tree.expandedSubagentDoneSessionIDs.contains(session.id),
                onToggleSubagents: { toggleSubagents(session.id) },
                onToggleSubagentsDone: { toggleSubagentsDone(session.id) },
                onCollapseSubagents: { collapseSubagents(session.id) }
            )
        }
    }

    /// Opens or folds one Session's subagent rows. Stored as an opened set so a
    /// new Session keeps its children in the title's count chip.
    private func toggleSubagents(_ sessionID: TerminalSessionID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.expandedSubagentSessionIDs.contains(sessionID) {
                tree.expandedSubagentSessionIDs.remove(sessionID)
                tree.expandedSubagentDoneSessionIDs.remove(sessionID)
            } else {
                tree.expandedSubagentSessionIDs.insert(sessionID)
            }
        }
    }

    private func toggleSubagentsDone(_ sessionID: TerminalSessionID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.expandedSubagentDoneSessionIDs.contains(sessionID) {
                tree.expandedSubagentDoneSessionIDs.remove(sessionID)
            } else {
                tree.expandedSubagentDoneSessionIDs.insert(sessionID)
            }
        }
    }

    /// Closes one Session's subagent group without a user action. The design
    /// collapses an all-done group when the parent's turn ends; clearing both
    /// sets makes the next turn treat it as never opened.
    private func collapseSubagents(_ sessionID: TerminalSessionID) {
        guard tree.expandedSubagentSessionIDs.contains(sessionID)
            || tree.expandedSubagentDoneSessionIDs.contains(sessionID) else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.expandedSubagentSessionIDs.remove(sessionID)
            tree.expandedSubagentDoneSessionIDs.remove(sessionID)
        }
    }

    private func activeSessions(
        in workspaceID: WorkspaceID
    ) -> [WarrenDesktopSession] {
        activeSessionsByWorkspaceID[workspaceID] ?? []
    }

    private func setDragMeasurementEnabled(_ enabled: Bool) {
        guard isDragMeasurementEnabled != enabled else { return }
        // AppKit can notify the representable while SwiftUI is applying the
        // current graph. Defer the state change so enabling row preferences
        // cannot publish from inside that transaction.
        Task { @MainActor in
            guard isDragMeasurementEnabled != enabled else { return }
            isDragMeasurementEnabled = enabled
        }
    }

    private func dropProject(
        _ payload: String,
        before projectID: ProjectID?
    ) -> Bool {
        guard !isInteractionDisabled else { return false }
        guard payload.hasPrefix(WarrenSidebarDragPayload.projectPrefix),
              let sourceID = ProjectID(uuidString: String(
                payload.dropFirst(WarrenSidebarDragPayload.projectPrefix.count)
              ))
        else { return false }
        guard !isProjectDeletionPending(sourceID),
              projectID.map({ !isProjectDeletionPending($0) }) ?? true
        else { return false }
        if projectID == sourceID {
            return false
        }
        onAction(.moveProject(sourceID, before: projectID))
        return true
    }

    private func dropWorkspace(
        _ payload: String,
        before workspaceID: WorkspaceID?,
        inProject projectID: ProjectID? = nil
    ) -> Bool {
        guard !isInteractionDisabled else { return false }
        guard payload.hasPrefix(WarrenSidebarDragPayload.workspacePrefix),
              let sourceID = WorkspaceID(uuidString: String(
                payload.dropFirst(WarrenSidebarDragPayload.workspacePrefix.count)
              )),
              let source = groups
                .flatMap(\.workspaces)
                .first(where: { $0.id == sourceID })
        else { return false }
        guard !isWorkspaceDeletionPending(source.id, projectID: source.projectID),
              !hasDeletingWorkspace(in: source.projectID)
        else { return false }
        if workspaceID == sourceID {
            return false
        }
        if let projectID, source.projectID != projectID {
            return false
        }
        if let workspaceID {
            guard let target = groups
                .flatMap(\.workspaces)
                .first(where: { $0.id == workspaceID }),
                  target.projectID == source.projectID,
                  !isWorkspaceDeletionPending(target.id, projectID: target.projectID)
            else { return false }
        }
        onAction(.moveWorkspace(sourceID, before: workspaceID))
        return true
    }

    private func isDragDisabled(_ info: WarrenSidebarRowDragInfo) -> Bool {
        guard !isInteractionDisabled else { return true }
        switch info.kind {
        case .project(let projectID):
            // Only the pinned band follows the Host's order; the active band
            // is ordered by when each project became active.
            return isProjectDeletionPending(projectID)
                || groups.first(where: { $0.project.id == projectID })?.project.pinned != true
        case .workspace(let workspaceID, let projectID):
            return isWorkspaceDeletionPending(workspaceID, projectID: projectID)
                || hasDeletingWorkspace(in: projectID)
        }
    }

    private func isProjectDeletionPending(_ projectID: ProjectID) -> Bool {
        deletingProjectIDs.contains(projectID) || hasDeletingWorkspace(in: projectID)
    }

    private func isWorkspaceDeletionPending(
        _ workspaceID: WorkspaceID,
        projectID: ProjectID
    ) -> Bool {
        deletingProjectIDs.contains(projectID) || deletingWorkspaceIDs.contains(workspaceID)
    }

    private func hasDeletingWorkspace(in projectID: ProjectID) -> Bool {
        groups.first(where: { $0.project.id == projectID })?.workspaces.contains {
            deletingWorkspaceIDs.contains($0.id)
        } == true
    }

}

/// A Terminal Session leaf shown below its owning Workspace by the rich
/// presentation.
///
/// The first line is the title. The second line, shown only while there is
/// something to report, is what the Session is doing; see `activityLine`. A
/// second line naming the provider was tried and removed earlier, because the
/// icon already carries it; an activity line earns its height by saying
/// something the row could not otherwise say.
///
/// The state is the dot on the icon's corner and nothing else. Its color
/// already separates a working Agent from a blocked or failed one, so a state
/// word only competed with the title for width; the full explanation still
/// reaches assistive technology and the hover tooltip. A plain shell has no
/// activity Warren can observe, so its icon carries no dot rather than an
/// invented one.
enum WarrenDesktopSessionRowScope {
    case workspace(project: Project, workspace: Workspace, semanticScope: String)

    /// The Worktree the Session hangs under, which is the root a shell's
    /// location title is made relative to.
    var worktreePath: String {
        switch self {
        case let .workspace(_, workspace, _): return workspace.path
        }
    }

    var workspace: Workspace {
        switch self {
        case let .workspace(_, workspace, _): return workspace
        }
    }
}

struct WarrenDesktopWorkspaceSessionRow: View {
    let session: WarrenDesktopSession
    let scope: WarrenDesktopSessionRowScope
    var isSelected: Bool = false
    let isInteractionDisabled: Bool
    let onOpen: () -> Void
    /// A leaf owns the Session's own actions. The tab strip is no longer a
    /// session switcher, so this row is where a Session is renamed, pinned, or
    /// ended; nothing else in the tree can reach it. They are optional because
    /// a background Host's leaf stays navigable but read-only.
    var onRename: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    /// Drops this Session onto a pane.
    ///
    /// The same handler the Tab strip uses, so a Session reaches a pane by
    /// either door. Rich mode's tree is the only place a Workspace's other
    /// Sessions are listed, which is where a drop is most useful.
    var onSplitDrop: ((String, String, SplitDropTarget) -> Void)? = nil
    /// Whether the Session's subagent rows are open. Persisted per Session.
    var isSubagentsExpanded: Bool = false
    /// Whether the completed subagents are open past the `N done` summary.
    var isSubagentsDoneExpanded: Bool = false
    var onToggleSubagents: (() -> Void)? = nil
    var onToggleSubagentsDone: (() -> Void)? = nil
    /// Called when the Session's turn ends with the group open, so the parent
    /// can forget the expansion: the design collapses and hides an all-done
    /// group at turn end, and it must not reopen on the next turn.
    var onCollapseSubagents: (() -> Void)? = nil

    init(
        session: WarrenDesktopSession,
        project: Project,
        workspace: Workspace,
        semanticScope: String,
        isSelected: Bool = false,
        isInteractionDisabled: Bool,
        onOpen: @escaping () -> Void,
        onRename: (() -> Void)? = nil,
        onTogglePin: (() -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        onSplitDrop: ((String, String, SplitDropTarget) -> Void)? = nil,
        isSubagentsExpanded: Bool = false,
        isSubagentsDoneExpanded: Bool = false,
        onToggleSubagents: (() -> Void)? = nil,
        onToggleSubagentsDone: (() -> Void)? = nil,
        onCollapseSubagents: (() -> Void)? = nil
    ) {
        self.session = session
        self.scope = .workspace(project: project, workspace: workspace, semanticScope: semanticScope)
        self.isSelected = isSelected
        self.isInteractionDisabled = isInteractionDisabled
        self.onOpen = onOpen
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onEnd = onEnd
        self.onSplitDrop = onSplitDrop
        self.isSubagentsExpanded = isSubagentsExpanded
        self.isSubagentsDoneExpanded = isSubagentsDoneExpanded
        self.onToggleSubagents = onToggleSubagents
        self.onToggleSubagentsDone = onToggleSubagentsDone
        self.onCollapseSubagents = onCollapseSubagents
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.warrenShellAttention) private var shellAttention
    @Environment(\.warrenPointerInsideSidebar) private var pointerInsideSidebar
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    /// The shell row's hover card, which trails the pointer by a beat so a row
    /// it only passes over never makes one.
    @State private var showsShellDetails = false
    @State private var shellDetailTask: Task<Void, Never>?
    /// The collapse the row draws, which follows `isCollapsed(now:)` through
    /// `shownCollapse(...)` inside an animation. The pointer dwelling on the
    /// row, leaving the rail, and the ten-minute tick all change the height,
    /// and only a transaction set where the state changes moves the rows below
    /// with it; an `.animation` on the row animates the row alone and leaves
    /// its neighbours to jump.
    @State private var shownCollapsed: Bool?
    /// Whether the pointer has dwelt on this row long enough to open it. Set
    /// a beat before the shell card, so a pointer passing over the row on its
    /// way to another never opens it.
    @State private var isDwelling = false

    private var providerName: String {
        session.presentedKind.displayName
    }

    private var title: String {
        Self.rowTitle(for: session, worktreeRoot: scope.worktreePath)
    }

    /// The row's title is the Session's one name, the same one the top bar,
    /// the tab, and the pane header use. See `SessionTitle`.
    static func rowTitle(for session: WarrenDesktopSession, worktreeRoot: String) -> String {
        WarrenDesktopTabTitle.sessionTitle(for: session, worktreeRoot: worktreeRoot).title
    }

    /// Whether this row's title is a location. A plain shell reads its title
    /// from where it is, and that title fades at its start so the tail of a
    /// path survives.
    static func usesLocationTitle(for session: WarrenDesktopSession) -> Bool {
        session.presentedKind == .shell && !session.isAgentSession
    }

    private var attention: AgentAttention? {
        session.agentStatus?.attention
    }

    /// The Activity state word, when there is one.
    ///
    /// A shell that never bound an Agent reports no activity, so it has no state
    /// to name. Treating that as "Running" claimed knowledge of a process Warren
    /// does not track.
    ///
    /// The word comes from the mark the row already draws, so the marker and the
    /// text can never disagree about which half of the status won.
    private var statusLabel: String? {
        session.activityMark?.statusWord
    }

    /// The full state sentence, kept for assistive technology and the hover
    /// tooltip. The row itself no longer draws it: the colored marker is the
    /// only trailing affordance.
    ///
    /// An attention reason is the Host's own bounded explanation of why a
    /// person is being asked to look, so it replaces the generic state word.
    /// A plain shell reports its running process instead.
    private var detailLabel: String? {
        if let attention {
            let reason = attention.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? statusLabel : reason
        }
        // `session.activity`, not the drawn mark: a completion the person has
        // already read should stop drawing, but its sentence is still the honest
        // answer to "what is this Session doing".
        switch session.activity {
        case .blocked, .failed, .exited:
            return statusLabel
        case .working, .ready:
            return nil
        case .none:
            // A shell with OSC 133 state reports its command on the second
            // line; naming the foreground process here too would say it twice.
            if session.shellState != nil { return nil }
            let detail = session.runtimeCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let process = session.runtimeProcess.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = detail.isEmpty ? process : detail
            return value.isEmpty ? nil : value
        }
    }

    private var semanticID: String {
        switch scope {
        case let .workspace(_, workspace, semanticScope):
            return "workspace-session.\(semanticScope).\(workspace.id.description).\(session.id.description)"
        }
    }

    private var semanticLabel: String {
        "\(providerName) Session \(title)"
    }

    /// Assistive technology has no hover, so it always receives the detail the
    /// pointer has to earn.
    private var semanticValue: String {
        var values: [String] = []
        if let statusLabel {
            values.append(statusLabel)
        }
        if let detailLabel, detailLabel != statusLabel {
            values.append(detailLabel)
        }
        if let second = Self.secondLine(for: session).announcement,
           second != detailLabel,
           second != statusLabel {
            values.append(second)
        }
        if session.pinned {
            values.append("Pinned")
        }
        switch scope {
        case let .workspace(project, workspace, _):
            values.append(project.name)
            values.append(workspace.name)
        }
        if isSelected {
            values.append("Selected")
        }
        return values.joined(separator: " · ")
    }

    var body: some View {
        // The row's own clock: the idle collapse and the elapsed labels all
        // resolve against one instant, so a height and its text agree.
        TimelineView(.periodic(from: .now, by: 10)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let rowWash: Color? = isSelected
            ? tokens.treeRowSelected
            : (isHovered ? tokens.treeRowHover : nil)
        let restingCollapsed = isCollapsed(now: now)
        let collapsed = shownCollapsed ?? restingCollapsed
        return VStack(alignment: .leading, spacing: 0) {
        Button(action: onOpen) {
            // A resting shell collapses to one line; every other row draws the
            // badge, the title, and the second line. The dot is the only place
            // the status appears either way. The two cross-fade inside a frame
            // that carries the height, so the change is one smooth resize
            // rather than the two layouts stacking for the length of the fade.
            ZStack(alignment: .topLeading) {
                if collapsed {
                    collapsedRow(tokens: tokens, rowWash: rowWash, now: now)
                        .transition(.opacity)
                } else {
                    expandedRow(tokens: tokens, rowWash: rowWash, now: now)
                        .transition(.opacity)
                }
            }
            .frame(
                height: collapsed ? Self.collapsedRowHeight : WarrenDesktopSidebarMetrics.sessionRowHeight,
                alignment: .topLeading
            )
            .clipped()
            .contentShape(.rect)
            // The drag source is native for the same reason a Tab's is: a drop
            // over the AppKit terminal has to be resolved by the drag source.
            // The handle owns the row's plain press, so it restores the click
            // and the focus the Button used to take.
            .overlay {
                if let onSplitDrop, !isInteractionDisabled, let tabID = session.tabID {
                    WarrenDesktopTabDragHandle(
                        tabID: tabID,
                        isEnabled: true,
                        onSelect: {
                            isFocused = true
                            onOpen()
                        },
                        onSplitDrop: onSplitDrop,
                        excludesTopTrailingControl: showsSubagentCapsule
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .background(
            rowWash ?? .clear,
            in: RoundedRectangle(
                cornerRadius: WarrenDesktopSidebarMetrics.sessionRadius,
                style: .continuous
            )
        )
        .opacity(isInteractionDisabled ? 0.62 : 1)
        .onHover { inside in
            isHovered = inside
            shellHover(inside)
        }
        .accessibilityLabel(semanticLabel)
        .accessibilityValue(semanticValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: semanticID,
            role: .button,
            label: semanticLabel,
            value: semanticValue,
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: { if !isInteractionDisabled { onOpen() } }
        )
        // The title truncates to one line; the whole of it is on hover. A shell
        // row moves that detail to its own card.
        .modifier(WarrenDesktopRowHelp(
            text: Self.usesLocationTitle(for: session) ? nil : helpText
        ))
        .warrenMenuPanel(
            isPresented: $showsShellDetails,
            width: WarrenDesktopDetailCard.width,
            isPassive: true
        ) {
            WarrenDesktopDetailCard(rows: shellDetailRows())
        }
        .warrenContextMenu(isInteractionDisabled ? [] : contextMenuActions)
        .onChange(of: session.activity) { activity in
            // The design closes an open, all-done group when the parent's turn
            // ends. Clearing the stored expansion keeps it from reopening on
            // the next turn as if the user had asked for it again.
            if isSubagentsExpanded, activity != .working {
                onCollapseSubagents?()
            }
        }
        .onChange(of: isSelected) { selected in
            // Looking at a failed Session is what starts its rest: an unseen
            // failure stays two lines until then.
            guard selected, let key = Self.failureKey(for: session) else { return }
            shellAttention?.markSeen(key, at: Date())
        }
        .onAppear { shownCollapsed = restingCollapsed }
        .onChange(of: restingCollapsed) { _ in settleCollapse() }
        .onChange(of: pointerInsideSidebar) { _ in settleCollapse() }
        .onChange(of: isDwelling) { _ in settleCollapse() }
            if showsSubagentRows {
                subagentRows(tokens: tokens)
            }
        }
    }

    static let statusDotSize: CGFloat = WarrenDesktopSidebarMetrics.sessionDotSize
    /// Pushes the dot past the icon's corner so it reads as attached to the
    /// icon rather than drawn on top of it.
    static let statusDotOffset: CGFloat = WarrenDesktopSidebarMetrics.sessionDotOffset
    static let lineSpacing: CGFloat = WarrenDesktopSidebarMetrics.sessionLineSpacing
    static let verticalInset: CGFloat = WarrenDesktopSidebarMetrics.sessionVerticalPadding
    /// How long a shell rests before its row collapses to one line.
    static let shellRestInterval: TimeInterval = 600
    /// The collapsed row's height, the same as a project row's.
    static let collapsedRowHeight: CGFloat = 30

    private func badge(tokens: WarrenColorTokens, rowWash: Color?) -> some View {
        WarrenDesktopSessionKindBadge(
            session: session,
            size: WarrenDesktopSidebarMetrics.sessionIconSize
        )
        .overlay(alignment: .bottomTrailing) {
            WarrenDesktopStatusDot(
                mark: session.rowStatusMark,
                size: Self.statusDotSize,
                ring: tokens.workbenchCardFill,
                tokens: tokens,
                ringTint: rowWash
            )
            .offset(x: Self.statusDotOffset, y: Self.statusDotOffset)
        }
    }

    private func expandedRow(tokens: WarrenColorTokens, rowWash: Color?, now: Date) -> some View {
        HStack(alignment: .top, spacing: WarrenDesktopSidebarMetrics.sessionIconSpacing) {
            badge(tokens: tokens, rowWash: rowWash)
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                titleLine(tokens: tokens)
                    .frame(height: WarrenDesktopSidebarMetrics.sessionIconSize)
                secondLine(tokens: tokens, now: now)
                    .frame(height: WarrenDesktopSidebarMetrics.sessionActivityLineHeight)
            }
        }
        .padding(.vertical, Self.verticalInset)
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A resting shell, drawn as one 30pt line: where it is, and how long since
    /// it last did anything. What it last ran moved to the hover card.
    private func collapsedRow(tokens: WarrenColorTokens, rowWash: Color?, now: Date) -> some View {
        HStack(spacing: WarrenDesktopSidebarMetrics.sessionIconSpacing) {
            badge(tokens: tokens, rowWash: rowWash)
            // The fading line is a GeometryReader, which fills the row's height
            // and pins its text to the top; the badge's height keeps the two
            // on one line, as in the expanded row.
            titleLine(tokens: tokens, titleColor: collapsedTitleColor(tokens: tokens))
                .frame(height: WarrenDesktopSidebarMetrics.sessionIconSize)
            Spacer(minLength: 8)
            if let age = collapsedAge(now: now) {
                Text(age)
                    .font(.system(size: WarrenDesktopSessionSecondLineLayout.metaFontSize))
                    .monospacedDigit()
                    .foregroundStyle(tokens.sessionMetaIdleText)
                    .fixedSize()
            }
        }
        .frame(height: Self.collapsedRowHeight)
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsedTitleColor(tokens: WarrenColorTokens) -> Color {
        isSelected ? tokens.treeSessionSelectedText : tokens.sessionCollapsedTitleText
    }

    private func collapsedAge(now: Date) -> String? {
        guard let shell = session.shellState else { return nil }
        let reference = shell.lastExitAt ?? session.createdAt
        guard let reference else { return nil }
        return WarrenDesktopSessionSecondLineLayout.elapsed(now.timeIntervalSince(reference))
    }

    /// Whether this shell has rested long enough to lose its second line.
    ///
    /// A command that failed stays two lines until the Session has been looked
    /// at once; only then does the ten-minute rest begin. What the pointer does
    /// to that is `shownCollapse(...)`'s business.
    static func isCollapsedShell(
        for session: WarrenDesktopSession,
        seenAt: Date?,
        now: Date
    ) -> Bool {
        guard session.presentedKind == .shell,
              !session.isAgentSession,
              session.state.isActive,
              let shell = session.shellState,
              !shell.isRunningCommand else { return false }
        guard let endedAt = shell.lastExitAt else { return true }
        if shell.displayedExitCode != nil {
            guard let seenAt else { return false }
            return now.timeIntervalSince(seenAt) >= shellRestInterval
        }
        return now.timeIntervalSince(endedAt) >= shellRestInterval
    }

    /// The identity of a shell's current failure: the Session, and when the
    /// command ended. A new failure is a new key, so it is unseen again.
    static func failureKey(for session: WarrenDesktopSession) -> String? {
        guard let shell = session.shellState,
              shell.displayedExitCode != nil,
              let endedAt = shell.lastExitAt else { return nil }
        return "\(session.id.description)|\(endedAt.timeIntervalSince1970)"
    }

    private func isCollapsed(now: Date) -> Bool {
        let seenAt = Self.failureKey(for: session).flatMap { shellAttention?.seen($0) }
        return Self.isCollapsedShell(
            for: session,
            seenAt: seenAt,
            now: now
        )
    }

    /// The collapse a row draws next, given the one it draws now.
    ///
    /// Only the row the pointer dwells on opens: the pointer merely entering
    /// the rail leaves every collapsed row as it is, so reaching for another
    /// Session does not reflow the tree. A row that is open stays open while
    /// the pointer is over the rail rather than shrinking under the pointer
    /// that is reading it; it folds once the pointer leaves.
    static func shownCollapse(
        current: Bool,
        resting: Bool,
        pointerInsideSidebar: Bool,
        isDwelling: Bool
    ) -> Bool {
        guard resting, !isDwelling else { return false }
        if current { return true }
        return !pointerInsideSidebar
    }

    private func settleCollapse() {
        let next = Self.shownCollapse(
            current: shownCollapsed ?? false,
            resting: isCollapsed(now: Date()),
            pointerInsideSidebar: pointerInsideSidebar,
            isDwelling: isDwelling
        )
        guard next != shownCollapsed else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            shownCollapsed = next
        }
    }

    /// The title, with its subagent count chip and pin.
    ///
    /// The chip sits at the title's tail and the pin after it: the title runs
    /// into the fade and whichever control follows it keeps its own place and
    /// stays legible, which is what the specification asks for between a title
    /// and its chip.
    @ViewBuilder
    private func titleLine(tokens: WarrenColorTokens, titleColor: Color? = nil) -> some View {
        HStack(spacing: 6) {
            WarrenDesktopFadingLine(edge: Self.usesLocationTitle(for: session) ? .leading : .trailing) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        titleColor
                            ?? (isSelected ? tokens.treeSessionSelectedText : tokens.treeSessionText)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            subagentCapsule(tokens: tokens)
            pin(tokens: tokens)
        }
    }

    @ViewBuilder
    private func pin(tokens: WarrenColorTokens) -> some View {
        if session.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tokens.treeQuietText)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Subagents

    private var runningSubagents: [WarrenDesktopSubagent] {
        session.subagents.filter(\.isRunning)
    }

    private var completedSubagents: [WarrenDesktopSubagent] {
        session.subagents.filter { !$0.isRunning }
    }

    /// The children waiting on a person. The Host lifts one of these to the
    /// parent's attention; the row names the child and reveals just that row.
    ///
    /// Empty until a provider reports a child's request; see
    /// `WarrenDesktopSubagent.isWaiting` for why that does not happen yet.
    private var waitingSubagents: [WarrenDesktopSubagent] {
        session.subagents.filter(\.isWaiting)
    }

    /// The chip names how many children are running, or, once an open group is
    /// all done, that they finished. A group that was never opened and has no
    /// running child draws nothing.
    static func showsSubagentCapsule(session: WarrenDesktopSession, isExpanded: Bool) -> Bool {
        guard !session.subagents.isEmpty else { return false }
        if session.subagents.contains(where: \.isRunning) { return true }
        return isExpanded && session.activity == .working
    }

    /// Whether the whole group is open. The user opened it and its turn is
    /// still running, so an all-done group keeps its dim chip until the turn
    /// ends and the parent clears the expansion.
    static func isSubagentGroupOpen(session: WarrenDesktopSession, isExpanded: Bool) -> Bool {
        isExpanded && session.activity == .working
    }

    /// The children to draw. An open group shows every child; a closed one
    /// shows only the child that needs a person, so its question is visible
    /// without the user opening anything.
    static func visibleSubagents(session: WarrenDesktopSession, isExpanded: Bool) -> [WarrenDesktopSubagent] {
        isSubagentGroupOpen(session: session, isExpanded: isExpanded)
            ? session.subagents
            : session.subagents.filter(\.isWaiting)
    }

    private var showsSubagentCapsule: Bool {
        Self.showsSubagentCapsule(session: session, isExpanded: isSubagentsExpanded)
    }

    private var isSubagentGroupOpen: Bool {
        Self.isSubagentGroupOpen(session: session, isExpanded: isSubagentsExpanded)
    }

    private var visibleSubagents: [WarrenDesktopSubagent] {
        Self.visibleSubagents(session: session, isExpanded: isSubagentsExpanded)
    }

    private var showsSubagentRows: Bool {
        !visibleSubagents.isEmpty
    }

    private var visibleSubagentRowCount: Int {
        guard isSubagentGroupOpen else { return waitingSubagents.count }
        return runningSubagents.count + (showsCompletedChildren ? completedSubagents.count : 0)
    }

    /// One `N done` row stands in for two or more completed children until the
    /// user opens it.
    private var showsCompletedChildren: Bool {
        completedSubagents.count <= 1 || isSubagentsDoneExpanded
    }

    /// TODO: the design also opens the group with the right arrow on the
    /// selected Session. The sidebar has no keyboard focus model of its own
    /// yet, so the chip is the only door for now.
    @ViewBuilder
    private func subagentCapsule(tokens: WarrenColorTokens) -> some View {
        if showsSubagentCapsule, let onToggleSubagents {
            let allDone = runningSubagents.isEmpty
            Button(action: onToggleSubagents) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(allDone ? "✓\(completedSubagents.count)" : "\(runningSubagents.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                }
                .foregroundStyle(allDone ? tokens.treeQuietText : tokens.sessionExtraRunningText)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(
                    isSubagentsExpanded || isHovered ? tokens.treeRowSelected : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .accessibilityLabel(allDone
                ? "\(completedSubagents.count) subagents done"
                : "\(runningSubagents.count) subagents running")
            .accessibilityValue(isSubagentsExpanded ? "Expanded" : "Collapsed")
            .warrenTooltip(isSubagentsExpanded ? "Hide subagents" : "Show subagents")
        }
    }

    /// The child rows: under the parent row, aligned to its title column, hung
    /// off one hairline from the parent's icon. They replace nothing and add no
    /// navigation of their own, because a subagent is not a Session.
    @ViewBuilder
    private func subagentRows(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if isSubagentGroupOpen {
                ForEach(runningSubagents) { agent in
                    subagentRow(agent, tokens: tokens)
                }
                if !showsCompletedChildren {
                    subagentDoneRow(tokens: tokens)
                } else {
                    ForEach(completedSubagents) { agent in
                        subagentRow(agent, tokens: tokens)
                    }
                }
            } else {
                ForEach(waitingSubagents) { agent in
                    subagentRow(agent, tokens: tokens)
                }
            }
        }
        .padding(.leading, Self.subagentRowIndent)
        .padding(.bottom, 2)
        .overlay(alignment: .topLeading) {
            subagentConnector(tokens: tokens, rowCount: visibleSubagentRowCount)
        }
    }

    @ViewBuilder
    private func subagentRow(
        _ agent: WarrenDesktopSubagent,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: 7) {
            subagentDot(agent, tokens: tokens)
            Text(agent.title)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.treeQuietText)
                .lineLimit(1)
                .fixedSize()
            subagentDescription(agent, tokens: tokens)
        }
        .frame(height: Self.subagentRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func subagentDot(
        _ agent: WarrenDesktopSubagent,
        tokens: WarrenColorTokens
    ) -> some View {
        if agent.isWaiting {
            Circle()
                .fill(tokens.warning)
                .frame(width: Self.subagentDotSize, height: Self.subagentDotSize)
        } else if agent.isRunning {
            Circle()
                .fill(tokens.success)
                .frame(width: Self.subagentDotSize, height: Self.subagentDotSize)
        } else {
            Circle()
                .strokeBorder(tokens.treeFaintText, lineWidth: 1)
                .frame(width: Self.subagentDotSize, height: Self.subagentDotSize)
        }
    }

    /// What a child is doing while it runs, and what it was asked to do once it
    /// is done. The activity is the most recent call from its own transcript;
    /// the summary stands in until the first one arrives.
    @ViewBuilder
    private func subagentDescription(
        _ agent: WarrenDesktopSubagent,
        tokens: WarrenColorTokens
    ) -> some View {
        let text = agent.isRunning
            ? (agent.lastActivity ?? agent.summary)
            : (agent.summary.isEmpty ? (agent.lastActivity ?? "") : agent.summary)
        if agent.isWaiting {
            // Waiting on a person is not running: it is the one row the user
            // has to act on, so it stays bright and still while the others
            // shimmer or dim.
            Text(WarrenDesktopActivityText.shortened(text))
                .font(.system(size: 12))
                .foregroundStyle(tokens.treeSessionText)
                .lineLimit(1)
        } else if agent.isRunning {
            Text(WarrenDesktopActivityText.shortened(text))
                .font(.system(size: 12))
                .lineLimit(1)
                .modifier(WarrenDesktopActivityShimmer(
                    base: tokens.treeSecondaryText,
                    peak: tokens.treeActivityHighlightText,
                    isActive: true
                ))
        } else {
            Text(WarrenDesktopActivityText.shortened(text))
                .font(.system(size: 12))
                .foregroundStyle(tokens.treeQuietText)
                .lineLimit(1)
        }
    }

    private func subagentDoneRow(tokens: WarrenColorTokens) -> some View {
        Button {
            onToggleSubagentsDone?()
        } label: {
            Text("\(completedSubagents.count) done")
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.treeQuietText)
                .frame(height: Self.subagentRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isInteractionDisabled)
        .accessibilityLabel("\(completedSubagents.count) subagents done")
    }

    /// The hairline that hangs the child rows off the parent's icon: one
    /// vertical drop, and a short tick into each row.
    private func subagentConnector(
        tokens: WarrenColorTokens,
        rowCount: Int
    ) -> some View {
        let x = WarrenDesktopSidebarMetrics.rowHorizontalPadding
            + WarrenDesktopSidebarMetrics.sessionIconSize / 2
        let step = Self.subagentRowHeight + 1
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: max(0, CGFloat(rowCount) * step - step / 2)))
            }
            .stroke(tokens.cardBorder, lineWidth: 1)
            ForEach(0..<rowCount, id: \.self) { index in
                Rectangle()
                    .fill(tokens.cardBorder)
                    .frame(width: 9, height: 1)
                    .offset(x: x, y: CGFloat(index) * step + step / 2)
            }
        }
        .allowsHitTesting(false)
    }

    static let subagentRowIndent: CGFloat = 36
    static let subagentRowHeight: CGFloat = 22
    static let subagentDotSize: CGFloat = 6

    /// The second line. Every Session row has one: what the Session is doing,
    /// what this turn did, or that it has not done anything yet.
    ///
    /// A working Session's line ticks on a ten-second clock: its trailing
    /// duration is read at a glance, and a per-second update would make the rail
    /// twitch. Only the working rows are driven by the clock; a resting age
    /// changes slowly enough to read once.
    @ViewBuilder
    private func secondLine(tokens: WarrenColorTokens, now: Date) -> some View {
        if session.activity == .working || session.shellState?.isRunningCommand == true {
            TimelineView(.periodic(from: Date(), by: 10)) { context in
                WarrenDesktopSecondLineView(
                    line: Self.secondLine(for: session, now: context.date),
                    tokens: tokens
                )
            }
        } else {
            WarrenDesktopSecondLineView(
                line: Self.secondLine(for: session, now: now),
                tokens: tokens
            )
        }
    }

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        Self.contextMenuActions(
            isPinned: session.pinned,
            onTogglePin: onTogglePin,
            onRename: onRename,
            onEnd: onEnd
        )
    }

    /// The leaf's menu model, kept separate from the view so the actions a
    /// Session can reach from the tree are assertable. A context menu is not
    /// part of the semantic tree, so this is the only place a test can see it.
    static func contextMenuActions(
        isPinned: Bool,
        onTogglePin: (() -> Void)?,
        onRename: (() -> Void)?,
        onEnd: (() -> Void)?
    ) -> [WarrenDesktopContextMenuAction] {
        var actions: [WarrenDesktopContextMenuAction] = []
        if let onTogglePin {
            actions.append(.button(
                title: isPinned ? "Unpin Session" : "Pin Session",
                action: onTogglePin
            ))
        }
        if let onRename {
            actions.append(.button(title: "Rename Session", action: onRename))
        }
        if let onEnd {
            if !actions.isEmpty {
                actions.append(.divider)
            }
            // Ending a Session stops a real process on the Host, so it reads
            // as destructive like every other resource deletion in the tree.
            actions.append(.button(title: "End Session…", destructive: true, action: onEnd))
        }
        return actions
    }

    /// The whole of both lines on hover. The row draws one line each, so the
    /// untruncated title and the untruncated activity have to be reachable
    /// somewhere, and the tooltip is where. The row shortens a command for its
    /// own width; this is the command as the Session reported it.
    private var helpText: String {
        var lines = ["\(providerName) · \(title)"]
        if let activity = Self.secondLine(for: session).announcement, activity != title {
            lines.append(activity)
        }
        return lines.joined(separator: "\n")
    }

    /// The shell row's card: what it last ran, how it exited, where it is, and
    /// the branch it is on. The second line drops these once the row rests.
    private func shellDetailRows() -> [WarrenDesktopDetailCard.Row] {
        var rows: [WarrenDesktopDetailCard.Row] = []
        let last = (session.shellState?.lastCommand ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            rows.append(.init(label: "Last command", value: last))
        }
        if let code = session.shellState?.displayedExitCode {
            rows.append(.init(label: "Exit code", value: "\(code)"))
        }
        let directory = session.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            rows.append(.init(label: "Directory", value: directory))
        }
        let branch = (scope.workspace.branch ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty {
            rows.append(.init(label: "Branch", value: branch))
        }
        return rows
    }

    private func shellHover(_ isInside: Bool) {
        shellDetailTask?.cancel()
        shellDetailTask = nil
        guard isInside, Self.usesLocationTitle(for: session) else {
            showsShellDetails = false
            isDwelling = false
            return
        }
        shellDetailTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            isDwelling = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            showsShellDetails = true
        }
    }
}

/// Applies the native tooltip only when a row still needs one. A shell row
/// replaced it with the detail card.
private struct WarrenDesktopRowHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// One line that ends by fading out rather than with an ellipsis.
///
/// The text is laid out at its own width inside a measured frame and then
/// clipped, so the line simply stops instead of drawing the truncation glyph a
/// row would otherwise end with; a mask fades its last few points into the row.
/// A line short enough to fit is unaffected, because the fade falls past its
/// last glyph.
///
/// The width comes from a `GeometryReader` rather than a frame of the line's
/// own. A line that overflows has by definition a wider content than its frame,
/// and both `mask` and the enclosing layout measure that content: without a
/// measured width the fade lands past the row and the sidebar lays its rows out
/// around a text it cannot show.
struct WarrenDesktopFadingLine<Content: View>: View {
    /// Which end of an overflowing line fades. A name keeps its start and
    /// fades its end; a location keeps its tail and fades its start.
    enum FadeEdge {
        case trailing
        case leading
    }

    private let content: Content
    private let edge: FadeEdge
    /// The content's natural width, measured so a line that fits is not faded
    /// or pushed to one end just because it *could* overflow.
    @State private var contentWidth: CGFloat = 0

    init(edge: FadeEdge = .trailing, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.edge = edge
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let overflows = contentWidth > width
            let alignment: Alignment = edge == .leading && overflows ? .trailing : .leading
            content
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { measured in
                        Color.clear.preference(
                            key: WarrenDesktopFadingLineWidthKey.self,
                            value: measured.size.width
                        )
                    }
                )
                .frame(width: width, alignment: alignment)
                .clipped()
                .mask(alignment: alignment) {
                    if overflows {
                        LinearGradient(
                            stops: stops(in: width),
                            startPoint: edge == .leading ? .trailing : .leading,
                            endPoint: edge == .leading ? .leading : .trailing
                        )
                        .frame(width: width)
                    } else {
                        Color.black
                    }
                }
                .onPreferenceChange(WarrenDesktopFadingLineWidthKey.self) { contentWidth = $0 }
        }
    }

    private func stops(in width: CGFloat) -> [Gradient.Stop] {
        [
            .init(color: .black, location: 0),
            .init(color: .black, location: Self.fadeStart(in: width)),
            .init(color: .clear, location: 1),
        ]
    }

    /// Where the fade begins, as a share of the line's width.
    static func fadeStart(in width: CGFloat) -> CGFloat {
        let fade = WarrenDesktopSidebarMetrics.sessionLineFadeWidth
        guard width > fade else { return 0 }
        return (width - fade) / width
    }
}

/// The measured width of a `WarrenDesktopFadingLine`'s content, so the line
/// knows whether it is actually overflowing.
private struct WarrenDesktopFadingLineWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The slow drift that tells a working row from a resting one.
///
/// A highlight crosses the activity line about once every six seconds and then
/// rests for the last third of the cycle, so the motion never settles into a
/// loop the eye can watch. The colours stay between the activity line's own tier
/// and one step above it: this is here to say "working" to a glance that is
/// already moving past, not to hold it.
struct WarrenDesktopActivityShimmer: ViewModifier {
    let base: Color
    let peak: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sweep and its rest.
    static let period: TimeInterval = 6
    /// The share of the period the highlight spends crossing the line.
    static let sweepShare: Double = 0.7
    /// How wide the moving band is, as a share of the line's width.
    static let bandWidth: Double = 0.6

    func body(content: Content) -> some View {
        if isActive, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: false)) { context in
                content.foregroundStyle(gradient(at: context.date))
            }
        } else {
            content.foregroundStyle(base)
        }
    }

    private func gradient(at date: Date) -> LinearGradient {
        let center = Self.center(at: date)
        let half = Self.bandWidth / 2
        return LinearGradient(
            stops: [
                .init(color: base, location: 0),
                .init(color: peak, location: 0.5),
                .init(color: base, location: 1),
            ],
            startPoint: UnitPoint(x: center - half, y: 0.5),
            endPoint: UnitPoint(x: center + half, y: 0.5)
        )
    }

    /// Where the highlight's centre sits in the line, from just past its right
    /// edge to just past its left, so the band enters and leaves the text.
    static func center(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period)
        let progress = (elapsed < 0 ? elapsed + period : elapsed) / period
        guard progress < sweepShare else { return -bandWidth / 2 }
        // The specification's cubic-bezier(.45, 0, .55, 1) is the standard
        // ease-in-out curve; smoothstep is the same shape and needs no solver.
        let eased = smoothstep(progress / sweepShare)
        return (1 + bandWidth / 2) - (1 + bandWidth) * eased
    }

    /// Ease in and out: slow at both ends, fastest in the middle.
    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct WarrenDesktopSidebarSectionAction: Identifiable {
    let id: String
    let image: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
}

struct WarrenDesktopSidebarSectionHeader: View {
    let title: String
    var disclosureExpanded: Bool? = nil
    var actionImage: String? = nil
    var actionLabel = ""
    var actionVisible = true
    var actionEnabled = true
    var onToggle: (() -> Void)?
    var onAction: (() -> Void)?
    var additionalActions: [WarrenDesktopSidebarSectionAction]
    /// One mark per Session in the section, drawn as dots while it is folded.
    var foldMarks: [WarrenActivityMark?] = []

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool
    @FocusState private var isToggleFocused: Bool
    @FocusState private var focusedAdditionalActionID: String?

    private var isFolded: Bool { disclosureExpanded == false }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let revealsActions = isHovered || forceHover || isActionFocused
            || focusedAdditionalActionID != nil
        HStack(spacing: 2) {
            Group {
                if let onToggle {
                    Button(action: onToggle) {
                        titleLabel(tokens: tokens)
                    }
                    .buttonStyle(.plain)
                    .disabled(!actionEnabled)
                    .focused($isToggleFocused)
                    .accessibilityLabel(title)
                    .accessibilityValue(isFolded ? "Collapsed" : "Expanded")
                } else {
                    titleLabel(tokens: tokens)
                }
            }

            ForEach(additionalActions) { action in
                Button(action: action.action) {
                    Image(systemName: action.image)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(
                    isFocused: focusedAdditionalActionID == action.id
                ))
                .disabled(!action.isEnabled)
                .focused($focusedAdditionalActionID, equals: action.id)
                .opacity(revealsActions ? 1 : 0)
                .animation(
                    WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                    value: revealsActions
                )
                .accessibilityLabel(action.label)
                .warrenTooltip(action.label)
            }

            if actionVisible, let actionImage, let onAction {
                Button(action: onAction) {
                    Image(systemName: actionImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isActionFocused))
                .disabled(!actionEnabled)
                .focused($isActionFocused)
                .accessibilityLabel(actionLabel)
                .warrenTooltip(actionLabel)
            }

            if isFolded, WarrenDesktopTreeFoldDots.drawsAny(foldMarks) {
                WarrenDesktopTreeFoldDots(marks: foldMarks)
            }

            if let disclosureExpanded, let onToggle {
                Button(action: onToggle) {
                    WarrenDesktopTreeChevron(isExpanded: disclosureExpanded)
                        .frame(width: 14, height: WarrenDesktopSidebarMetrics.sectionHeaderHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!actionEnabled)
                .accessibilityHidden(true)
            }
        }
        .foregroundStyle(tokens.treeQuietText)
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(height: WarrenDesktopSidebarMetrics.sectionHeaderHeight)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    private func titleLabel(tokens: WarrenColorTokens) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(tokens.treeQuietText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: WarrenDesktopSidebarMetrics.sectionHeaderHeight)
            .contentShape(.rect)
    }
}

struct WarrenDesktopDeleteTaskConfirmation: View {
    let task: WarrenTask
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let isConfirmEnabled: Bool
    let validationMessage: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Delete task?",
            message: "\u{201C}\(task.name)\u{201D} will be removed from Warren.\n"
                + "Linked workspaces and their terminal sessions will be kept and detached from this task."
        ) {
            if let validationMessage {
                Text(validationMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: "Delete",
                isDestructive: true,
                isConfirmEnabled: isConfirmEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        }
        .onExitCommand(perform: onCancel)
    }
}

struct WarrenDesktopDeleteWorkspaceConfirmation: View {
    let workspace: Workspace
    let project: Project?
    @Binding var removeWorktree: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let isConfirmEnabled: Bool
    let validationMessage: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private var isWorktree: Bool {
        workspaceIsWorktree(workspace, project: project)
    }

    private var canRemoveWorktree: Bool {
        isWorktree && workspace.managedWorktree && !workspace.worktreeLocked
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Delete workspace?",
            message: "\u{201C}\(workspace.name)\u{201D} and every session it owns will be removed from Warren."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if canRemoveWorktree {
                    Toggle("Also delete the local worktree directory", isOn: $removeWorktree)
                        .toggleStyle(.checkbox)
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.foreground)
                        .tint(tokens.highlight)
                        .help("Leave unchecked to keep the Git worktree and branch on disk.")
                        .disabled(!isConfirmEnabled)
                } else if isWorktree && workspace.worktreeLocked {
                    Text("This Git worktree is locked and will be kept on disk.")
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isWorktree && project != nil {
                    Text("This checkout is managed outside Warren and will be kept on disk.")
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.mutedForeground)
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: "Delete",
                isDestructive: true,
                isConfirmEnabled: isConfirmEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        }
        .onExitCommand(perform: onCancel)
    }
}

func workspaceIsWorktree(_ workspace: Workspace, project: Project?) -> Bool {
    guard let project else { return true }
    return URL(fileURLWithPath: workspace.path)
        .standardizedFileURL.path
        != URL(fileURLWithPath: project.rootPath)
            .standardizedFileURL.path
}

struct WarrenDesktopDeleteProjectConfirmation: View {
    let project: Project
    let workspaceCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let isConfirmEnabled: Bool
    let validationMessage: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Delete project?",
            message: "\u{201C}\(project.name)\u{201D} and its \(workspaceCount) workspaces will be removed from Warren.\n"
                + "Local Git worktree directories are kept on disk."
        ) {
            if let validationMessage {
                Text(validationMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: "Delete",
                isDestructive: true,
                isConfirmEnabled: isConfirmEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        }
        .onExitCommand(perform: onCancel)
    }
}

/// The shared Cancel / primary footer for a destructive confirmation.
/// Primary is rightmost and carries its shortcut as a keycap.
struct WarrenDesktopDialogFooter: View {
    let confirmLabel: String
    var isDestructive = false
    var isConfirmEnabled = true
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(action: onCancel) {
                HStack(spacing: 6) {
                    Text("Cancel")
                    WarrenDialogKeycap("esc")
                }
            }
            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
            .keyboardShortcut(.cancelAction)
            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    Text(confirmLabel)
                    WarrenDialogKeycap(
                        "\u{2318}\u{23CE}",
                        isOnPrimary: !isDestructive
                    )
                }
            }
            .modifier(WarrenDialogConfirmButtonStyle(
                isDestructive: isDestructive,
                isEnabled: isConfirmEnabled
            ))
        }
    }
}

