import AppKit
import QuartzCore
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// Superset v2's workspace chrome is one 40pt row. Leading controls only
/// appear when the left rail is collapsed; an expanded sidebar owns its own
/// header controls, so the workspace never gets a duplicate 48pt top bar.
struct WarrenDesktopTabBar: View {
    /// What the bar draws, resolved once from the display mode and the layout.
    ///
    /// The bar renders this value and decides nothing itself: which surface
    /// lists Sessions is a mode question, and answering it in one place is what
    /// keeps the pane control and the Session switcher from drifting apart.
    let presentation: WarrenDesktopPaneBarPresentation
    let tabTitles: [String: String]
    let tabActivities: [TerminalSessionID: AgentActivityState]
    let pinnedSessionIDs: Set<TerminalSessionID>
    let selectedTabID: String?
    /// The pane group the track draws, when the scope's layout has one.
    let splitGroup: WarrenDesktopSplitGroup?
    var onCopyPaneTitle: () -> Void = {}
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let embeddedEditorAvailable: Bool
    /// Whether the editor region is up beside the Terminal. The IDE control
    /// reports this rather than a content mode: there is no longer a mode to be
    /// in.
    let embeddedEditorSelected: Bool
    let embeddedEditorDefault: Bool
    let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]
    let isOverflowPresented: Bool
    let onToggleSidebar: () -> Void
    let onSettings: () -> Void
    let onChromePopover: (WarrenDesktopChromePopover) -> Void
    let onOpenInExternalIDE: (WarrenDesktopExternalIDEOption) -> Void
    let onOpenEmbeddedEditor: () -> Void
    let onCloseEmbeddedEditor: () -> Void
    let onSelectEndpoint: (String) -> Void
    let onRetryConnection: () -> Void
    let onStopConnection: () -> Void
    let onSelectTab: (String) -> Void
    let onMoveTab: (String, String?) -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void
    let sessionMoveTargets: [WarrenDesktopSessionMoveTarget]
    let sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination]
    let onMoveSession: (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void
    let canAddTab: Bool
    let isAddingTab: Bool
    let onAddTab: () -> Void
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    /// Closes every pane of the layout the named Tab belongs to.
    let onCloseAllTabs: (String) -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onToggleSessionPin: (TerminalSessionID, Bool) -> Void
    let onDismissActivity: (TerminalSessionID, AgentActivityState) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingTabID: String?
    @State private var pendingTabGeneration = 0

    init(
        presentation: WarrenDesktopPaneBarPresentation,
        tabTitles: [String: String],
        tabActivities: [TerminalSessionID: AgentActivityState],
        pinnedSessionIDs: Set<TerminalSessionID>,
        selectedTabID: String?,
        splitGroup: WarrenDesktopSplitGroup? = nil,
        onCopyPaneTitle: @escaping () -> Void = {},
        chromeMode: WarrenDesktopChromeMode,
        isSidebarCollapsed: Bool,
        connectionState: WarrenDesktopConnectionState,
        endpointOptions: [WarrenDesktopEndpointOption],
        selectedEndpointID: String,
        webStatus: WarrenDesktopWebStatus,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorAvailable: Bool,
        embeddedEditorSelected: Bool,
        embeddedEditorDefault: Bool,
        externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl] = WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
        isOverflowPresented: Bool = false,
        onToggleSidebar: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onChromePopover: @escaping (WarrenDesktopChromePopover) -> Void,
        onOpenInExternalIDE: @escaping (WarrenDesktopExternalIDEOption) -> Void,
        onOpenEmbeddedEditor: @escaping () -> Void,
        onCloseEmbeddedEditor: @escaping () -> Void = {},
        onSelectEndpoint: @escaping (String) -> Void,
        onRetryConnection: @escaping () -> Void = {},
        onStopConnection: @escaping () -> Void = {},
        onSelectTab: @escaping (String) -> Void,
        onMoveTab: @escaping (String, String?) -> Void,
        onSplitDrop: @escaping (String, String, SplitDropTarget) -> Void = { _, _, _ in },
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        onMoveSession: @escaping (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void,
        canAddTab: Bool,
        isAddingTab: Bool,
        onAddTab: @escaping () -> Void,
        onCloseTab: @escaping (String) -> Void,
        onCloseOtherTabs: @escaping (String) -> Void,
        onCloseAllTabs: @escaping (String) -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onToggleSessionPin: @escaping (TerminalSessionID, Bool) -> Void,
        onDismissActivity: @escaping (TerminalSessionID, AgentActivityState) -> Void
    ) {
        self.presentation = presentation
        self.tabTitles = tabTitles
        self.tabActivities = tabActivities
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedTabID = selectedTabID
        self.splitGroup = splitGroup
        self.onCopyPaneTitle = onCopyPaneTitle
        self.chromeMode = chromeMode
        self.isSidebarCollapsed = isSidebarCollapsed
        self.connectionState = connectionState
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.webStatus = webStatus
        self.externalIDEOptions = externalIDEOptions
        self.embeddedEditorAvailable = embeddedEditorAvailable
        self.embeddedEditorSelected = embeddedEditorSelected
        self.embeddedEditorDefault = embeddedEditorDefault
        self.externallyVisibleControls = WarrenDesktopWorkspaceTabTrailingControl.controlsForEndpointCount(
            externallyVisibleControls,
            endpointCount: endpointOptions.count
        )
        self.isOverflowPresented = isOverflowPresented
        self.onToggleSidebar = onToggleSidebar
        self.onSettings = onSettings
        self.onChromePopover = onChromePopover
        self.onOpenInExternalIDE = onOpenInExternalIDE
        self.onOpenEmbeddedEditor = onOpenEmbeddedEditor
        self.onCloseEmbeddedEditor = onCloseEmbeddedEditor
        self.onSelectEndpoint = onSelectEndpoint
        self.onRetryConnection = onRetryConnection
        self.onStopConnection = onStopConnection
        self.onSelectTab = onSelectTab
        self.onMoveTab = onMoveTab
        self.onSplitDrop = onSplitDrop
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

    /// The track's width for a listing, including the slot a drawn group's
    /// mark costs. The mark is not a Tab, so it has to be added here and to
    /// every Tab origin behind it in the scroll follower.
    static func tabTrackWidth(tabCount: Int, groupMarkSlotWidth: CGFloat = 0) -> CGFloat {
        CGFloat(tabCount) * WarrenLayoutMetrics.tabWidth + groupMarkSlotWidth
    }

    private var tabs: [ClientTab] { presentation.listings }

    private var rowElements: [WarrenDesktopTabRowElement] {
        WarrenDesktopPaneBar.rowElements(listings: tabs, group: splitGroup)
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

                if let solo = presentation.solo {
                    // With no track this row is the only chrome above the
                    // terminal, so the Session's identity belongs here rather
                    // than in a third bar below the presets.
                    WarrenDesktopSoloPaneIdentity(
                        identity: solo,
                        onCopyTitle: onCopyPaneTitle,
                        onClose: { onCloseTab(solo.tabID) }
                    )
                }

                if presentation.showsTrack {
                WarrenOverflowFadeScrollView(
                    .horizontal,
                    fadeLength: WarrenLayoutMetrics.tabScrollFadeLength,
                    surface: tokens.chromeSurface,
                    showsEdgeChevrons: true
                ) {
                    HStack(spacing: 0) {
                        ForEach(rowElements) { element in
                            switch element {
                            case .tab(let tab):
                                tabItem(
                                    tab,
                                    showsTrailingSeparator: true,
                                    dropBeforeTabID: tab.id,
                                    canStartDrag: true
                                )
                            case .groupRun(let group, let runTabs, let dropBeforeTabID):
                                groupRun(
                                    group: group,
                                    tabs: runTabs,
                                    dropBeforeTabID: dropBeforeTabID
                                )
                            }
                        }
                    }
                    .background {
                        WarrenDesktopTabScrollFollower(
                            selectedTabID: selectedTabID,
                            tabIDs: rowElements.drawnTabIDs,
                            groupMarkSlotWidth: rowElements.groupMarkSlotWidth,
                            groupMarkAnchorIndex: rowElements.groupMarkAnchorIndex,
                            reduceMotion: reduceMotion
                        )
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(
                    maxWidth: Self.tabTrackWidth(
                        tabCount: tabs.count,
                        groupMarkSlotWidth: rowElements.groupMarkSlotWidth
                    ),
                    alignment: .leading
                )
                .layoutPriority(1)
                }

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
                        embeddedEditorAvailable: embeddedEditorAvailable,
                        embeddedEditorSelected: embeddedEditorSelected,
                        embeddedEditorDefault: embeddedEditorDefault,
                        externallyVisibleControls: externallyVisibleControls,
                        isOverflowPresented: isOverflowPresented,
                        onSettings: onSettings,
                        onChromePopover: onChromePopover,
                        onOpenInExternalIDE: onOpenInExternalIDE,
                        onOpenEmbeddedEditor: onOpenEmbeddedEditor,
                        onCloseEmbeddedEditor: onCloseEmbeddedEditor,
                        onSelectEndpoint: onSelectEndpoint,
                        onRetryConnection: onRetryConnection,
                        onStopConnection: onStopConnection
                    )
                }
            }
            .frame(height: WarrenLayoutMetrics.tabBarHeight)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .overlay(alignment: .bottom) {
            WarrenDesktopChromeDivider()
        }
        .onChange(of: selectedTabID) { selectedID in
            pendingTabGeneration &+= 1
            pendingTabID = nil
        }
        .onChange(of: tabs) { _ in
            // Workspace changes can remove or reuse a pending target without
            // publishing a matching selection. Clear the visual gate
            // immediately so the next workspace's tabs are never left
            // disabled for the timeout.
            guard let pendingTabID,
                  !tabs.contains(where: { $0.id == pendingTabID }) else { return }
            pendingTabGeneration &+= 1
            self.pendingTabID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tab bar")
    }

    /// One Tab of the track, with the pending feedback the bar owns.
    ///
    /// `dropBeforeTabID` is the Tab a drop on this one moves its source in
    /// front of. It differs from the Tab itself for a pane group's members,
    /// where every drop resolves to the group's leading edge.
    @ViewBuilder
    private func tabItem(
        _ tab: ClientTab,
        showsTrailingSeparator: Bool,
        dropBeforeTabID: String?,
        canStartDrag: Bool
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let activity = tab.sessionID.flatMap { tabActivities[$0] }
        WarrenDesktopTabItem(
            tab: tab,
            displayTitle: tabTitles[tab.id] ?? tab.title,
            activity: activity,
            isSelected: selectedTabID == tab.id,
            showsTrailingSeparator: showsTrailingSeparator,
            canStartDrag: canStartDrag,
            isPinned: tab.sessionID.map(pinnedSessionIDs.contains) ?? false,
            onSelect: { selectTab(tab.id) },
            onClose: { onCloseTab(tab.id) },
            onCloseOthers: { onCloseOtherTabs(tab.id) },
            onCloseAll: { onCloseAllTabs(tab.id) },
            onMoveBefore: { sourceID in
                guard let dropBeforeTabID else { return }
                onMoveTab(sourceID, dropBeforeTabID)
            },
            onSplitDrop: { paneID, droppedTabID, target in
                onSplitDrop(paneID, droppedTabID, target)
            },
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
        .disabled(pendingTabID != nil)
        .opacity(pendingTabID == tab.id ? 0.72 : 1)
        .overlay(alignment: .bottom) {
            // Keep the pending state visible while the selection itself
            // remains free of a colored underline. The tab surface already
            // carries the selected background and border.
            Rectangle()
                .fill(pendingTabID == tab.id ? tokens.info : .clear)
                .frame(height: pendingTabID == tab.id ? 2 : 0)
                .allowsHitTesting(false)
        }
    }

    /// One pane group: the mark in front of its first member, and the rule that
    /// binds the members to it.
    ///
    /// A drop anywhere in the run lands after the group, which is the only
    /// position a Session from outside can take: the group leads the strip, and
    /// the Tab the drop goes in front of is the first one that follows it. The
    /// group is one placement, so nothing can be inserted between its members —
    /// that is also the only reason the rule under them can keep meaning "these
    /// belong together".
    @ViewBuilder
    private func groupRun(
        group: WarrenDesktopSplitGroup,
        tabs runTabs: [ClientTab],
        dropBeforeTabID: String?
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let color = WarrenDesktopSplitGroupPalette.color(for: group.scopeKey, tokens: tokens)
        HStack(spacing: 0) {
            WarrenDesktopSplitGroupMark(tree: group.tree, color: color)
                .padding(.leading, WarrenLayoutMetrics.tabGroupMarkLeadingInset)
                .padding(.trailing, WarrenLayoutMetrics.tabGroupMarkTrailingInset)
                // The mark is part of the group for drops as well, so landing on
                // it lands beside the group instead of on nothing.
                .dropDestination(for: String.self) { tabIDs, _ in
                    guard let sourceID = tabIDs.first else { return false }
                    onMoveTab(sourceID, dropBeforeTabID)
                    return true
                }
            ForEach(Array(runTabs.enumerated()), id: \.element.id) { index, tab in
                tabItem(
                    tab,
                    showsTrailingSeparator: WarrenDesktopTabRowElement
                        .memberShowsTrailingSeparator(index: index, count: runTabs.count),
                    dropBeforeTabID: dropBeforeTabID,
                    // A member cannot be pulled out of its group: the layout,
                    // not the Tab strip, decides which Session sits where.
                    canStartDrag: false
                )            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(WarrenLayoutMetrics.tabGroupRuleOpacity))
                .frame(height: WarrenLayoutMetrics.tabGroupRuleHeight)
                .allowsHitTesting(false)
        }
        .warrenSemanticElement(
            id: "tabgroup.\(group.scopeKey)",
            role: .group,
            label: "Split group",
            value: "\(runTabs.count) panes"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split group of \(runTabs.count) panes")
    }

    private func selectTab(_ tabID: String) {
        guard pendingTabID == nil else { return }
        guard selectedTabID != tabID else {
            onSelectTab(tabID)
            return
        }
        pendingTabGeneration &+= 1
        let generation = pendingTabGeneration
        pendingTabID = tabID
        onSelectTab(tabID)
        // A rejected selection should not leave the tab rail looking busy.
        // The normal path clears this as soon as selectedTabID publishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if pendingTabGeneration == generation, pendingTabID == tabID {
                pendingTabID = nil
            }
        }
    }
}

/// Where the native tab track must sit to keep the active Session readable.
///
/// The bar mirrors the sidebar's reveal contract instead of centering. A
/// selection already inside the visible band is left alone; one that crosses an
/// edge moves the track by the smallest distance that brings it back. Centering
/// on every change made an adjacent, fully visible tab slide the whole strip
/// sideways for no reason, which read as a jump rather than navigation.
enum WarrenDesktopTabScrollPosition {
    /// The margin kept clear at each end of the track.
    ///
    /// The track draws a fade and an overlaid chevron at both edges, so a tab
    /// revealed flush against the clip edge would sit under them. Reusing the
    /// fade length clears the whole band with one existing token.
    static let defaultRevealInset = WarrenLayoutMetrics.tabScrollFadeLength

    /// The origin that reveals a Tab starting at `selectedMinX` with the
    /// smallest movement, or the current origin when the Tab is already fully
    /// visible.
    ///
    /// The Tab's own origin is passed in rather than derived from its index:
    /// a drawn group's mark is a slot that is not a Tab, so the track's origins
    /// stop being `index * tabWidth` the moment a group exists.
    static func revealOriginX(
        selectedMinX: CGFloat,
        tabWidth: CGFloat,
        trackWidth: CGFloat,
        viewportWidth: CGFloat,
        currentOriginX: CGFloat,
        revealInset: CGFloat = WarrenDesktopTabScrollPosition.defaultRevealInset
    ) -> CGFloat {
        let maximumOriginX = max(trackWidth - viewportWidth, 0)
        let origin = min(max(currentOriginX, 0), maximumOriginX)
        guard viewportWidth > 0 else { return origin }

        // A viewport narrower than both insets would invert the visible band,
        // so the margin yields before the band does.
        let inset = min(max(revealInset, 0), viewportWidth / 2)
        let selectedMaxX = selectedMinX + tabWidth
        let visibleMinX = origin + inset
        let visibleMaxX = origin + viewportWidth - inset

        if selectedMinX < visibleMinX {
            return min(max(selectedMinX - inset, 0), maximumOriginX)
        }
        if selectedMaxX > visibleMaxX {
            return min(max(selectedMaxX - viewportWidth + inset, 0), maximumOriginX)
        }
        return origin
    }
}

/// Keeps the native horizontal track aligned with the active tab. SwiftUI's
/// `ScrollViewProxy` cannot reliably cross WarrenOverflowFadeScrollView's
/// nested reader on macOS, so this leaf scrolls its enclosing AppKit view.
private struct WarrenDesktopTabScrollFollower: NSViewRepresentable {
    let selectedTabID: String?
    let tabIDs: [String]
    /// The slot a drawn pane group's mark costs, and the Tab index it sits in
    /// front of. Together they are the follower's only reason to stop treating
    /// a Tab's origin as `index * tabWidth`.
    let groupMarkSlotWidth: CGFloat
    let groupMarkAnchorIndex: Int?
    let reduceMotion: Bool

    func makeNSView(context: Context) -> WarrenDesktopTabScrollFollowerView {
        let view = WarrenDesktopTabScrollFollowerView()
        view.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            groupMarkSlotWidth: groupMarkSlotWidth,
            groupMarkAnchorIndex: groupMarkAnchorIndex,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabScrollFollowerView, context: Context) {
        nsView.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            groupMarkSlotWidth: groupMarkSlotWidth,
            groupMarkAnchorIndex: groupMarkAnchorIndex,
            reduceMotion: reduceMotion
        )
    }
}

