import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// The leading glyph a workspace row draws.
///
/// Two things read this value: the row, which draws the glyph, and the tree
/// rail, whose top tick has to reach it. The three glyphs are different widths
/// inside the same 18pt slot, so the reach differs per kind; keeping one switch
/// here is what stops the row and the guide from disagreeing.
enum WarrenDesktopWorkspaceGlyph: Equatable, Sendable {
    /// The main checkout: a laptop glyph.
    case checkout
    /// A worktree already merged to its default branch: the merge glyph.
    case mergedWorktree
    /// Any other worktree: a plain 5pt dot.
    case worktree

    init(_ workspace: Workspace) {
        if workspace.branch == nil {
            self = .checkout
        } else if workspace.mergeState == .merged {
            self = .mergedWorktree
        } else {
            self = .worktree
        }
    }
}

/// A workspace row uses a compact 26pt desktop rhythm. Its marker lives in a
/// stable slot. Project-list copies attached to a Task are context-only; the
/// Task-list copy remains the workspace navigation target.
struct WarrenDesktopWorkspaceRow: View {
    let workspace: Workspace
    let semanticScope: String
    let activity: AgentActivityState?
    let activeTabCount: Int
    let isCollapsed: Bool
    let isSelected: Bool
    /// True when this workspace is the navigation scope but one of its Session
    /// leaves owns the selection.
    ///
    /// The row then answers "you are working in here" without taking the
    /// selection fill off the leaf that answers "and in this Session". Painting
    /// both rows put the louder answer on the row the user did not click.
    var containsSelection: Bool = false
    let isPinned: Bool
    /// Whether this Workspace carries a Desktop-local Embedded Editor marker.
    ///
    /// Drawn because the marker widens the `Active only` filter (RFC 0021 §7):
    /// without a glyph an editor-only Workspace would appear among the active
    /// ones with nothing to say why, and the marker is local to this Mac rather
    /// than Workspace-wide activity every client can see.
    var isEditorMarked: Bool = false
    /// Reveals the marked Workspace's editor, or `nil` when this row cannot
    /// reach it.
    ///
    /// The marker is stored per Endpoint, so only the current Host's tree can
    /// act on it; a background Host's row keeps the glyph as a plain readout
    /// rather than offering an entry that would land on the wrong Host.
    var onOpenEditor: (() -> Void)? = nil
    let isDeleting: Bool
    let isInteractionDisabled: Bool
    /// Disables Host mutations while retaining selection and double-click
    /// navigation for a connected background Host.
    let isMutationDisabled: Bool
    /// Project-list copies of Task workspaces remain visible for context but
    /// are not navigation targets; the Task-list copy owns selection.
    let isSelectionDisabled: Bool
    /// True when the rich presentation lists at least one of this workspace's
    /// Sessions as a child row.
    ///
    /// The row then drops its activity marker entirely: every state it could
    /// summarise is already spelled out one row below, by name, with its own
    /// reason text. Keeping the aggregate made the workspace restate its
    /// children and left two markers competing in one 28pt band.
    ///
    /// The same flag makes the row stop navigating. A workspace that shows its
    /// Sessions hands navigation to them; selecting the row instead would move
    /// the user into one of the leaves they can already see and click. Double
    /// click still opens the workspace, as it does in compact mode.
    var showsSessionChildren: Bool = false
    /// The tree's row rhythm, owned by the display mode so a workspace, its
    /// project, and its Session leaves stay on one grid.
    var rowHeight: CGFloat = WarrenLayoutMetrics.sidebarWorkspaceRowHeight
    /// The task label is supplied only when this workspace is rendered in the
    /// project list. Task-list rows already sit beneath their task heading.
    let taskName: String?
    let taskID: TaskID?
    let tasks: [WarrenTask]
    let onSelectTask: (TaskID) -> Void
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onAttachToTask: (TaskID) -> Void
    let onDetachFromTask: (TaskID) -> Void
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
        return Button(action: {
            guard !isSelectionDisabled else { return }
            onSelect()
        }) {
            ZStack(alignment: .topTrailing) {
                workspaceGlyph(tokens: tokens)
                // The icon rail has no room for leaves, so the aggregate marker
                // is the only signal a workspace has work in it. It is never
                // redundant here, however the tree is configured.
                if let activity {
                    WarrenDesktopWorkspaceActivityIndicator(
                        activity: activity,
                        activeTabCount: activeTabCount,
                        isCompact: true
                    )
                        .offset(x: 5, y: -3)
                }
                if isDeleting {
                    WarrenBrailleSpinner(size: 12, accessibilityLabel: "Deleting workspace")
                        .background(tokens.sidebarSurface, in: Circle())
                        .offset(x: 5, y: 5)
                }
            }
        }
        .buttonStyle(WarrenInteractiveRowStyle(
            isSelected: isSelected && !isSelectionDisabled,
            isFocused: isFocused
        ))
        .disabled(isInteractionDisabled || isSelectionDisabled)
        .frame(width: 32, height: 32)
        .contentShape(.rect)
        .foregroundStyle(tokens.mutedForeground)
        .opacity(isInteractionDisabled ? 0.62 : 1)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .help(taskName.map { "Task: \($0)" } ?? "")
        .overlay(alignment: .topTrailing) {
            taskLinkButton
                .offset(x: 2, y: -2)
        }
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected && !isSelectionDisabled ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: workspaceAccessibilityValue,
            isEnabled: !isInteractionDisabled && !isSelectionDisabled,
            isSelected: isSelected && !isSelectionDisabled,
            action: {
                if !isInteractionDisabled && !isSelectionDisabled { onSelect() }
            }
        )
        .focused($isFocused)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isInteractionDisabled && !isSelectionDisabled { onDoubleClick() }
        })
        .contextMenu {
            if !isInteractionDisabled && !isMutationDisabled {
                WarrenDesktopContextMenu(contextMenuActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: {
            // See showsSessionChildren: a row that lists its Sessions does not
            // navigate, so a single click is inert. The leaves, the context
            // menu, and the double-click open stay live.
            guard !isSelectionDisabled, !showsSessionChildren else { return }
            onSelect()
        }) {
            HStack(spacing: WarrenSpacing.compact) {
                workspaceGlyph(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                           height: WarrenLayoutMetrics.sidebarRowIconSlotSize)

                Text(workspace.name.isEmpty ? "Workspace" : workspace.name)
                    .font(WarrenTypography.navigationItem)
                    // A workspace holding the selected leaf reads at the same
                    // weight as a selected one. Only the fill moves to the leaf,
                    // so the rail still answers "which workspace am I in" at a
                    // glance rather than by tracing indentation upward.
                    .foregroundStyle(
                        isSelectionDisabled
                            ? tokens.mutedForeground.opacity(0.62)
                            : isSelected || containsSelection
                            ? tokens.workspaceSelectedText
                            : tokens.workspaceText
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isDeleting {
                    deletionStatus(tokens: tokens)
                }

                if let activity, !showsSessionChildren {
                    WarrenDesktopWorkspaceActivityIndicator(
                        activity: activity,
                        activeTabCount: activeTabCount,
                        isCompact: false
                    )
                }

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)
            }
            // The indent lives inside the button, as it does on a project row,
            // so nesting a workspace deeper never shrinks the row's hit area.
            .padding(.leading, WarrenDesktopSidebarIndent.workspace)
            .frame(minHeight: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(
            isSelected: isSelected && !isSelectionDisabled,
            isFocused: isFocused,
            // Hover belongs to the rail this row hangs from; see
            // WarrenDesktopSessionLeafGroup.
            showsHoverBackground: !showsSessionChildren
        ))
        .disabled(isInteractionDisabled || isSelectionDisabled)
        .focused($isFocused)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isInteractionDisabled && !isSelectionDisabled { onDoubleClick() }
        })
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected && !isSelectionDisabled ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(workspace.name)",
            value: workspaceAccessibilityValue,
            isEnabled: !isInteractionDisabled && !isSelectionDisabled,
            isSelected: isSelected && !isSelectionDisabled,
            action: {
                if !isInteractionDisabled && !isSelectionDisabled { onSelect() }
            }
        )
        .frame(maxWidth: .infinity, minHeight: rowHeight)
        .padding(.trailing, WarrenSpacing.compact)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        // Both accessories sit outside the row's Button rather than inside its
        // label: a Button nested in another Button's label never receives the
        // click on macOS, the outer one swallows it.
        .overlay(alignment: .trailing) {
            HStack(spacing: WarrenSpacing.xs) {
                editorEntry
                taskLinkButton
            }
            .padding(.trailing, WarrenSpacing.compact)
        }
        .contextMenu {
            if !isInteractionDisabled && !isMutationDisabled {
                WarrenDesktopContextMenu(contextMenuActions)
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .help(taskName.map { "Task: \($0)" } ?? "")
        .accessibilityElement(children: .contain)
    }

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        var actions: [WarrenDesktopContextMenuAction] = [
            .button(title: isPinned ? "Unpin Workspace" : "Pin Workspace", action: onTogglePin),
            .button(title: "Rename Workspace", action: onRename),
        ]
        if let taskID = workspace.taskID {
            actions.append(.button(title: "Detach from Task", action: {
                onDetachFromTask(taskID)
            }))
        } else if !tasks.isEmpty {
            actions.append(.menu(title: "Add to Task", actions: tasks.map { task in
                .button(title: task.name, action: { onAttachToTask(task.id) })
            }))
        }
        actions.append(contentsOf: [
            .divider,
            .button(title: "Delete Workspace…", destructive: true, action: onDelete),
        ])
        return actions
    }

    /// The marked Workspace's editor entry.
    ///
    /// `chevron.left.forwardslash.chevron.right` is the mark: it reads as code
    /// without enclosing itself in a square, which at this size would look like
    /// the control border this row does not have. The affordance is hover alone,
    /// as it is on the Task link beside it, so a row with an editor open is no
    /// louder at rest than one without.
    @ViewBuilder
    private var editorEntry: some View {
        if isEditorMarked {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            let label = "Editor open on this Mac"
            let glyph = Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tokens.info)
            if let onOpenEditor {
                Button {
                    guard !isInteractionDisabled else { return }
                    onOpenEditor()
                } label: {
                    glyph
                        .frame(width: 20, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(WarrenChromeButtonStyle())
                .disabled(isInteractionDisabled)
                .accessibilityLabel(label)
                .accessibilityValue("Show the editor")
                .help("Show the editor")
                .warrenSemanticElement(
                    id: "workspace-editor-entry.\(semanticScope).\(workspace.id.description)",
                    role: .button,
                    label: label,
                    value: "Show the editor",
                    isEnabled: !isInteractionDisabled,
                    action: {
                        if !isInteractionDisabled { onOpenEditor() }
                    }
                )
            } else {
                glyph
                    .frame(width: 20, height: 18)
                    .accessibilityHidden(true)
                    .help(label)
            }
        }
    }

    @ViewBuilder
    private var taskLinkButton: some View {
        if let taskID, let taskName {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            Button {
                guard !isInteractionDisabled, !isMutationDisabled else { return }
                onSelectTask(taskID)
            } label: {
                Text("Task")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.highlight)
                    .frame(width: 32, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled || isMutationDisabled)
            .accessibilityLabel("Task \(taskName)")
            .accessibilityValue("Open task")
            .warrenSemanticElement(
                id: "workspace-task.\(semanticScope).\(workspace.id.description)",
                role: .button,
                label: "Task \(taskName)",
                value: "Open task",
                isEnabled: !isInteractionDisabled && !isMutationDisabled,
                action: {
                    if !isInteractionDisabled && !isMutationDisabled {
                        onSelectTask(taskID)
                    }
                }
            )
        }
    }

    private var workspaceAccessibilityValue: String {
        var values: [String] = []
        if let taskName {
            values.append("Belongs to task \(taskName)")
        }
        if isSelectionDisabled {
            values.append("Open from Task")
        }
        if containsSelection {
            values.append("Contains the selected session")
        }
        if workspace.branch != nil, let mergeState = workspace.mergeState {
            values.append(mergeState.accessibilityLabel)
        }
        if isEditorMarked {
            values.append("Editor open on this Mac")
        }
        if isDeleting {
            values.append("Deleting")
        } else if isInteractionDisabled {
            values.append("Unavailable")
        }
        if activeTabCount > 0 {
            values.append(
                activeTabCount == 1
                    ? "1 tab active"
                    : "\(activeTabCount) tabs active"
            )
        }
        values.append(isSelected ? "Selected" : "Not selected")
        return values.joined(separator: " · ")
    }

    private func deletionStatus(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            WarrenBrailleSpinner(size: 14, accessibilityLabel: "Deleting workspace")
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

    /// Superset renders local worktrees as a plain dot; the main workspace gets
    /// a laptop glyph. A merged worktree uses the native merge glyph while
    /// other branch rows retain the plain dot.
    @ViewBuilder
    private func workspaceGlyph(tokens: WarrenColorTokens) -> some View {
        let disabledColor = tokens.mutedForeground.opacity(0.62)
        switch WarrenDesktopWorkspaceGlyph(workspace) {
        case .checkout:
            Image(systemName: "laptopcomputer")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isSelectionDisabled ? disabledColor : tokens.mutedForeground)
                .accessibilityHidden(true)
        case .mergedWorktree:
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(
                    isSelectionDisabled ? disabledColor : tokens.success.opacity(0.8)
                )
                .accessibilityHidden(true)
        case .worktree:
            Circle()
                .strokeBorder(
                    isSelectionDisabled ? disabledColor : tokens.mutedForeground.opacity(0.9),
                    lineWidth: WarrenSpacing.hairline
                )
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
            isActive: activity == .working || activity == .blocked,
            size: indicatorSize,
            accessibilityLabel: accessibilityLabel
        )
        .frame(width: 10, height: 10)
    }

    private var indicatorSize: CGFloat {
        activity == .blocked ? 6 : 7
    }

    private var color: Color {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return switch activity {
        case .failed: tokens.destructive
        case .blocked: tokens.warning
        case .working: tokens.amber
        case .ready: tokens.success
        case .exited: tokens.mutedForeground
        }
    }

    private var accessibilityLabel: String {
        switch activity {
        case .failed: "Session failed"
        case .blocked: "Session needs attention"
        case .working: "Agent working"
        case .ready: "Agent ready"
        case .exited: "Session exited"
        }
    }
}

