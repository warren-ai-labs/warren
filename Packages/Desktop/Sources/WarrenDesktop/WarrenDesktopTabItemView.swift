import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopTabItem: View {
    let tab: ClientTab
    let displayTitle: String
    /// The app icon the pill leads with.
    let icon: WarrenDesktopAppIcon
    let mark: WarrenActivityMark?
    let isSelected: Bool
    /// Whether this Tab still draws the short divider that separates it from
    /// the Tab after it. Members of one pane-group run hide theirs: the run's
    /// shared backing is what binds them, and a divider between them would
    /// divide what the backing just joined.
    var showsTrailingSeparator: Bool = true
    /// Whether this Tab can start a drag.
    ///
    /// A pane group is one placement rather than a set of slots, so its members
    /// are not draggable: the layout decides which Session sits where, and a
    /// member that moved on its own would leave the group's icon stack
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial
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
            hasActivity: mark != nil,
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

    /// The pill's corner radius: fully rounded at the item's height.
    static let pillCornerRadius = WarrenLayoutMetrics.tabCapsuleItemHeight / 2

    /// The pill is inset from the Tab's fixed slot so neighbouring pills keep a
    /// visible gap without changing the track's `index * tabWidth` geometry,
    /// which the scroll follower depends on.
    static let pillHorizontalInset: CGFloat = 1.5

    /// Only a mark that asks for a person earns a place on a Tab. Progress and
    /// "done" are read from the sidebar; the bar keeps one dot that means
    /// "this pane is waiting on you".
    static func showsActivityDot(_ mark: WarrenActivityMark?) -> Bool {
        mark?.tier == .actionable
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let isLight = colorScheme == .light
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: WarrenSpacing.small) {
                    if tab.sessionID == nil {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tokens.info.opacity(0.8))
                            .frame(width: 7, height: 7)
                            .frame(
                                width: WarrenLayoutMetrics.tabIconTileSize,
                                height: WarrenLayoutMetrics.tabIconTileSize
                            )
                            .accessibilityHidden(true)
                    } else {
                        WarrenDesktopAppIconTile(
                            icon: icon,
                            size: WarrenLayoutMetrics.tabIconTileSize
                        )
                        .opacity(isSelected ? 1 : 0.86)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 0) {
                        Text(displayTitle)
                            .font(isSelected ? WarrenTypography.bodyStrong : WarrenTypography.body)
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
                    if let mark, Self.showsActivityDot(mark) {
                        WarrenDesktopActivityIndicator(mark: mark)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, WarrenSpacing.small)
                // The close control only claims its column while it is shown,
                // so a resting Tab gives the whole pill to its title.
                .padding(
                    .trailing,
                    exposesClose
                        ? WarrenLayoutMetrics.tabAccessoryColumnWidth
                        : WarrenSpacing.medium
                )
                .padding(.horizontal, Self.pillHorizontalInset)
                .frame(
                    width: WarrenLayoutMetrics.tabWidth,
                    height: WarrenLayoutMetrics.tabCapsuleItemHeight,
                    alignment: .leading
                )
                .background(Color.clear)
                .contentShape(.rect)
            }
            // Selection and hover backgrounds are owned by the outer pill. The
            // inner button only adds focus and press feedback, so the active
            // tab never picks up an extra wash while the pointer rests on it.
            .buttonStyle(WarrenTabButtonStyle(isFocused: isTabFocused))
            .focused($isTabFocused)
            .disabled(tab.sessionID == nil)
            .foregroundStyle(
                isSelected
                    ? tokens.foreground
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
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .buttonStyle(WarrenChromeButtonStyle(isFocused: isCloseFocused))
            .frame(
                width: WarrenLayoutMetrics.tabCloseButtonSize,
                height: WarrenLayoutMetrics.tabCloseButtonSize
            )
            .contentShape(Circle())
            .background {
                Circle().fill(
                    isCloseHovered
                        ? (isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.12))
                        : .clear
                )
            }
            .clipShape(Circle())
            .foregroundStyle(tokens.mutedForeground)
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
            .padding(.trailing, WarrenSpacing.xs + Self.pillHorizontalInset)
        }
        .frame(width: WarrenLayoutMetrics.tabWidth, height: WarrenLayoutMetrics.tabCapsuleItemHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)
                .fill(pillFill(tokens: tokens, isLight: isLight))
                .shadow(
                    color: Color.black.opacity(isSelected && isLight ? 0.08 : 0),
                    radius: 1.5,
                    y: 0.5
                )
                .padding(.horizontal, Self.pillHorizontalInset)
        }
        .overlay(alignment: .trailing) {
            // A short divider between two resting pills, so a row of
            // unselected Tabs still reads as separate items. It steps aside for
            // the selected and hovered pill, whose own fill already separates it.
            Rectangle()
                .fill(tokens.border.opacity(0.7))
                .frame(width: WarrenSpacing.hairline, height: 14)
                .opacity(showsTrailingSeparator && !isSelected && !isHovered ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isHovered
        )
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isSelected
        )
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

    /// The selected pill is the brightest thing in the capsule: a white lift on
    /// dark, the raised surface on light. Hover is a quieter step of the same.
    private func pillFill(tokens: WarrenColorTokens, isLight: Bool) -> Color {
        if isSelected {
            return isLight ? tokens.selectedTabFill : Color.white.opacity(0.14)
        }
        if isHovered {
            return isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.06)
        }
        return .clear
    }
}

/// Tab-specific button feedback: focus ring and press opacity only.
///
/// Unlike the shared row style, this never paints a hover background.
/// Selection and hover washes are drawn once by `WarrenDesktopTabItem`'s
/// outer pill so the active tab keeps its pure background.
private struct WarrenTabButtonStyle: ButtonStyle {
    var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .overlay {
                RoundedRectangle(
                    cornerRadius: WarrenDesktopTabItem.pillCornerRadius,
                    style: .continuous
                )
                .strokeBorder(isFocused ? tokens.focusRing : .clear, lineWidth: isFocused ? 1 : 0)
                .padding(.horizontal, WarrenDesktopTabItem.pillHorizontalInset)
            }
            .animation(
                WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

/// The new-tab control: the first round button of the trailing capsule.
struct WarrenDesktopTabAddSlot: View {
    let action: () -> Void
    let isEnabled: Bool
    let isLoading: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let isLight = colorScheme == .light
        let size = WarrenLayoutMetrics.tabCapsuleItemHeight
        Button(action: action) {
            Group {
                if isLoading {
                    WarrenBrailleSpinner(size: 14, accessibilityLabel: "Starting session")
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .frame(width: size, height: size)
        .foregroundStyle(isHovered && isEnabled ? tokens.foreground : tokens.mutedForeground)
        .background {
            Circle().fill(
                isHovered && isEnabled && !isLoading
                    ? (isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.10))
                    : .clear
            )
        }
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .help("New tab")
        .accessibilityLabel(isLoading ? "Starting session" : "New tab")
        .warrenSemanticElement(
            id: "tab.new",
            role: .button,
            label: "New tab",
            isEnabled: isEnabled && !isLoading,
            action: action
        )
    }
}
