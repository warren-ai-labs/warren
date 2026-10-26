import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

enum WarrenDesktopProjectDeletionKind: Equatable {
    case project
    case workspace

    var accessibilityLabel: String {
        switch self {
        case .project: "Deleting project"
        case .workspace: "Deleting workspace"
        }
    }
}

/// A project row mirrors Superset's `DashboardSidebarProjectRow`: the avatar
/// leads, the workspace count sits beside the name, and the new-workspace plus
/// remains available while the disclosure chevron overlays the avatar slot on
/// hover or keyboard focus.
struct WarrenDesktopProjectRow: View {
    let project: Project
    /// Optional endpoint scope used by the aggregated sidebar. The legacy
    /// single-host rows keep their historical semantic IDs when this is nil.
    let semanticScope: String?
    let workspaceCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let isPinned: Bool
    let deletionKind: WarrenDesktopProjectDeletionKind?
    let isInteractionDisabled: Bool
    /// Disables writes while keeping a connected background Host selectable
    /// and expandable. The aggregated sidebar uses this for non-current Hosts.
    let isMutationDisabled: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void
    let onAddWorkspace: () -> Void
    let onImportWorktrees: () -> Void
    let onConfigureSetupScript: () -> Void
    let onToggleAutoImportWorktrees: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// One mark per Session under the project, drawn as dots while folded.
    let foldMarks: [WarrenActivityMark?]
    /// The branch of the project's only Workspace, when the project lists
    /// that Workspace's Sessions directly instead of drawing a row for it.
    let branchName: String?
    /// That Workspace's menu, which has no row of its own to hang on.
    let workspaceMenu: [WarrenDesktopContextMenuAction]
    /// Double-click on such a project does what it does on a Workspace row.
    let onDoubleClick: (() -> Void)?

    init(
        project: Project,
        semanticScope: String? = nil,
        workspaceCount: Int,
        isSelected: Bool,
        isExpanded: Bool,
        isPinned: Bool,
        deletionKind: WarrenDesktopProjectDeletionKind?,
        isInteractionDisabled: Bool,
        isMutationDisabled: Bool = false,
        onSelect: @escaping () -> Void,
        onToggleExpansion: @escaping () -> Void,
        onAddWorkspace: @escaping () -> Void,
        onImportWorktrees: @escaping () -> Void,
        onConfigureSetupScript: @escaping () -> Void,
        onToggleAutoImportWorktrees: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        foldMarks: [WarrenActivityMark?] = [],
        branchName: String? = nil,
        workspaceMenu: [WarrenDesktopContextMenuAction] = [],
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.foldMarks = foldMarks
        self.branchName = branchName
        self.workspaceMenu = workspaceMenu
        self.onDoubleClick = onDoubleClick
        self.project = project
        self.semanticScope = semanticScope
        self.workspaceCount = workspaceCount
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.isPinned = isPinned
        self.deletionKind = deletionKind
        self.isInteractionDisabled = isInteractionDisabled
        self.isMutationDisabled = isMutationDisabled
        self.onSelect = onSelect
        self.onToggleExpansion = onToggleExpansion
        self.onAddWorkspace = onAddWorkspace
        self.onImportWorktrees = onImportWorktrees
        self.onConfigureSetupScript = onConfigureSetupScript
        self.onToggleAutoImportWorktrees = onToggleAutoImportWorktrees
        self.onRename = onRename
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
    }

    private var semanticID: String {
        if let semanticScope, !semanticScope.isEmpty {
            return "project.\(semanticScope).\(project.id.description)"
        }
        return "project.\(project.id.description)"
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @FocusState private var isAddFocused: Bool
    @FocusState private var isToggleFocused: Bool

    var body: some View {
        expandedRow
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return HStack(spacing: WarrenDesktopSidebarMetrics.groupIconSpacing) {
            Button(action: onToggleExpansion) {
                HStack(spacing: WarrenDesktopSidebarMetrics.groupIconSpacing) {
                    WarrenDesktopProjectAvatar(
                        name: project.name,
                        identity: project.id.description
                    )

                    // The name gives way first; the branch stays readable.
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        WarrenDesktopFadingName(text: WarrenDesktopTreeTypography.groupNameText(project.name))
                            .foregroundStyle(tokens.treeGroupText)
                        if let branchName {
                            WarrenDesktopTreeTypography.scriptText(
                                branchName,
                                latin: WarrenDesktopTreeTypography.branchName,
                                wide: WarrenDesktopTreeTypography.branchNameWide
                            )
                                .foregroundStyle(tokens.treeBranchText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                    }

                    if let deletionKind {
                        deletionStatus(tokens: tokens, kind: deletionKind)
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.treeQuietText)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)
                }
                .frame(height: WarrenDesktopSidebarMetrics.groupRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .focused($isFocused)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if !isInteractionDisabled { onDoubleClick?() }
            })
            .accessibilityLabel("Project \(project.name)")
            .accessibilityValue(projectAccessibilityValue(isExpanded: isExpanded))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: semanticID,
                role: .button,
                label: "Project \(project.name)",
                value: projectAccessibilityValue(isExpanded: isExpanded),
                isEnabled: !isInteractionDisabled,
                isSelected: isSelected,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )

            // The hidden "+" gives back its gap as well as its width, the
            // same as the task row, so a resting row spends that room on the
            // name.
            HStack(spacing: showsAddButton ? WarrenDesktopSidebarMetrics.groupIconSpacing : 0) {
                Button(action: onAddWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.treeQuietText)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isAddFocused))
                .disabled(isInteractionDisabled || isMutationDisabled)
                .opacity(showsAddButton ? 1 : 0)
                .animation(
                    WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                    value: showsAddButton
                )
                // Hidden, it gives its width back to the name, as the task
                // row's add menu does.
                .frame(width: showsAddButton ? nil : 0)
                .clipped()
                .focused($isAddFocused)
                .accessibilityLabel("New workspace in \(project.name)")
                .warrenTooltip("New workspace")
                .warrenSemanticElement(
                    id: "\(semanticID).new-workspace",
                    role: .button,
                    label: "New workspace in \(project.name)",
                    isEnabled: !isInteractionDisabled && !isMutationDisabled,
                    action: {
                        if !isInteractionDisabled && !isMutationDisabled {
                            onAddWorkspace()
                        }
                    }
                )
                if !isExpanded, WarrenDesktopTreeFoldDots.drawsAny(foldMarks) {
                    WarrenDesktopTreeFoldDots(marks: foldMarks)
                }
            }

