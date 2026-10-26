import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// The Projects / Tasks switch at the top of the sidebar's list.
///
/// One list shows at a time, so the tabs are the list's heading: each names
/// its list and counts it, the selected one in the brightest ink with a
/// 1.5pt line laid on the hairline under the bar. A tab that is not showing
/// carries a small ember dot while one of its Sessions waits on a person or
/// has failed, so switching away never hides a request.
///
/// With Tasks turned off in Settings only the Projects tab is drawn; the bar
/// stays as the list's heading and keeps its `+`.
struct WarrenDesktopSidebarTabBar: View {
    let selected: WarrenDesktopSidebarTab
    let showsTasks: Bool
    let projectCount: Int
    let taskCount: Int
    /// Whether each list holds a Session that waits on a person or failed.
    let projectsNeedYou: Bool
    let tasksNeedYou: Bool
    let addAction: WarrenDesktopSidebarSectionAction?
    /// Hover actions drawn before `+`, for the list on screen.
    var additionalActions: [WarrenDesktopSidebarSectionAction] = []
    let onSelect: (WarrenDesktopSidebarTab) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var focusedActionID: String?

    static let topInset: CGFloat = 6
    static let height: CGFloat = topInset + WarrenDesktopSidebarMetrics.tabBarHeight + 1

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let revealsActions = isHovered || forceHover || focusedActionID != nil
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                HStack(alignment: .bottom, spacing: 4) {
                    tab(.projects, title: "Projects", count: projectCount,
                        needsYou: projectsNeedYou, tokens: tokens)
                    if showsTasks {
                        tab(.tasks, title: "Tasks", count: taskCount,
                            needsYou: tasksNeedYou, tokens: tokens)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(additionalActions) { action in
                        actionButton(action, size: 10, tokens: tokens)
                            .opacity(revealsActions ? 1 : 0)
                            .animation(
                                WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                                value: revealsActions
                            )
                    }
                    if let addAction {
                        actionButton(addAction, size: 13, tokens: tokens)
                    }
                }
                .frame(height: WarrenDesktopSidebarMetrics.tabBarHeight)
            }
            .padding(.top, Self.topInset)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            Rectangle()
                .fill(tokens.cardBorder)
                .frame(height: 1)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    private func tab(
        _ tab: WarrenDesktopSidebarTab,
        title: String,
        count: Int,
        needsYou: Bool,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = tab == selected
        let ink = tokens.sidebarInk
        return Button {
            onSelect(tab)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(isSelected
                        ? WarrenDesktopTreeTypography.tabTitleSelected
                        : WarrenDesktopTreeTypography.tabTitle)
                    .foregroundStyle(isSelected ? ink.t1 : ink.t4)
                Text("\(count)")
                    .font(WarrenDesktopTreeTypography.tabCount)
                    .foregroundStyle(isSelected ? ink.t4 : ink.t5)
                if needsYou && !isSelected {
                    Circle()
                        .fill(tokens.highlight)
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(height: WarrenDesktopSidebarMetrics.tabBarHeight, alignment: .top)
            .overlay(alignment: .bottom) {
                if isSelected {
                    // Laid on the hairline under the bar, one point lower than
                    // the tab's own bottom.
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(ink.t1)
                        .frame(height: 1.5)
                        .padding(.horizontal, 8)
                        .offset(y: 1)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue(count: count, needsYou: needsYou))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "sidebar-tab.\(tab.rawValue)",
            role: .button,
            label: title,
            value: accessibilityValue(count: count, needsYou: needsYou),
            isEnabled: true,
            isSelected: isSelected,
            action: { onSelect(tab) }
        )
    }

    private func accessibilityValue(count: Int, needsYou: Bool) -> String {
        needsYou ? "\(count), needs you" : "\(count)"
    }

    private func actionButton(
        _ action: WarrenDesktopSidebarSectionAction,
        size: CGFloat,
        tokens: WarrenColorTokens
    ) -> some View {
        Button(action: action.action) {
            Image(systemName: action.image)
                .font(.system(size: size, weight: size > 11 ? .semibold : .medium))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: focusedActionID == action.id))
        .foregroundStyle(tokens.sidebarInk.t4)
        .disabled(!action.isEnabled)
        .focused($focusedActionID, equals: action.id)
        .accessibilityLabel(action.label)
        .warrenTooltip(action.label)
        .warrenSemanticElement(
            id: "sidebar-tab-action.\(action.id)",
            role: .button,
            label: action.label,
            isEnabled: action.isEnabled,
            action: { if action.isEnabled { action.action() } }
        )
    }
}

/// Whether a Session wants a person: it waits on an answer or it failed.
/// The tab bar's dot asks this of the list it is not showing.
extension WarrenDesktopSidebarAttention {
    static func needsYou(_ session: WarrenDesktopSession) -> Bool {
        if session.leadNeedsAttention { return true }
        guard let mark = session.rowStatusMark else { return false }
        return mark == .failed || mark.tier == .actionable
    }

    static func needsYou(_ sessions: some Sequence<WarrenDesktopSession>) -> Bool {
        sessions.contains(where: needsYou)
    }
}

/// Whether every visible project is open, reported up from whichever tree
/// the Projects tab shows, so the tab bar can offer the right fold.
struct WarrenDesktopAllProjectsExpandedKey: PreferenceKey {
    static let defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        value = nextValue() ?? value
    }
}