private final class WarrenDesktopTabScrollFollowerView: NSView {
    private var selectedTabID: String?
    private var tabIDs: [String] = []
    private var groupMarkSlotWidth: CGFloat = 0
    private var groupMarkAnchorIndex: Int?
    private var reduceMotion = false
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

    func update(
        selectedTabID: String?,
        tabIDs: [String],
        groupMarkSlotWidth: CGFloat,
        groupMarkAnchorIndex: Int?,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        guard self.selectedTabID != selectedTabID
            || self.tabIDs != tabIDs
            || self.groupMarkSlotWidth != groupMarkSlotWidth
            || self.groupMarkAnchorIndex != groupMarkAnchorIndex else { return }
        self.selectedTabID = selectedTabID
        self.tabIDs = tabIDs
        self.groupMarkSlotWidth = groupMarkSlotWidth
        self.groupMarkAnchorIndex = groupMarkAnchorIndex
        scheduleScroll()
    }

    /// Where a Tab starts on the track.
    ///
    /// The mark is drawn before the group's first member, so that member and
    /// everything after it are shifted by the mark's slot; Tabs in front of the
    /// group keep their plain `index * tabWidth` origin.
    private func originX(forTabIndex index: Int) -> CGFloat {
        let base = CGFloat(index) * WarrenLayoutMetrics.tabWidth
        guard let groupMarkAnchorIndex, index >= groupMarkAnchorIndex else { return base }
        return base + groupMarkSlotWidth
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
        let trackWidth = max(originX(forTabIndex: tabIDs.count), bounds.width)
        let originX = WarrenDesktopTabScrollPosition.revealOriginX(
            selectedMinX: self.originX(forTabIndex: selectedIndex),
            tabWidth: tabWidth,
            trackWidth: trackWidth,
            viewportWidth: viewport.width,
            currentOriginX: viewport.minX
        )
        guard abs(viewport.minX - originX) > 0.5 else { return }

        var origin = viewport.origin
        origin.x = originX
        // Revealing an off-screen tab is the only movement left, so spending an
        // animation on it is what makes the track feel continuous rather than
        // snapped. Reduce Motion — and a view that is not in a window yet, whose
        // animation would never advance — keeps the change instant.
        guard !reduceMotion, window != nil else {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = WarrenMotion.stateChangeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// The pane bar's resolved content.
///
/// The display mode answers exactly one question — does the sidebar tree list
/// Sessions — and this value carries both of its consequences: the entries the
/// track draws and the lone pane's identity. They are mutually exclusive by
/// construction, so the bar cannot draw both and cannot silently draw neither.
struct WarrenDesktopPaneBarPresentation {
    /// Entries the track iterates, in the order the bar draws them.
    let listings: [ClientTab]
    /// Whether the track is drawn at all.
    let showsTrack: Bool
    /// The lone pane's identity, non-nil only when no track is drawn.
    let solo: WarrenDesktopSoloPaneIdentity.Model?
}

extension WarrenDesktopPaneBar {
    /// The track's elements for one listing.
    ///
    /// A pane group is one placement, so the track leads with it: the members
    /// are drawn as one run at the head of the strip, in the pane order the
    /// mark's glyph draws, and the rest of the listing follows in its own order.
    /// Nothing can sit between the members, which is what lets the mark and the
    /// rule say "these belong together".
    ///
    /// The stored Tab order is moved to match (`WarrenDesktopTabOrdering`), so
    /// the run's position is only the bar's business for the frames between a
    /// layout change and that reorder landing. A Tab's drop target is the first
    /// one that follows the group, since nothing can land inside it.
    static func rowElements(
        listings: [ClientTab],
        group: WarrenDesktopSplitGroup?
    ) -> [WarrenDesktopTabRowElement] {
        guard let group, group.isDrawn else {
            return listings.map { .tab(tab: $0) }
        }
        let paneOrder = Dictionary(
            uniqueKeysWithValues: group.tabIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let members = listings
            .filter { paneOrder[$0.id] != nil }
            .sorted { (paneOrder[$0.id] ?? 0) < (paneOrder[$1.id] ?? 0) }
        let rest = listings.filter { paneOrder[$0.id] == nil }
        guard !members.isEmpty else { return listings.map { .tab(tab: $0) } }
        return [.groupRun(group: group, tabs: members, dropBeforeTabID: rest.first?.id)]
            + rest.map { WarrenDesktopTabRowElement.tab(tab: $0) }
    }

    /// Whether a scope's Sessions earn the bar a track.
    ///
    /// As a pane control the bar has nothing to do with one pane: the mark
    /// cannot switch anywhere and repeats a title the pane header carries and
    /// the sidebar leaf highlights. Panes earn their marks once there are two to
    /// choose between.
    ///
    /// As the Session switcher — which it becomes when the tree stops listing
    /// Sessions — one entry is not redundant: it may be the only way to reach a
    /// Session that is not currently in a pane.
    static func showsTrack(
        entryCount: Int,
        mode: WarrenDesktopWorkspaceDisplayMode
    ) -> Bool {
        mode.paneBarListsEverySession ? entryCount > 0 : entryCount > 1
    }

    /// Resolves the mode's one decision into everything the bar renders.
    ///
    /// `solo` is asked only when no track will be drawn, so a mode that lists
    /// Sessions in the bar never pays for an identity it will not show.
    static func presentation(
        visibleIn tree: SplitLayoutTree,
        from tabs: [ClientTab],
        selected: ClientTab?,
        mode: WarrenDesktopWorkspaceDisplayMode,
        solo: ([ClientTab]) -> WarrenDesktopSoloPaneIdentity.Model?
    ) -> WarrenDesktopPaneBarPresentation {
        let listings = self.tabs(
            visibleIn: tree,
            from: tabs,
            selected: selected,
            mode: mode
        )
        let drawsTrack = Self.showsTrack(
            entryCount: listings.count,
            mode: mode
        )
        return WarrenDesktopPaneBarPresentation(
            listings: listings,
            showsTrack: drawsTrack,
            solo: drawsTrack ? nil : solo(listings)
        )
    }
}

/// One drawn unit of the pane bar's track.
///
/// A track stops being a flat list of Tabs once a pane group exists: the
/// group's mark takes a slot of its own in front of its first member, and the
/// group's members are drawn as one run so that nothing can sit between them.
/// Resolving both here — and nowhere else — is what keeps the body, the track's
/// width, and the scroll follower agreeing about where each Tab starts.
enum WarrenDesktopTabRowElement: Identifiable, Equatable {
    case tab(tab: ClientTab)
    case groupRun(
        group: WarrenDesktopSplitGroup,
        tabs: [ClientTab],
        /// The Tab a drop on this run goes in front of, or nil for the end.
        dropBeforeTabID: String?
    )

    var id: String {
        switch self {
        case .tab(let tab):
            return tab.id
        case .groupRun(let group, _, _):
            return "tabgroup.\(group.scopeKey)"
        }
    }

    var drawsGroupMark: Bool {
        if case .groupRun = self { return true }
        return false
    }

    /// Whether the member at `index` of a run still draws the hairline that
    /// divides it from the member after it.
    ///
    /// Only the last member does. The group's rule is what joins the members,
    /// so a hairline between two of them would divide what the rule just
    /// joined — while the last one still has to separate the group from
    /// whatever Tab follows it.
    static func memberShowsTrailingSeparator(index: Int, count: Int) -> Bool {
        index == count - 1
    }
}

extension Array where Element == WarrenDesktopTabRowElement {
    /// The Tab index the group's mark sits in front of.
    ///
    /// The follower needs it because the mark is a slot rather than a Tab:
    /// every Tab from this index on is shifted right by the mark's width, so a
    /// Tab's origin is no longer `index * tabWidth`.
    var groupMarkAnchorIndex: Int? {
        var tabCount = 0
        for element in self {
            switch element {
            case .tab:
                tabCount += 1
            case .groupRun:
                return tabCount
            }
        }
        return nil
    }

    /// The extra track width one drawn group costs.
    var groupMarkSlotWidth: CGFloat {
        contains(where: \.drawsGroupMark)
            ? WarrenLayoutMetrics.tabGroupMarkSlotWidth
            : 0
    }

    /// The Tabs in the order the track draws them.
    ///
    /// Equal to the listing's order once the layout has moved the stored order
    /// (`WarrenDesktopTabOrdering`); it differs only in the frames between a
    /// layout change and that reorder landing, which is exactly why the scroll
    /// follower reads this rather than either order on its own.
    var drawnTabIDs: [String] {
        flatMap { element -> [String] in
            switch element {
            case .tab(let tab):
                return [tab.id]
            case .groupRun(_, let tabs, _):
                return tabs.map(\.id)
            }
        }
    }
}

/// The lone pane's identity, rendered in the top chrome row.
///
/// With one pane there is no track to draw, so the row is free — and a separate
/// 28pt pane header below the presets was spending a third band to say what this
/// row now says in space it already occupies. Splits keep their per-pane headers,
/// because there the question is "which of these" rather than "what is this".
struct WarrenDesktopSoloPaneIdentity: View {
    struct Model: Equatable {
        let tabID: String
        let title: String
        let fullTitle: String
        let providerPresetID: String?
        let activity: AgentActivityState?
        let canClose: Bool
    }

    let identity: Model
    let onCopyTitle: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @State private var isHovered = false

    private var preset: WarrenDesktopSessionPreset? {
        identity.providerPresetID.flatMap { id in
            WarrenDesktopSessionPreset.builtIns.first { $0.id == id }
        }
    }

    /// The trailing controls are hover-revealed, so a resting workspace shows a
    /// title and nothing else.
    private var showsControls: Bool { isHovered || forceHover }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            if let preset {
                WarrenDesktopPresetIcon(preset: preset)
                    .frame(width: 13, height: 13)
                    .opacity(0.9)
                    .accessibilityHidden(true)
            }

            Text(identity.title)
                .font(WarrenTypography.activeTabTitle)
                .foregroundStyle(tokens.foreground.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let activity = identity.activity {
                WarrenDesktopActivityIndicator(activity: activity)
            }

            HStack(spacing: WarrenSpacing.xxs) {
                Button(action: onCopyTitle) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Copy Full Title")
                .accessibilityLabel("Copy Full Title")

                if identity.canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // View-only, like every other pane close.
                    .help("Close Pane (⌘W)")
                    .accessibilityLabel("Close Pane")
                    .warrenSemanticElement(
                        id: "pane.solo.close",
                        role: .button,
                        label: "Close Pane",
                        action: onClose
                    )
                }
            }
            // The controls keep their own width so a squeezed row truncates the
            // title instead of overlapping the buttons with it.
            .fixedSize(horizontal: true, vertical: false)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
        }
        .padding(.leading, WarrenSpacing.medium)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        // The row is free, so this identity would happily take the whole width
        // of a title it can grow to: a Session named after a long shell command
        // made the row demand hundreds of points more than the window had, and
        // the resulting overflow is centred on the window — which pushed the
        // sidebar's leading edge off screen instead of clipping the title. The
        // identity is the flexible part of the row; its title already
        // truncates in the middle.
        .onHover { isHovered = $0 }
        .help(identity.fullTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(identity.fullTitle)")
        .warrenSemanticElement(
            id: "pane.solo",
            role: .text,
            label: "Pane \(identity.fullTitle)",
            value: identity.title
        )
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

/// The trailing controls are ordered from workspace actions to global utilities.
/// Settings is kept as a compatibility case for persisted layouts, but is now
/// rendered in the sidebar footer to match the workspace navigation model.
public enum WarrenDesktopWorkspaceTabTrailingControl: CaseIterable, Hashable, Sendable {
    case externalIDE
    case endpoint
    case web
    case settings

    public static let maximumExternalButtonCount = 4
    /// Locked priority for the workspace trailing chrome: IDE → Endpoint →
    /// Web → Settings.
    public static let defaultExternalControls: [Self] = [
        .externalIDE,
        .web,
        .settings,
    ]

    public static func normalizedExternalControls(_ controls: [Self]) -> [Self] {
        var seen = Set<Self>()
        return Array(
            controls
                .filter { seen.insert($0).inserted }
                .prefix(maximumExternalButtonCount)
        )
    }

    /// Resolve the explicit priority for the current endpoint count. The locked
    /// order is IDE → Endpoint → Web → Notifications → Settings; Endpoint is
    /// only exposed when more than one execution server exists. It is inserted
    /// at priority slot 2 (index 1) so the resolved array is already sorted
    /// for `layout(direct:overflow:)`.
    public static func controlsForEndpointCount(
        _ controls: [Self],
        endpointCount: Int
    ) -> [Self] {
        let normalized = normalizedExternalControls(controls)
        guard endpointCount > 1, !normalized.contains(.endpoint) else {
            return normalized
        }

        var visible = normalized
        visible.insert(.endpoint, at: min(1, visible.count))
        return normalizedExternalControls(visible)
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
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .externalIDE: "macwindow"
        case .endpoint: "server.rack"
        case .web: "globe"
        case .settings: "gearshape"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .externalIDE: "Choose an application for the current workspace"
        case .endpoint: "Switch the execution server"
        case .web: "Manage Public Access"
        case .settings: "Open Warren settings"
        }
    }

    static func available(
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorAvailable: Bool = false
    ) -> [Self] {
        allCases.filter { control in
            control != .settings
                && (control != .externalIDE
                    || embeddedEditorAvailable
                    || !(externalIDEOptions?.isEmpty ?? true))
        }
    }
}

private struct WarrenDesktopWorkspaceTabTrailing: View {
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let embeddedEditorAvailable: Bool
    let embeddedEditorSelected: Bool
    let embeddedEditorDefault: Bool
    let externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl]
    let isOverflowPresented: Bool
    let onSettings: () -> Void
    let onChromePopover: (WarrenDesktopChromePopover) -> Void
    let onOpenInExternalIDE: (WarrenDesktopExternalIDEOption) -> Void
    let onOpenEmbeddedEditor: () -> Void
    let onCloseEmbeddedEditor: () -> Void
    let onSelectEndpoint: (String) -> Void
    let onRetryConnection: () -> Void
    let onStopConnection: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xxs) {
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
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace actions")
    }

    private var controlLayout: (direct: [WarrenDesktopWorkspaceTabTrailingControl], overflow: [WarrenDesktopWorkspaceTabTrailingControl]) {
        WarrenDesktopWorkspaceTabTrailingControl.layout(
            externallyVisibleControls: externallyVisibleControls,
            availableControls: WarrenDesktopWorkspaceTabTrailingControl.available(
                externalIDEOptions: externalIDEOptions,
                embeddedEditorAvailable: embeddedEditorAvailable
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
            if embeddedEditorAvailable {
                WarrenDesktopIDEControl(
                    embeddedEditorSelected: embeddedEditorSelected,
                    embeddedEditorDefault: embeddedEditorDefault,
                    onOpenEmbeddedEditor: onOpenEmbeddedEditor,
                    onCloseEmbeddedEditor: onCloseEmbeddedEditor,
                    onPresentChoices: { onChromePopover(.externalIDE) }
                )
                .warrenSemanticElement(
                    id: "workspace-ide.open",
                    role: .button,
                    label: embeddedEditorSelected
                        ? "Close Embedded Editor"
                        : "Open in IDE",
                    value: embeddedEditorSelected
                        ? "Editor open"
                        : (embeddedEditorDefault
                            ? "Embedded editor default"
                            : "Choose an IDE"),
                    isSelected: embeddedEditorSelected,
                    action: idePrimaryAction
                )
            } else if let externalIDEOptions, !externalIDEOptions.isEmpty {
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
                    : (webStatus.isRunning ? tokens.success : nil),
                edgeSpaced: true
            )
        case .settings:
            WarrenDesktopChromeButton(
                systemImage: "gearshape",
                label: "Settings",
                hint: "Open Warren settings",
                action: onSettings,
                edgeSpaced: true
            )
        }
    }

    private func idePrimaryAction() {
        switch WarrenDesktopIDEPrimaryAction.resolve(
            embeddedEditorDefault: embeddedEditorDefault,
            embeddedEditorSelected: embeddedEditorSelected
        ) {
        case .openEmbeddedEditor:
            onOpenEmbeddedEditor()
        case .closeEmbeddedEditor:
            onCloseEmbeddedEditor()
        case .presentChoices:
            onChromePopover(.externalIDE)
        }
    }
}

enum WarrenDesktopIDEPrimaryAction: Equatable {
    case openEmbeddedEditor
    case closeEmbeddedEditor
    case presentChoices

    /// The control is tinted while the editor region is up, so a lit control has
    /// to turn it off: that used to be the editor Tab's close box, and the Tab is
    /// gone. Without this the lit control only reopened the picker, leaving the
    /// region with no visible way to close it.
    static func resolve(
        embeddedEditorDefault: Bool,
        embeddedEditorSelected: Bool
    ) -> Self {
        if embeddedEditorSelected {
            return .closeEmbeddedEditor
        }
        return embeddedEditorDefault ? .openEmbeddedEditor : .presentChoices
    }
}

private struct WarrenDesktopIDEControl: View {
    let embeddedEditorSelected: Bool
    let embeddedEditorDefault: Bool
    let onOpenEmbeddedEditor: () -> Void
    let onCloseEmbeddedEditor: () -> Void
    let onPresentChoices: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromeButton(
            systemImage: "macwindow",
            label: embeddedEditorSelected ? "Close Embedded Editor" : "Open in IDE",
            hint: hint,
            action: primaryAction,
            tint: embeddedEditorSelected ? tokens.info : nil,
            edgeSpaced: true
        )
    }

    private var hint: String {
        switch WarrenDesktopIDEPrimaryAction.resolve(
            embeddedEditorDefault: embeddedEditorDefault,
            embeddedEditorSelected: embeddedEditorSelected
        ) {
        case .openEmbeddedEditor: "Open the embedded editor"
        case .closeEmbeddedEditor: "Close the embedded editor"
        case .presentChoices: "Choose an IDE"
        }
    }

    private func primaryAction() {
        switch WarrenDesktopIDEPrimaryAction.resolve(
            embeddedEditorDefault: embeddedEditorDefault,
            embeddedEditorSelected: embeddedEditorSelected
        ) {
        case .openEmbeddedEditor:
            onOpenEmbeddedEditor()
        case .closeEmbeddedEditor:
            onCloseEmbeddedEditor()
        case .presentChoices:
            onPresentChoices()
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
        let endpointColor = selectedEndpoint.map {
            WarrenDesktopEndpointAppearance.color(
                for: $0.id,
                in: endpoints,
                tokens: tokens
            )
        } ?? tokens.mutedForeground
        Button(action: onPresent) {
            Image(systemName: "server.rack")
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .padding(.top, 2)
                .padding(.trailing, 2)
                .foregroundStyle(endpointColor)
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .fixedSize(horizontal: true, vertical: false)
        .focused($isFocused)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel("Execution server: \(selectedEndpoint?.label ?? "Server")")
        .accessibilityHint("\(presentation.label). Click for details.")
    }

}
