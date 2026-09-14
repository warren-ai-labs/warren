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
    let splitTabIDs: Set<String>
    var onCopyPaneTitle: () -> Void = {}
    let chromeMode: WarrenDesktopChromeMode
    let isSidebarCollapsed: Bool
    let connectionState: WarrenDesktopConnectionState
    let endpointOptions: [WarrenDesktopEndpointOption]
    let selectedEndpointID: String
    let webStatus: WarrenDesktopWebStatus
    let externalIDEOptions: [WarrenDesktopExternalIDEOption]?
    let embeddedEditorAvailable: Bool
    let embeddedEditorTabVisible: Bool
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
    let onCloseAllTabs: () -> Void
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
        splitTabIDs: Set<String> = [],
        onCopyPaneTitle: @escaping () -> Void = {},
        chromeMode: WarrenDesktopChromeMode,
        isSidebarCollapsed: Bool,
        connectionState: WarrenDesktopConnectionState,
        endpointOptions: [WarrenDesktopEndpointOption],
        selectedEndpointID: String,
        webStatus: WarrenDesktopWebStatus,
        externalIDEOptions: [WarrenDesktopExternalIDEOption]?,
        embeddedEditorAvailable: Bool,
        embeddedEditorTabVisible: Bool,
        embeddedEditorSelected: Bool,
        embeddedEditorDefault: Bool,
        externallyVisibleControls: [WarrenDesktopWorkspaceTabTrailingControl] = WarrenDesktopWorkspaceTabTrailingControl.defaultExternalControls,
        isOverflowPresented: Bool = false,
        onToggleSidebar: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onChromePopover: @escaping (WarrenDesktopChromePopover) -> Void,
        onOpenInExternalIDE: @escaping (WarrenDesktopExternalIDEOption) -> Void,
        onOpenEmbeddedEditor: @escaping () -> Void,
        onCloseEmbeddedEditor: @escaping () -> Void,
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
        onCloseAllTabs: @escaping () -> Void,
        onRequestRename: @escaping (WarrenDesktopRenameRequest) -> Void,
        onToggleSessionPin: @escaping (TerminalSessionID, Bool) -> Void,
        onDismissActivity: @escaping (TerminalSessionID, AgentActivityState) -> Void
    ) {
        self.presentation = presentation
        self.tabTitles = tabTitles
        self.tabActivities = tabActivities
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedTabID = selectedTabID
        self.splitTabIDs = splitTabIDs
        self.onCopyPaneTitle = onCopyPaneTitle
        self.chromeMode = chromeMode
        self.isSidebarCollapsed = isSidebarCollapsed
        self.connectionState = connectionState
        self.endpointOptions = endpointOptions
        self.selectedEndpointID = selectedEndpointID
        self.webStatus = webStatus
        self.externalIDEOptions = externalIDEOptions
        self.embeddedEditorAvailable = embeddedEditorAvailable
        self.embeddedEditorTabVisible = embeddedEditorTabVisible
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

    static func tabTrackWidth(tabCount: Int) -> CGFloat {
        CGFloat(tabCount) * WarrenLayoutMetrics.tabWidth
    }

    private var tabs: [ClientTab] { presentation.listings }

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
                        ForEach(tabs) { tab in
                            let activity = tab.sessionID.flatMap { tabActivities[$0] }
                            let isSelected = !embeddedEditorSelected && selectedTabID == tab.id
                            let isSplitVisible = splitTabIDs.contains(tab.id) && !isSelected
                            WarrenDesktopTabItem(
                                tab: tab,
                                displayTitle: tabTitles[tab.id] ?? tab.title,
                                activity: activity,
                                isSelected: isSelected,
                                isSplitVisible: isSplitVisible,
                                isPinned: tab.sessionID.map(pinnedSessionIDs.contains) ?? false,
                                onSelect: { selectTab(tab.id) },
                                onClose: { onCloseTab(tab.id) },
                                onCloseOthers: { onCloseOtherTabs(tab.id) },
                                onCloseAll: onCloseAllTabs,
                                onMoveBefore: { sourceID in onMoveTab(sourceID, tab.id) },
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
                                // Keep the pending state visible while the
                                // selection itself remains free of a colored
                                // underline. The tab surface already carries
                                // the selected background and border.
                                Rectangle()
                                    .fill(pendingTabID == tab.id ? tokens.info : .clear)
                                    .frame(height: pendingTabID == tab.id ? 2 : 0)
                                    .allowsHitTesting(false)
                            }
                        }

                        if embeddedEditorTabVisible {
                            WarrenDesktopEditorTabItem(
                                isSelected: embeddedEditorSelected,
                                onSelect: onOpenEmbeddedEditor,
                                onClose: onCloseEmbeddedEditor
                            )
                        }
                    }
                    .background {
                        WarrenDesktopTabScrollFollower(
                            selectedTabID: embeddedEditorSelected
                                ? Self.editorTabID
                                : selectedTabID,
                            tabIDs: tabs.map(\.id)
                                + (embeddedEditorTabVisible ? [Self.editorTabID] : []),
                            reduceMotion: reduceMotion
                        )
                    }
                    .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
                }
                .frame(
                    maxWidth: Self.tabTrackWidth(
                        tabCount: tabs.count + (embeddedEditorTabVisible ? 1 : 0)
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

    private static let editorTabID = "warren.workspace.editor"

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

    /// The origin that reveals `selectedIndex` with the smallest movement, or
    /// the current origin when the tab is already fully visible.
    static func revealOriginX(
        selectedIndex: Int,
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
        let selectedMinX = CGFloat(selectedIndex) * tabWidth
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
    let reduceMotion: Bool

    func makeNSView(context: Context) -> WarrenDesktopTabScrollFollowerView {
        let view = WarrenDesktopTabScrollFollowerView()
        view.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabScrollFollowerView, context: Context) {
        nsView.update(
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            reduceMotion: reduceMotion
        )
    }
}

private final class WarrenDesktopTabScrollFollowerView: NSView {
    private var selectedTabID: String?
    private var tabIDs: [String] = []
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

    func update(selectedTabID: String?, tabIDs: [String], reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
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
        let originX = WarrenDesktopTabScrollPosition.revealOriginX(
            selectedIndex: selectedIndex,
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
    /// Whether a scope's Sessions earn the bar a track.
    ///
    /// As a pane control the bar has nothing to do with one pane: the chip
    /// cannot switch anywhere and repeats a title the pane header carries and
    /// the sidebar leaf highlights. Panes earn their chips once there are two to
    /// choose between.
    ///
    /// As the Session switcher — which it becomes when the tree stops listing
    /// Sessions — one entry is not redundant: it may be the only way to reach a
    /// Session that is not currently in a pane.
    static func showsTrack(
        entryCount: Int,
        embeddedEditorTabVisible: Bool,
        mode: WarrenDesktopWorkspaceDisplayMode
    ) -> Bool {
        let total = entryCount + (embeddedEditorTabVisible ? 1 : 0)
        return mode.paneBarListsEverySession ? total > 0 : total > 1
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
        includesEditorTab: Bool,
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
            embeddedEditorTabVisible: includesEditorTab,
            mode: mode
        )
        return WarrenDesktopPaneBarPresentation(
            listings: listings,
            showsTrack: drawsTrack,
            solo: drawsTrack ? nil : solo(listings)
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
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
        }
        .padding(.leading, WarrenSpacing.medium)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(minHeight: WarrenLayoutMetrics.tabBarHeight)
        .fixedSize(horizontal: true, vertical: false)
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
                    onPresentChoices: { onChromePopover(.externalIDE) }
                )
                .warrenSemanticElement(
                    id: "workspace-ide.open",
                    role: .button,
                    label: "Open in IDE",
                    value: embeddedEditorDefault
                        ? "Embedded editor default"
                        : "Choose an IDE",
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
        case .presentChoices:
            onChromePopover(.externalIDE)
        }
    }
}

enum WarrenDesktopIDEPrimaryAction: Equatable {
    case openEmbeddedEditor
    case presentChoices

    static func resolve(
        embeddedEditorDefault: Bool,
        embeddedEditorSelected: Bool
    ) -> Self {
        embeddedEditorDefault && !embeddedEditorSelected
            ? .openEmbeddedEditor
            : .presentChoices
    }
}

private struct WarrenDesktopIDEControl: View {
    let embeddedEditorSelected: Bool
    let embeddedEditorDefault: Bool
    let onOpenEmbeddedEditor: () -> Void
    let onPresentChoices: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromeButton(
            systemImage: "macwindow",
            label: "Open in IDE",
            hint: embeddedEditorDefault && !embeddedEditorSelected
                ? "Open the embedded editor"
                : "Choose an IDE",
            action: primaryAction,
            tint: embeddedEditorSelected ? tokens.info : nil,
            edgeSpaced: true
        )
    }

    private func primaryAction() {
        switch WarrenDesktopIDEPrimaryAction.resolve(
            embeddedEditorDefault: embeddedEditorDefault,
            embeddedEditorSelected: embeddedEditorSelected
        ) {
        case .openEmbeddedEditor:
            onOpenEmbeddedEditor()
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
