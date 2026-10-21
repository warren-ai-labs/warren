import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopTabItem: View {
    let tab: ClientTab
    let displayTitle: String
    let mark: WarrenActivityMark?
    let isSelected: Bool
    /// Whether this Tab can start a drag.
    var canStartDrag: Bool = true
    let isPinned: Bool
    /// The bar's selection namespace, so the plate slides between Tabs.
    let selectionNamespace: Namespace.ID
    /// This Tab's width. The bar gives every Tab the same width, so the track's
    /// origin math stays `index * width`.
    var width: CGFloat = WarrenLayoutMetrics.tabWidth
    /// Whether the plate travels here. A Tab more than a viewport away appears
    /// with the plate already on it instead of sweeping the whole track.
    var plateTravels = true
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

    private var contextMenuActions: [WarrenDesktopContextMenuAction] {
        guard let sessionID = tab.sessionID else { return [] }
        return Self.contextMenuActions(
            sessionID: sessionID,
            isPinned: isPinned,
            hasActivity: mark != nil,
            workspaceMoveTargets: sessionMoveTargets,
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
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let pillShape = RoundedRectangle(
            cornerRadius: WarrenLayoutMetrics.tabPillRadius,
            style: .continuous
        )
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    badge(tokens: tokens)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    WarrenDesktopFadingLine(edge: .trailing) {
                        Text(displayTitle)
                            .font(.system(size: 13, weight: .medium))
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
                .padding(.leading, 5)
                .padding(.trailing, WarrenLayoutMetrics.tabAccessoryColumnWidth - 4)
                .frame(
                    width: width,
                    height: WarrenLayoutMetrics.tabPillHeight,
                    alignment: .leading
                )
                .contentShape(.rect)
            }
            // Selection and hover fills are owned by the pill below. The inner
            // button only adds focus and press feedback.
            .buttonStyle(WarrenTabButtonStyle(isFocused: isTabFocused))
            .focused($isTabFocused)
            .disabled(tab.sessionID == nil)
            .foregroundStyle(
                isSelected
                    ? tokens.foreground.opacity(0.95)
                    : (isHovered ? tokens.foreground.opacity(0.83) : tokens.mutedForeground)
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
            .frame(width: 18, height: 18)
            .contentShape(.rect)
            .background(
                isCloseHovered ? tokens.fillHover : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
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
            .padding(.trailing, 4)
        }
        .frame(width: width, height: WarrenLayoutMetrics.tabPillHeight)
        .background {
            if isSelected {
                // The plate is the anchor: it slides to the newly selected Tab
                // rather than fading in place.
                // The same plate as the single pane's pill and the split
                // group's, so a selected Tab reads one way at any count.
                pillShape
                    .fill(tokens.selectedTabPillFill)
                    .matchedGeometryEffect(
                        id: plateTravels ? "tab-selection" : "tab-selection-here",
                        in: selectionNamespace
                    )
                    .transition(.opacity)
            } else if isHovered {
                pillShape.fill(tokens.fillHover)
            }
        }
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: isHovered
        )
        .animation(
            WarrenMotion.selection(reduceMotion: reduceMotion),
            value: isSelected
        )
        .contentShape(.rect)
        .dropDestination(for: String.self) { tabIDs, _ in
            guard let sourceID = tabIDs.first else { return false }
            onMoveBefore(sourceID)
            return true
        }
        .onHover { isHovered = $0 }
        .warrenContextMenu(tab.sessionID == nil ? [] : contextMenuActions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(displayTitle)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    /// The Session's kind badge. A Tab with no Session yet shows a placeholder
    /// tile.
    @ViewBuilder
    private func badge(tokens: WarrenColorTokens) -> some View {
        if tab.sessionID == nil {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tokens.info.opacity(0.6))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            // Status lives in the sidebar's dots; the Tab names the Session.
            WarrenDesktopSessionKindBadge(kind: tab.kind, size: 16)
        }
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .overlay {
                RoundedRectangle(
                    cornerRadius: WarrenLayoutMetrics.tabPillRadius,
                    style: .continuous
                )
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack {
            Button(action: action) {
                Group {
                    if isLoading {
                        WarrenLoadingIndicator(size: 14, accessibilityLabel: "Starting session")
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .regular))
                    }
                }
                .accessibilityHidden(true)
            }
            // Drawn like the panels button beside it: two plain glyphs at the
            // trailing edge, not a boxed control competing with the Tabs.
            .buttonStyle(WarrenChromeButtonStyle())
            .disabled(!isEnabled || isLoading)
            .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(isLoading ? "Starting session" : "New session")
            .warrenTooltip("New session")
            .warrenSemanticElement(
                id: "tab.new",
                role: .button,
                label: "New session",
                isEnabled: isEnabled && !isLoading,
                action: action
            )
        }
        .frame(height: WarrenLayoutMetrics.tabPillHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab actions")
    }
}
