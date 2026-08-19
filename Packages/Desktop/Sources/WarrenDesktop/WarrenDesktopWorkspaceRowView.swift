import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// A workspace row uses a compact 26pt desktop rhythm. Its marker lives in a
/// stable slot. The complete row is one navigation/session target; there is no
/// tiny nested add button competing with branch selection.
struct WarrenDesktopWorkspaceRow: View {
    let workspace: Workspace
    let semanticScope: String
    let activity: AgentActivityState?
    let isCollapsed: Bool
    let isSelected: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

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
            ZStack(alignment: .topTrailing) {
                workspaceGlyph(tokens: tokens)
                if let activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                        .offset(x: 5, y: -3)
                }
            }
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: workspaceAccessibilityValue,
            isSelected: isSelected,
            action: onSelect
        )
        .focused($isFocused)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
        .contextMenu {
            Button(isPinned ? "Unpin Workspace" : "Pin Workspace", action: onTogglePin)
            Button("Rename Workspace", action: onRename)
            Divider()
            Button("Delete Workspace…", role: .destructive, action: onDelete)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            HStack(spacing: WarrenSpacing.compact) {
                workspaceGlyph(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                           height: WarrenLayoutMetrics.sidebarRowIconSlotSize)

                Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    .font(WarrenTypography.navigationItem)
                    .foregroundStyle(
                        isSelected
                            ? tokens.workspaceSelectedText
                            : tokens.workspaceText
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let activity {
                    WarrenDesktopActivityIndicator(activity: activity)
                }

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .focused($isFocused)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: workspaceAccessibilityValue,
            isSelected: isSelected,
            action: onSelect
        )
        .frame(maxWidth: .infinity, minHeight: WarrenLayoutMetrics.sidebarWorkspaceRowHeight)
        .padding(.leading, WarrenSpacing.compact + WarrenSpacing.xs)
        .padding(.trailing, WarrenSpacing.compact)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .contextMenu {
            Button(isPinned ? "Unpin Workspace" : "Pin Workspace", action: onTogglePin)
            Button("Rename Workspace", action: onRename)
            Divider()
            Button("Delete Workspace…", role: .destructive, action: onDelete)
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    private var isMergedWorktree: Bool {
        workspace.branch != nil && workspace.mergeState == .merged
    }

    private var workspaceAccessibilityValue: String {
        var values: [String] = []
        if workspace.branch != nil, let mergeState = workspace.mergeState {
            values.append(mergeState.accessibilityLabel)
        }
        values.append(isSelected ? "Selected" : "Not selected")
        return values.joined(separator: " · ")
    }

    /// Superset renders local worktrees as a plain dot; the main workspace gets
    /// a laptop glyph. A merged worktree uses the native merge glyph while
    /// other branch rows retain the plain dot.
    @ViewBuilder
    private func workspaceGlyph(tokens: WarrenColorTokens) -> some View {
        if workspace.branch == nil {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
        } else if isMergedWorktree {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.success.opacity(0.8))
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(tokens.mutedForeground.opacity(0.9), lineWidth: WarrenSpacing.hairline)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// Superset-style Agent activity point. Live/actionable states pulse; ready is
/// a quiet static marker.
struct WarrenDesktopActivityIndicator: View {
    let activity: AgentActivityState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WarrenStatusIndicator(
            color: color,
            isActive: activity == .working,
            size: 7,
            accessibilityLabel: accessibilityLabel
        )
        .frame(width: 10, height: 10)
    }

    private var color: Color {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return switch activity {
        case .failed: tokens.destructive
        case .waitingForInput: tokens.warning
        case .working: tokens.amber
        case .ready: tokens.success
        case .exited: tokens.mutedForeground
        }
    }

    private var accessibilityLabel: String {
        switch activity {
        case .failed: "Session failed"
        case .waitingForInput: "Session needs input"
        case .working: "Agent working"
        case .ready: "Agent ready"
        case .exited: "Session exited"
        }
    }
}
