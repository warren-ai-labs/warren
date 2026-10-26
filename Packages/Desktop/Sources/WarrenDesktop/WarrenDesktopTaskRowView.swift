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

                    // The name owns the whole line. A task created from an
                    // external tracker carries a long custom ID, and printing
                    // it here cost the name its width; the row's tooltip has
                    // it, so a hover still answers what the ID is.
                    WarrenDesktopFadingName(text: WarrenDesktopTreeTypography.groupNameText(task.name))
                        .foregroundStyle(tokens.treeGroupText)

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
            .accessibilityLabel("Task \(task.name), \(workspaceCountText)")
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
                if !isExpanded {
                    WarrenDesktopFoldSummary(marks: foldMarks, count: foldMarks.count)
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
            // Open, the chevron waits for the pointer; folded, it stays as the
            // sign of the fold.
            .opacity(isExpanded && !(isHovered || isFocused || isToggleFocused || forceHover) ? 0 : 1)
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
        // A long name truncates to one line; the whole name, and the external
        // ID the row keeps out of its layout, are on hover.
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

    /// The Task tile, the project avatar's size, so both group heads share
    /// one icon column and their names one start.
    static let taskIconWidth: CGFloat = WarrenDesktopSidebarMetrics.groupIconSize

    private func taskIcon(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopTaskTile()
    }

    private func taskAddMenu(tokens: WarrenColorTokens) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tokens.treeQuietText)
            .frame(width: 18, height: 18)
            .contentShape(.rect)
            .warrenMenuButton(taskAddActions)
            .modifier(WarrenDesktopTaskAddFocus(isFocused: isAddFocused, ring: tokens.focusRing))
            .disabled(isInteractionDisabled)
            .opacity(showsAddMenu ? 1 : 0)
            // Hidden, it gives its width back to the name, so a resting row
            // shows as much of the name as it can.
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
        "\(workspaceCountText) · \(isExpanded ? "Expanded" : "Collapsed")"
    }

    private var workspaceCountText: String {
        "\(workspaceCount) \(workspaceCount == 1 ? "workspace" : "workspaces")"
    }
}

/// Keyboard focus for the task row's "+", matching the project row's button.
///
/// A plain `focusable()` made the "+" a click-focus target, so when a click
/// elsewhere left the keyboard without an owner it landed here, kept the "+"
/// shown, and drew the system's blue ring around it. Taking focus only the way
/// a button does (Full Keyboard Access) and drawing Warren's own ring keeps it
/// reachable by keyboard without catching focus a click let go of.
private struct WarrenDesktopTaskAddFocus: ViewModifier {
    let isFocused: Bool
    let ring: Color

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable(interactions: .activate)
                .focusEffectDisabled()
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                        .strokeBorder(ring, lineWidth: 1)
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                }
        } else {
            content.focusable()
        }
    }
}
