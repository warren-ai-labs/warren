import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

enum WarrenDesktopDeletionRequest {
    case workspace(Workspace, project: Project?)
    case project(Project, workspaceCount: Int)
    case terminalGroup(TerminalGroup, sessionCount: Int)
}

struct WarrenDesktopSidebarRows: View {
    let groups: [WarrenDesktopProjectGroup]
    let terminalGroups: [WarrenDesktopTerminalGroup]
    let workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    @Binding var tree: WarrenDesktopSidebarTreeState
    let isCollapsed: Bool
    let selection: WarrenDesktopSidebarSelection?
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let isInteractionDisabled: Bool
    let onAddProject: () -> Void
    let onRequestTerminalGroupCreate: () -> Void
    let onRequestTerminalGroupEdit: (TerminalGroup) -> Void
    let onAction: (WarrenDesktopAction) -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void

    @State private var dragSession = WarrenDesktopSidebarDragSession()
    /// Ephemeral presentation state; persisted expansion preferences remain untouched.
    @State private var dragAutoCollapse: WarrenSidebarDragAutoCollapse?
    @State private var dragSourceRowID: String?
    @State private var isDragMeasurementEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // This list is bounded by the sidebar scroll view and also hosts
        // optional drag-frame measurement. Eager layout keeps geometry
        // feedback out of LazyVStack's placement cache during navigation.
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            terminalGroupsSection
            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Projects",
                    disclosureExpanded: !tree.projectsCollapsed,
                    actionImage: "folder.badge.plus",
                    actionLabel: "Add project",
                    actionEnabled: !isInteractionDisabled,
                    onToggle: toggleProjects,
                    onAction: onAddProject
                )
            }
            if groups.isEmpty && !isCollapsed {
                VStack(spacing: WarrenSpacing.xs) {
                    Text("No workspaces yet")
                        .font(WarrenTypography.body)
                    Text("Add a project or drop a Git repository folder")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, WarrenSpacing.large)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("No workspaces yet. Add a project or drop a Git repository folder.")
            }
            if isCollapsed || !tree.projectsCollapsed || hasPendingProjectDeletion {
                ForEach(visibleProjectGroups) { group in
                    projectRow(for: group)
                    if isCollapsed
                        || isProjectExpanded(group.project.id)
                        || hasDeletingWorkspace(in: group.project.id) {
                        ForEach(group.workspaces) { workspace in
                            workspaceRow(workspace, in: group)
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
        .onChange(of: selection) { _, newSelection in
            guard case .workspace(let workspaceID)? = newSelection,
                  let workspace = groups
                    .flatMap(\.workspaces)
                    .first(where: { $0.id == workspaceID })
            else { return }
            _ = withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.expandedProjectIDs.insert(workspace.projectID)
            }
        }
        .onChange(of: groups) { oldGroups, newGroups in
            guard let projectID = selectedProjectID else { return }
            let oldCount = workspaceCount(for: projectID, in: oldGroups)
            let newCount = workspaceCount(for: projectID, in: newGroups)
            guard newCount > oldCount else { return }
            _ = withAnimation(WarrenMotion.animation(
                .stateChange,
                reduceMotion: reduceMotion
            )) {
                tree.expandedProjectIDs.insert(projectID)
            }
        }
    }

    private var terminalGroupsSection: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if !isCollapsed {
                WarrenDesktopSidebarSectionHeader(
                    title: "Terminals",
                    actionImage: "plus",
                    actionLabel: "New terminal group",
                    actionEnabled: !isInteractionDisabled,
                    onAction: onRequestTerminalGroupCreate
                )
            }
            if terminalGroups.isEmpty {
                if !isCollapsed {
                    Text("No terminal groups")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(WarrenColorTokens.dark.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.bottom, WarrenSpacing.compact)
                }
            } else {
                ScrollView(.vertical, showsIndicators: terminalGroups.count > 3) {
                    LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                        ForEach(terminalGroups) { group in
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
        guard !tree.projectsCollapsed || isCollapsed else { return groups.filter { group in
            deletingProjectIDs.contains(group.project.id)
                || hasDeletingWorkspace(in: group.project.id)
        } }
        return groups
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
        in group: WarrenDesktopProjectGroup
    ) -> some View {
        let isProjectDeleting = deletingProjectIDs.contains(group.project.id)
        let isDeleting = deletingWorkspaceIDs.contains(workspace.id)
        ZStack {
            let activitySummary = workspaceActivitySummary(workspace.id)
            WarrenDesktopWorkspaceRow(
                workspace: workspace,
                semanticScope: "project-list",
                activity: activitySummary?.activity,
                activeTabCount: activitySummary?.activeTabCount ?? 0,
                isCollapsed: isCollapsed,
                isSelected: selection == .workspace(workspace.id),
                isPinned: workspace.pinned,
                isDeleting: isDeleting,
                isInteractionDisabled: isInteractionDisabled || isProjectDeleting || isDeleting,
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

private struct WarrenDesktopSessionRow: View {
    let session: WarrenDesktopSession
    let workspace: Workspace?
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.compact) {
            Button(action: onOpen) {
                HStack(spacing: WarrenSpacing.compact) {
                    if let activity = session.activity {
                        WarrenDesktopActivityIndicator(activity: activity)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayTitle)
                            .font(WarrenTypography.navigationItem)
                            .foregroundStyle(tokens.foreground.opacity(0.86))
                            .lineLimit(1)
                        if let workspace {
                            Text(workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isFocused: isActionFocused))
            .focused($isActionFocused)
            .warrenSemanticElement(
                id: "session.\(session.id.description)",
                role: .button,
                label: "Open Session \(session.displayTitle)",
                value: isSelected ? "Selected" : nil,
                isSelected: isSelected,
                action: onOpen
            )

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .regular))
                        .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                               height: WarrenLayoutMetrics.sidebarActionButtonSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.destructive)
                .accessibilityLabel("Delete Session \(session.displayTitle)")
                .help("Delete Session")
                .warrenSemanticElement(
                    id: "session.\(session.id.description).delete",
                    role: .button,
                    label: "Delete Session \(session.displayTitle)",
                    action: onDelete
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, WarrenSpacing.standard)
        .padding(.trailing, WarrenSpacing.compact)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: false,
            pressed: false,
            selected: isSelected,
            focused: isActionFocused,
            hovered: isHovered
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .padding(.horizontal, WarrenSpacing.compact)
        .onHover { isHovered = $0 }
    }
}

private struct WarrenDesktopSidebarSectionHeader: View {
    let title: String
    var disclosureExpanded: Bool? = nil
    let actionImage: String
    let actionLabel: String
    var actionEnabled = true
    var onToggle: (() -> Void)?
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isActionFocused: Bool
    @FocusState private var isToggleFocused: Bool

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
