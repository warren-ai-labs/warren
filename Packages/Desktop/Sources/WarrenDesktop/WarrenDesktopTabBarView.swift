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
    let tabMarks: [TerminalSessionID: WarrenActivityMark]
    let pinnedSessionIDs: Set<TerminalSessionID>
    let selectedTabID: String?
    /// Every pane group the track draws. Compact mode lists a scope's panes, so
    /// it draws one run per arrangement; rich mode hands over only the activen
    /// one.
    let splitGroups: [WarrenDesktopSplitGroup]
    var onCopyPaneTitle: () -> Void = {}
    /// The solo pill's title menu, built from the bar's own rename request and
    /// the current editor list. Nil leaves the menu empty.
    var soloTitleActions: ((WarrenDesktopSoloPaneIdentity.Model) -> [WarrenDesktopContextMenuAction])? = nil
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let onToggleSidebar: () -> Void
    /// The dot the collapsed sidebar button carries, or nil.
    var sidebarAttentionMark: WarrenActivityMark? = nil
    /// Reports the pointer over the collapsed sidebar button, for the peek
    /// gesture.
    var onSidebarButtonHover: ((Bool) -> Void)? = nil
    let onChromePopover: (WarrenDesktopChromePopover) -> Void
    /// The right sidebar's state and its toggle. The icon is the sidebar's own,
    /// so it opens and closes the sidebar rather than a menu of panels.
    let rightSidebarOpen: Bool
    let rightSidebarAvailable: Bool
    let onToggleRightSidebar: () -> Void
    /// The Host picker entry while the rail is collapsed, or nil when the rail
    /// is expanded.
    let collapsedHost: WarrenDesktopCollapsedHost?
    let onSelectTab: (String) -> Void
    let onMoveTab: (String, String?) -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void
    let sessionMoveTargets: [WarrenDesktopSessionMoveTarget]
    let sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination]
    let onMoveSession: (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void
    let canAddTab: Bool
    let isAddingTab: Bool
    let onAddTab: () -> Void
    /// Whether "+" opens the preset menu. Without one, "+" starts the
    /// default Session directly.
    let hasNewSessionMenu: Bool
    let onCloseTab: (String) -> Void
    let onCloseOtherTabs: (String) -> Void
    /// Closes every pane of the layout the named Tab belongs to.
    let onCloseAllTabs: (String) -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onToggleSessionPin: (TerminalSessionID, Bool) -> Void
    let onDismissActivity: (TerminalSessionID, AgentActivityState) -> Void
    /// The group pill's own commands. A Tab id names the member each applies to.
    let zoomedTabID: String?
    let onToggleZoom: (String) -> Void
    let onSplitGroup: () -> Void
    let onUngroup: () -> Void
    let onMergeIntoGroup: (String) -> Void
    /// Window-level chrome that sits just before the trailing capsule: the
    /// approval tray's pill. It draws nothing while it has nothing to say.
    let trailingAccessory: AnyView?
    /// The notice center's bell, first in the trailing capsule. Nil leaves it
    /// out, for a bar mounted without a notice center.
    let noticeBell: AnyView?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingTabID: String?
    @Namespace private var tabSelection
    /// The width the track's viewport was given, so every Tab can be sized to
    /// fill it evenly down to the floor.
    @State private var trackViewport: CGFloat = 0
    /// Whether the selection plate travels to the newly selected Tab. It does
    /// not when the Tab is more than a viewport away: a plate sweeping across
    /// several screens' worth of track reads as a stray highlight rather than as
    /// "this one moved there".
    @State private var plateTravels = true
    @State private var previousSelectedIndex: Int?
    @State private var plateTravelReset: Task<Void, Never>?
    @Environment(\.warrenPaneGroupHover) private var injectedGroupHover
    @StateObject private var ownGroupHover = WarrenDesktopPaneGroupHover()

    /// The window shares its hover with the pane cards; a bar mounted on its
    /// own keeps one of its own.
    private var groupHover: WarrenDesktopPaneGroupHover {
        injectedGroupHover ?? ownGroupHover
    }

    init(
        presentation: WarrenDesktopPaneBarPresentation,
        tabTitles: [String: String],
        tabMarks: [TerminalSessionID: WarrenActivityMark],
        pinnedSessionIDs: Set<TerminalSessionID>,
        selectedTabID: String?,
        splitGroups: [WarrenDesktopSplitGroup] = [],
        onCopyPaneTitle: @escaping () -> Void = {},
        soloTitleActions: ((WarrenDesktopSoloPaneIdentity.Model) -> [WarrenDesktopContextMenuAction])? = nil,
        chromeMode: WarrenDesktopChromeMode,
        isSidebarCollapsed: Bool,
        onToggleSidebar: @escaping () -> Void,
        sidebarAttentionMark: WarrenActivityMark? = nil,
        onSidebarButtonHover: ((Bool) -> Void)? = nil,
        onChromePopover: @escaping (WarrenDesktopChromePopover) -> Void,
        rightSidebarOpen: Bool = false,
        rightSidebarAvailable: Bool = false,
        onToggleRightSidebar: @escaping () -> Void = {},
        collapsedHost: WarrenDesktopCollapsedHost? = nil,
        onSelectTab: @escaping (String) -> Void,
        onMoveTab: @escaping (String, String?) -> Void,
        onSplitDrop: @escaping (String, String, SplitDropTarget) -> Void = { _, _, _ in },
        sessionMoveTargets: [WarrenDesktopSessionMoveTarget],
        sessionMoveDestinations: [TerminalSessionID: WarrenDesktopSessionMoveDestination],
        onMoveSession: @escaping (TerminalSessionID, WarrenDesktopSessionMoveDestination) -> Void,
        canAddTab: Bool,
        isAddingTab: Bool,
        onAddTab: @escaping () -> Void,
        hasNewSessionMenu: Bool = false,
        onCloseTab: @escaping (String) -> Void,
        onCloseOtherTabs: @escaping (String) -> Void,
        onCloseAllTabs: @escaping (String) -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onToggleSessionPin: @escaping (TerminalSessionID, Bool) -> Void,
        onDismissActivity: @escaping (TerminalSessionID, AgentActivityState) -> Void,
        zoomedTabID: String? = nil,
        onToggleZoom: @escaping (String) -> Void = { _ in },
        onSplitGroup: @escaping () -> Void = {},
        onUngroup: @escaping () -> Void = {},
        onMergeIntoGroup: @escaping (String) -> Void = { _ in },
        trailingAccessory: AnyView? = nil,
        noticeBell: AnyView? = nil
    ) {
        self.presentation = presentation
        self.tabTitles = tabTitles
        self.tabMarks = tabMarks
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedTabID = selectedTabID
        self.splitGroups = splitGroups
        self.onCopyPaneTitle = onCopyPaneTitle
        self.soloTitleActions = soloTitleActions
        self.chromeMode = chromeMode
        self.isSidebarCollapsed = isSidebarCollapsed
        self.onToggleSidebar = onToggleSidebar
        self.sidebarAttentionMark = sidebarAttentionMark
        self.onSidebarButtonHover = onSidebarButtonHover
        self.onChromePopover = onChromePopover
        self.rightSidebarOpen = rightSidebarOpen
        self.rightSidebarAvailable = rightSidebarAvailable
        self.onToggleRightSidebar = onToggleRightSidebar
        self.collapsedHost = collapsedHost
        self.onSelectTab = onSelectTab
        self.onMoveTab = onMoveTab
        self.onSplitDrop = onSplitDrop
        self.sessionMoveTargets = sessionMoveTargets
        self.sessionMoveDestinations = sessionMoveDestinations
        self.onMoveSession = onMoveSession
        self.canAddTab = canAddTab
        self.isAddingTab = isAddingTab
        self.onAddTab = onAddTab
        self.hasNewSessionMenu = hasNewSessionMenu
        self.onCloseTab = onCloseTab
        self.onCloseOtherTabs = onCloseOtherTabs
        self.onCloseAllTabs = onCloseAllTabs
        self.onRequestRename = onRequestRename
        self.onToggleSessionPin = onToggleSessionPin
        self.onDismissActivity = onDismissActivity
        self.zoomedTabID = zoomedTabID
        self.onToggleZoom = onToggleZoom
        self.onSplitGroup = onSplitGroup
        self.onUngroup = onUngroup
        self.onMergeIntoGroup = onMergeIntoGroup
        self.trailingAccessory = trailingAccessory
        self.noticeBell = noticeBell
    }

    private var tabs: [ClientTab] { presentation.listings }

    private func addAction() {
        if hasNewSessionMenu {
            onChromePopover(.newSession)
        } else {
            onAddTab()
        }
    }

    private var rowElements: [WarrenDesktopTabRowElement] {
        WarrenDesktopPaneBar.rowElements(listings: tabs, groups: splitGroups)
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        // One 32pt row on the window backdrop: a capsule of Tabs on the
        // leading side, a capsule holding the panels and "+" buttons on the
        // trailing side, and the backdrop between them as the drag area.
        HStack(spacing: WarrenLayoutMetrics.cardGap) {
            if chromeMode == .workspace, isSidebarCollapsed {
                WarrenDesktopCollapsedWorkspaceLeading(
                    onToggleSidebar: onToggleSidebar,
                    host: collapsedHost,
                    attentionMark: sidebarAttentionMark,
                    onSidebarButtonHover: onSidebarButtonHover
                )
            }

            if let solo = presentation.solo {
                // One pane: the capsule holds that Session's pill.
                WarrenDesktopChromeCapsule {
                    WarrenDesktopSoloPaneIdentity(
                        identity: solo,
                        menuActions: soloTitleActions?(solo) ?? [],
                        onCopyTitle: onCopyPaneTitle,
                        onClose: { onCloseTab(solo.tabID) }
                    )
                }
                .layoutPriority(1)
            }

            if presentation.showsTrack {
                // No outer container: the selected plate is the anchor, so the
                // Tabs sit straight on the bar.
                HStack(spacing: 2) {
                    ForEach(rowElements.filter(\.drawsGroupMark)) { element in
                        groupPill(element)
                    }
                    if !rowElements.trackTabs.isEmpty {
                        track(tokens: tokens)
                    }
                }
                .layoutPriority(1)
            }

            // The drag filler is the backdrop between the two capsules, like
            // Superset's TabBar: it stays available when the track is full so
            // there is always a native drag leaf. A Tab dropped here moves to
            // the end of the track.
            WarrenDesktopWindowDragRegion(identifier: "warren.tab-bar-drag-region")
                .frame(minWidth: WarrenSpacing.standard, maxWidth: .infinity)
                .frame(height: WarrenLayoutMetrics.tabBarHeight)
                .accessibilityHidden(true)
                .dropDestination(for: String.self) { tabIDs, _ in
                    guard let tabID = tabIDs.first else { return false }
                    onMoveTab(tabID, nil)
                    return true
                }

            if let trailingAccessory {
                trailingAccessory
            }

            // Everything that is not a Tab sits in one capsule: the bell
            // (only while the sidebar is hidden), the right sidebar's toggle
            // and "+" (the presets).
            WarrenDesktopChromeCapsule {
                HStack(spacing: 2) {
                    if let noticeBell {
                        noticeBell
                    }
                    // The way back to a Tab the track has scrolled away from.
                    if presentation.showsTrack, trackOverflows {
                        overflowButton(tokens: tokens)
                    }
                    if chromeMode == .workspace, rightSidebarAvailable {
                        WarrenDesktopRightSidebarToggle(
                            isOpen: rightSidebarOpen,
                            action: onToggleRightSidebar
                        )
                    }
                    WarrenDesktopTabAddSlot(
                        action: addAction,
                        isEnabled: canAddTab,
                        isLoading: isAddingTab
                    )
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .onChange(of: selectedTabID) { selectedID in
            pendingTabID = nil
            updatePlateTravel(to: selectedID)
        }
        .onChange(of: tabs) { _ in
            // Workspace changes can remove or reuse a pending target without
            // publishing a matching selection. Clear the visual gate
            // immediately so the next workspace's tabs are never left
            // disabled for the timeout.
            guard let pendingTabID,
                  !tabs.contains(where: { $0.id == pendingTabID }) else { return }
            self.pendingTabID = nil
        }
        .task(id: pendingTabID) {
            // A rejected selection should not leave the tab rail looking
            // busy. The normal path clears this as soon as selectedTabID
            // publishes, which also cancels this wait.
            guard pendingTabID != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            pendingTabID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tab bar")
    }

    /// One Tab of the track, with the pending feedback the bar owns.
    ///
    /// `dropBeforeTabID` is the Tab a drop on this one moves its source in
    /// front of.
    @ViewBuilder
    private func tabItem(
        _ tab: ClientTab,
        dropBeforeTabID: String?
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let mark = tab.sessionID.flatMap { tabMarks[$0] }
        WarrenDesktopTabItem(
            tab: tab,
            displayTitle: tabTitles[tab.id] ?? tab.title,
            mark: mark,
            isSelected: selectedTabID == tab.id,
            isPinned: tab.sessionID.map(pinnedSessionIDs.contains) ?? false,
            selectionNamespace: tabSelection,
            width: trackTabWidth,
            plateTravels: plateTravels,
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
                // The dismiss intent is defined over the lifecycle state,
                // which is what the Host tracks per Session; the mark only adds
                // what was being asked on top of it.
                guard let sessionID = tab.sessionID,
                      let mark else { return }
                onDismissActivity(sessionID, mark.activityState)
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
            // stays a plain pill.
            Capsule()
                .fill(pendingTabID == tab.id ? tokens.info : .clear)
                .frame(width: 24, height: pendingTabID == tab.id ? 2 : 0)
                .allowsHitTesting(false)
        }
    }

    /// Decides whether the plate slides to `selectedID`, and lets it slide again
    /// once this change has settled.
    private func updatePlateTravel(to selectedID: String?) {
        let ids = rowElements.trackTabs.map(\.id)
        guard let selectedID,
              let target = ids.firstIndex(of: selectedID),
              let previous = previousSelectedIndex,
              trackViewport > 0 else {
            previousSelectedIndex = selectedID.flatMap(ids.firstIndex(of:))
            plateTravels = true
            return
        }
        plateTravels = WarrenDesktopTabTrack.plateTravels(
            from: previous,
            to: target,
            tabWidth: trackTabWidth,
            viewport: trackViewport
        )
        previousSelectedIndex = target
        // The next move should slide again.
        plateTravelReset?.cancel()
        plateTravelReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            plateTravels = true
        }
    }

    /// The track's overflow control: how many Tabs there are, and every one of
    /// them, so a Tab scrolled off the end is still one click away.
    private func overflowButton(tokens: WarrenColorTokens) -> some View {
        let actions: [WarrenDesktopContextMenuAction] = tabs.map { tab in
            .check(
                title: tabTitles[tab.id] ?? tab.title,
                isOn: selectedTabID == tab.id
            ) {
                onSelectTab(tab.id)
            }
        }
        return HStack(spacing: 3) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
            Text("\(tabs.count)")
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .foregroundStyle(tokens.mutedForeground)
        .padding(.horizontal, 5)
        .frame(height: 20)
        .contentShape(.rect)
        .warrenMenuButton(actions, title: "All tabs")
        .warrenTooltip("All \(tabs.count) tabs")
        .accessibilityLabel("All \(tabs.count) tabs")
        .accessibilityIdentifier("tab.overflow")
    }

    /// The width every Tab takes in the track at the measured viewport.
    private var trackTabWidth: CGFloat {
        WarrenDesktopTabTrack.tabWidth(
            count: rowElements.trackTabs.count,
            viewport: trackViewport,
            groupMarkTotalWidth: rowElements.groupMarkTotalWidth
        )
    }

    /// Whether the Tabs no longer fit at the floor width.
    private var trackOverflows: Bool {
        WarrenDesktopTabTrack.overflows(
            count: rowElements.trackTabs.count,
            tabWidth: trackTabWidth,
            viewport: trackViewport,
            groupMarkTotalWidth: rowElements.groupMarkTotalWidth
        )
    }

    /// The scrolling run of Tabs outside the group.
    private func track(tokens: WarrenColorTokens) -> some View {
        let trackTabs = rowElements.trackTabs
        let tabWidth = trackTabWidth
        return WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: WarrenLayoutMetrics.tabScrollFadeLength,
            surface: tokens.windowBackdrop,
            showsEdgeChevrons: false
        ) {
            HStack(spacing: 0) {
                ForEach(trackTabs) { tab in
                    tabItem(tab, dropBeforeTabID: tab.id)
                }
            }
            .background {
                WarrenDesktopTabScrollFollower(
                    selectedTabID: selectedTabID,
                    tabIDs: trackTabs.map(\.id),
                    tabWidth: tabWidth,
                    reduceMotion: reduceMotion
                )
            }
            .frame(height: WarrenLayoutMetrics.tabPillHeight)
            .animation(
                WarrenMotion.selection(reduceMotion: reduceMotion),
                value: selectedTabID
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: WarrenDesktopTabTrackWidthKey.self,
                    value: geo.size.width
                )
            }
        }
        .onPreferenceChange(WarrenDesktopTabTrackWidthKey.self) { width in
            guard abs(width - trackViewport) > 0.5 else { return }
            trackViewport = width
        }
    }

    /// The pane group's pill, and the shelf it drops.
    ///
    /// The pill is pinned in front of the scrolling track: the group is one
    /// placement that leads the strip, and its icons lift above the pill's
    /// bounds, which a scroll view would clip.
    @ViewBuilder
    private func groupPill(_ element: WarrenDesktopTabRowElement) -> some View {
        if case .groupRun(let group, let runTabs, _) = element {
            let model = groupPresentation(group: group, tabs: runTabs)
            let actions = groupActions(model)
            let hover = groupHover
            WarrenDesktopPaneGroupPill(group: model, actions: actions, hover: hover)
                .overlay(alignment: .topLeading) {
                    WarrenDesktopPaneGroupShelfLayer(group: model, actions: actions, hover: hover)
                }
                .zIndex(1)
        }
    }

    private func groupPresentation(
        group: WarrenDesktopSplitGroup,
        tabs runTabs: [ClientTab]
    ) -> WarrenDesktopPaneGroupPresentation {
        let frames = group.tree.unitFrames()
        let members = runTabs.map { tab in
            WarrenDesktopPaneGroupPresentation.Member(
                tab: tab,
                title: tabTitles[tab.id] ?? tab.title,
                mark: tab.sessionID.flatMap { tabMarks[$0] },
                activity: group.activity[tab.id] ?? "",
                icon: group.icons[tab.id] ?? WarrenDesktopAppIcon(kind: tab.kind),
                unitFrame: frames[tab.id] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            )
        }
        let ids = Set(runTabs.map(\.id))
        let selectedMember = selectedTabID.flatMap { ids.contains($0) ? $0 : nil }
        return WarrenDesktopPaneGroupPresentation(
            scopeKey: group.scopeKey,
            title: group.title.isEmpty ? "Split group" : group.title,
            context: group.context,
            members: members,
            currentTabID: selectedMember ?? group.activeTabID ?? runTabs.first?.id,
            containsSelection: selectedMember != nil,
            canSplit: group.tree.count < SplitLayoutTree.maxPanes
        )
    }

    private func groupActions(_ model: WarrenDesktopPaneGroupPresentation) -> WarrenDesktopPaneGroupActions {
        WarrenDesktopPaneGroupActions(
            selectMember: { selectTab($0) },
            selectGroup: {
                guard !model.containsSelection, let tabID = model.currentTabID else { return }
                selectTab(tabID)
            },
            toggleZoom: onToggleZoom,
            isZoomed: { $0 == zoomedTabID },
            closeMember: onCloseTab,
            split: onSplitGroup,
            ungroup: onUngroup,
            merge: onMergeIntoGroup,
            splitDrop: onSplitDrop,
            contextMenu: contextMenuActions(for:)
        )
    }

    /// One Tab's context menu, shared by the track's pills and the group's
    /// members.
    private func contextMenuActions(for tab: ClientTab) -> [WarrenDesktopContextMenuAction] {
        guard let sessionID = tab.sessionID else { return [] }
        let mark = tabMarks[sessionID]
        let targets = sessionMoveTargets.filter {
            $0.destination != sessionMoveDestinations[sessionID]
        }
        return WarrenDesktopTabItem.contextMenuActions(
            sessionID: sessionID,
            isPinned: pinnedSessionIDs.contains(sessionID),
            hasActivity: mark != nil,
            workspaceMoveTargets: targets,
            onMoveSession: onMoveSession,
            onTogglePin: {
                onToggleSessionPin(sessionID, !pinnedSessionIDs.contains(sessionID))
            },
            onDismissActivity: {
                guard let mark else { return }
                onDismissActivity(sessionID, mark.activityState)
            },
            onRename: {
                onRequestRename(.session(sessionID, title: tabTitles[tab.id] ?? tab.title))
            },
            onClose: { onCloseTab(tab.id) },
            onCloseOthers: { onCloseOtherTabs(tab.id) },
            onCloseAll: { onCloseAllTabs(tab.id) }
        )
    }

    private func selectTab(_ tabID: String) {
        guard pendingTabID == nil else { return }
        guard selectedTabID != tabID else {
            onSelectTab(tabID)
            return
        }
        pendingTabID = tabID
        onSelectTab(tabID)
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
    /// Every Tab's width, so the follower's origins match what the track drew.
    let tabWidth: CGFloat
    let reduceMotion: Bool

    func makeNSView(context: Context) -> WarrenDesktopTabScrollFollowerView {
        let view = WarrenDesktopTabScrollFollowerView()
        view.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            tabWidth: tabWidth,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabScrollFollowerView, context: Context) {
        nsView.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            tabWidth: tabWidth,
            reduceMotion: reduceMotion
        )
    }
}

private final class WarrenDesktopTabScrollFollowerView: NSView {
    private var selectedTabID: String?
    private var tabIDs: [String] = []
    private var tabWidth = WarrenLayoutMetrics.tabWidth
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
        tabWidth: CGFloat,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        guard self.selectedTabID != selectedTabID
            || self.tabIDs != tabIDs
            || self.tabWidth != tabWidth else { return }
        self.selectedTabID = selectedTabID
        self.tabIDs = tabIDs
        self.tabWidth = tabWidth
        scheduleScroll()
    }

    /// Where a Tab starts on the track.
    private func originX(forTabIndex index: Int) -> CGFloat {
        CGFloat(index) * tabWidth
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
    /// each run's position is only the bar's business for the frames between a
    /// layout change and that reorder landing. A Tab's drop target is the first
    /// one that follows every run, since nothing can land inside a run.
    static func rowElements(
        listings: [ClientTab],
        groups: [WarrenDesktopSplitGroup]
    ) -> [WarrenDesktopTabRowElement] {
        let drawn = groups.filter(\.isDrawn)
        guard !drawn.isEmpty else {
            return listings.map { .tab(tab: $0) }
        }
        var claimed: Set<String> = []
        var runs: [(group: WarrenDesktopSplitGroup, tabs: [ClientTab])] = []
        for group in drawn {
            let paneOrder = Dictionary(
                uniqueKeysWithValues: group.tabIDs.enumerated().map { ($0.element, $0.offset) }
            )
            let members = listings
                .filter { paneOrder[$0.id] != nil && !claimed.contains($0.id) }
                .sorted { (paneOrder[$0.id] ?? 0) < (paneOrder[$1.id] ?? 0) }
            guard !members.isEmpty else { continue }
            claimed.formUnion(members.map(\.id))
            runs.append((group, members))
        }
        guard !runs.isEmpty else { return listings.map { .tab(tab: $0) } }
        let rest = listings.filter { !claimed.contains($0.id) }
        return runs.map { .groupRun(group: $0.group, tabs: $0.tabs, dropBeforeTabID: rest.first?.id) }
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
            return "tabgroup.\(group.id)"
        }
    }

    var drawsGroupMark: Bool {
        if case .groupRun = self { return true }
        return false
    }
}

