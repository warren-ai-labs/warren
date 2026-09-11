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
    let isCollapsed: Bool
    let isExpanded: Bool
    let isInteractionDisabled: Bool
    let onToggleExpansion: () -> Void
    let onAttachWorkspace: (WorkspaceID) -> Void
    let onCreateWorkspace: (ProjectID) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @FocusState private var isAddFocused: Bool
    @FocusState private var isToggleFocused: Bool

    var body: some View {
        if isCollapsed {
            collapsedRow
        } else {
            expandedRow
        }
    }

    private var collapsedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onToggleExpansion) {
            taskIcon(tokens: tokens)
        }
        .buttonStyle(.plain)
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: false, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityLabel("Task \(task.name)")
        .accessibilityValue(taskAccessibilityValue)
        .warrenSemanticElement(
            id: "task.\(task.id.description)",
            role: .button,
            label: "Task \(task.name)",
            value: taskAccessibilityValue,
            isEnabled: !isInteractionDisabled,
            action: { if !isInteractionDisabled { onToggleExpansion() } }
        )
        .focused($isFocused)
        .contextMenu {
            taskContextMenu
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let actionSlot = WarrenLayoutMetrics.sidebarActionButtonSize + WarrenSpacing.compact
        let compactActionSize = WarrenLayoutMetrics.sidebarActionButtonSize - WarrenSpacing.xs
        return ZStack(alignment: .trailing) {
            Button(action: onToggleExpansion) {
                HStack(spacing: WarrenSpacing.compact) {
                    taskIcon(tokens: tokens)
                        .opacity(isHovered || isToggleFocused ? 0 : 1)

                    Text(task.name)
                        .font(WarrenTypography.navigationItem)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("(\(workspaceCount))")
                        .font(WarrenTypography.navigationMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .opacity(isHovered || isToggleFocused || forceHover ? 1 : 0)
                        .accessibilityHidden(true)

                    Spacer(minLength: 0)
                }
                .padding(.leading, WarrenDesktopSidebarIndent.task)
                .padding(.trailing, actionSlot)
                .frame(minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: false, isFocused: isFocused))
            .disabled(isInteractionDisabled)
            .focused($isFocused)
            .foregroundStyle(tokens.projectText)
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

            taskAddMenu(
                tokens: tokens,
                compactActionSize: compactActionSize
            )
        }
        .overlay(alignment: .leading) {
            Button(action: onToggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground.opacity(0.86))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isToggleFocused))
            .disabled(isInteractionDisabled)
            .frame(
                width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                height: WarrenLayoutMetrics.sidebarRowIconSlotSize
            )
            .contentShape(.rect)
            .opacity(isHovered || isToggleFocused ? 1 : 0)
            .focused($isToggleFocused)
            .padding(.leading, WarrenDesktopSidebarIndent.task)
            .accessibilityLabel(isExpanded ? "Collapse task \(task.name)" : "Expand task \(task.name)")
            .warrenSemanticElement(
                id: "task.\(task.id.description).toggle",
                role: .button,
                label: isExpanded ? "Collapse task \(task.name)" : "Expand task \(task.name)",
                isEnabled: !isInteractionDisabled,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: isInteractionDisabled,
            pressed: false,
            selected: false,
            focused: isFocused,
            hovered: isHovered || isAddFocused || isToggleFocused
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            taskContextMenu
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    private func taskIcon(tokens: WarrenColorTokens) -> some View {
        Image(systemName: "checklist")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(tokens.projectText)
            .frame(
                width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                height: WarrenLayoutMetrics.sidebarRowIconSlotSize
            )
            .accessibilityHidden(true)
    }

    private func taskAddMenu(
        tokens: WarrenColorTokens,
        compactActionSize: CGFloat
    ) -> some View {
        Menu {
            Menu("Add Existing Workspace") {
                let availableGroups = WarrenDesktopTaskWorkspaceOptions.availableGroups(
                    from: availableProjectGroups
                )
                if availableGroups.isEmpty {
                    Text("No unassigned workspaces")
                } else {
                    ForEach(availableGroups) { projectGroup in
                        Menu(projectGroup.project.name) {
                            ForEach(projectGroup.workspaces) { workspace in
                                Button(workspace.name) {
                                    onAttachWorkspace(workspace.id)
                                }
                            }
                        }
                    }
                }
            }
            Menu("Create Workspace") {
                if availableProjectGroups.isEmpty {
                    Text("No projects available")
                } else {
                    ForEach(availableProjectGroups) { projectGroup in
                        Button(projectGroup.project.name) {
                            onCreateWorkspace(projectGroup.project.id)
                        }
                    }
                }
            }
            Divider()
            Button("Rename Task", action: onRename)
            Button("Delete Task…", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tokens.mutedForeground.opacity(0.86))
                .frame(width: compactActionSize, height: compactActionSize)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isInteractionDisabled)
        .opacity(isHovered || isAddFocused ? 1 : 0)
        .focused($isAddFocused)
        .accessibilityLabel("Add workspace to task \(task.name)")
        .help("Add workspace")
        .warrenSemanticElement(
            id: "task.\(task.id.description).new-workspace",
            role: .button,
            label: "Add workspace to task \(task.name)",
            isEnabled: !isInteractionDisabled,
            action: {}
        )
        .padding(.trailing, WarrenSpacing.xs)
    }

    @ViewBuilder
    private var taskContextMenu: some View {
        if !isInteractionDisabled {
            WarrenDesktopContextMenu([
                .button(title: "Rename Task", action: onRename),
                .button(
                    title: "Delete Task…",
                    destructive: true,
                    action: onDelete
                ),
            ])
        }
    }

    private var taskAccessibilityValue: String {
        "\(workspaceCount) workspaces · \(isExpanded ? "Expanded" : "Collapsed")"
    }
}
