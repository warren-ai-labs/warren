import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopWorkspaceContent<TerminalSurface: View>: View {
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let tab: ClientTab?
    let hasProjects: Bool
    let connectionState: WarrenDesktopConnectionState
    let isMigratingRuntimeSessions: Bool
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let showsPaneHeader: Bool
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let terminalFont: TerminalFontPreference
    let wantsTerminalFocus: Bool
    let splitTree: SplitLayoutTree?
    let activePaneID: String?
    let allTabs: [ClientTab]
    let sessionLookup: (TerminalSessionID) -> WarrenDesktopSession?
    let onSelectPane: (String) -> Void
    let onClosePane: (String) -> Void
    let onMaximizePane: (String) -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void
    let onResizeSplit: ([Bool], Double) -> Void
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface

    init(
        workspace: Workspace?,
        terminalGroup: TerminalGroup?,
        tab: ClientTab?,
        hasProjects: Bool,
        connectionState: WarrenDesktopConnectionState,
        isMigratingRuntimeSessions: Bool,
        endpointCapabilities: WarrenDesktopEndpointCapabilities,
        showsPaneHeader: Bool,
        session: WarrenDesktopSession?,
        hostName: String,
        titleTemplate: TerminalDisplayTitleTemplate,
        terminalFont: TerminalFontPreference,
        wantsTerminalFocus: Bool,
        splitTree: SplitLayoutTree? = nil,
        activePaneID: String? = nil,
        allTabs: [ClientTab] = [],
        sessionLookup: @escaping (TerminalSessionID) -> WarrenDesktopSession? = { _ in nil },
        onSelectPane: @escaping (String) -> Void = { _ in },
        onClosePane: @escaping (String) -> Void = { _ in },
        onMaximizePane: @escaping (String) -> Void = { _ in },
        onSplitDrop: @escaping (String, String, SplitDropTarget) -> Void = { _, _, _ in },
        onResizeSplit: @escaping ([Bool], Double) -> Void = { _, _ in },
        onAddProject: @escaping () -> Void,
        onImportSuperset: @escaping () -> Void,
        terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.workspace = workspace
        self.terminalGroup = terminalGroup
        self.tab = tab
        self.hasProjects = hasProjects
        self.connectionState = connectionState
        self.isMigratingRuntimeSessions = isMigratingRuntimeSessions
        self.endpointCapabilities = endpointCapabilities
        self.showsPaneHeader = showsPaneHeader
        self.session = session
        self.hostName = hostName
        self.titleTemplate = titleTemplate
        self.terminalFont = terminalFont
        self.wantsTerminalFocus = wantsTerminalFocus
        self.splitTree = splitTree
        self.activePaneID = activePaneID
        self.allTabs = allTabs
        self.sessionLookup = sessionLookup
        self.onSelectPane = onSelectPane
        self.onClosePane = onClosePane
        self.onMaximizePane = onMaximizePane
        self.onSplitDrop = onSplitDrop
        self.onResizeSplit = onResizeSplit
        self.onAddProject = onAddProject
        self.onImportSuperset = onImportSuperset
        self.terminalSurface = terminalSurface
    }

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var primaryButtonFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let workspace {
            if let splitTree, splitTree.count > 1 {
                WarrenDesktopSplitTreeView(
                    tree: splitTree,
                    activePaneID: activePaneID,
                    workspace: workspace,
                    terminalGroup: nil,
                    allTabs: allTabs.isEmpty ? (tab.map { [$0] } ?? []) : allTabs,
                    sessionLookup: sessionLookup,
                    hostName: hostName,
                    titleTemplate: titleTemplate,
                    terminalFont: terminalFont,
                    wantsTerminalFocus: wantsTerminalFocus,
                    onSelectPane: onSelectPane,
                    onClosePane: onClosePane,
                    onMaximizePane: onMaximizePane,
                    onSplitDrop: onSplitDrop,
                    onResizeSplit: onResizeSplit,
                    terminalSurface: terminalSurface
                )
                // Match Ghostty's split renderer: only a structural change
                // replaces the recursive view. Ratio updates keep each
                // mounted terminal host alive during divider drags.
                .id(splitTree.structuralIdentity)
            } else {
                let resolvedTab = tab ?? ClientTab(
                    id: "workspace-empty-\(workspace.id.rawValue.uuidString)",
                    title: "No open sessions",
                    sessionID: nil,
                    kind: .shell
                )
                let paneID = activePaneID ?? (splitTree?.allPaneIDs.first ?? resolvedTab.id)
                WarrenDesktopPaneView(
                    paneID: paneID,
                    workspace: workspace,
                    terminalGroup: nil,
                    tab: resolvedTab,
                    session: session ?? resolvedTab.sessionID.flatMap(sessionLookup),
                    hostName: hostName,
                    titleTemplate: titleTemplate,
                    showsPaneHeader: showsPaneHeader,
                    isActive: true,
                    canSplit: true,
                    canClose: false,
                    canMaximize: false,
                    onFocus: { onSelectPane(paneID) },
                    onClose: { onClosePane(paneID) },
                    onMaximize: { onMaximizePane(paneID) },
                    onSplitDrop: { droppedTabID, target in
                        onSplitDrop(paneID, droppedTabID, target)
                    },
                    terminalSurface: terminalSurface(
                        WarrenDesktopTerminalContext(
                            workspace: workspace,
                            tab: resolvedTab,
                            font: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus
                        )
                    )
                )
            }
        } else if let terminalGroup {
            if let splitTree, splitTree.count > 1 {
                WarrenDesktopSplitTreeView(
                    tree: splitTree,
                    activePaneID: activePaneID,
                    workspace: nil,
                    terminalGroup: terminalGroup,
                    allTabs: allTabs.isEmpty ? (tab.map { [$0] } ?? []) : allTabs,
                    sessionLookup: sessionLookup,
                    hostName: hostName,
                    titleTemplate: titleTemplate,
                    terminalFont: terminalFont,
                    wantsTerminalFocus: wantsTerminalFocus,
                    onSelectPane: onSelectPane,
                    onClosePane: onClosePane,
                    onMaximizePane: onMaximizePane,
                    onSplitDrop: onSplitDrop,
                    onResizeSplit: onResizeSplit,
                    terminalSurface: terminalSurface
                )
                .id(splitTree.structuralIdentity)
            } else {
                let resolvedTab = tab ?? ClientTab(
                    id: "terminal-group-empty-\(terminalGroup.id.rawValue.uuidString)",
                    title: "No open sessions",
                    sessionID: nil,
                    kind: .shell
                )
                let paneID = activePaneID ?? (splitTree?.allPaneIDs.first ?? resolvedTab.id)
                WarrenDesktopPaneView(
                    paneID: paneID,
                    workspace: nil,
                    terminalGroup: terminalGroup,
                    tab: resolvedTab,
                    session: session ?? resolvedTab.sessionID.flatMap(sessionLookup),
                    hostName: hostName,
                    titleTemplate: titleTemplate,
                    showsPaneHeader: showsPaneHeader,
                    isActive: true,
                    canSplit: true,
                    canClose: false,
                    canMaximize: false,
                    onFocus: { onSelectPane(paneID) },
                    onClose: { onClosePane(paneID) },
                    onMaximize: { onMaximizePane(paneID) },
                    onSplitDrop: { droppedTabID, target in
                        onSplitDrop(paneID, droppedTabID, target)
                    },
                    terminalSurface: terminalSurface(
                        WarrenDesktopTerminalContext(
                            terminalGroup: terminalGroup,
                            tab: resolvedTab,
                            font: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus
                        )
                    )
                )
            }
        } else if workspace == nil, tab == nil,
                  connectionState == .connecting || connectionState == .reconnecting {
            connectionLoadingState(tokens: tokens)
        } else if workspace == nil, tab == nil,
                  connectionState == .disconnected || connectionState == .failed {
            connectionUnavailableState(tokens: tokens)
        } else if workspace == nil, tab == nil, !hasProjects {
            emptyWelcome(tokens: tokens)
        } else {
            VStack(spacing: WarrenSpacing.standard) {
                Text("Select a workspace")
                    .font(WarrenTypography.emptyStateTitle)
                    .foregroundStyle(tokens.mutedForeground)
                Text("Choose a workspace to open its terminals")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .opacity(0.72)
                    .multilineTextAlignment(.center)
                    .lineSpacing(WarrenSpacing.small)
            }
            .padding(.bottom, emptyStatePageOffset * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No workspace selected")
        }
    }

    private func emptyWelcome(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            Text(endpointCapabilities.canAddProject || endpointCapabilities.canImportSuperset
                ? "Open a project to begin"
                : "No projects yet")
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
            if endpointCapabilities.canAddProject {
                Button(action: onAddProject) {
                    Text("Add Project…")
                        .font(WarrenTypography.body)
                }
                .buttonStyle(WarrenPrimaryButtonStyle(isFocused: primaryButtonFocused))
                .focused($primaryButtonFocused)
                .warrenSemanticElement(
                    id: "onboarding.add-project",
                    role: .button,
                    label: "Add Project",
                    action: onAddProject
                )
            }
            if endpointCapabilities.canImportSuperset {
                Button(action: onImportSuperset) {
                    Text("Import from Superset")
                        .font(WarrenTypography.body)
                }
                .buttonStyle(WarrenSecondaryButtonStyle())
                .warrenSemanticElement(
                    id: "onboarding.import-superset",
                    role: .button,
                    label: "Import from Superset",
                    action: onImportSuperset
                )
            }
            if !endpointCapabilities.canAddProject && !endpointCapabilities.canImportSuperset {
                Text("Add a project from the remote CLI on the host machine.")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, emptyStatePageOffset * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func connectionLoadingState(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(
            connectionState,
            migratingRuntimeSessions: isMigratingRuntimeSessions
        )
        return VStack(spacing: WarrenSpacing.standard) {
            WarrenBrailleSpinner(
                size: 22,
                accessibilityLabel: presentation.label
            )
            Text(presentation.label)
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.mutedForeground)
            Text("Waiting for projects and sessions from \(hostName)")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .opacity(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.label) Waiting for projects and sessions")
    }

    private func connectionUnavailableState(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        return VStack(spacing: WarrenSpacing.standard) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .light))
            Text(presentation.label)
                .font(WarrenTypography.emptyStateTitle)
            Text("Choose another execution server or wait for this server to return")
                .font(WarrenTypography.body)
                .opacity(0.72)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(tokens.mutedForeground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.label)
    }

    /// The empty state sits inside the content area below the tab and preset
    /// bars; nudge it up by half that chrome so its visual center lands on the
    /// whole page's center instead of the terminal pane's center.
    private var emptyStatePageOffset: CGFloat {
        (WarrenLayoutMetrics.tabBarHeight + WarrenLayoutMetrics.presetBarHeight) / 2
    }

}

