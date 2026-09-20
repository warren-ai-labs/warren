import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopTabItem: View {
    let tab: ClientTab
    let displayTitle: String
    let activity: AgentActivityState?
    let isSelected: Bool
    /// Whether this Tab still draws the hairline that divides it from the Tab
    /// after it. Members of one pane-group run hide theirs: the group's rule is
    /// what binds them, and a hairline between them would divide what the rule
    /// just joined.
    var showsTrailingSeparator: Bool = true
    /// Whether this Tab can start a drag.
    ///
    /// A pane group is one placement rather than a set of slots, so its members
    /// are not draggable: the layout decides which Session sits where, and a
    /// member that moved on its own would leave the group's chip and rule
    /// describing an arrangement the strip no longer shows. Selection, the
    /// context menu, and the close control are untouched.
    var canStartDrag: Bool = true
    let isPinned: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let onMoveBefore: (String) -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDismissActivity: () -> Void
    let sessionMoveTargets: [WarrenDesktopSessionMoveTarget]
    let onMoveSession: (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTabFocused: Bool
    @FocusState private var isCloseFocused: Bool
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var exposesClose: Bool {
        tab.sessionID != nil && (isHovered || isCloseFocused || forceHover)
    }

    private var workspaceMoveTargets: [WarrenDesktopSessionMoveTarget] {
        sessionMoveTargets.filter { target in
            if case .workspace = target.destination { return true }
            return false
        }
    }

    private var terminalGroupMoveTargets: [WarrenDesktopSessionMoveTarget] {
        sessionMoveTargets.filter { target in
            if case .terminalGroup = target.destination { return true }
            return false
        }
    }

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        guard let sessionID = tab.sessionID else { return [] }
        return Self.contextMenuActions(
            sessionID: sessionID,
            isPinned: isPinned,
            hasActivity: activity != nil,
            workspaceMoveTargets: workspaceMoveTargets,
            terminalGroupMoveTargets: terminalGroupMoveTargets,
            onMoveSession: onMoveSession,
            onTogglePin: onTogglePin,
            onDismissActivity: onDismissActivity,
            onRename: onRename,
            onClose: onClose,
            onCloseOthers: onCloseOthers,
            onCloseAll: onCloseAll
        )
    }

    /// The bar is a pane control, so its close actions are view operations only.
    /// Ending a Session lives on its sidebar leaf, which is also the only place
    /// the workspace's other Sessions are reachable.
    static func contextMenuActions(
        sessionID: TerminalSessionID,
        isPinned: Bool,
        hasActivity: Bool,
        workspaceMoveTargets: [WarrenDesktopSessionMoveTarget],
        terminalGroupMoveTargets: [WarrenDesktopSessionMoveTarget],
        onMoveSession: @escaping (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void,
        onTogglePin: @escaping () -> Void,
        onDismissActivity: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onCloseOthers: @escaping () -> Void,
        onCloseAll: @escaping () -> Void
    ) -> [WarrenDesktopContextMenuAction] {
        var actions: [WarrenDesktopContextMenuAction] = []
        var moveActions: [WarrenDesktopContextMenuAction] = []
        if !workspaceMoveTargets.isEmpty {
            moveActions.append(.menu(title: "Workspace", actions: workspaceMoveTargets.map { target in
                .button(title: target.title, action: { onMoveSession(sessionID, target.destination) })
            }))
        }
        if !terminalGroupMoveTargets.isEmpty {
            moveActions.append(.menu(title: "Terminal Group", actions: terminalGroupMoveTargets.map { target in
                .button(title: target.title, action: { onMoveSession(sessionID, target.destination) })
            }))
        }
        if !moveActions.isEmpty {
            actions.append(.menu(title: "Move Session To", actions: moveActions))
        }
        actions.append(.button(title: isPinned ? "Unpin Session" : "Pin Session", action: onTogglePin))
        if hasActivity {
            actions.append(.button(title: "Dismiss Activity", action: onDismissActivity))
        }
        actions.append(.button(title: "Rename Session", action: onRename))
        actions.append(.divider)
        actions.append(.button(title: "Close Pane", action: onClose))
        actions.append(.button(title: "Close Other Panes", action: onCloseOthers))
        actions.append(.button(title: "Close All Panes", action: onCloseAll))
        return actions
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: WarrenSpacing.small) {
                    if tab.sessionID == nil {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tokens.info.opacity(0.8))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    if let activity {
                        WarrenDesktopActivityIndicator(activity: activity)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 0) {
                        Text(displayTitle)
                            .font(WarrenTypography.tabShellTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    // The drag source is native because SwiftUI's `.draggable`
                    // does not reliably complete a drop over the AppKit
                    // terminal. The handle forwards a plain click to selection
                    // and resolves a split itself once the pointer crosses the
                    // movement threshold. See `WarrenDesktopTabDrag`.
                    .overlay {
                        WarrenDesktopTabDragHandle(
                            tabID: tab.id,
                            isEnabled: isEnabled && tab.sessionID != nil && canStartDrag,
                            // The handle owns the title press now, so it has
                            // to restore the keyboard focus the Button used to
                            // take on click.
                            onSelect: {
                                isTabFocused = true
                                onSelect()
                            },
                            onSplitDrop: onSplitDrop
                        )
                    }
                }
                .padding(.leading, WarrenSpacing.medium)
                .padding(.trailing, WarrenLayoutMetrics.tabAccessoryColumnWidth)
                .frame(
                    width: WarrenLayoutMetrics.tabWidth,
                    height: WarrenLayoutMetrics.tabBarHeight,
                    alignment: .leading
                )
                .background(Color.clear)
                .contentShape(.rect)
            }
            // Selection and hover backgrounds are owned by the outer tab
            // surface (background + hairline stroke). The inner button only
            // adds focus and press feedback, so the active tab never picks
            // up an extra wash while the pointer rests on it.
            .buttonStyle(WarrenTabButtonStyle(isFocused: isTabFocused))
            .focused($isTabFocused)
            .disabled(tab.sessionID == nil)
            .foregroundStyle(
                isSelected
                    ? tokens.foreground.opacity(0.90)
                    : tokens.mutedForeground
            )
            .accessibilityLabel("Tab \(displayTitle)")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .warrenSemanticElement(
                id: "tab.\(tab.id)",
                role: .tab,
                label: "Tab \(displayTitle)",
                value: isSelected ? "Selected" : "Not selected",
                isSelected: isSelected,
                action: onSelect
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isCloseFocused))
            .frame(
                width: WarrenLayoutMetrics.tabCloseButtonSize,
                height: WarrenLayoutMetrics.tabCloseButtonSize
            )
            .contentShape(.rect)
            .background(
                isCloseHovered
                    ? (isSelected ? tokens.muted.opacity(0.65) : tokens.fillHover)
                    : .clear
            )
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .opacity(exposesClose ? 1 : 0)
            .allowsHitTesting(exposesClose)
            .focused($isCloseFocused)
            .onHover { isCloseHovered = $0 }
            .accessibilityHidden(!exposesClose)
            .accessibilityLabel("Close pane \(displayTitle)")
            .warrenSemanticElement(
                id: "tab.\(tab.id).close",
                role: .button,
                label: "Close pane \(displayTitle)",
                isEnabled: exposesClose,
                action: onClose
            )
            .padding(.trailing, WarrenSpacing.xs)
        }
        .frame(width: WarrenLayoutMetrics.tabWidth, height: WarrenLayoutMetrics.tabBarHeight)
        .background(
            isSelected
                ? tokens.background
                : (isHovered ? tokens.fillHover : .clear)
        )
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isHovered
        )
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isSelected
        )
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline)
            }
        }
        .overlay(alignment: .trailing) {
            // Active tab outlines trailing edge; inactive tabs draw hairline separator.
            Rectangle()
                .fill((isSelected || showsTrailingSeparator) ? tokens.border : .clear)
                .frame(width: WarrenSpacing.hairline)
        }
        .overlay(alignment: .bottom) {
            // Superset-aligned tab flow: active tab has a transparent bottom so its
            // background flows seamlessly into the content canvas below. Inactive tabs
            // keep the continuous baseline separator.
            Rectangle()
                .fill(isSelected ? .clear : tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
        .contentShape(.rect)
        .dropDestination(for: String.self) { tabIDs, _ in
            guard let sourceID = tabIDs.first else { return false }
            onMoveBefore(sourceID)
            return true
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if tab.sessionID != nil {
                WarrenDesktopContextMenu(contextMenuActions)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(displayTitle)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

/// Tab-specific button feedback: focus ring and press opacity only.
///
/// Unlike the shared row style, this never paints a hover background.
/// Selection and hover washes are drawn once by `WarrenDesktopTabItem`'s
/// outer surface so the active tab keeps its pure background.
private struct WarrenTabButtonStyle: ButtonStyle {
    var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .overlay {
                Rectangle()
                    .stroke(isFocused ? tokens.focusRing : .clear, lineWidth: isFocused ? 1 : 0)
            }
            .animation(
                WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

struct WarrenDesktopTabAddSlot: View {
    let action: () -> Void
    let isEnabled: Bool
    let isLoading: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack {
            Button(action: action) {
                Group {
                    if isLoading {
                        WarrenBrailleSpinner(size: 14, accessibilityLabel: "Starting session")
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || isLoading)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .background(tokens.muted.opacity(0.30))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.small)
                    .stroke(tokens.border.opacity(0.60), lineWidth: WarrenSpacing.hairline)
            }
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(isLoading ? "Starting session" : "New tab")
            .warrenSemanticElement(
                id: "tab.new",
                role: .button,
                label: "New tab",
                isEnabled: isEnabled && !isLoading,
                action: action
            )
        }
        .frame(width: WarrenLayoutMetrics.tabAddButtonSlotWidth, height: WarrenLayoutMetrics.tabBarHeight)
        .padding(.leading, WarrenSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab actions")
    }
}
