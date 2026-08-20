import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct WarrenDesktopTabBar: View {
    let tabs: [ClientTab]
    let tabTitles: [String: String]
    let tabActivities: [TerminalSessionID: AgentActivityState]
    let pinnedSessionIDs: Set<TerminalSessionID>
    let selectedTabID: String?
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    let onSettings: () -> Void
    let onWeb: () -> Void
    let onOpenInExternalIDE: (WarrenDesktopExternalIDEOption) -> Void
    let onSelectEndpoint: (String) -> Void
    let onSelectTab: (String) -> Void
    let onMoveTab: (String, String?) -> Void
    let sessionMoveTargets: [WarrenDesktopSessionMoveTarget]
    let sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination]
    let onMoveSession: (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void
    let canAddTab: Bool
    let isAddingTab: Bool
    let onAddTab: () -> Void
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    let onCloseAllTabs: () -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onToggleSessionPin: (TerminalSessionID, Bool) -> Void
    let onDismissActivity: (TerminalSessionID, AgentActivityState) -> Void

    @Environment(\.colorScheme) private var colorScheme

    static func tabTrackWidth(tabCount: Int) -> CGFloat {
        CGFloat(tabCount) * WarrenLayoutMetrics.tabWidth
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(tokens.chromeSurface)

            HStack(spacing: 0) {
                if chromeMode == .workspace, isSidebarCollapsed {
                    WarrenDesktopCollapsedWorkspaceLeading(onToggleSidebar: onToggleSidebar)
                }

                WarrenOverflowFadeScrollView(
                    .horizontal,
                    fadeLength: WarrenLayoutMetrics.tabScrollFadeLength,
                    surface: tokens.chromeSurface,
                    showsEdgeChevrons: true
                ) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            let activity = tab.sessionID.flatMap { tabActivities[$0] }
                            WarrenDesktopTabItem(
                                tab: tab,
                                displayTitle: tabTitles[tab.id] ?? tab.title,
                                activity: activity,
                                isSelected: selectedTabID == tab.id,
                                isPinned: tab.sessionID.map(pinnedSessionIDs.contains) ?? false,
                                onSelect: { onSelectTab(tab.id) },
                                onClose: { onCloseTab(tab.id) },
                                onCloseOthers: { onCloseOtherTabs(tab.id) },
                                onCloseAll: onCloseAllTabs,
                                onMoveBefore: { sourceID in onMoveTab(sourceID, tab.id) },
                                onRename: {
                                    guard let sessionID = tab.sessionID else { return }
                                    onRequestRename(.session(
                                        sessionID,
                                        title: tabTitles[tab.id] ?? tab.title
                                    ))
                                },
                                onTogglePin: {
                                    guard let sessionID = tab.sessionID else { return }
                                    onToggleSessionPin(
                                        sessionID,
                                        !pinnedSessionIDs.contains(sessionID)
                                    )
                                },
                                onDismissActivity: {
                                    guard let sessionID = tab.sessionID,
                                          let activity else { return }
                                    onDismissActivity(sessionID, activity)
                                },
                                sessionMoveTargets: tab.sessionID.map { sessionID in
                                    sessionMoveTargets.filter {
                                        $0.destination != sessionMoveDestinations[sessionID]
                                    }
                                } ?? [],
                                onMoveSession: { sessionID, destination in
                                    onMoveSession(sessionID, destination)
                                }
                            )
                        }
                    }
                    .background {
                        WarrenDesktopTabScrollFollower(
                            selectedTabID: selectedTabID,
                            tabIDs: tabs.map(\.id)
                        )
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(
                    maxWidth: Self.tabTrackWidth(tabCount: tabs.count),
                    alignment: .leading
                )
                .layoutPriority(1)

                WarrenDesktopTabAddSlot(
                    action: onAddTab,
                    isEnabled: canAddTab,
                    isLoading: isAddingTab
                )
                .dropDestination(for: String.self) { tabIDs, _ in
                    guard let tabID = tabIDs.first else { return false }
                    onMoveTab(tabID, nil)
                    return true
                }

                // The drag filler lives outside the scroll view, exactly like
                // Superset's TabBar: it stays available when the track is full
                // so there is always a small native drag leaf.
                WarrenDesktopWindowDragRegion(identifier: "warren.tab-bar-drag-region")
                    .frame(minWidth: WarrenSpacing.standard, maxWidth: .infinity)
                    .accessibilityHidden(true)

                if chromeMode == .workspace {
                    WarrenDesktopWorkspaceTabTrailing(
                        connectionState: connectionState,
                        endpointOptions: endpointOptions,
                        selectedEndpointID: selectedEndpointID,
                        webStatus: webStatus,
                        externalIDEOptions: externalIDEOptions,
                        hasInspector: hasInspector,
                        isInspectorVisible: isInspectorVisible,
                        onSettings: onSettings,
                        onWeb: onWeb,
                        onOpenInExternalIDE: onOpenInExternalIDE,
                        onSelectEndpoint: onSelectEndpoint,
                        onToggleInspector: onToggleInspector
                    )
                }
            }
            .frame(height: WarrenLayoutMetrics.tabBarHeight)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .overlay(alignment: .bottom) {
            WarrenDesktopChromeDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tab bar")
    }
}