struct WarrenDesktopPaneView<TerminalSurface: View>: View {
    var paneID: String = ""
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let tab: ClientTab
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let showsPaneHeader: Bool
    var isActive: Bool = true
    var canSplit: Bool = true
    var canClose: Bool = false
    var canMaximize: Bool = false
    var onFocus: () -> Void = {}
    var onClose: () -> Void = {}
    var onMaximize: () -> Void = {}
    var onSplitDrop: (String, SplitDropTarget) -> Void = { _, _ in }
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            if showsPaneHeader, !displayTitle.isEmpty {
                HStack(spacing: WarrenSpacing.xs) {
                    if canClose || canMaximize {
                        Circle()
                            .fill(isActive ? tokens.info : Color.clear)
                            .frame(width: 6, height: 6)
                            .padding(.trailing, 2)
                    }
                    // Auxiliary context bar: Tab owns the primary title.
                    Text(displayTitle)
                        .font(.system(size: 11, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? tokens.foreground.opacity(0.85) : tokens.mutedForeground.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fullDisplayTitle, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(tokens.mutedForeground.opacity(0.6))
                                .frame(width: 18, height: 18)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Copy Full Title")
                        .accessibilityLabel("Copy Full Title")
                        .opacity(0.9)

                        if canMaximize {
                            Button {
                                onMaximize()
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(tokens.mutedForeground.opacity(0.6))
                                    .frame(width: 18, height: 18)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Maximize Pane (C-x 1)")
                            .accessibilityLabel("Maximize Pane")
                        }

                        if canClose {
                            Button {
                                onClose()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(tokens.mutedForeground.opacity(0.6))
                                    .frame(width: 18, height: 18)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Close Split Pane (C-x 0)")
                            .accessibilityLabel("Close Split Pane")
                        }
                    }
                }
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
                .background(isActive ? tokens.tertiaryWash.opacity(0.06) : tokens.tertiaryWash.opacity(0.02))
                .help(fullDisplayTitle)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pane context \(fullDisplayTitle)")
            }

            ZStack {
                terminalSurface
                    // AppKit-backed terminal views have a useful intrinsic grid
                    // size. Without an explicit flexible frame SwiftUI preserves
                    // that size and centers a 50-column surface inside a much
                    // larger pane. The pane owns geometry, so the renderer must
                    // accept the entire proposed content size.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(WarrenSpacing.compact)
                    .background(tokens.background)

                WarrenDesktopSplitDropOverlay(canSplit: canSplit, onDrop: onSplitDrop)

                // Keep the focused-pane treatment familiar to Ghostty's
                // split renderer: inactive surfaces remain live and readable,
                // but a subtle wash makes the keyboard target unambiguous.
                if !isActive, (canClose || canMaximize) {
                    Color.black
                        .opacity(0.08)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if canClose || canMaximize {
                    Rectangle()
                        .stroke(isActive ? tokens.info.opacity(0.4) : tokens.border.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .contentShape(Rectangle())
        // A click in the pane chrome (header, padding) selects the pane. It
        // must stay simultaneous so the click still reaches the terminal:
        // clicks inside the terminal body are AppKit's to route, and the
        // surface manager reports that focus change back as a pane selection.
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel \(tab.title)")
    }

    private var displayTitle: String {
        return titleTemplate.renderCompact(titleContext)
    }

    private var fullDisplayTitle: String {
        return titleTemplate.render(titleContext)
    }

    private var normalizedCustomTitle: String? {
        guard let customTitle = session?.customTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !customTitle.isEmpty else {
            return nil
        }
        return customTitle
    }

    private var titleContext: TerminalDisplayTitleContext {
        TerminalDisplayTitleContext(
            // A generated or manually renamed session is one placeholder
            // value. It must not replace the complete auxiliary template.
            session: normalizedCustomTitle ?? session?.title ?? tab.title,
            command: session?.runtimeProcess ?? tab.kind.displayName,
            directory: session?.workingDirectory.isEmpty == false
                ? session!.workingDirectory
                : (workspace?.path ?? terminalGroup?.home ?? ""),
            workspace: workspace?.name ?? terminalGroup?.name ?? "",
            branch: workspace?.branch ?? "",
            host: hostName,
            user: NSUserName(),
            os: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

struct WarrenDesktopEmbeddedEditorPane<Surface: View>: View {
    let workspace: Workspace
    let surface: Surface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tokens.background)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editor for \(workspace.name)")
    }
}

struct WarrenDesktopSplitTreeView<TerminalSurface: View>: View {
    let tree: SplitLayoutTree
    let activePaneID: String?
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let allTabs: [ClientTab]
    let sessionLookup: (TerminalSessionID) -> WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let terminalFont: TerminalFontPreference
    let wantsTerminalFocus: Bool
    let onSelectPane: (String) -> Void
    let onClosePane: (String) -> Void
    let onMaximizePane: (String) -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void
    let onResizeSplit: ([Bool], Double) -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    var splitPath: [Bool] = []

    var body: some View {
        let paneCount = tree.count
        switch tree {
        case .leaf(let item):
            let resolvedTab = allTabs.first { $0.id == item.tabID } ?? ClientTab(
                id: item.tabID,
                title: "Terminal",
                sessionID: nil,
                kind: .shell
            )
            let resolvedSession = resolvedTab.sessionID.flatMap(sessionLookup)
            let isActive = activePaneID == nil || activePaneID == item.id
            WarrenDesktopPaneView(
                paneID: item.id,
                workspace: workspace,
                terminalGroup: terminalGroup,
                tab: resolvedTab,
                session: resolvedSession,
                hostName: hostName,
                titleTemplate: titleTemplate,
                showsPaneHeader: true,
                isActive: isActive,
                canSplit: paneCount < SplitLayoutTree.maxPanes,
                canClose: paneCount > 1,
                canMaximize: paneCount > 1,
                onFocus: { onSelectPane(item.id) },
                onClose: { onClosePane(item.id) },
                onMaximize: { onMaximizePane(item.id) },
                onSplitDrop: { droppedTabID, target in
                    onSplitDrop(item.id, droppedTabID, target)
                },
                terminalSurface: terminalSurface(
                    WarrenDesktopTerminalContext(
                        workspace: workspace,
                        terminalGroup: terminalGroup,
                        tab: resolvedTab,
                        font: terminalFont,
                        wantsTerminalFocus: wantsTerminalFocus && isActive
                    )
                )
            )

        case .split(let axis, let rawRatio, let first, let second):
            let ratio = rawRatio.isFinite ? min(max(rawRatio, 0.05), 0.95) : 0.5
            GeometryReader { proxy in
                // The divider draws a one-point rule but reserves two points
                // of hit-target padding on either side.
                let dividerThickness: CGFloat = 5
                if axis == .horizontal {
                    let totalWidth = max(0, proxy.size.width - dividerThickness)
                    let firstWidth = totalWidth * CGFloat(ratio)
                    let secondWidth = totalWidth - firstWidth
                    let minimumRatioValue = minimumRatio(
                        first: first,
                        second: second,
                        total: totalWidth,
                        axis: .horizontal
                    )
                    let maximumRatioValue = maximumRatio(
                        first: first,
                        second: second,
                        total: totalWidth,
                        axis: .horizontal
                    )
                    HStack(spacing: 0) {
                        WarrenDesktopSplitTreeView(
                            tree: first,
                            activePaneID: activePaneID,
                            workspace: workspace,
                            terminalGroup: terminalGroup,
                            allTabs: allTabs,
                            sessionLookup: sessionLookup,
                            hostName: hostName,
                            titleTemplate: titleTemplate,
                            terminalFont: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus,
                            onSelectPane: onSelectPane,
                            onClosePane: onClosePane,
                            onMaximizePane: onMaximizePane,
                            onSplitDrop: onSplitDrop,
                            onResizeSplit: onResizeSplit,
                            terminalSurface: terminalSurface,
                            splitPath: splitPath + [false]
                        )
                        .frame(width: firstWidth)

                        WarrenDesktopSplitDivider(
                            axis: .horizontal,
                            ratio: ratio,
                            minimumRatio: minimumRatioValue,
                            maximumRatio: maximumRatioValue,
                            totalLength: totalWidth,
                            onDrag: { newRatio in
                                onResizeSplit(splitPath, clampedRatio(
                                    newRatio,
                                    minimum: minimumRatioValue,
                                    maximum: maximumRatioValue
                                ))
                            },
                            onAdjust: { delta in
                                onResizeSplit(splitPath, clampedRatio(
                                    ratio + delta,
                                    minimum: minimumRatioValue,
                                    maximum: maximumRatioValue
                                ))
                            }
                        )

                        WarrenDesktopSplitTreeView(
                            tree: second,
                            activePaneID: activePaneID,
                            workspace: workspace,
                            terminalGroup: terminalGroup,
                            allTabs: allTabs,
                            sessionLookup: sessionLookup,
                            hostName: hostName,
                            titleTemplate: titleTemplate,
                            terminalFont: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus,
                            onSelectPane: onSelectPane,
                            onClosePane: onClosePane,
                            onMaximizePane: onMaximizePane,
                            onSplitDrop: onSplitDrop,
                            onResizeSplit: onResizeSplit,
                            terminalSurface: terminalSurface,
                            splitPath: splitPath + [true]
                        )
                        .frame(width: secondWidth)
                    }
                } else {
                    let totalHeight = max(0, proxy.size.height - dividerThickness)
                    let firstHeight = totalHeight * CGFloat(ratio)
                    let secondHeight = totalHeight - firstHeight
                    let minimumRatioValue = minimumRatio(
                        first: first,
                        second: second,
                        total: totalHeight,
                        axis: .vertical
                    )
                    let maximumRatioValue = maximumRatio(
                        first: first,
                        second: second,
                        total: totalHeight,
                        axis: .vertical
                    )
                    VStack(spacing: 0) {
                        WarrenDesktopSplitTreeView(
                            tree: first,
                            activePaneID: activePaneID,
                            workspace: workspace,
                            terminalGroup: terminalGroup,
                            allTabs: allTabs,
                            sessionLookup: sessionLookup,
                            hostName: hostName,
                            titleTemplate: titleTemplate,
                            terminalFont: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus,
                            onSelectPane: onSelectPane,
                            onClosePane: onClosePane,
                            onMaximizePane: onMaximizePane,
                            onSplitDrop: onSplitDrop,
                            onResizeSplit: onResizeSplit,
                            terminalSurface: terminalSurface,
                            splitPath: splitPath + [false]
                        )
                        .frame(height: firstHeight)

                        WarrenDesktopSplitDivider(
                            axis: .vertical,
                            ratio: ratio,
                            minimumRatio: minimumRatioValue,
                            maximumRatio: maximumRatioValue,
                            totalLength: totalHeight,
                            onDrag: { newRatio in
                                onResizeSplit(splitPath, clampedRatio(
                                    newRatio,
                                    minimum: minimumRatioValue,
                                    maximum: maximumRatioValue
                                ))
                            },
                            onAdjust: { delta in
                                onResizeSplit(splitPath, clampedRatio(
                                    ratio + delta,
                                    minimum: minimumRatioValue,
                                    maximum: maximumRatioValue
                                ))
                            }
                        )

                        WarrenDesktopSplitTreeView(
                            tree: second,
                            activePaneID: activePaneID,
                            workspace: workspace,
                            terminalGroup: terminalGroup,
                            allTabs: allTabs,
                            sessionLookup: sessionLookup,
                            hostName: hostName,
                            titleTemplate: titleTemplate,
                            terminalFont: terminalFont,
                            wantsTerminalFocus: wantsTerminalFocus,
                            onSelectPane: onSelectPane,
                            onClosePane: onClosePane,
                            onMaximizePane: onMaximizePane,
                            onSplitDrop: onSplitDrop,
                            onResizeSplit: onResizeSplit,
                            terminalSurface: terminalSurface,
                            splitPath: splitPath + [true]
                        )
                        .frame(height: secondHeight)
                    }
                }
            }
        }
    }

    private func minimumRatio(
        first: SplitLayoutTree,
        second: SplitLayoutTree,
        total: CGFloat,
        axis: SplitAxis
    ) -> Double {
        guard total > 0 else { return SplitLayoutTree.minimumInteractiveRatio }
        let minimum = axis == .horizontal
            ? first.minimumPaneWidth
            : first.minimumPaneHeight
        return min(
            max(Double(minimum / total), SplitLayoutTree.minimumInteractiveRatio),
            0.5
        )
    }

    private func maximumRatio(
        first: SplitLayoutTree,
        second: SplitLayoutTree,
        total: CGFloat,
        axis: SplitAxis
    ) -> Double {
        guard total > 0 else { return SplitLayoutTree.maximumInteractiveRatio }
        let minimum = axis == .horizontal
            ? second.minimumPaneWidth
            : second.minimumPaneHeight
        return max(
            min(Double(1 - minimum / total), SplitLayoutTree.maximumInteractiveRatio),
            0.5
        )
    }

    private func clampedRatio(
        _ ratio: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        min(max(ratio, minimum), maximum)
    }
}

struct WarrenDesktopSplitDivider: View {
    let axis: SplitAxis
    let ratio: Double
    let minimumRatio: Double
    let maximumRatio: Double
    let totalLength: CGFloat
    let onDrag: (Double) -> Void
    let onAdjust: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var dragStartRatio: Double?
    @State private var snappedTarget: Double?

    private var isSnapped: Bool { snappedTarget != nil }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Rectangle()
            .fill(ruleColor(tokens))
            .frame(
                width: axis == .horizontal ? 1 : nil,
                height: axis == .vertical ? 1 : nil
            )
            // Overlays never claim layout space, so the snap guides and the
            // latch highlight cannot shift the panes they are drawn over.
            .overlay { snapGuides(tokens) }
            .overlay { latchHighlight(tokens) }
            .padding(axis == .horizontal ? .horizontal : .vertical, 2)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .accessibilityElement()
            .accessibilityLabel(
                axis == .horizontal
                    ? "Vertical split divider"
                    : "Horizontal split divider"
            )
            .accessibilityValue(Text("\(Int(ratio * 100)) percent"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onAdjust(max(0, min(0.05, maximumRatio - ratio)))
                case .decrement:
                    onAdjust(-max(0, min(0.05, ratio - minimumRatio)))
                @unknown default:
                    break
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRatio == nil {
                            dragStartRatio = ratio
                        }
                        guard let dragStartRatio, totalLength > 0 else { return }
                        let translation = axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        let pointerRatio = dragStartRatio + Double(translation / totalLength)
                        let target = SplitLayoutTree.snapTarget(
                            for: pointerRatio,
                            totalLength: totalLength,
                            minimum: minimumRatio,
                            maximum: maximumRatio
                        )
                        // The trackpad taps once as the divider latches, the
                        // same alignment feedback the system uses elsewhere, so
                        // the snap is felt as well as seen.
                        if let target, target != snappedTarget {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment,
                                performanceTime: .now
                            )
                        }
                        snappedTarget = target
                        onDrag(target ?? pointerRatio)
                    }
                    .onEnded { _ in
                        dragStartRatio = nil
                        snappedTarget = nil
                    }
            )
    }

    private func ruleColor(_ tokens: WarrenColorTokens) -> Color {
        if isSnapped { return tokens.info }
        return isHovered ? tokens.info.opacity(0.8) : tokens.border
    }

    /// Dashed lines at every reachable snap target, drawn from hover onwards so
    /// the pull points are visible before the drag starts rather than being
    /// discovered by accident. `ratio` is the divider's own position, so the
    /// offset to a target shrinks to zero exactly when the divider latches.
    @ViewBuilder
    private func snapGuides(_ tokens: WarrenColorTokens) -> some View {
        if isHovered || dragStartRatio != nil, totalLength > 0 {
            ZStack {
                ForEach(reachableSnapRatios, id: \.self) { target in
                    let offset = CGFloat(target - ratio) * totalLength
                    WarrenDesktopSplitSnapGuide(axis: axis)
                        .stroke(
                            tokens.info.opacity(snappedTarget == target ? 0.9 : 0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .offset(
                            x: axis == .horizontal ? offset : 0,
                            y: axis == .vertical ? offset : 0
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// A wider glow while latched. Without it the divider would look identical
    /// whether it is snapped or merely near the target, and the pointer drifting
    /// inside the pull radius would give no feedback at all.
    @ViewBuilder
    private func latchHighlight(_ tokens: WarrenColorTokens) -> some View {
        if isSnapped {
            Rectangle()
                .fill(tokens.info.opacity(0.35))
                .frame(
                    width: axis == .horizontal ? 5 : nil,
                    height: axis == .vertical ? 5 : nil
                )
                .allowsHitTesting(false)
        }
    }

    private var reachableSnapRatios: [Double] {
        SplitLayoutTree.snapRatios.filter { $0 >= minimumRatio && $0 <= maximumRatio }
    }
}

/// A single line across the divider's cross axis, used for the snap guides.
/// `Rectangle` cannot carry a dash pattern, and a shape keeps the guide aligned
/// with the divider's own 1-point rule.
struct WarrenDesktopSplitSnapGuide: Shape {
    let axis: SplitAxis

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if axis == .horizontal {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return path
    }
}
