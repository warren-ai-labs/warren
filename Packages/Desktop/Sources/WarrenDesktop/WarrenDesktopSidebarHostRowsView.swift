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
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarResourceSelection?
    let activeEndpointID: String
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let onAction: (WarrenDesktopAction) -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    let onSelect: (WarrenDesktopSidebarResourceSelection) -> Void
    let onOpenWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    let onFocusTask: (TaskID) -> Void
    let onToggleActiveOnly: () -> Void
    let onRetry: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProjectKeys: Set<String> = []
    @State private var collapsedHostIDs: Set<String> = []
    @State private var singleHostProjectsCollapsed = false
    @StateObject private var tintAllocator = WarrenDesktopHostTintAllocator()

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if !isCollapsed, usesHostSectionPresentation {
                WarrenDesktopSidebarHostsSectionHeader(hostCount: hosts.count)
            }
            ForEach(hosts, id: \.endpointID) { host in
                hostSection(host)
                    .id(host.endpointID)
            }
        }
        .onChange(of: hosts) { nextHosts in
            let valid = Set(nextHosts.flatMap { host in
                host.projectGroups.map { projectKey(host, $0.project.id) }
            })
            let nextExpandedProjectKeys = expandedProjectKeys.filter(valid.contains)
            if nextExpandedProjectKeys != expandedProjectKeys {
                expandedProjectKeys = nextExpandedProjectKeys
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
            revealSelection(selection, in: hosts)
            updateTintAssignments()
        }
        .onChange(of: selection) { nextSelection in
            revealSelection(nextSelection, in: hosts)
        }
    }

    @ViewBuilder
    private func hostSection(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        if isCollapsed {
            collapsedHostRows(host)
        } else if usesHostSectionPresentation {
            expandedHostSection(host)
        } else {
            singleHostSection(host)
        }
    }

    private var usesHostSectionPresentation: Bool {
        hosts.count > 1
    }

    private func collapsedHostRows(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        VStack(spacing: WarrenSpacing.xxs) {
            ForEach(scopedProjectGroups(for: host)) { scopedGroup in
                let group = scopedGroup.group
                Button {
                    onSelect(.project(host.projectReference(group.project.id)))
                } label: {
                    projectGlyph(group.project)
                }
                .buttonStyle(WarrenInteractiveRowStyle(
                    isSelected: isSelected(project: group.project.id, in: host)
                ))
                .disabled(!host.connectionState.isConnected)
                .frame(width: 32, height: 32)
                .help("\(host.title) · \(group.project.name)")
                .accessibilityLabel("\(host.title), project \(group.project.name)")
                .accessibilityIdentifier(projectKey(host, group.project.id))
                .warrenSemanticElement(
                    id: projectKey(host, group.project.id),
                    role: .button,
                    label: "\(host.title), project \(group.project.name)",
                    isEnabled: host.connectionState.isConnected,
                    isSelected: isSelected(project: group.project.id, in: host),
                    action: {
                        guard host.connectionState.isConnected else { return }
                        onSelect(.project(host.projectReference(group.project.id)))
                    }
                )
                .contextMenu {
                    if canMutate(host) {
                        WarrenDesktopContextMenu(projectContextMenuActions(group, host: host))
                    }
                }
                .id(projectKey(host, group.project.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func singleHostSection(_ host: WarrenDesktopSidebarHostProjection) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
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
            actionVisible: false,
            onToggle: toggleSingleHostProjects,
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
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let tintIndex = tintAllocator.assignments[host.endpointID]
            ?? WarrenDesktopHostTint.index(
                for: host.endpointID,
                count: tokens.hostSectionTints.count
            )
        let tint = tokens.hostSectionTints.indices.contains(tintIndex)
            ? tokens.hostSectionTints[tintIndex]
            : .clear
        return VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            WarrenDesktopSidebarHostHeader(
                host: host,
                isExpanded: isHostExpanded(host),
                onToggle: { toggleHost(host.endpointID) },
                onRetry: { onRetry(host.endpointID) }
            )

            if isHostExpanded(host) {
                hostProjectRows(for: host)
            }
        }
        // A Host is a compact tree group, not a padded card. A 4% wash over the
        // sidebar surface resolves to a few units of 255 and does not read as a
        // grouping at all, so the subtree is marked by a leading rule instead:
        // it spans the same range, survives a squint, and costs no vertical
        // chrome.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(WarrenDesktopHostTint.ruleOpacity))
                .frame(width: WarrenDesktopHostTint.ruleWidth)
                .padding(.leading, WarrenSpacing.compact)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Host \(host.title)")
    }

    @ViewBuilder
    private func hostProjectRows(
        for host: WarrenDesktopSidebarHostProjection
    ) -> some View {
        let groups = scopedProjectGroups(for: host)
        if groups.isEmpty {
            if let reason = emptyReason(for: host) {
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
            ForEach(groups) { scopedGroup in
                let group = scopedGroup.group
                hostProjectRow(group, host: host)
                if isProjectExpanded(group.project.id, in: host) {
                    ForEach(scopedWorkspaces(for: group, host: host)) { scopedWorkspace in
                        hostWorkspaceRow(
                            scopedWorkspace.workspace,
                            project: group.project,
                            host: host
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hostProjectRow(
        _ group: WarrenDesktopProjectGroup,
        host: WarrenDesktopSidebarHostProjection
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
            isCollapsed: false,
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
        let isSelectionDisabled = workspace.taskID != nil
            && host.endpointID == activeEndpointID
        let taskName = workspace.taskID.flatMap { taskID in
            host.tasks.first(where: { $0.id == taskID })?.name
        }
        return WarrenDesktopWorkspaceRow(
            workspace: workspace,
            semanticScope: "host.\(host.endpointID)",
            activity: summary?.activity,
            activeTabCount: summary?.activeTabCount ?? 0,
            isCollapsed: false,
            isSelected: isSelected(workspace: workspace.id, in: host)
                && !isSelectionDisabled,
            isPinned: workspace.pinned,
            isDeleting: isDeleting,
            isInteractionDisabled: !enabled || isProjectDeleting || isDeleting,
            isMutationDisabled: !canWrite,
            isSelectionDisabled: isSelectionDisabled,
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
                onOpenWorkspace(host.workspaceReference(workspace.id))
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

    private func reveal(_ projectKey: String, in endpointID: String) {
        if collapsedHostIDs.contains(endpointID) {
            collapsedHostIDs.remove(endpointID)
        }
        if !expandedProjectKeys.contains(projectKey) {
            expandedProjectKeys.insert(projectKey)
        }
    }

    private func updateTintAssignments() {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        tintAllocator.update(
            endpointIDs: hosts.map(\.endpointID),
            paletteCount: tokens.hostSectionTints.count
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
        for group: WarrenDesktopProjectGroup,
        host: WarrenDesktopSidebarHostProjection
    ) -> [ScopedWorkspace] {
        group.workspaces.map { workspace in
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
            // A spinner already sits in the Host header; a second message would
            // report the same transient state twice.
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

    private func projectGlyph(_ project: Project, size: CGFloat = 22) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Text(String(project.name.prefix(1)).uppercased())
            .font(.system(size: max(10, size * 0.48), weight: .semibold))
            .foregroundStyle(tokens.background)
            .frame(width: size, height: size)
            .background(tokens.foreground.opacity(0.72), in: Circle())
            .accessibilityHidden(true)
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

    private func isProjectExpanded(
        _ projectID: ProjectID,
        in host: WarrenDesktopSidebarHostProjection
    ) -> Bool {
        expandedProjectKeys.contains(projectKey(host, projectID))
    }

    private func toggleProject(
        _ projectID: ProjectID,
        in host: WarrenDesktopSidebarHostProjection
    ) {
        let key = projectKey(host, projectID)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            if expandedProjectKeys.contains(key) {
                expandedProjectKeys.remove(key)
            } else {
                expandedProjectKeys.insert(key)
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
            if keys.allSatisfy(expandedProjectKeys.contains) {
                expandedProjectKeys.subtract(keys)
            } else {
                expandedProjectKeys.formUnion(keys)
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
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Text(WarrenDesktopSidebarHostsSectionPresentation.title(
            hostCount: hostCount,
            isHovered: isHovered
        ))
        .font(WarrenTypography.sectionLabel)
        .tracking(1.0)
        .foregroundStyle(tokens.mutedForeground)
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarSectionLabelHeight, alignment: .leading)
        .padding(.leading, WarrenDesktopSidebarIndent.section)
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

private struct WarrenDesktopSidebarHostHeader: View {
    let host: WarrenDesktopSidebarHostProjection
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isToggleFocused: Bool
    @FocusState private var isRetryFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            Button(action: onToggle) {
                HStack(spacing: WarrenSpacing.small) {
                    Text(host.title)
                        .font(WarrenTypography.groupHeading)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(isHovered || isToggleFocused ? 1 : 0)
                        .animation(
                            WarrenMotion.animation(
                                .stateChange,
                                reduceMotion: reduceMotion
                            ),
                            value: isExpanded
                        )
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .focused($isToggleFocused)
            .accessibilityLabel("Host \(host.title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide this Host's projects and workspaces")
            .warrenSemanticElement(
                id: "host.\(host.endpointID).toggle",
                role: .button,
                label: "Host \(host.title)",
                value: isExpanded ? "Expanded" : "Collapsed",
                action: onToggle
            )

            connectionAccessory(tokens: tokens)
        }
        .frame(height: WarrenLayoutMetrics.sidebarHostHeaderHeight)
        .padding(.leading, WarrenDesktopSidebarIndent.host)
        .padding(.trailing, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
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
            .help("Retry \(host.title)")
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
