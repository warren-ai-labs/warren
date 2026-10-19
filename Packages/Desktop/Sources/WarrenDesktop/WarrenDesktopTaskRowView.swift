import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// A task row mirrors the project row interaction: secondary actions stay out
/// of the default layout and appear when the row is hovered or focused.
struct WarrenDesktopTaskRow: View {
    let task: WarrenTask
    let workspaceCount: Int
    let availableProjectGroups: [WarrenDesktopProjectGroup]
    let isExpanded: Bool
    let isInteractionDisabled: Bool
    let onToggleExpansion: () -> Void
    let onAttachWorkspace: (WorkspaceID) -> Void
    let onCreateWorkspace: (ProjectID) -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    /// One mark per Session under the task, drawn as dots while folded.
    var foldMarks: [WarrenActivityMark?] = []

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
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
                    taskIcon(tokens: tokens)

                    // The name gives way first; the task's external ID stays
                    // readable beside it.
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(task.name)
                            .font(WarrenDesktopTreeTypography.groupName)
                            .foregroundStyle(tokens.treeGroupText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let externalID {
                            Text(externalID)
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.treeQuietText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    if task.pinned {
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
            .accessibilityLabel("Task \(task.name), \(workspaceCount) workspaces")
            .accessibilityValue(taskAccessibilityValue)
            .warrenSemanticElement(
                id: "task.\(task.id.description)",
                role: .button,
                label: "Task \(task.name)",
                value: taskAccessibilityValue,
                isEnabled: !isInteractionDisabled,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )

            // The hidden add menu gives back its gap as well as its width, so
            // a resting row spends that room on the name.
            HStack(spacing: showsAddMenu ? WarrenDesktopSidebarMetrics.groupIconSpacing : 0) {
                taskAddMenu(tokens: tokens)
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
            .accessibilityLabel(isExpanded ? "Collapse task \(task.name)" : "Expand task \(task.name)")
            .warrenSemanticElement(
                id: "task.\(task.id.description).toggle",
                role: .button,
                label: isExpanded ? "Collapse task \(task.name)" : "Expand task \(task.name)",
                isEnabled: !isInteractionDisabled,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )
        }
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: WarrenDesktopSidebarMetrics.groupRowHeight)
        .background(
            isHovered || isFocused ? tokens.treeRowHover : .clear,
            in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        // A long name truncates to one line; the whole name is on hover.
        .help(externalID.map { "\(task.name) · \($0)" } ?? task.name)
        .warrenContextMenu(taskContextMenuActions)
        .accessibilityElement(children: .contain)
    }

    private var showsAddMenu: Bool {
        isHovered || isAddFocused || forceHover
    }

    private var externalID: String? {
        let trimmed = task.externalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func taskIcon(tokens: WarrenColorTokens) -> some View {
        Image(systemName: "checkmark.square")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tokens.treeGroupIcon)
            .frame(
                width: WarrenDesktopSidebarMetrics.groupIconSize,
                height: WarrenDesktopSidebarMetrics.groupIconSize
            )
            .accessibilityHidden(true)
    }

    private func taskAddMenu(tokens: WarrenColorTokens) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tokens.treeQuietText)
            .frame(width: 18, height: 18)
            .contentShape(.rect)
            .warrenMenuButton(taskAddActions)
            .focusable()
            .disabled(isInteractionDisabled)
            .opacity(showsAddMenu ? 1 : 0)
            // Hidden, it gives its width back to the name, so a resting row shows
            // the whole name and the external ID beside it.
            .frame(width: showsAddMenu ? nil : 0)
            .clipped()
            .focused($isAddFocused)
            .accessibilityLabel("Add workspace to task \(task.name)")
            .accessibilityAddTraits(.isButton)
            .warrenTooltip("Add workspace")
            .warrenSemanticElement(
                id: "task.\(task.id.description).new-workspace",
                role: .button,
                label: "Add workspace to task \(task.name)",
                isEnabled: !isInteractionDisabled,
                action: {}
            )
    }

    private var taskAddActions: [WarrenDesktopContextMenuAction] {
        let availableGroups = WarrenDesktopTaskWorkspaceOptions.availableGroups(
            from: availableProjectGroups
        )
        return [
            .menu(title: "Add Existing Workspace", actions: availableGroups.map { projectGroup in
                .menu(title: projectGroup.project.name, actions: projectGroup.workspaces.map { workspace in
                    .button(title: workspace.name) { onAttachWorkspace(workspace.id) }
                })
            }),
            .menu(title: "Create Workspace", actions: availableProjectGroups.map { projectGroup in
                .button(title: projectGroup.project.name) { onCreateWorkspace(projectGroup.project.id) }
            }),
            .divider,
            .button(title: "Rename Task", action: onRename),
            .button(title: "Delete Task…", destructive: true, action: onDelete),
        ]
    }

    private var taskContextMenuActions: [WarrenDesktopContextMenuAction] {
        guard !isInteractionDisabled else { return [] }
        return [
            .button(title: task.pinned ? "Unpin Task" : "Pin Task", action: onTogglePin),
            .button(title: "Rename Task", action: onRename),
            .button(
                title: "Delete Task…",
                destructive: true,
                action: onDelete
            ),
        ]
    }

    private var taskAccessibilityValue: String {
        "\(workspaceCount) workspaces · \(isExpanded ? "Expanded" : "Collapsed")"
    }
}
