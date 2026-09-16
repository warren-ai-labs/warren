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
            let resolvedTab = tab ?? ClientTab(
                id: "workspace-empty-\(workspace.id.rawValue.uuidString)",
                title: "No open sessions",
                sessionID: nil,
                kind: .shell
            )
            WarrenDesktopSplitTreeView(
                tree: splitTree ?? .leaf(
                    SplitPaneItem(
                        id: activePaneID ?? resolvedTab.id,
                        tabID: resolvedTab.id
                    )
                ),
                activePaneID: activePaneID,
                workspace: workspace,
                terminalGroup: nil,
                allTabs: allTabs,
                sessionLookup: sessionLookup,
                hostName: hostName,
                titleTemplate: titleTemplate,
                terminalFont: terminalFont,
                wantsTerminalFocus: wantsTerminalFocus,
                onSelectPane: onSelectPane,
                onClosePane: onClosePane,
                onMaximizePane: onMaximizePane,
                onResizeSplit: onResizeSplit,
                terminalSurface: terminalSurface,
                lonePaneChrome: WarrenDesktopSplitTreeView<TerminalSurface>.LonePaneChrome(
                    showsHeader: showsPaneHeader,
                    canClose: resolvedTab.sessionID != nil,
                    emptyTab: resolvedTab,
                    session: session
                )
            )
        } else if let terminalGroup {
            let resolvedTab = tab ?? ClientTab(
                id: "terminal-group-empty-\(terminalGroup.id.rawValue.uuidString)",
                title: "No open sessions",
                sessionID: nil,
                kind: .shell
            )
            WarrenDesktopSplitTreeView(
                tree: splitTree ?? .leaf(
                    SplitPaneItem(
                        id: activePaneID ?? resolvedTab.id,
                        tabID: resolvedTab.id
                    )
                ),
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
                onResizeSplit: onResizeSplit,
                terminalSurface: terminalSurface,
                lonePaneChrome: WarrenDesktopSplitTreeView<TerminalSurface>.LonePaneChrome(
                    showsHeader: showsPaneHeader,
                    canClose: resolvedTab.sessionID != nil,
                    emptyTab: resolvedTab,
                    session: session
                )
            )
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
    /// True when this pane shares the view with others.
    ///
    /// The border, the inactive wash, and the focus dot all answer "which of
    /// these panes am I typing into", so they only belong in a split. A lone
    /// pane still offers close, which is why this is separate from `canClose`.
    var isSplit: Bool = false
    var onFocus: () -> Void = {}
    var onClose: () -> Void = {}
    var onMaximize: () -> Void = {}
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            // The header is chrome, so its presence must not depend on live
            // metadata. Gating it on a rendered title that can transiently be
            // empty changed the pane's height by 28 pt, which resized the PTY
            // and made a full-screen TUI repaint end to end — the "replay"
            // seen while a Session streamed output. The fallback label below
            // keeps the height and the bar itself stable.
            if showsPaneHeader {
                HStack(spacing: WarrenSpacing.xs) {
                    // The focus dot answers "which of these panes takes my
                    // keys", so it only appears once there is more than one.
                    if isSplit {
                        Circle()
                            .fill(isActive ? tokens.info : Color.clear)
                            .frame(width: 6, height: 6)
                            .padding(.trailing, 2)
                    }
                    // With a single pane the bar above shows no chip, so this is
                    // the primary title and has to name the provider itself.
                    if let providerPreset {
                        WarrenDesktopPresetIcon(preset: providerPreset)
                            .frame(width: 12, height: 12)
                            .opacity(isActive ? 0.9 : 0.55)
                            .accessibilityHidden(true)
                    }
                    Text(paneHeaderTitle)
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
                            // Taking the pane off screen; the Session keeps
                            // running and stays in the sidebar tree.
                            .help("Close Pane (C-x 0)")
                            .accessibilityLabel("Close Pane")
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

                WarrenDesktopSplitDropOverlay(paneID: paneID, canSplit: canSplit)

                // Keep the focused-pane treatment familiar to Ghostty's
                // split renderer: inactive surfaces remain live and readable,
                // but a subtle wash makes the keyboard target unambiguous.
                if !isActive, isSplit {
                    Color.black
                        .opacity(0.08)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isSplit {
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

    /// The title the pane header draws.
    ///
    /// A rendered title can be empty for a moment while metadata for the
    /// Session is being rewritten. The header occupies a fixed height, so it
    /// falls back to a stable label instead of disappearing: chrome that comes
    /// and goes with live data moves every pane in the split.
    private var paneHeaderTitle: String {
        Self.stablePaneHeaderTitle(
            rendered: displayTitle,
            sessionTitle: session?.displayTitle ?? tab.title,
            kindName: (session?.kind ?? tab.kind).displayName
        )
    }

    /// Resolves a pane header label that is never empty.
    ///
    /// Exposed so the invariant is testable: the header's height must not
    /// depend on whether live metadata currently renders to something.
    static func stablePaneHeaderTitle(
        rendered: String,
        sessionTitle: String,
        kindName: String
    ) -> String {
        for candidate in [rendered, sessionTitle, kindName] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return kindName
    }

    /// The catalog entry for the agent bound to this pane's Session, read from
    /// the binding rather than from what Warren launched.
    private var providerPreset: WarrenDesktopSessionPreset? {
        guard let kind = session?.presentedKind else { return nil }
        return WarrenDesktopSessionPreset.builtIns.first { $0.request.kind == kind }
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
        let command = WarrenDesktopTabTitle.resolvedCommand(
            kind: session?.kind ?? tab.kind,
            process: session?.runtimeProcess ?? "",
            commandLine: session?.runtimeCommandLine ?? ""
        )
        let directory = session?.workingDirectory.isEmpty == false
            ? session!.workingDirectory
            : (workspace?.path ?? terminalGroup?.home ?? "")
        // A generated or manually renamed session is one placeholder value.
        // The generated default repeats the kind the icon already shows, so it
        // is suppressed whenever the directory or command carries the label.
        let generatedTitle = session?.title ?? tab.title
        return TerminalDisplayTitleContext(
            session: normalizedCustomTitle ?? ((directory.isEmpty && command.isEmpty) ? generatedTitle : ""),
            command: command,
            directory: directory,
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
    /// Chrome for a layout that holds a single pane.
    ///
    /// A lone pane is not a split: the content may hide its header because the
    /// top chrome row already carries the title, and its header owns the close
    /// control even when it is the only pane. It is drawn through this same view
    /// so that nothing about the terminal changes when a second pane arrives —
    /// the two used to be different views, and a split therefore re-created the
    /// pane that was already on screen, which reads as the terminal replaying
    /// itself.
    struct LonePaneChrome {
        let showsHeader: Bool
        let canClose: Bool
        let emptyTab: ClientTab
        let session: WarrenDesktopSession?
    }

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
    let onResizeSplit: ([Bool], Double) -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    var lonePaneChrome: LonePaneChrome? = nil

    var body: some View {
        GeometryReader { proxy in
            let placement = tree.placement(in: proxy.size)
            // Every pane is a sibling here rather than a node in a recursive
            // tree. The shape of the layout therefore changes which frames the
            // panes have, and never which views they are: adding a pane leaves
            // the terminals that were already on screen mounted, so nothing
            // flashes and no pane that did not move is re-attached.
            ZStack(alignment: .topLeading) {
                ForEach(placement.panes) { pane in
                    paneView(pane)
                        .frame(width: pane.frame.width, height: pane.frame.height)
                        .offset(x: pane.frame.minX, y: pane.frame.minY)
                }

                ForEach(placement.dividers) { divider in
                    WarrenDesktopSplitDivider(
                        axis: divider.axis,
                        ratio: divider.ratio,
                        minimumRatio: divider.minimumRatio,
                        maximumRatio: divider.maximumRatio,
                        totalLength: divider.totalLength,
                        onDrag: { ratio in
                            onResizeSplit(
                                divider.path,
                                clampedRatio(
                                    ratio,
                                    minimum: divider.minimumRatio,
                                    maximum: divider.maximumRatio
                                )
                            )
                        },
                        onAdjust: { delta in
                            onResizeSplit(
                                divider.path,
                                clampedRatio(
                                    divider.ratio + delta,
                                    minimum: divider.minimumRatio,
                                    maximum: divider.maximumRatio
                                )
                            )
                        }
                    )
                    .frame(width: divider.frame.width, height: divider.frame.height)
                    .offset(x: divider.frame.minX, y: divider.frame.minY)
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
    }

    private func paneView(_ pane: SplitLayoutPlacement.Pane) -> some View {
        let paneCount = tree.count
        let chrome = paneCount == 1 ? lonePaneChrome : nil
        let resolvedTab = allTabs.first { $0.id == pane.item.tabID }
            ?? chrome?.emptyTab
            ?? ClientTab(
                id: pane.item.tabID,
                title: "Terminal",
                sessionID: nil,
                kind: .shell
            )
        let resolvedSession = chrome?.session ?? resolvedTab.sessionID.flatMap(sessionLookup)
        let isActive = chrome != nil || activePaneID == nil || activePaneID == pane.id
        return WarrenDesktopPaneView(
            paneID: pane.id,
            workspace: workspace,
            terminalGroup: terminalGroup,
            tab: resolvedTab,
            session: resolvedSession,
            hostName: hostName,
            titleTemplate: titleTemplate,
            showsPaneHeader: chrome?.showsHeader ?? true,
            isActive: isActive,
            canSplit: chrome != nil || paneCount < SplitLayoutTree.maxPanes,
            canClose: chrome?.canClose ?? (paneCount > 1),
            canMaximize: chrome == nil && paneCount > 1,
            isSplit: chrome == nil && paneCount > 1,
            onFocus: { onSelectPane(pane.id) },
            onClose: { onClosePane(pane.id) },
            onMaximize: { onMaximizePane(pane.id) },
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
                // The divider is repositioned by the ratio it publishes, so a
                // local coordinate space would move with it and feed its own
                // displacement back into the next translation. Measuring the
                // drag against the window keeps it tracking the pointer.
                DragGesture(coordinateSpace: .global)
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
