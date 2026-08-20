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
    let workspaceCount: Int
    let isCollapsed: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isPinned: Bool
    let deletionKind: WarrenDesktopProjectDeletionKind?
    let isInteractionDisabled: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void
    let onAddWorkspace: () -> Void
    let onImportWorktrees: () -> Void
    let onToggleAutoImportWorktrees: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
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
        return Button(action: onSelect) {
            ZStack(alignment: .bottomTrailing) {
                projectAvatar(tokens: tokens)
                    .frame(width: 24, height: 24)
                if let deletionKind {
                    WarrenBrailleSpinner(size: 12, accessibilityLabel: deletionKind.accessibilityLabel)
                        .background(tokens.sidebarSurface, in: Circle())
                        .offset(x: 5, y: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityLabel("Project \(project.name)")
        .accessibilityValue(projectAccessibilityValue())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "project.\(project.id.description)",
            role: .button,
            label: "Project \(project.name)",
            value: projectAccessibilityValue(),
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: { if !isInteractionDisabled { onSelect() } }
        )
        .focused($isFocused)
        .contextMenu {
            if !isInteractionDisabled {
                WarrenDesktopContextMenu([
                    .button(title: isPinned ? "Unpin Project" : "Pin Project", action: onTogglePin),
                    .button(title: "Rename Project", action: onRename),
                    .button(title: "Import Existing Worktrees…", action: onImportWorktrees),
                    .button(
                        title: project.autoImportGitWorktrees
                            ? "Disable Automatic Worktree Import"
                            : "Enable Automatic Worktree Import (No Confirmation)",
                        action: onToggleAutoImportWorktrees
                    ),
                    .divider,
                    .button(title: "Delete Project…", destructive: true, action: onDelete),
                ])
            }
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
                    projectAvatar(tokens: tokens)
                        .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                               height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
                        .opacity(isHovered || isToggleFocused ? 0 : 1)

                    Text(project.name)
                        .font(WarrenTypography.navigationItem)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let deletionKind {
                        deletionStatus(tokens: tokens, kind: deletionKind)
                    }

                    Text("(\(workspaceCount))")
                        .font(WarrenTypography.navigationMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .opacity(isHovered || isToggleFocused || forceHover ? 1 : 0)
                        .accessibilityHidden(true)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, WarrenSpacing.compact)
                .padding(.trailing, actionSlot)
                .frame(minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
            .disabled(isInteractionDisabled)
            .focused($isFocused)
            .foregroundStyle(tokens.projectText)
            .accessibilityLabel("Project \(project.name)")
            .accessibilityValue(projectAccessibilityValue(isExpanded: isExpanded))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: "project.\(project.id.description)",
                role: .button,
                label: "Project \(project.name)",
                value: projectAccessibilityValue(isExpanded: isExpanded),
                isEnabled: !isInteractionDisabled,
                isSelected: isSelected,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )

            HStack(spacing: WarrenSpacing.xxs) {
                Button(action: onAddWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.86))
                        .accessibilityHidden(true)
                }
                .buttonStyle(WarrenChromeButtonStyle(isFocused: isAddFocused))
                .disabled(isInteractionDisabled)
                .frame(width: compactActionSize, height: compactActionSize)
                .contentShape(.rect)
                .opacity(isHovered || isAddFocused ? 1 : 0)
                .focused($isAddFocused)
                .accessibilityLabel("New workspace in \(project.name)")
                .help("New workspace")
                .warrenSemanticElement(
                    id: "project.\(project.id.description).new-workspace",
                    role: .button,
                    label: "New workspace in \(project.name)",
                    isEnabled: !isInteractionDisabled,
                    action: { if !isInteractionDisabled { onAddWorkspace() } }
                )
            }
            .padding(.trailing, WarrenSpacing.xs)
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
            .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                   height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
            .contentShape(.rect)
            .opacity(isHovered || isToggleFocused ? 1 : 0)
            .focused($isToggleFocused)
            .padding(.leading, WarrenSpacing.compact)
            .accessibilityLabel(isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)")
            .warrenSemanticElement(
                id: "project.\(project.id.description).toggle",
                role: .button,
                label: isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)",
                isEnabled: !isInteractionDisabled,
                action: { if !isInteractionDisabled { onToggleExpansion() } }
            )
        }
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarProjectRowHeight)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: isInteractionDisabled,
            pressed: false,
            selected: isSelected,
            focused: isFocused,
            hovered: isHovered || isAddFocused || isToggleFocused
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !isInteractionDisabled {
                WarrenDesktopContextMenu([
                    .button(title: isPinned ? "Unpin Project" : "Pin Project", action: onTogglePin),
                    .button(title: "Rename Project", action: onRename),
                    .button(title: "Import Existing Worktrees…", action: onImportWorktrees),
                    .button(
                        title: project.autoImportGitWorktrees
                            ? "Disable Automatic Worktree Import"
                            : "Enable Automatic Worktree Import (No Confirmation)",
                        action: onToggleAutoImportWorktrees
                    ),
                    .divider,
                    .button(title: "Delete Project…", destructive: true, action: onDelete),
                ])
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    /// Superset's project rows render a first-letter avatar (or the project's
    /// icon); Warren uses the same slot for its first-letter avatar.
    private func projectAvatar(tokens: WarrenColorTokens) -> some View {
        Text(String(project.name.prefix(1)).uppercased())
            .font(WarrenTypography.compactCode)
            .foregroundStyle(tokens.foreground.opacity(0.92))
            .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                   height: WarrenLayoutMetrics.sidebarRowIconSlotSize)
            .background(tokens.muted.opacity(0.55))
            .clipShape(.rect(cornerRadius: WarrenRadius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.xs)
                    .stroke(tokens.border.opacity(0.55), lineWidth: WarrenSpacing.hairline)
            }
            .accessibilityHidden(true)
    }

    private func deletionStatus(
        tokens: WarrenColorTokens,
        kind: WarrenDesktopProjectDeletionKind
    ) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            WarrenBrailleSpinner(size: 14, accessibilityLabel: kind.accessibilityLabel)
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