/// Shows concurrent working tabs as a compact, unboxed dot cluster. A
/// higher-priority failure or input state remains visible beside the orange
/// working marker.
struct WarrenDesktopWorkspaceActivityIndicator: View {
    let activity: AgentActivityState
    let activeTabCount: Int
    let isCompact: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var showsMultipleWorkingTabs: Bool {
        activity == .working && activeTabCount > 1
    }

    private var showsMixedActivity: Bool {
        activity != .working && activeTabCount > 0
    }

    private var visibleDotCount: Int {
        min(activeTabCount, 2)
    }

    private var usesCountLabel: Bool {
        activeTabCount > visibleDotCount
    }

    var body: some View {
        if showsMultipleWorkingTabs {
            activeTabCluster
        } else if showsMixedActivity {
            HStack(spacing: WarrenSpacing.xxs) {
                WarrenDesktopActivityIndicator(activity: activity)
                activeTabCluster
                    .accessibilityHidden(true)
            }
        } else {
            WarrenDesktopActivityIndicator(activity: activity)
        }
    }

    private var activeTabCluster: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let dotSize: CGFloat = isCompact ? 4.5 : 5.5
        let dotSlotSize = dotSize * 1.6
        return HStack(spacing: 0) {
            WarrenStatusIndicator(
                color: tokens.amber,
                isActive: true,
                size: dotSize,
                accessibilityLabel: accessibilityLabel
            )
            if !usesCountLabel {
                ForEach(1..<visibleDotCount, id: \.self) { _ in
                    Circle()
                        .fill(tokens.amber)
                        .frame(width: dotSize, height: dotSize)
                        .frame(width: dotSlotSize, height: dotSlotSize)
                        .accessibilityHidden(true)
                }
            } else {
                Text("\(activeTabCount)")
                    .font(WarrenTypography.activityChip)
                    .foregroundStyle(tokens.amber)
                    .monospacedDigit()
                    .padding(.leading, WarrenSpacing.xxs)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        activeTabCount == 1
            ? "1 tab active"
            : "\(activeTabCount) tabs active"
    }
}
