import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

enum WarrenDesktopDeletionRequest {
    case task(WarrenTask)
    case workspace(Workspace, project: Project?)
    case project(Project, workspaceCount: Int)
    case terminalGroup(TerminalGroup, sessionCount: Int)
}

struct WarrenDesktopSidebarRows: View {
    let taskGroups: [WarrenDesktopTaskGroup]
    let groups: [WarrenDesktopProjectGroup]
    let terminalGroups: [WarrenDesktopTerminalGroup]
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
    /// Multi-host mode reuses this view for current-host-only sections (Tasks
    /// and Terminal Groups) and renders the scoped project tree separately.
    let showsProjects: Bool
    @Binding var tree: WarrenDesktopSidebarTreeState
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let isInteractionDisabled: Bool
    let onAddProject: () -> Void
    let onRequestTaskCreate: () -> Void
    let onFocusTask: (TaskID) -> Void
    let onRequestTerminalGroupCreate: () -> Void
    let onRequestTerminalGroupEdit: (TerminalGroup) -> Void
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
        terminalGroups: [WarrenDesktopTerminalGroup],
        workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary],
        activeWorkspaceIDs: Set<WorkspaceID> = [],
        editorMarkedWorkspaceIDs: Set<WorkspaceID> = [],
        activeSessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]] = [:],
        workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact,
        showsTasks: Bool = true,
        showsProjects: Bool = true,
        tree: Binding<WarrenDesktopSidebarTreeState>,
        isCollapsed: Bool,
        selection: WarrenDesktopSidebarSelection?,
        selectedTabID: String? = nil,
        deletingProjectIDs: Set<ProjectID>,
        deletingWorkspaceIDs: Set<WorkspaceID>,
        endpointCapabilities: WarrenDesktopEndpointCapabilities,
        isInteractionDisabled: Bool,
        onAddProject: @escaping () -> Void,
        onRequestTaskCreate: @escaping () -> Void,
        onFocusTask: @escaping (TaskID) -> Void,
        onRequestTerminalGroupCreate: @escaping () -> Void,
        onRequestTerminalGroupEdit: @escaping (TerminalGroup) -> Void,
        onAction: @escaping (WarrenDesktopAction) -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onRequestDeletion: @escaping (WarrenDesktopDeletionRequest) -> Void,
        onOpenEditor: @escaping (WorkspaceID) -> Void = { _ in },
        onSplitDropSession: ((String, String, SplitDropTarget) -> Void)? = nil
    ) {
        self.taskGroups = taskGroups
        self.groups = groups
        self.terminalGroups = terminalGroups
        self.workspaceActivitySummaries = workspaceActivitySummaries
        self.activeWorkspaceIDs = activeWorkspaceIDs
        self.editorMarkedWorkspaceIDs = editorMarkedWorkspaceIDs
        self.activeSessionsByWorkspaceID = activeSessionsByWorkspaceID
        self.workspaceDisplayMode = workspaceDisplayMode
        self.showsTasks = showsTasks
        self.showsProjects = showsProjects
        self._tree = tree
        self.isCollapsed = isCollapsed
        self.selection = selection
        self.selectedTabID = selectedTabID
        self.deletingProjectIDs = deletingProjectIDs
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.endpointCapabilities = endpointCapabilities
        self.isInteractionDisabled = isInteractionDisabled
        self.onAddProject = onAddProject
        self.onRequestTaskCreate = onRequestTaskCreate
        self.onFocusTask = onFocusTask
        self.onRequestTerminalGroupCreate = onRequestTerminalGroupCreate
        self.onRequestTerminalGroupEdit = onRequestTerminalGroupEdit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // This list is bounded by the sidebar scroll view and also hosts
        // optional drag-frame measurement. Eager layout keeps geometry
        // feedback out of LazyVStack's placement cache during navigation.
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            terminalGroupsSection
            if showsTasks {
                tasksSection
            }
            if showsProjects {
                if !isCollapsed {
                    projectsSectionHeader
                }
                if groups.isEmpty && !isCollapsed {
                    noProjectsMessage
                } else if tree.showsActiveOnly && visibleProjectGroups.isEmpty && !isCollapsed {
                    noActiveWorkspacesMessage
                }
                if isCollapsed || !tree.projectsCollapsed || hasPendingProjectDeletion {
                    ForEach(Array(visibleProjectGroups.enumerated()), id: \.element.id) { index, group in
                        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                            projectRow(for: group)
                            if isCollapsed
                                || isProjectExpanded(group.project.id)
                                || hasDeletingWorkspace(in: group.project.id) {
                                ForEach(group.workspaces) { workspace in
                                    WarrenDesktopSessionLeafGroup(
                                        leafCount: ownsSessionLeaves(
                                            workspace,
                                            semanticScope: "project-list"
                                        ) ? activeSessions(in: workspace.id).count : 0,
                                        mode: workspaceDisplayMode,
                                        workspaceGlyph: WarrenDesktopWorkspaceGlyph(workspace),
                                        isCurrentScope: selection == .workspace(workspace.id)
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
                                    .padding(.top, workspaceDisplayMode.sessionGroupSpacing)
                                }
                            }
                        }
                        // The gap separates one project's subtree from the next.
                        // The first group already sits below the section header.
                        .padding(.top, index == 0 ? 0 : projectGroupSpacing)
                    }
                    .transition(.opacity)
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
            guard case .workspace(let workspaceID)? = newSelection,
                  let workspace = groups
                    .flatMap(\.workspaces)
                    .first(where: { $0.id == workspaceID })
            else { return }
            withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.expandedProjectIDs.insert(workspace.projectID)
                if let taskID = workspace.taskID {
                    tree.expandedTaskIDs.insert(taskID)
                }
            }
        }
        .onAppear {
            previousGroups = groups
            previousTaskGroups = taskGroups
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
                tree.expandedProjectIDs.formUnion(grownProjectIDs)
                // If a workspace was created under a task, also expand that task.
                for projectID in grownProjectIDs {
                    if let newWorkspace = newGroups.first(where: { $0.project.id == projectID })?.workspaces.last,
                       let taskID = newWorkspace.taskID {
                        tree.expandedTaskIDs.insert(taskID)
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
                tree.expandedTaskIDs.formUnion(grownTaskIDs)
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
            tree.expandedProjectIDs.formUnion(projectIDs)
            tree.projectsCollapsed = false
        }
    }

    private var projectsSectionHeader: some View {
        let allProjectsExpanded = areAllProjectsExpanded
        return WarrenDesktopSidebarSectionHeader(
            title: "Projects",
            disclosureExpanded: !tree.projectsCollapsed,
            actionVisible: false,
            onToggle: toggleProjects,
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
            ]
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
        case .terminalGroup(let groupID):
            return session.terminalGroupID == groupID
        case .project, nil:
            return false
        }
    }

    /// Session leaves are only rendered where they can be read as leaves.
    ///
    /// The collapsed rail is 32pt of icons; a full-width leaf row there has no
    /// parent to sit under and no room for its title, so rich mode falls back to
    /// the workspace's aggregate marker until the rail is expanded again.
    private var showsSessionRows: Bool {
        workspaceDisplayMode.isRich && !isCollapsed
    }

    /// Whether a workspace's Session leaves belong to the copy rendered in
    /// `semanticScope`.
    ///
    /// Leaves follow navigation: a Task-linked workspace routes selection to its
    /// Task copy, so the Projects copy stays context-only. The collapsed rail
    /// lists no leaves at all. The row and both call sites ask this one question,
    /// so the leaf count and the leaf rows cannot disagree.
    private func ownsSessionLeaves(
        _ workspace: Workspace,
        semanticScope: String
    ) -> Bool {
        showsSessionRows && !routesSelectionToTaskRow(workspace, semanticScope: semanticScope)
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
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    if !isCollapsed {
                        WarrenDesktopSidebarSectionHeader(
                            title: "Tasks",
                            disclosureExpanded: !tree.tasksCollapsed,
                            actionImage: "plus",
                            actionLabel: "New task",
                            actionEnabled: !isInteractionDisabled,
                            onToggle: toggleTasks,
                            onAction: onRequestTaskCreate,
                            additionalActions: []
                        )
                    }
                    // An empty section states its own emptiness by having no
                    // rows. Placeholder copy repeats that at full row cost, and
                    // the section header's own "+" already says what to do
                    // about it.
                    if !tree.tasksCollapsed || isCollapsed {
                        ForEach(visibleTaskGroups) { group in
                            taskRow(group)
                            if isCollapsed || tree.expandedTaskIDs.contains(group.task.id) {
                                ForEach(group.workspaces) { workspace in
                                    if let project = groups.first(where: { $0.project.id == workspace.projectID }) {
                                        WarrenDesktopSessionLeafGroup(
                                            leafCount: ownsSessionLeaves(
                                                workspace,
                                                semanticScope: "task-list"
                                            ) ? activeSessions(in: workspace.id).count : 0,
                                            mode: workspaceDisplayMode,
                                            workspaceGlyph: WarrenDesktopWorkspaceGlyph(workspace),
                                            isCurrentScope: selection == .workspace(workspace.id)
                                        ) {
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
                                        .padding(.top, workspaceDisplayMode.sessionGroupSpacing)
                                    }
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
            isCollapsed: isCollapsed,
            isExpanded: tree.expandedTaskIDs.contains(group.task.id),
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
            }
        )
        .id("task.\(group.task.id.description)")
    }

    private var visibleTerminalGroups: [WarrenDesktopTerminalGroup] {
        if tree.showsActiveOnly {
            return terminalGroups.filter { $0.runningSessionCount > 0 }
        }
        return terminalGroups
    }

    private func ownsTerminalGroupSessionLeaves(
        _ group: WarrenDesktopTerminalGroup
    ) -> Bool {
        showsSessionRows
    }

    private func activeSessions(
        in group: WarrenDesktopTerminalGroup
    ) -> [WarrenDesktopSession] {
        group.sessions.filter { $0.state.isActive }
    }

    private func isTerminalGroupRowSelected(
        _ group: WarrenDesktopTerminalGroup,
        ownsSessionLeaves: Bool
    ) -> Bool {
        guard selection == .terminalGroup(group.id) else { return false }
        guard ownsSessionLeaves else { return true }
        return !activeSessions(in: group).contains(where: isSessionSelected)
    }

    private func terminalGroupRowContainsSelection(
        _ group: WarrenDesktopTerminalGroup,
        ownsSessionLeaves: Bool
    ) -> Bool {
        guard selection == .terminalGroup(group.id) else { return false }
        return !isTerminalGroupRowSelected(group, ownsSessionLeaves: ownsSessionLeaves)
    }

    private func terminalGroupRow(
        _ group: WarrenDesktopTerminalGroup,
        ownsSessionLeaves: Bool
    ) -> some View {
        WarrenDesktopTerminalGroupRow(
            group: group,
            isCollapsed: isCollapsed,
            isSelected: isTerminalGroupRowSelected(group, ownsSessionLeaves: ownsSessionLeaves),
            containsSelection: terminalGroupRowContainsSelection(group, ownsSessionLeaves: ownsSessionLeaves),
            isInteractionDisabled: isInteractionDisabled,
            showsSessionChildren: ownsSessionLeaves && !activeSessions(in: group).isEmpty,
            rowHeight: workspaceDisplayMode.rowHeight,
            onSelect: { onAction(.selectTerminalGroup(group.id)) },
            onDoubleClick: { onAction(.selectTerminalGroup(group.id)) },
            onRename: { onRequestTerminalGroupEdit(group.group) },
            onSetHome: { onRequestTerminalGroupEdit(group.group) },
            onDelete: {
                onRequestDeletion(.terminalGroup(
                    group.group,
                    sessionCount: group.sessions.count
                ))
            }
        )
    }

    @ViewBuilder
    private func terminalGroupSessionRows(
        for group: WarrenDesktopTerminalGroup
    ) -> some View {
        ForEach(activeSessions(in: group)) { session in
            WarrenDesktopWorkspaceSessionRow(
                session: session,
                terminalGroup: group.group,
                isSelected: isSessionSelected(session),
                isInteractionDisabled: isInteractionDisabled,
                onOpen: { onAction(.openSession(session.id)) },
                onRename: {
                    onRequestRename(.session(session.id, title: session.displayTitle))
                },
                onTogglePin: {
                    onAction(.setSessionPinned(session.id, !session.pinned))
                },
                onEnd: { onAction(.deleteSession(session.id)) },
                onSplitDrop: onSplitDropSession
            )
        }
    }

    private var terminalGroupsSection: some View {
        Group {
            if !tree.showsActiveOnly || !visibleTerminalGroups.isEmpty {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    if !isCollapsed {
                        WarrenDesktopSidebarSectionHeader(
                            title: "Terminals",
                            disclosureExpanded: !tree.terminalGroupsCollapsed,
                            actionImage: "plus",
                            actionLabel: "New terminal group",
                            actionEnabled: !isInteractionDisabled,
                            onToggle: toggleTerminalGroups,
                            onAction: onRequestTerminalGroupCreate,
                            additionalActions: []
                        )
                    }
                    // No rows is the empty state; see the Tasks section above.
                    if !tree.terminalGroupsCollapsed || isCollapsed {
                        ForEach(visibleTerminalGroups) { group in
                            let ownsLeaves = ownsTerminalGroupSessionLeaves(group)
                            let liveSessions = activeSessions(in: group)
                            WarrenDesktopSessionLeafGroup(
                                leafCount: ownsLeaves ? liveSessions.count : 0,
                                mode: workspaceDisplayMode,
                                workspaceGlyph: .terminalGroup,
                                isCurrentScope: selection == .terminalGroup(group.id)
                            ) {
                                terminalGroupRow(group, ownsSessionLeaves: ownsLeaves)
                            } leaves: {
                                terminalGroupSessionRows(for: group)
                            }
                            .padding(.top, workspaceDisplayMode.sessionGroupSpacing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var selectedProjectID: ProjectID? {
        switch selection {
        case .project(let projectID):
            return projectID
        case .workspace(let workspaceID):
            return groups.first { $0.workspaces.contains { $0.id == workspaceID } }?.project.id
        case .terminalGroup:
            return nil
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

        guard !tree.projectsCollapsed || isCollapsed else {
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
        case .terminalGroup(let groupID):
            onAction(.selectTerminalGroup(groupID))
        }
    }

    private func toggleProject(_ projectID: ProjectID) {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if tree.expandedProjectIDs.contains(projectID) {
                tree.expandedProjectIDs.remove(projectID)
            } else {
                tree.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private func isProjectExpanded(_ projectID: ProjectID) -> Bool {
        WarrenSidebarDragPresentation.isExpanded(
            projectID,
            persistedExpansions: tree.expandedProjectIDs,
            autoCollapse: dragAutoCollapse
        )
    }

    private func setDragAutoCollapse(_ autoCollapse: WarrenSidebarDragAutoCollapse?) {
        guard autoCollapse == nil || !isCollapsed else { return }
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
            && groups.allSatisfy { tree.expandedProjectIDs.contains($0.project.id) }
    }

    private func toggleAllProjects() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            if areAllProjectsExpanded {
                tree.expandedProjectIDs.removeAll()
            } else {
                tree.expandedProjectIDs.formUnion(groups.map(\.project.id))
            }
        }
    }

    private func toggleTerminalGroups() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.terminalGroupsCollapsed.toggle()
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
            if tree.expandedTaskIDs.contains(taskID) {
                tree.expandedTaskIDs.remove(taskID)
            } else {
                tree.expandedTaskIDs.insert(taskID)
            }
        }
    }

    @ViewBuilder
    private func projectRow(
        for group: WarrenDesktopProjectGroup
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
                isCollapsed: isCollapsed,
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
                                    isLastOfList: group.project.id == groups.last?.project.id
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
        let leafCount = ownsLeaves ? activeSessions(in: workspace.id).count : 0
        ZStack {
            let activitySummary = workspaceActivitySummary(workspace.id)
            WarrenDesktopWorkspaceRow(
                workspace: presentedWorkspace,
                semanticScope: semanticScope,
                activity: activitySummary?.activity,
                activeTabCount: activitySummary?.activeTabCount ?? 0,
                isCollapsed: isCollapsed,
                isSelected: isWorkspaceRowSelected(
                    workspace,
                    ownsSessionLeaves: ownsLeaves
                ) && !isSelectionDisabled,
                containsSelection: workspaceRowContainsSelection(
                    workspace,
                    ownsSessionLeaves: ownsLeaves
                ) && !isSelectionDisabled,
                isPinned: workspace.pinned,
                isEditorMarked: editorMarkedWorkspaceIDs.contains(workspace.id),
                onOpenEditor: { onOpenEditor(workspace.id) },
                isDeleting: isDeleting,
                isInteractionDisabled: isInteractionDisabled || isProjectDeleting || isDeleting,
                isMutationDisabled: false,
                isSelectionDisabled: isSelectionDisabled,
                showsSessionChildren: leafCount > 0,
                rowHeight: workspaceDisplayMode.rowHeight,
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
                onSplitDrop: onSplitDropSession
            )
        }
    }

    private func activeSessions(
        in workspaceID: WorkspaceID
    ) -> [WarrenDesktopSession] {
        activeSessionsByWorkspaceID[workspaceID] ?? []
    }

    private var projectGroupSpacing: CGFloat {
        workspaceDisplayMode.projectGroupSpacing
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
            return isProjectDeletionPending(projectID)
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
/// The row is one line: the provider icon leads, the session title takes the
/// remaining width, and the trailing slot carries the state. A second line
/// naming the provider was tried and removed — the icon already carries it, and
/// two lines inside a navigation row leaves neither enough vertical room.
///
/// Trailing detail is the activity marker alone, and only for a Session that
/// reports Agent activity. The marker's color already separates a working Agent
/// from a blocked or failed one, so a state word beside it only competed with
/// the title for width; the full explanation still reaches assistive technology
/// and the hover tooltip. A plain shell has no activity Warren can observe, so
/// its leaf spends the trailing slot on nothing rather than on an invented
/// marker.
enum WarrenDesktopSessionRowScope {
    case workspace(project: Project, workspace: Workspace, semanticScope: String)
    case terminalGroup(TerminalGroup)
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
        onSplitDrop: ((String, String, SplitDropTarget) -> Void)? = nil
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
    }

    init(
        session: WarrenDesktopSession,
        terminalGroup: TerminalGroup,
        isSelected: Bool = false,
        isInteractionDisabled: Bool,
        onOpen: @escaping () -> Void,
        onRename: (() -> Void)? = nil,
        onTogglePin: (() -> Void)? = nil,
        onEnd: (() -> Void)? = nil,
        onSplitDrop: ((String, String, SplitDropTarget) -> Void)? = nil
    ) {
        self.session = session
        self.scope = .terminalGroup(terminalGroup)
        self.isSelected = isSelected
        self.isInteractionDisabled = isInteractionDisabled
        self.onOpen = onOpen
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onEnd = onEnd
        self.onSplitDrop = onSplitDrop
    }

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    private var providerName: String {
        session.presentedKind.displayName
    }

    private var title: String {
        Self.displayTitle(for: session)
    }

    /// The row label: a user-set name wins, otherwise the running command and
    /// the directory, so an unnamed shell never reads as the generic "Shell".
    static func displayTitle(for session: WarrenDesktopSession) -> String {
        let providerName = session.presentedKind.displayName
        let fallback = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = TerminalSessionPresentation.tabTitle(
            customTitle: session.customTitle,
            title: session.title,
            kind: session.presentedKind,
            process: session.runtimeProcess,
            commandLine: session.runtimeCommandLine,
            directory: session.workingDirectory,
            fallbackTitle: fallback.isEmpty ? providerName : fallback
        )
        return resolved.isEmpty ? providerName : resolved
    }

    private var attention: AgentAttention? {
        session.agentStatus?.attention
    }

    /// The Activity state word, when there is one.
    ///
    /// A shell that never bound an Agent reports no activity, so it has no state
    /// to name. Treating that as "Running" claimed knowledge of a process Warren
    /// does not track.
    private var statusLabel: String? {
        if let attention {
            return attention.kind.rowLabel
        }
        guard let activity = session.activity else { return nil }
        switch activity {
        case .working: return "Working"
        case .blocked: return "Needs attention"
        case .failed: return "Failed"
        case .ready: return "Idle"
        case .exited: return "Exited"
        }
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
        switch session.activity {
        case .blocked, .failed, .exited:
            return statusLabel
        case .working, .ready:
            return nil
        case .none:
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
        case let .terminalGroup(group):
            return "terminal-group-session.\(group.id.description).\(session.id.description)"
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
        if session.pinned {
            values.append("Pinned")
        }
        switch scope {
        case let .workspace(project, workspace, _):
            values.append(project.name)
            values.append(workspace.name)
        case let .terminalGroup(group):
            values.append(group.name.isEmpty ? "Terminal Group" : group.name)
        }
        if isSelected {
            values.append("Selected")
        }
        return values.joined(separator: " · ")
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: onOpen) {
            // The leaf indent is nudged right so its icon clears the rail, and
            // the glyph-to-title gap gives that width back. The title's origin
            // therefore does not move, so the extra rail gap costs the readable
            // column nothing.
            HStack(spacing: WarrenSpacing.compact - WarrenDesktopSidebarIndent.sessionGuideGap) {
                sessionIcon
                    .frame(width: WarrenLayoutMetrics.sidebarLeafIconSlotSize,
                           height: WarrenLayoutMetrics.sidebarLeafIconSlotSize)
                Text(title)
                    .font(WarrenTypography.navigationItem)
                    .foregroundStyle(
                        isSelected
                            ? tokens.sidebarLeafSelectedText
                            : tokens.sidebarLeafText
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                if session.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tokens.sidebarMetaText)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: WarrenSpacing.xs)

                if let activity = session.activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                }
            }
            .padding(.leading, WarrenDesktopSidebarIndent.session)
            .padding(.trailing, WarrenSpacing.compact)
            .frame(maxWidth: .infinity, minHeight: rowHeight)
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
                        onSplitDrop: onSplitDrop
                    )
                }
            }
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .opacity(isInteractionDisabled ? 0.62 : 1)
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
        .help(helpText)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contextMenu {
            if !isInteractionDisabled, !contextMenuActions.isEmpty {
                WarrenDesktopContextMenu(contextMenuActions)
            }
        }
        // A leaf's selection fill is inset like every other row's. Without this
        // it started at the rail's edge, so the deepest row in the tree drew the
        // widest highlight and read as the outermost one.
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var rowHeight: CGFloat {
        WarrenDesktopWorkspaceDisplayMode.rich.rowHeight
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

    private var helpText: String {
        guard let detailLabel else {
            return "Open \(providerName) session \(title)"
        }
        return "\(providerName) · \(detailLabel)"
    }

    @ViewBuilder
    private var sessionIcon: some View {
        if let preset = WarrenDesktopSessionPreset.builtIns.first(where: {
            $0.request.kind == session.presentedKind
        }) {
            WarrenDesktopPresetIcon(preset: preset)
        } else {
            Image(systemName: session.presentedKind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
                .accessibilityHidden(true)
        }
    }
}

private extension AgentAttentionKind {
    /// The row says what is being asked of the user, not which enum case the
    /// provider reported.
    var rowLabel: String {
        switch self {
        case .input: "Input needed"
        case .approval: "Approval needed"
        }
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool
    @FocusState private var isToggleFocused: Bool
    @FocusState private var focusedAdditionalActionID: String?

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            if let onToggle {
                Button(action: onToggle) {
                    titleLabel
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
                .disabled(!actionEnabled)
                .focused($isToggleFocused)
            } else {
                // Sections without a disclosure control keep the same label
                // styling as collapsible sections instead of rendering a
                // disabled, dimmed button.
                titleLabel
            }

            ForEach(additionalActions) { action in
                Button(action: action.action) {
                    Image(systemName: action.image)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(
                    isFocused: focusedAdditionalActionID == action.id
                ))
                .disabled(!action.isEnabled)
                .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                       height: WarrenLayoutMetrics.sidebarActionButtonSize)
                .contentShape(.rect)
                .focused($focusedAdditionalActionID, equals: action.id)
                .accessibilityLabel(action.label)
            }

            if actionVisible, let actionImage, let onAction {
                Button(action: onAction) {
                    Image(systemName: actionImage)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isActionFocused))
                .disabled(!actionEnabled)
                .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                       height: WarrenLayoutMetrics.sidebarActionButtonSize)
                .contentShape(.rect)
                .focused($isActionFocused)
                .accessibilityLabel(actionLabel)
            }
        }
        // A heading names its region; it does not compete with the resources
        // under it. Its controls rise to the readable tier on hover.
        .foregroundStyle(isHovered ? tokens.mutedForeground : tokens.sidebarSectionText)
        .frame(height: WarrenLayoutMetrics.sidebarSectionLabelHeight)
        .padding(.leading, WarrenDesktopSidebarIndent.section)
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }

    private var titleLabel: some View {
        HStack(spacing: WarrenSpacing.small) {
            Text(title.uppercased())
                .font(WarrenTypography.sectionLabel)
                .tracking(1.0)
            if let disclosureExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                    .opacity(isHovered || isToggleFocused ? 1 : 0)
                    .animation(
                        WarrenMotion.animation(
                            .stateChange,
                            reduceMotion: reduceMotion
                        ),
                        value: disclosureExpanded
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WarrenDesktopDeleteTaskConfirmation: View {
    let task: WarrenTask
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let isConfirmEnabled: Bool
    let validationMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete task?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("\u{201C}\(task.name)\u{201D} will be removed from Warren.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            Text("Linked workspaces and their terminal sessions will be kept and detached from this task.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Text(validationMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                    .disabled(!isConfirmEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 390)
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

    private var isWorktree: Bool {
        workspaceIsWorktree(workspace, project: project)
    }

    private var canRemoveWorktree: Bool {
        isWorktree && workspace.managedWorktree && !workspace.worktreeLocked
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete workspace?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("“\(workspace.name)” and every session it owns will be removed from Warren.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

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

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                    .disabled(!isConfirmEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 380)
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

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete project?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("“\(project.name)” and its \(workspaceCount) workspace(s) will be removed from Warren.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            Text("Local Git worktree directories are kept on disk.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)

            if let validationMessage {
                Text(validationMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                    .disabled(!isConfirmEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 380)
        .onExitCommand(perform: onCancel)
    }
}

struct WarrenDesktopDeleteTerminalGroupConfirmation: View {
    let group: TerminalGroup
    let sessionCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let isConfirmEnabled: Bool
    let validationMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("Delete terminal group?")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            Text("\"\(group.name)\" and its \(sessionCount) session(s) will be removed from Warren.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            Text("Running sessions will be terminated.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.warning)

            if let validationMessage {
                Text(validationMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                    .disabled(!isConfirmEnabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 390)
        .onExitCommand(perform: onCancel)
    }
}