extension Array where Element == WarrenDesktopTabRowElement {
    /// The drawn group, which is pinned in front of the track.
    var groupRunElement: WarrenDesktopTabRowElement? {
        first(where: \.drawsGroupMark)
    }

    /// The Tabs the scrolling track draws: everything outside the group.
    var trackTabs: [ClientTab] {
        compactMap { element in
            if case .tab(let tab) = element { return tab }
            return nil
        }
    }

    /// Every Tab in the order the bar draws them, the group's members first.
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

    /// The drawn-Tab index each group's mark sits in front of, in draw order.
    ///
    /// The track's width and every Tab origin behind a mark are computed from
    /// these, so they are the only reason a Tab's origin is not simply
    /// `index * tabWidth` once a group is drawn.
    var groupMarkAnchors: [Int] {
        var anchors: [Int] = []
        var tabCount = 0
        for element in self {
            switch element {
            case .tab:
                tabCount += 1
            case .groupRun(let group, let tabs, _):
                if group.isDrawn { anchors.append(tabCount) }
                tabCount += tabs.count
            }
        }
        return anchors
    }

    /// The extra track width every drawn group costs together.
    var groupMarkTotalWidth: CGFloat {
        WarrenLayoutMetrics.tabGroupMarkSlotWidth * CGFloat(groupMarkAnchors.count)
    }
}

