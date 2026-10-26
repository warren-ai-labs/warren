import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// The leading glyph a workspace row draws.
///
/// Every kind draws inside the same 18pt slot, so the titles beside them start
/// on one column.
enum WarrenDesktopWorkspaceGlyph: Equatable, Sendable {
    /// The main checkout: a laptop glyph.
    case checkout
    /// A worktree already merged to its default branch: the merge glyph.
    case mergedWorktree
    /// Any other worktree: the branch glyph.
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
    /// The project named ahead of the branch, for a Task's worktrees: one Task
    /// can span several projects.
    var projectLabel: String? = nil
    /// False when the branch repeats the one its sibling worktrees share, so
    /// the row names only its project.
    var showsBranch: Bool = true
    let mark: WarrenActivityMark?
    let activeTabCount: Int
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
    /// Folds this row's Session leaves away, or `nil` when it lists none.
    ///
    /// A row that offers it spends its click on folding: its leaves already
    /// do the navigating, and a folded row keeps one dot per Session in place
    /// of the aggregate marker.
    var leafDisclosure: WarrenDesktopLeafDisclosure? = nil
    /// The tree's row rhythm, owned by the display mode so a workspace, its
    /// project, and its Session leaves stay on one grid.
    var rowHeight: CGFloat = WarrenDesktopSidebarMetrics.worktreeRowHeight
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        expandedRow
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return HStack(spacing: WarrenDesktopSidebarMetrics.worktreeIconSpacing) {
            Button(action: {
                // A row that lists its Sessions spends its click on folding
                // them; the leaves do the navigating. The context menu and the
                // double-click open stay live.
                if let leafDisclosure {
                    leafDisclosure.toggle()
                    return
                }
                guard !isSelectionDisabled, !showsSessionChildren else { return }
                onSelect()
            }) {
                HStack(spacing: WarrenDesktopSidebarMetrics.worktreeIconSpacing) {
                    workspaceGlyph(tokens: tokens)
                        .frame(width: 12, height: 12)

                    // A branch name stays quiet whatever it holds; the
                    // selected Session below says where the work is. Its
                    // type prefix is dimmer still, so the eye lands on the
                    // rest.
                    if let projectLabel {
                        Text(projectLabel)
                            .font(WarrenDesktopTreeTypography.worktreeProjectName)
                            .foregroundStyle(isSelectionDisabled ? tokens.treeQuietText : tokens.treeSecondaryText)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if projectLabel == nil || showsBranch {
                        if projectLabel != nil {
                            Text("·")
                                .font(WarrenDesktopTreeTypography.worktreeBranchSuffix)
                                .foregroundStyle(tokens.treeFaintText)
                        }
                        WarrenDesktopBranchNameLabel(
                            name: workspace.name.isEmpty ? "Workspace" : workspace.name,
                            leafColor: projectLabel != nil || isSelectionDisabled
                                ? tokens.treeQuietText : tokens.treeSecondaryText,
                            prefixColor: projectLabel != nil || isSelectionDisabled
                                ? tokens.treeFaintText : tokens.treeQuietText,
                            font: projectLabel == nil
                                ? WarrenDesktopTreeTypography.branchName
                                : WarrenDesktopTreeTypography.worktreeBranchSuffix
                        )
                    }

                    if isDeleting {
                        deletionStatus(tokens: tokens)
                    }

                    // With no Session leaves under it, the row itself says how
                    // its Sessions are doing.
                    if let mark, !showsSessionChildren, leafDisclosure == nil {
                        WarrenDesktopStatusDot(
                            mark: mark,
                            size: WarrenDesktopSidebarMetrics.foldDotSize,
                            ring: nil,
                            tokens: tokens
                        )
                    }

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.treeQuietText)
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 0)
                }
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled || isSelectionDisabled)
            .focused($isFocused)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if !isInteractionDisabled && !isSelectionDisabled { onDoubleClick() }
            })
            .accessibilityLabel("Workspace \(presentedName)")
            .accessibilityValue(workspaceAccessibilityValue)
            .accessibilityAddTraits(isSelected && !isSelectionDisabled ? .isSelected : [])
            .warrenSemanticElement(
                id: "workspace.\(semanticScope).\(workspace.id.description)",
                role: .button,
                label: "Workspace \(presentedName)",
                value: workspaceAccessibilityValue,
                isEnabled: !isInteractionDisabled && !isSelectionDisabled,
                isSelected: isSelected && !isSelectionDisabled,
                action: {
                    if !isInteractionDisabled && !isSelectionDisabled { onSelect() }
                }
            )

            // The accessories sit beside the row's Button rather than inside
            // its label: a Button nested in another Button's label never
            // receives the click on macOS.
            editorEntry
            taskLinkButton
            if let leafDisclosure {
                WarrenDesktopLeafDisclosureAccessory(
                    disclosure: leafDisclosure,
                    isRevealed: true,
                    label: "workspace \(presentedName)",
                    semanticID: "workspace-leaves.\(semanticScope).\(workspace.id.description)",
                    isEnabled: !isInteractionDisabled,
                    chevronColor: tokens.treeChevron.opacity(0.8)
                )
                // An open worktree's chevron waits for the pointer: one per
                // worktree read as a column of noise down a busy rail. A
                // folded one stays, since it is then the only sign of the fold.
                .opacity(leafDisclosure.isExpanded && !(isHovered || isFocused || forceHover) ? 0 : 1)
            }
        }
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: rowHeight)
        .background(
            isSelected && !isSelectionDisabled
                ? tokens.treeRowSelected
                : ((isHovered || isFocused) && (leafDisclosure != nil || !showsSessionChildren)
                    ? tokens.treeRowHover
                    : .clear),
            in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
        )
        .contentShape(.rect)
        .warrenContextMenu(
            !isInteractionDisabled && !isMutationDisabled ? contextMenuActions : []
        )
        // A long name truncates to one line; the whole name is on hover.
        .help(taskName.map { "\(presentedName) · Task: \($0)" } ?? presentedName)
        .accessibilityElement(children: .contain)
        .onHover { isHovered = $0 }
    }

    /// The whole name, project included, for hover and assistive technology,
    /// whatever the row has room to draw.
    private var presentedName: String {
        projectLabel.map { "\($0) · \(workspace.name)" } ?? workspace.name
    }

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        Self.contextMenuActions(
            workspace: workspace,
            isPinned: isPinned,
            tasks: tasks,
            onTogglePin: onTogglePin,
            onRename: onRename,
            onAttachToTask: onAttachToTask,
            onDetachFromTask: onDetachFromTask,
            onDelete: onDelete
        )
    }

    /// The Workspace's menu. Shared with a project that lists its only
    /// Workspace's Sessions directly and so has no Workspace row to hold it.
    static func contextMenuActions(
        workspace: Workspace,
        isPinned: Bool,
        tasks: [WarrenTask],
        onTogglePin: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onAttachToTask: @escaping (TaskID) -> Void,
        onDetachFromTask: @escaping (TaskID) -> Void,
        onDelete: @escaping () -> Void
    ) -> [WarrenDesktopContextMenuAction] {
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
            let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
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
                        .frame(width: WarrenDesktopWorkspaceRowAccessories.editorEntryWidth, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(WarrenChromeButtonStyle())
                .disabled(isInteractionDisabled)
                .accessibilityLabel(label)
                .accessibilityValue("Show the editor")
                .warrenTooltip("Show the editor")
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
                    .frame(width: WarrenDesktopWorkspaceRowAccessories.editorEntryWidth, height: 18)
                    .accessibilityHidden(true)
                    .warrenTooltip(label)
            }
        }
    }

    @ViewBuilder
    private var taskLinkButton: some View {
        if let taskID, let taskName {
            let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
            Button {
                guard !isInteractionDisabled, !isMutationDisabled else { return }
                onSelectTask(taskID)
            } label: {
                Text("Task")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.highlight)
                    .frame(width: WarrenDesktopWorkspaceRowAccessories.taskLinkWidth, height: 18)
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
            WarrenLoadingIndicator(size: 14, accessibilityLabel: "Deleting workspace")
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

    private func workspaceGlyph(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopWorkspaceGlyphView(workspace: workspace, isDisabled: isSelectionDisabled)
    }
}

/// The main workspace gets a laptop glyph, a merged worktree the merge glyph,
/// and any other worktree the branch glyph.
struct WarrenDesktopWorkspaceGlyphView: View {
    let workspace: Workspace
    var isDisabled = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let disabledColor = tokens.mutedForeground.opacity(0.62)
        switch WarrenDesktopWorkspaceGlyph(workspace) {
        case .checkout:
            Image(systemName: "laptopcomputer")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isDisabled ? disabledColor : tokens.treeQuietText)
                .accessibilityHidden(true)
        case .mergedWorktree:
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    isDisabled ? disabledColor : tokens.success.opacity(0.8)
                )
                .accessibilityHidden(true)
        case .worktree:
            WarrenDesktopViewBoxGlyph.worktreeBranch(size: WarrenDesktopSidebarMetrics.worktreeIconSize)
                .foregroundStyle(isDisabled ? disabledColor : tokens.treeQuietText)
        }
    }
}

/// Agent state as one mark: a dot for the states that need nothing, a glyph
/// badge for the ones that want a person.
///
/// The view is a thin wrapper over the shared `WarrenActivityMarkView`; the
/// Desktop's only contribution is the palette. It used to take a bare
/// `AgentActivityState` and fold everything into hue, which dropped the Host's
/// attention payload on the floor — the row that most needed someone drew the
/// same quiet dot as an idle Agent whenever the lifecycle half of the snapshot
/// was stale.
struct WarrenDesktopActivityIndicator: View {
    let mark: WarrenActivityMark
    var dotSize: CGFloat = 7
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        WarrenActivityMarkView(
            mark: mark,
            color: mark.color(WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)),
            dotSize: dotSize
        )
    }
}
