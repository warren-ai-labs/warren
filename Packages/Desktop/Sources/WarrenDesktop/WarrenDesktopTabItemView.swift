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
    let isPinned: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let onMoveBefore: (String) -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDismissActivity: () -> Void
    let sessionMoveTargets: [WarrenDesktopSessionMoveTarget]
    let onMoveSession: (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void

    @Environment(\.colorScheme) private var colorScheme
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
        guard tab.sessionID != nil else { return [] }
        var actions: [WarrenDesktopContextMenuAction] = []
        if !sessionMoveTargets.isEmpty {
            var moveActions: [WarrenDesktopContextMenuAction] = []
            if !workspaceMoveTargets.isEmpty {
                moveActions.append(.menu(title: "Workspace", actions: workspaceMoveTargets.map { target in
                    .button(title: target.title, action: {
                        guard let sessionID = tab.sessionID else { return }
                        onMoveSession(sessionID, target.destination)
                    })
                }))
            }
            if !terminalGroupMoveTargets.isEmpty {
                moveActions.append(.menu(title: "Terminal Group", actions: terminalGroupMoveTargets.map { target in
                    .button(title: target.title, action: {
                        guard let sessionID = tab.sessionID else { return }
                        onMoveSession(sessionID, target.destination)
                    })
                }))
            }
            actions.append(.menu(title: "Move Session To", actions: moveActions))
        }
        actions.append(.button(title: isPinned ? "Unpin Session" : "Pin Session", action: onTogglePin))
        if activity != nil {
            actions.append(.button(title: "Dismiss Activity", action: onDismissActivity))
        }
        actions.append(.button(title: "Rename Session", action: onRename))
        actions.append(.button(title: "Close Tab", action: onClose))
        actions.append(.button(title: "Close Other Tabs", action: onCloseOthers))
        actions.append(.button(title: "Close All Tabs", action: onCloseAll))
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
                    .draggable(tab.id)
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
            .accessibilityLabel("Close tab \(displayTitle)")
            .warrenSemanticElement(
                id: "tab.\(tab.id).close",
                role: .button,
                label: "Close tab \(displayTitle)",
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
        .overlay {
            Rectangle()
                .stroke(isSelected ? tokens.border : .clear, lineWidth: isSelected ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            // Tabs separate with a hairline. The active tab keeps its own
            // stroke instead, so the boundary never doubles.
            Rectangle()
                .fill(isSelected ? .clear : tokens.border)
                .frame(width: WarrenSpacing.hairline)
        }
        .overlay(alignment: .bottom) {
            // Active tabs flow into pane content by covering the bar's bottom
            // border. Inactive tabs keep the unbroken 1px separator.
            Rectangle()
                .fill(isSelected ? tokens.background : tokens.border)
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