/// Caps a view's width at `maxWidth` without stretching it to the cap.
///
/// A plain `frame(maxWidth:)` grows to whatever the row offers, so a two-letter
/// title would still take the whole cap. This measures the content's own width
/// and clamps that, while still letting the content shrink when the row is
/// narrower than the content itself.
private struct WarrenDesktopClampedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        let bounded = min(ideal.width, maxWidth)
        return CGSize(
            width: min(bounded, proposal.width ?? bounded),
            height: min(ideal.height, proposal.height ?? ideal.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
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
        /// A shell's foreground command, drawn beside the title. Empty for an
        /// idle shell and for every other kind.
        var runningCommand: String = ""
        let fullTitle: String
        /// The detail card's rows. The command is the full line, the directory
        /// the Session's working directory, and the branch its Workspace's.
        var commandLine: String = ""
        var directory: String = ""
        var branch: String = ""
        var kindName: String = "Shell"
        let providerPresetID: String?
        let mark: WarrenActivityMark?
        let canClose: Bool
    }

    let identity: Model
    /// The title's click menu. The bar owns the actions because it owns the
    /// rename request and the editor list.
    var menuActions: [WarrenDesktopContextMenuAction] = []
    let onCopyTitle: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// The detail card trails the pointer by a beat so a title the pointer only
    /// passes over never makes one.
    @State private var showsDetails = false
    @State private var detailTask: Task<Void, Never>?

    private var preset: WarrenDesktopSessionPreset? {
        identity.providerPresetID.flatMap { id in
            WarrenDesktopSessionPreset.builtIns.first { $0.id == id }
        }
    }

    /// The trailing controls are hover-revealed, so a resting workspace shows a
    /// title and nothing else.
    private var showsControls: Bool { isHovered || forceHover }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 7) {
            Group {
                if let preset {
                    WarrenDesktopSessionKindBadge(kind: preset.request.kind, size: 16)
                } else {
                    WarrenDesktopSessionKindBadge(kind: .shell, size: 16)
                }
            }

            titleArea(tokens: tokens)
                .warrenMenuButton(menuActions)
                .onHover(perform: titleHover)
                .warrenMenuPanel(
                    isPresented: $showsDetails,
                    width: WarrenDesktopDetailCard.width,
                    isPassive: true
                ) {
                    WarrenDesktopDetailCard(rows: detailRows)
                }

            HStack(spacing: 0) {
                Button(action: onCopyTitle) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(WarrenChromeButtonStyle())
                .warrenTooltip("Copy Full Title")
                .accessibilityLabel("Copy Full Title")

                if identity.canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(WarrenChromeButtonStyle())
                    // View-only, like every other pane close.
                    .warrenTooltip("Close Pane", shortcut: "⌘W")
                    .accessibilityLabel("Close Pane")
                    .warrenSemanticElement(
                        id: "pane.solo.close",
                        role: .button,
                        label: "Close Pane",
                        action: onClose
                    )
                }
            }
            // The controls keep their own width so a squeezed pill truncates
            // the title instead of overlapping the buttons with it.
            .fixedSize(horizontal: true, vertical: false)
            .opacity(showsControls ? 1 : 0)
            .animation(
                WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                value: showsControls
            )
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
        }
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .frame(height: WarrenLayoutMetrics.tabPillHeight)
        .background(
            tokens.selectedTabPillFill,
            in: RoundedRectangle(cornerRadius: WarrenLayoutMetrics.tabPillRadius, style: .continuous)
        )
        // A Session named after a long shell command must not make the row
        // demand more width than the window has: SwiftUI centres that overflow
        // on the window and pushes the sidebar off screen. The pill is the
        // flexible part of the row, capped at the width a long title is allowed
        // to take; see `titleArea`.
        .onHover { isHovered = $0 }
        // A shell's command arriving or leaving changes the pill's width; the
        // pill grows into it and the command fades in rather than appearing.
        .animation(
            WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion),
            value: identity.runningCommand
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(identity.fullTitle)")
        .warrenSemanticElement(
            id: "pane.solo",
            role: .text,
            label: "Pane \(identity.fullTitle)",
            value: identity.title
        )
    }

    /// The Session's name, with a shell's running command beside it.
    ///
    /// The appended command is shown whole or not at all — a half command
    /// reads as a different command — so the title gives up width first: the
    /// pill drops the command before it shortens the title, and only a title
    /// that still does not fit fades at its tail, with no ellipsis. The width
    /// cap keeps a long name from taking the whole row while a short one still
    /// hugs its own width.
    private func titleArea(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopClampedWidth(maxWidth: WarrenLayoutMetrics.soloPillTitleMaxWidth) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    titleText(tokens: tokens)
                    runningCommandText(tokens: tokens)
                }
                titleText(tokens: tokens)
                fadingTitleText(tokens: tokens)
            }
        }
    }

    private func titleText(tokens: WarrenColorTokens) -> some View {
        Text(identity.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tokens.foreground.opacity(0.95))
            .lineLimit(1)
            .textSelection(.enabled)
    }

    /// The title when it does not fit: it keeps its start, drops the ellipsis,
    /// and fades over the last 28 points instead.
    private func fadingTitleText(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopFadingLine(edge: .trailing) {
            titleText(tokens: tokens)
        }
    }

    @ViewBuilder
    private func runningCommandText(tokens: WarrenColorTokens) -> some View {
        if !identity.runningCommand.isEmpty {
            Text("· \(identity.runningCommand)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The rows the pointer reveals: the full command, where the Session is,
    /// the Workspace's branch, and what kind of Session it is.
    private var detailRows: [WarrenDesktopDetailCard.Row] {
        var rows: [WarrenDesktopDetailCard.Row] = []
        if !identity.commandLine.isEmpty {
            rows.append(.init(label: "Command", value: identity.commandLine))
        }
        if !identity.directory.isEmpty {
            rows.append(.init(label: "Directory", value: identity.directory))
        }
        if !identity.branch.isEmpty {
            rows.append(.init(label: "Branch", value: identity.branch))
        }
        rows.append(.init(label: "Kind", value: identity.kindName))
        return rows
    }

    /// Shows the detail card only after the pointer has rested on the title.
    private func titleHover(_ isInside: Bool) {
        detailTask?.cancel()
        detailTask = nil
        guard isInside else {
            showsDetails = false
            return
        }
        detailTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            showsDetails = true
        }
    }
}

private struct WarrenDesktopCollapsedWorkspaceLeading: View {
    let onToggleSidebar: () -> Void
    let host: WarrenDesktopCollapsedHost?
    var attentionMark: WarrenActivityMark? = nil
    var onSidebarButtonHover: ((Bool) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        HStack(spacing: WarrenSpacing.xs) {
            // The rail's card owns the real traffic lights when it is docked.
            // With the rail collapsed there is no card, so the window's own
            // lights move into the title bar to stay where they always are.
            WarrenDesktopTrafficLights()
                .padding(.leading, 8)

            WarrenDesktopChromeButton(
                systemImage: "sidebar.left",
                label: "Expand sidebar",
                hint: "Show the project and workspace list",
                action: onToggleSidebar,
                shortcut: "⌘B"
            )
            .overlay(alignment: .topTrailing) {
                if let attentionMark {
                    WarrenDesktopSidebarAttentionDot(mark: attentionMark)
                }
            }
            .onHover { onSidebarButtonHover?($0) }

            // The Host panel is the entry to Settings and Public Access, so it
            // has to stay reachable while the rail is collapsed.
            if let host {
                hostButton(host)
            }
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace navigation")
    }

    private func hostButton(_ host: WarrenDesktopCollapsedHost) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return Button(action: host.toggle) {
            HStack(spacing: 5) {
                Text(host.initial)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.foreground.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(
                        tokens.foreground.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if host.isPublicAccessOn {
                            Circle()
                                .fill(tokens.success)
                                .frame(width: 6, height: 6)
                                .padding(1)
                                .background(Circle().fill(tokens.workbenchCardFill))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
            .background(
                host.isPickerPresented ? tokens.selectedTabPillFill : .clear,
                in: RoundedRectangle(cornerRadius: WarrenLayoutMetrics.tabPillRadius, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Host \(host.name)")
        .accessibilityLabel("Host \(host.name)")
        .accessibilityValue(host.isPublicAccessOn ? "Public Access on" : "")
        .warrenSemanticElement(
            id: "collapsed-host",
            role: .button,
            label: "Host",
            value: host.name,
            isSelected: host.isPickerPresented,
            action: host.toggle
        )
    }
}

/// The Host picker entry the collapsed rail keeps in the top bar.
struct WarrenDesktopCollapsedHost {
    let name: String
    let initial: String
    let isPublicAccessOn: Bool
    let isPickerPresented: Bool
    let toggle: () -> Void
}

/// The right sidebar's toggle.
///
/// The icon is the sidebar's own (`sidebar.right`), and it used to open a menu
/// of panels instead of doing what it drew. It is a real switch now: selected
/// while the sidebar is up, and no Public Access dot — that moved to the Host
/// name, where it stays visible with the sidebar closed.
struct WarrenDesktopRightSidebarToggle: View {
    let isOpen: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Button(action: action) {
            Image(systemName: isOpen ? "rectangle.righthalf.inset.filled" : "sidebar.right")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
        .background(
            isOpen ? tokens.selectedTabPillFill : .clear,
            in: RoundedRectangle(cornerRadius: WarrenLayoutMetrics.tabPillRadius, style: .continuous)
        )
        .foregroundStyle(isOpen ? tokens.foreground : tokens.mutedForeground)
        .warrenTooltip(isOpen ? "Hide Right Sidebar" : "Show Right Sidebar", shortcut: "\u{2325}\u{2318}B")
        .accessibilityLabel("Right Sidebar")
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
        .accessibilityHint("Toggle the right sidebar")
        .warrenSemanticElement(
            id: "right-sidebar.toggle",
            role: .button,
            label: "Right Sidebar",
            value: isOpen ? "Shown" : "Hidden",
            isSelected: isOpen,
            action: action
        )
    }
}
