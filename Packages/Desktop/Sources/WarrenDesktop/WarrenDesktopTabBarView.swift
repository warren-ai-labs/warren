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
    let notices: [WarrenDesktopNotice]
    let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]
    let isOverflowPresented: Bool
    let isNoticePresented: Bool
    let onToggleSidebar: () -> Void
    let onSettings: () -> Void
    let onChromePopover: (WarrenDesktopChromePopover) -> Void
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

    init(
        tabs: [ClientTab],
        tabTitles: [String: String],
        tabActivities: [TerminalSessionID: AgentActivityState],
        pinnedSessionIDs: Set<TerminalSessionID>,
        selectedTabID: String?,
        chromeMode: WarrenDesktopChromeMode,
        isSidebarCollapsed: Bool,
        connectionState: WarrenDesktopConnectionState,
        endpointOptions: [WarrenDesktopEndpointOption],
        selectedEndpointID: String,
        webStatus: WarrenDesktopWebStatus,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        notices: [WarrenDesktopNotice] = [],
        externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl] = WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
        isOverflowPresented: Bool = false,
        isNoticePresented: Bool = false,
        onToggleSidebar: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onChromePopover: @escaping (WarrenDesktopChromePopover) -> Void,
        onOpenInExternalIDE: @escaping (WarrenDesktopExternalIDEOption) -> Void,
        onSelectEndpoint: @escaping (String) -> Void,
        onSelectTab: @escaping (String) -> Void,
        onMoveTab: @escaping (String, String?) -> Void,
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        onMoveSession: @escaping (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void,
        canAddTab: Bool,
        isAddingTab: Bool,
        onAddTab: @escaping () -> Void,
        onCloseTab: @escaping (String) -> Void,
        onCloseOtherTabs: @escaping (String) -> Void,
        onCloseAllTabs: @escaping () -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onToggleSessionPin: @escaping (TerminalSessionID, Bool) -> Void,
        onDismissActivity: @escaping (TerminalSessionID, AgentActivityState) -> Void
    ) {
        self.tabs = tabs
        self.tabTitles = tabTitles
        self.tabActivities = tabActivities
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedTabID = selectedTabID
        self.chromeMode = chromeMode
        self.isSidebarCollapsed = isSidebarCollapsed
        self.connectionState = connectionState
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.webStatus = webStatus
        self.externalIDEOptions = externalIDEOptions
        self.notices = notices
        self.externallyVisibleControls = externallyVisibleControls
        self.isOverflowPresented = isOverflowPresented
        self.isNoticePresented = isNoticePresented
        self.onToggleSidebar = onToggleSidebar
        self.onSettings = onSettings
        self.onChromePopover = onChromePopover
        self.onOpenInExternalIDE = onOpenInExternalIDE
        self.onSelectEndpoint = onSelectEndpoint
        self.onSelectTab = onSelectTab
        self.onMoveTab = onMoveTab
        self.sessionMoveTargets = sessionMoveTargets
        self.sessionMoveDestinations = sessionMoveDestinations
        self.onMoveSession = onMoveSession
        self.canAddTab = canAddTab
        self.isAddingTab = isAddingTab
        self.onAddTab = onAddTab
        self.onCloseTab = onCloseTab
        self.onCloseOtherTabs = onCloseOtherTabs
        self.onCloseAllTabs = onCloseAllTabs
        self.onRequestRename = onRequestRename
        self.onToggleSessionPin = onToggleSessionPin
        self.onDismissActivity = onDismissActivity
    }

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
                        notices: notices,
                        externallyVisibleControls: externallyVisibleControls,
                        isOverflowPresented: isOverflowPresented,
                        isNoticePresented: isNoticePresented,
                        onSettings: onSettings,
                        onChromePopover: onChromePopover,
                        onOpenInExternalIDE: onOpenInExternalIDE,
                        onSelectEndpoint: onSelectEndpoint
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
        HStack(spacing: WarrenSpacing.xs) {
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
public enum WarrenDesktopWorkspaceTabTrailingControl: CaseIterable, Hashable, Sendable {
    case externalIDE
    case endpoint
    case web
    case notifications
    case settings

    public static let maximumExternalButtonCount = 5
    /// Keep the original high-signal chrome visible; execution-server
    /// switching and Settings remain in More so the direct controls stay
    /// visually quiet while preserving the five-button ceiling.
    public static let defaultExternalControls: [Self] = [
        .externalIDE,
        .web,
        .notifications,
    ]

    public static func normalizedExternalControls(_ controls: [Self]) -> [Self] {
        var seen = Set<Self>()
        return Array(
            controls
                .filter { seen.insert($0).inserted }
                .prefix(maximumExternalButtonCount)
        )
    }

    /// Produces direct top-bar controls and the one-level overflow list. The
    /// overflow button itself reserves one of the five visible slots.
    public static func layout(
        externallyVisibleControls: [Self],
        availableControls: [Self]
    ) -> (direct: [Self], overflow: [Self]) {
        let available = allCases.filter { availableControls.contains($0) }
        let requested = normalizedExternalControls(externallyVisibleControls)
            .filter { available.contains($0) }
        let hidden = available.filter { !requested.contains($0) }
        let directLimit = hidden.isEmpty
            ? maximumExternalButtonCount
            : max(maximumExternalButtonCount - 1, 0)
        let direct = Array(requested.prefix(directLimit))
        let overflow = available.filter { !direct.contains($0) }
        return (direct, overflow)
    }

    var title: String {
        switch self {
        case .externalIDE: "Open in IDE"
        case .endpoint: "Execution Server"
        case .web: "Public Access"
        case .notifications: "Notifications"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .externalIDE: "arrow.up.forward.app"
        case .endpoint: "server.rack"
        case .web: "globe"
        case .notifications: "bell"
        case .settings: "gearshape"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .externalIDE: "Choose an application for the current workspace"
        case .endpoint: "Switch the execution server"
        case .web: "Manage Public Access"
        case .notifications: "Show system messages and errors"
        case .settings: "Open Warren settings"
        }
    }

    static func available(
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    ) -> [Self] {
        allCases.filter { control in
            control != .externalIDE || !(externalIDEOptions?.isEmpty ?? true)
        }
    }
}

private struct WarrenDesktopWorkspaceTabTrailing: View {
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let notices: [WarrenDesktopNotice]
    let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]
    let isOverflowPresented: Bool
    let isNoticePresented: Bool
    let onSettings: () -> Void
    let onChromePopover: (WarrenDesktopChromePopover) -> Void
    let onOpenInExternalIDE: (WarrenDesktopExternalIDEOption) -> Void
    let onSelectEndpoint: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            ForEach(controlLayout.direct, id: \.self) {
                trailingControl($0, tokens: tokens)
            }
            if !controlLayout.overflow.isEmpty {
                WarrenDesktopOverflowButton(
                    isPresented: isOverflowPresented,
                    action: { onChromePopover(.overflow) }
                )
            }
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace actions")
    }

    private var controlLayout: (direct: [WarrenDesktopWorkspaceTabTrailingControl], overflow: [WarrenDesktopWorkspaceTabTrailingControl]) {
        WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: externallyVisibleControls,
            availableControls: WarrenDesktopWorkspaceTabTrailingControl.available(
                externalIDEOptions: externalIDEOptions
            )
        )
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
                    onPresent: { onChromePopover(.externalIDE) },
                    onOpen: onOpenInExternalIDE
                )
            }
        case .endpoint:
            WarrenDesktopEndpointControl(
                connectionState: connectionState,
                endpoints: endpointOptions,
                selectedID: selectedEndpointID,
                onPresent: { onChromePopover(.endpoint) },
                onSelect: onSelectEndpoint
            )
        case .web:
            WarrenDesktopChromeButton(
                systemImage: "globe",
                label: "Web",
                hint: webStatus.tunnelRunning
                    ? "Public Access is on"
                    : (webStatus.isRunning ? "Web is running" : "Web is stopped"),
                action: { onChromePopover(.web) },
                tint: webStatus.tunnelRunning
                    ? tokens.info
                    : (webStatus.isRunning ? tokens.success : nil)
            )
        case .notifications:
            WarrenDesktopNoticeButton(
                unreadCount: notices.filter(\.isUnread).count,
                isPresented: isNoticePresented,
                action: { onChromePopover(.notices) }
            )
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
    let onPresent: () -> Void
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    private var selectedEndpoint: WarrenDesktopEndpointOption? {
        endpoints.first { $0.id == selectedID }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        Button(action: onPresent) {
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

}