enum WarrenDesktopTabScrollPosition {
    static func originX(
        selectedIndex: Int,
        tabWidth: CGFloat,
        trackWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let maximumOriginX = max(trackWidth - viewportWidth, 0)
        let selectedMidpoint = (CGFloat(selectedIndex) + 0.5) * tabWidth
        return min(
            max(selectedMidpoint - viewportWidth / 2, 0),
            maximumOriginX
        )
    }
}

/// Keeps the native horizontal track aligned with the active tab. SwiftUI's
/// `ScrollViewProxy` cannot reliably cross WarrenOverflowFadeScrollView's
/// nested reader on macOS, so this leaf scrolls its enclosing AppKit view.
private struct WarrenDesktopTabScrollFollower: NSViewRepresentable {
    let selectedTabID: String?
    let tabIDs: [String]

    func makeNSView(context: Context) -> WarrenDesktopTabScrollFollowerView {
        let view = WarrenDesktopTabScrollFollowerView()
        view.update(selectedTabID: selectedTabID, tabIDs: tabIDs)
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabScrollFollowerView, context: Context) {
        nsView.update(selectedTabID: selectedTabID, tabIDs: tabIDs)
    }
}

private final class WarrenDesktopTabScrollFollowerView: NSView {
    private var selectedTabID: String?
    private var tabIDs: [String] = []
    private var lastViewportWidth: CGFloat?
    private var scrollScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleScroll()
    }

    override func layout() {
        super.layout()
        guard let scrollView = enclosingScrollView else { return }
        let viewportWidth = scrollView.contentView.bounds.width
        guard viewportWidth != lastViewportWidth else { return }
        lastViewportWidth = viewportWidth
        scheduleScroll()
    }

    func update(selectedTabID: String?, tabIDs: [String]) {
        guard self.selectedTabID != selectedTabID || self.tabIDs != tabIDs else { return }
        self.selectedTabID = selectedTabID
        self.tabIDs = tabIDs
        scheduleScroll()
    }

    private func scheduleScroll() {
        guard !scrollScheduled else { return }
        scrollScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollScheduled = false
            self.scrollToSelectedTab()
        }
    }

    private func scrollToSelectedTab() {
        guard let selectedTabID,
              let selectedIndex = tabIDs.firstIndex(of: selectedTabID),
              let scrollView = enclosingScrollView else { return }

        let viewport = scrollView.contentView.bounds
        guard viewport.width > 0 else { return }

        let tabWidth = WarrenLayoutMetrics.tabWidth
        let trackWidth = max(CGFloat(tabIDs.count) * tabWidth, bounds.width)
        let originX = WarrenDesktopTabScrollPosition.originX(
            selectedIndex: selectedIndex,
            tabWidth: tabWidth,
            trackWidth: trackWidth,
            viewportWidth: viewport.width
        )
        guard abs(viewport.minX - originX) > 0.5 else { return }

        var origin = viewport.origin
        origin.x = originX
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private struct WarrenDesktopCollapsedWorkspaceLeading: View {
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: WarrenSpacing.small) {
            WarrenDesktopWindowDragRegion()
                .frame(width: max(
                    WarrenLayoutMetrics.macTrafficLightInset
                        - WarrenLayoutMetrics.sidebarCollapsedWidth,
                    0
                ))

            WarrenDesktopChromeButton(
                systemImage: "sidebar.left",
                label: "Expand sidebar",
                hint: "Show the project and workspace list",
                action: onToggleSidebar
            )
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }
}

/// The trailing controls are ordered from workspace actions to global preferences.
/// Add new controls here so their placement remains explicit and reviewable.
enum WarrenDesktopWorkspaceTabTrailingControl: CaseIterable, Hashable {
    case externalIDE
    case endpoint
    case web
    case inspector
    case settings
}

