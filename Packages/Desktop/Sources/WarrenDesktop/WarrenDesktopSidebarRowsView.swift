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
    let activeAgentGroups: [WarrenDesktopActiveAgentGroup]
    /// Kept for embedded callers that still render the legacy rows directly;
    /// the production sidebar always disables this section in favor of the
    /// dedicated Active Sessions switcher.
    let showsActiveSessions: Bool
    let showsTasks: Bool
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
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void

    init(
        taskGroups: [WarrenDesktopTaskGroup],
        groups: [WarrenDesktopProjectGroup],
        terminalGroups: [WarrenDesktopTerminalGroup],
        workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary],
        activeWorkspaceIDs: Set<WorkspaceID> = [],
        activeAgentGroups: [WarrenDesktopActiveAgentGroup] = [],
        showsActiveSessions: Bool = true,
        showsTasks: Bool = true,
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
        onRequestDeletion: @escaping (WarrenDesktopDeletionRequest) -> Void
    ) {
        self.taskGroups = taskGroups
        self.groups = groups
        self.terminalGroups = terminalGroups
        self.workspaceActivitySummaries = workspaceActivitySummaries
        self.activeWorkspaceIDs = activeWorkspaceIDs
        self.activeAgentGroups = activeAgentGroups
        self.showsActiveSessions = showsActiveSessions
        self.showsTasks = showsTasks
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
            if showsActiveSessions {
                activeSessionsSection
            }
            if !isCollapsed {
                projectsSectionHeader
            }
            if groups.isEmpty && !isCollapsed {
                noProjectsMessage
            } else if tree.showsActiveOnly && visibleProjectGroups.isEmpty && !isCollapsed {
                noActiveWorkspacesMessage
            }
            if isCollapsed || !tree.projectsCollapsed || hasPendingProjectDeletion {
                ForEach(visibleProjectGroups) { group in
                    projectRow(for: group)
                    if isCollapsed
                        || isProjectExpanded(group.project.id)
                        || hasDeletingWorkspace(in: group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            workspaceRow(
                                workspace,
                                in: group,
                                taskName: taskName(for: workspace)
                            )
                        }
                    }
                }
                .transition(.opacity)
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
                withAnimation(WarrenMotion.animation(
                    .stateChange,
                    reduceMotion: reduceMotion
                )) {
                    tree.expandedProjectIDs.formUnion(groups.map(\.project.id))
                }
            }
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

    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Active Sessions",
                    disclosureExpanded: !tree.activeSessionsCollapsed,
                    actionEnabled: !isInteractionDisabled,
                    onToggle: toggleActiveSessions,
                    additionalActions: []
                )
            }
            if !tree.activeSessionsCollapsed || isCollapsed {
                if activeSessionItems.isEmpty && !isCollapsed {
                    Text("No active sessions")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.bottom, WarrenSpacing.compact)
                } else {
                    ForEach(activeSessionItems) { item in
                        activeAgentRow(item.session, context: item.context)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var activeSessionItems: [WarrenDesktopActiveSessionItem] {
        activeAgentGroups.flatMap { group in
            let workspaceName = group.workspace.branch?.isEmpty == false
                ? group.workspace.branch!
                : group.workspace.name
            let context = "\(group.project.name) · \(workspaceName.isEmpty ? "Workspace" : workspaceName)"
            return group.sessions.map { session in
                WarrenDesktopActiveSessionItem(session: session, context: context)
            }
        }
    }

    private var noProjectsMessage: some View {
        VStack(spacing: WarrenSpacing.xs) {
            Text("No workspaces yet")
                .font(WarrenTypography.body)
            Text(endpointCapabilities.canAddProject
                ? "Add a project or drop a Git repository folder"
                : "Add a project from the remote CLI on the host machine")
                .font(WarrenTypography.supporting)
                .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            endpointCapabilities.canAddProject
                ? "No workspaces yet. Add a project or drop a Git repository folder."
                : "No workspaces yet. Add a project from the remote CLI on the host machine."
        )
    }

    private var noActiveWorkspacesMessage: some View {
        VStack(spacing: WarrenSpacing.xs) {
            Text("No active workspaces")
                .font(WarrenTypography.body)
            Text("No workspaces currently have running or attached sessions.")
                .font(WarrenTypography.supporting)
                .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                .multilineTextAlignment(.center)
            Button("Show all workspaces") {
                withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                    tree.showsActiveOnly = false
                }
            }
            .font(WarrenTypography.supporting)
            .buttonStyle(.plain)
            .foregroundStyle(WarrenColorTokens.dark.highlight)
            .padding(.top, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No active workspaces. No workspaces currently have running or attached sessions.")
    }

    private func activeAgentRow(
        _ session: WarrenDesktopSession,
        context: String
    ) -> some View {
        WarrenDesktopActiveAgentRow(
            session: session,
            context: context,
            isCollapsed: isCollapsed,
            isSelected: isSessionSelected(session),
            isInteractionDisabled: isInteractionDisabled,
            onOpen: { onAction(.openSession(session.id)) }
        )
    }

    private func isSessionSelected(
        _ session: WarrenDesktopSession
    ) -> Bool {
        guard case .workspace = selection else { return false }
        guard let selectedTabID else { return false }
        return session.tabID == selectedTabID
    }

    private var visibleTaskGroups: [WarrenDesktopTaskGroup] {
        if tree.showsActiveOnly {
            return taskGroups.compactMap { group in
                let activeWorkspaces = group.workspaces.filter { activeWorkspaceIDs.contains($0.id) }
                guard !activeWorkspaces.isEmpty else { return nil }
                return WarrenDesktopTaskGroup(
                    task: group.task,
                    workspaces: activeWorkspaces
                )
            }
        }
        return taskGroups
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
                    if !tree.tasksCollapsed || isCollapsed {
                        if visibleTaskGroups.isEmpty && !isCollapsed {
                            Text("No tasks yet")
                                .font(WarrenTypography.supporting)
                                .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                                .padding(.horizontal, WarrenSpacing.standard)
                                .padding(.bottom, WarrenSpacing.compact)
                        }
                        ForEach(visibleTaskGroups) { group in
                            taskRow(group)
                            if isCollapsed || tree.expandedTaskIDs.contains(group.task.id) {
                                if group.workspaces.isEmpty {
                                    if !isCollapsed {
                                        Text("No linked workspaces")
                                            .font(WarrenTypography.supporting)
                                            .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                                            .padding(.horizontal, WarrenSpacing.standard + WarrenSpacing.medium)
                                            .padding(.bottom, WarrenSpacing.xs)
                                    }
                                } else {
                                    ForEach(group.workspaces) { workspace in
                                        if let project = groups.first(where: { $0.project.id == workspace.projectID }) {
                                            workspaceRow(
                                                workspace,
                                                in: project,
                                                semanticScope: "task-list",
                                                displayName: "\(project.project.name) · \(workspace.name)"
                                            )
                                        }
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
        let isExpanded = tree.expandedTaskIDs.contains(group.task.id)
        return HStack(spacing: WarrenSpacing.xxs) {
            Button {
                toggleTask(group.task.id)
            } label: {
                HStack(spacing: WarrenSpacing.compact) {
                    Image(systemName: "checklist")
                        .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize)
                    if !isCollapsed {
                        Text(group.task.name)
                            .font(WarrenTypography.navigationItem)
                            .lineLimit(1)
                        Text("\(group.workspaces.count)")
                            .font(WarrenTypography.navigationMeta)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: false, isFocused: false))
            .disabled(isInteractionDisabled)
            .accessibilityLabel("Task \(group.task.name), \(group.workspaces.count) workspaces")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .warrenSemanticElement(
                id: "task.\(group.task.id.description)",
                role: .button,
                label: "Task \(group.task.name)",
                value: "\(group.workspaces.count) workspaces · \(isExpanded ? "Expanded" : "Collapsed")",
                isEnabled: !isInteractionDisabled,
                action: { toggleTask(group.task.id) }
            )

            if !isCollapsed {
                taskAddMenu(group)
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .id("task.\(group.task.id.description)")
        .contextMenu {
            if !isInteractionDisabled {
                WarrenDesktopContextMenu([
                    .button(
                        title: "Delete Task…",
                        destructive: true,
                        action: { onRequestDeletion(.task(group.task)) }
                    ),
                ])
            }
        }
    }

    private func taskAddMenu(_ group: WarrenDesktopTaskGroup) -> some View {
        Menu {
            Menu("Add Existing Workspace") {
                let availableGroups = WarrenDesktopTaskWorkspaceOptions.availableGroups(
                    from: groups
                )
                if availableGroups.isEmpty {
                    Text("No unassigned workspaces")
                } else {
                    ForEach(availableGroups) { projectGroup in
                        Menu(projectGroup.project.name) {
                            ForEach(projectGroup.workspaces) { workspace in
                                Button(workspace.name) {
                                    onAction(.attachWorkspaceToTask(group.task.id, workspace.id))
                                }
                            }
                        }
                    }
                }
            }
            Menu("Create Workspace") {
                if groups.isEmpty {
                    Text("No projects available")
                } else {
                    ForEach(groups) { projectGroup in
                        Button(projectGroup.project.name) {
                            onAction(.requestNewWorkspace(
                                projectGroup.project.id,
                                taskID: group.task.id
                            ))
                        }
                    }
                }
            }
            Divider()
            Button("Delete Task…", role: .destructive) {
                onRequestDeletion(.task(group.task))
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(
                    width: WarrenLayoutMetrics.sidebarActionButtonSize,
                    height: WarrenLayoutMetrics.sidebarActionButtonSize
                )
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isInteractionDisabled)
        .accessibilityLabel("Add workspace to task \(group.task.name)")
    }

    private var visibleTerminalGroups: [WarrenDesktopTerminalGroup] {
        if tree.showsActiveOnly {
            return terminalGroups.filter { $0.runningSessionCount > 0 }
        }
        return terminalGroups
    }

    private var terminalGroupsSection: some View {
        Group {
            if !tree.showsActiveOnly || !visibleTerminalGroups.isEmpty {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    if !isCollapsed {
                        WarrenDesktopSidebarSectionHeader(
                            title: "Terminals",
                            actionImage: "plus",
                            actionLabel: "New terminal group",
                            actionEnabled: !isInteractionDisabled,
                            onAction: onRequestTerminalGroupCreate,
                            additionalActions: []
                        )
                    }
                    if visibleTerminalGroups.isEmpty {
                        if !isCollapsed {
                            Text("No terminal groups")
                                .font(WarrenTypography.supporting)
                                .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                                .padding(.horizontal, WarrenSpacing.standard)
                                .padding(.bottom, WarrenSpacing.compact)
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: visibleTerminalGroups.count > 3) {
                            LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                ForEach(visibleTerminalGroups) { group in
                                    WarrenDesktopTerminalGroupRow(
                                        group: group,
                                        isCollapsed: isCollapsed,
                                        isSelected: selection == .terminalGroup(group.id),
                                        isInteractionDisabled: isInteractionDisabled,
                                        onSelect: { onAction(.selectTerminalGroup(group.id)) },
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
                            }
                        }
                        .frame(
                            maxHeight: (isCollapsed
                                ? WarrenLayoutMetrics.sidebarHeaderRowHeight
                                : WarrenLayoutMetrics.sidebarProjectRowHeight) * 3
                                + WarrenSpacing.xxs * 2
                        )
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

    private func toggleActiveSessions() {
        guard !isInteractionDisabled else { return }
        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
            tree.activeSessionsCollapsed.toggle()
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
        let isProjectDeleting = deletingProjectIDs.contains(group.project.id)
        let isDeleting = deletingWorkspaceIDs.contains(workspace.id)
        ZStack {
            let activitySummary = workspaceActivitySummary(workspace.id)
            WarrenDesktopWorkspaceRow(
                workspace: presentedWorkspace,
                semanticScope: semanticScope,
                activity: activitySummary?.activity,
                activeTabCount: activitySummary?.activeTabCount ?? 0,
                isCollapsed: isCollapsed,
                isSelected: selection == .workspace(workspace.id),
                isPinned: workspace.pinned,
                isDeleting: isDeleting,
                isInteractionDisabled: isInteractionDisabled || isProjectDeleting || isDeleting,
                taskName: taskName,
                taskID: workspace.taskID,
                tasks: taskGroups.map(\.task),
                onSelectTask: onFocusTask,
                onSelect: { select(.workspace(workspace.id)) },
                onDoubleClick: { onAction(.openWorkspace(workspace.id)) },
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
        .id(workspace.id)
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

private struct WarrenDesktopActiveSessionItem: Identifiable {
    let session: WarrenDesktopSession
    let context: String

    var id: TerminalSessionID { session.id }
}

private struct WarrenDesktopActiveAgentRow: View {
    let session: WarrenDesktopSession
    let context: String
    let isCollapsed: Bool
    let isSelected: Bool
    let isInteractionDisabled: Bool
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        if isCollapsed {
            compactRow
        } else {
            expandedRow
        }
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onOpen) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(session.displayTitle.isEmpty ? "Session" : session.displayTitle)
                        .font(WarrenTypography.navigationItem)
                        .foregroundStyle(tokens.foreground.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    activityView(tokens: tokens)
                }
                Text(context)
                    .font(WarrenTypography.navigationMeta)
                    // Scope metadata recedes in the idle rail, then rises to
                    // a readable secondary tier when the row is selected or
                    // under the pointer. The session title remains primary.
                    .foregroundStyle(tokens.mutedForeground.opacity(isSelected || isHovered ? 0.96 : 0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .accessibilityLabel("Open Agent Session \(session.displayTitle)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "active-agent.\(session.id.description)",
            role: .button,
            label: "Agent Session \(session.displayTitle)",
            value: accessibilityValue,
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: { if !isInteractionDisabled { onOpen() } }
        )
        .frame(
            maxWidth: .infinity,
            minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight + WarrenSpacing.xs
        )
        .padding(.leading, WarrenSpacing.compact)
        .padding(.trailing, WarrenSpacing.compact)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: isInteractionDisabled,
            pressed: false,
            selected: isSelected,
            focused: isFocused,
            hovered: false
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isHovered
        )
    }

    private var compactRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onOpen) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityHidden(true)
                compactActivityView(tokens: tokens)
                    .offset(x: 5, y: 5)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .help(session.displayTitle)
        .accessibilityLabel("Open Agent Session \(session.displayTitle)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "active-agent.\(session.id.description)",
            role: .button,
            label: "Agent Session \(session.displayTitle)",
            value: accessibilityValue,
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: { if !isInteractionDisabled { onOpen() } }
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    @ViewBuilder
    private func activityView(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            if let activity = session.activity {
                WarrenDesktopActivityIndicator(activity: activity)
            } else {
                WarrenStatusIndicator(
                    color: tokens.amber,
                    isActive: true,
                    size: 7,
                    accessibilityLabel: "Session running"
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func compactActivityView(tokens: WarrenColorTokens) -> some View {
        if let activity = session.activity {
            WarrenDesktopActivityIndicator(activity: activity)
        } else {
            WarrenStatusIndicator(
                color: tokens.amber,
                isActive: true,
                size: 6,
                accessibilityLabel: "Session running"
            )
        }
    }

    private var activityLabel: String {
        guard let activity = session.activity else { return "Running" }
        switch activity {
        case .working: return "Working"
        case .blocked, .stalled: return "Needs attention"
        case .failed: return "Failed"
        case .ready: return "Idle"
        case .exited: return "Exited"
        }
    }

    private var accessibilityValue: String {
        var values = [activityLabel, context]
        if isSelected {
            values.append("Selected")
        }
        return values.joined(separator: " · ")
    }
}

private struct WarrenDesktopSidebarSectionAction: Identifiable {
    let id: String
    let image: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void
}

private struct WarrenDesktopSidebarSectionHeader: View {
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
                // Sections without a disclosure control (e.g. Terminals) keep
                // the same label styling as collapsible sections instead of
                // rendering a disabled, dimmed button.
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
        .foregroundStyle(tokens.mutedForeground)
        .frame(height: WarrenLayoutMetrics.sidebarSectionLabelHeight)
        .padding(.leading, WarrenSpacing.standard)
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