            Button(action: onToggleExpansion) {
                WarrenDesktopTreeChevron(isExpanded: isExpanded)
                    .frame(
                        width: WarrenDesktopSidebarMetrics.chevronSize,
                        height: WarrenDesktopSidebarMetrics.groupRowHeight
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .focused($isToggleFocused)
            .accessibilityLabel(isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)")
            .warrenSemanticElement(
                id: "\(semanticID).toggle",
                role: .button,
                label: isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)",
                isEnabled: !isInteractionDisabled,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )
        }
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: WarrenDesktopSidebarMetrics.groupRowHeight)
        .background(
            isSelected
                ? tokens.treeRowSelected
                : (isHovered || isFocused ? tokens.treeRowHover : .clear),
            in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        // A long name truncates to one line; the whole name is on hover.
        .help(branchName.map { "\(project.name) · \($0)" } ?? project.name)
        .warrenContextMenu(
            !isInteractionDisabled && !isMutationDisabled ? contextMenuActions : []
        )
        .accessibilityElement(children: .contain)
    }

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        Self.contextMenuActions(
            project: project,
            isPinned: isPinned,
            workspaceMenu: workspaceMenu,
            onImportWorktrees: onImportWorktrees,
            onConfigureSetupScript: onConfigureSetupScript,
            onToggleAutoImportWorktrees: onToggleAutoImportWorktrees,
            onRename: onRename,
            onTogglePin: onTogglePin,
            onDelete: onDelete
        )
    }

    /// The Project's menu. Shared with the compact row an inactive Project
    /// gets in the folded list at the end of the section.
    static func contextMenuActions(
        project: Project,
        isPinned: Bool,
        workspaceMenu: [WarrenDesktopContextMenuAction] = [],
        onImportWorktrees: @escaping () -> Void,
        onConfigureSetupScript: @escaping () -> Void,
        onToggleAutoImportWorktrees: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> [WarrenDesktopContextMenuAction] {
        var actions: [WarrenDesktopContextMenuAction] = [
            .button(title: isPinned ? "Unpin Project" : "Pin Project", action: onTogglePin),
            .button(title: "Rename Project", action: onRename),
            .button(title: "Import Existing Worktrees…", action: onImportWorktrees),
            .button(title: "Configure Setup Script…", action: onConfigureSetupScript),
            .button(
                title: project.autoImportGitWorktrees
                    ? "Disable Automatic Worktree Import"
                    : "Enable Automatic Worktree Import (No Confirmation)",
                action: onToggleAutoImportWorktrees
            ),
        ]
        if !workspaceMenu.isEmpty {
            actions.append(.divider)
            actions.append(.menu(title: "Workspace", actions: workspaceMenu))
        }
        actions.append(contentsOf: [
            .divider,
            .button(title: "Delete Project…", destructive: true, action: onDelete),
        ])
        return actions
    }

    private func deletionStatus(
        tokens: WarrenColorTokens,
        kind: WarrenDesktopProjectDeletionKind
    ) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            WarrenLoadingIndicator(size: 14, accessibilityLabel: kind.accessibilityLabel)
                .accessibilityHidden(true)
            Text("Deleting…")
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }

    private var showsAddButton: Bool {
        isHovered || isAddFocused || forceHover
    }

    private func projectAccessibilityValue(isExpanded: Bool? = nil) -> String {
        var values: [String] = []
        if let isExpanded {
            values.append(isExpanded ? "Expanded" : "Collapsed")
        }
        if let deletionKind {
            values.append(deletionKind.accessibilityLabel)
        } else if isInteractionDisabled {
            values.append("Unavailable")
        }
        if isExpanded == nil {
            values.append(isSelected ? "Selected" : "Not selected")
        } else if isSelected {
            values.append("Selected")
        }
        return values.joined(separator: " · ")
    }
}