private struct WarrenDesktopWorkspaceTabTrailing: View {
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let hasInspector: Bool
    let isInspectorVisible: Bool
    let onSettings: () -> Void
    let onWeb: () -> Void
    let onOpenInExternalIDE: (WarrenDesktopExternalIDEOption) -> Void
    let onSelectEndpoint: (String) -> Void
    let onToggleInspector: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            ForEach(WarrenDesktopWorkspaceTabTrailingControl.allCases, id: \.self) {
                trailingControl($0, tokens: tokens)
            }
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace actions")
    }

    @ViewBuilder
    private func trailingControl(
        _ control: WarrenDesktopWorkspaceTabTrailingControl,
        tokens: WarrenColorTokens
    ) -> some View {
        switch control {
        case .externalIDE:
            if let externalIDEOptions, !externalIDEOptions.isEmpty {
                WarrenDesktopExternalIDEMenu(
                    options: externalIDEOptions,
                    onOpen: onOpenInExternalIDE
                )
            }
        case .endpoint:
            WarrenDesktopEndpointControl(
                connectionState: connectionState,
                endpoints: endpointOptions,
                selectedID: selectedEndpointID,
                onSelect: onSelectEndpoint
            )
        case .web:
            WarrenDesktopChromeButton(
                systemImage: "globe",
                label: "Web",
                hint: webStatus.tunnelRunning
                    ? "Public sharing is on"
                    : (webStatus.isRunning ? "Web is running" : "Web is stopped"),
                action: onWeb,
                tint: webStatus.tunnelRunning
                    ? tokens.info
                    : (webStatus.isRunning ? tokens.success : nil)
            )
        case .inspector:
            if hasInspector {
                WarrenDesktopInspectorButton(
                    isVisible: isInspectorVisible,
                    action: onToggleInspector
                )
            }
        case .settings:
            WarrenDesktopChromeButton(
                systemImage: "gearshape",
                label: "Settings",
                hint: "Open Warren settings",
                action: onSettings
            )
        }
    }
}

private struct WarrenDesktopEndpointControl: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var dismissTask: Task<Void, Never>?

    private var selectedEndpoint: WarrenDesktopEndpointOption? {
        endpoints.first { $0.id == selectedID }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "server.rack")
                    .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
                WarrenStatusIndicator(
                    color: statusColor(presentation.tone, tokens: tokens),
                    isActive: presentation.isActive,
                    size: 6,
                    accessibilityLabel: presentation.label
                )
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .focused($isFocused)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel("Execution server: \(selectedEndpoint?.label ?? "Server")")
        .accessibilityHint("\(presentation.label). Click for details.")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent(tokens: tokens)
        }
        .onDisappear {
            dismissTask?.cancel()
        }
    }

    @ViewBuilder
    private func popoverContent(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                WarrenStatusIndicator(
                    color: statusColor(presentation.tone, tokens: tokens),
                    isActive: presentation.isActive,
                    size: 8,
                    accessibilityLabel: presentation.label
                )
                Text(presentation.label)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
            }
            .padding(.bottom, WarrenSpacing.compact)

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
                .padding(.bottom, WarrenSpacing.small)

            ForEach(endpoints) { endpoint in
            Button {
                    onSelect(endpoint.id)
                    dismissTask?.cancel()
                    dismissTask = nil
                    isPresented = false
            } label: {
                HStack(spacing: WarrenSpacing.compact) {
                    Image(systemName: endpoint.id == selectedID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            endpoint.id == selectedID
                                ? tokens.highlight
                                    : tokens.mutedForeground
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.label)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.foreground)
                            if let detail = endpoint.detail {
                                Text(detail)
                                    .font(WarrenTypography.supporting)
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, WarrenSpacing.xs)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(WarrenSpacing.medium)
        .frame(width: 220)
        .warrenPanelSurface(cornerRadius: WarrenRadius.base)
    }

    private func statusColor(
        _ tone: WarrenDesktopConnectionTone,
        tokens: WarrenColorTokens
    ) -> Color {
        switch tone {
        case .success: tokens.success
        case .info: tokens.info
        case .warning: tokens.warning
        case .destructive: tokens.destructive
        }
    }

    private func toggle() {
        if isPresented {
            dismissTask?.cancel()
            dismissTask = nil
            isPresented = false
        } else {
            show()
        }
    }

    private func show() {
        dismissTask?.cancel()
        isPresented = true
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                isPresented = false
            }
        }
    }
}
