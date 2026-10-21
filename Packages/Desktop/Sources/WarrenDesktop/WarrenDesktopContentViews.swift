import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopWorkspaceContent<TerminalSurface: View>: View {
    let workspace: Workspace?
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
    let zoomedPaneID: String?
    let foldedPaneID: String?
    let allTabs: [ClientTab]
    let sessionLookup: (TerminalSessionID) -> WarrenDesktopSession?
    let onSelectPane: (String) -> Void
    let onClosePane: (String) -> Void
    let onMaximizePane: (String) -> Void
    /// Shows every pane again while one is zoomed.
    let onRestoreLayout: () -> Void
    let onResizeSplit: ([Bool], Double) -> Void
    let onFoldPane: (String, [Bool], Double?) -> Void
    let onUnfoldPane: (String) -> Void
    let onRetryConnection: (() -> Void)?
    let onSwitchHost: (() -> Void)?
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface

    init(
        workspace: Workspace?,
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
        zoomedPaneID: String? = nil,
        foldedPaneID: String? = nil,
        allTabs: [ClientTab] = [],
        sessionLookup: @escaping (TerminalSessionID) -> WarrenDesktopSession? = { _ in nil },
        onSelectPane: @escaping (String) -> Void = { _ in },
        onClosePane: @escaping (String) -> Void = { _ in },
        onMaximizePane: @escaping (String) -> Void = { _ in },
        onRestoreLayout: @escaping () -> Void = {},
        onResizeSplit: @escaping ([Bool], Double) -> Void = { _, _ in },
        onFoldPane: @escaping (String, [Bool], Double?) -> Void = { _, _, _ in },
        onUnfoldPane: @escaping (String) -> Void = { _ in },
        onRetryConnection: (() -> Void)? = nil,
        onSwitchHost: (() -> Void)? = nil,
        onAddProject: @escaping () -> Void,
        onImportSuperset: @escaping () -> Void,
        terminalSurface: @escaping @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    ) {
        self.workspace = workspace
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
        self.zoomedPaneID = zoomedPaneID
        self.foldedPaneID = foldedPaneID
        self.allTabs = allTabs
        self.sessionLookup = sessionLookup
        self.onSelectPane = onSelectPane
        self.onClosePane = onClosePane
        self.onMaximizePane = onMaximizePane
        self.onRestoreLayout = onRestoreLayout
        self.onResizeSplit = onResizeSplit
        self.onFoldPane = onFoldPane
        self.onUnfoldPane = onUnfoldPane
        self.onRetryConnection = onRetryConnection
        self.onSwitchHost = onSwitchHost
        self.onAddProject = onAddProject
        self.onImportSuperset = onImportSuperset
        self.terminalSurface = terminalSurface
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var primaryButtonFocused: Bool

    /// Still waiting on the Host with nothing else to show.
    ///
    /// The launch holds this card's ground and then crossfades into whatever
    /// the Host answers with, so a connect that beats the reveal delay never
    /// draws a loading state at all.
    private var holdsForHost: Bool {
        workspace == nil && tab == nil && connectionState.isSettling
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        content(tokens: tokens)
            .animation(
                WarrenDesktopLoadingReveal.animation(reduceMotion: reduceMotion),
                value: holdsForHost
            )
    }

    @ViewBuilder
    private func content(tokens: WarrenColorTokens) -> some View {
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
                zoomedPaneID: zoomedPaneID,
                foldedPaneID: foldedPaneID,
                workspace: workspace,
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
                onFoldPane: onFoldPane,
                onUnfoldPane: onUnfoldPane,
                terminalSurface: terminalSurface,
                onRestoreLayout: onRestoreLayout,
                lonePaneChrome: WarrenDesktopSplitTreeView<TerminalSurface>.LonePaneChrome(
                    showsHeader: showsPaneHeader,
                    canClose: resolvedTab.sessionID != nil,
                    emptyTab: resolvedTab,
                    session: session
                )
            )
            .transition(.opacity)
        } else if holdsForHost {
            WarrenDesktopConnectingStage(
                title: Self.connectingTitle(
                    hostName: hostName,
                    isReconnecting: connectionState == .reconnecting,
                    migratingRuntimeSessions: isMigratingRuntimeSessions
                )
            )
            .warrenCard()
            .transition(.opacity)
        } else if workspace == nil, tab == nil,
                  connectionState == .disconnected || connectionState == .failed {
            connectionUnavailableState(tokens: tokens)
                .warrenCard()
                .transition(.opacity)
        } else if workspace == nil, tab == nil, !hasProjects {
            emptyWelcome(tokens: tokens)
                .warrenCard()
                .transition(.opacity)
        } else {
            WarrenDesktopEmptyStage(
                mark: .symbol("sidebar.left"),
                title: "Select a workspace",
                message: "Pick a Workspace in the sidebar to open its Sessions here."
            )
            .warrenCard()
            .accessibilityLabel("No workspace selected")
            .transition(.opacity)
        }
    }

    /// The one line the launch state reads.
    ///
    /// It names the Host rather than repeating the sidebar chip's verb: the
    /// chip already says the connection is being made, so this says to what.
    static func connectingTitle(
        hostName: String,
        isReconnecting: Bool,
        migratingRuntimeSessions: Bool
    ) -> String {
        if migratingRuntimeSessions {
            return "Migrating runtime sessions…"
        }
        return isReconnecting
            ? "Reconnecting to \(hostName)"
            : "Connecting to \(hostName)"
    }

    private func emptyWelcome(tokens: WarrenColorTokens) -> some View {
        let canStart = endpointCapabilities.canAddProject || endpointCapabilities.canImportSuperset
        return WarrenDesktopEmptyStage(
            title: canStart ? "Open a project to begin" : "No projects yet",
            message: canStart
                ? "Add a Git repository to start working in it."
                : "Add a project from the remote CLI on \(hostName)."
        ) {
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
                // The second way in stays plain text, so the card has one
                // control that asks to be pressed and one that does not.
                Button(action: onImportSuperset) {
                    Text("Import from Superset")
                        .font(WarrenTypography.body)
                        // Plain text still needs the height of the button
                        // beside it, so the two share a baseline and a hit
                        // target of the same size.
                        .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .warrenSemanticElement(
                    id: "onboarding.import-superset",
                    role: .button,
                    label: "Import from Superset",
                    action: onImportSuperset
                )
            }
        }
    }

    private func connectionUnavailableState(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        // The way out has to be here: with the sidebar collapsed this card
        // is the only thing on screen. Other Hosts live at the sidebar's
        // foot, which is what the message points to.
        return WarrenDesktopEmptyStage(
            mark: .warning("bolt.horizontal.circle"),
            title: presentation.label,
            message: "Retry the connection, switch to another Host from the list at the bottom of the sidebar, "
                + "or wait for \(hostName) to return."
        ) {
            if let onRetryConnection {
                Button(action: onRetryConnection) {
                    Text("Retry Connection")
                        .font(WarrenTypography.body)
                }
                .buttonStyle(WarrenPrimaryButtonStyle(isFocused: primaryButtonFocused))
                .focused($primaryButtonFocused)
                .warrenSemanticElement(
                    id: "connection.retry",
                    role: .button,
                    label: "Retry Connection",
                    action: onRetryConnection
                )
            }
            if let onSwitchHost {
                Button(action: onSwitchHost) {
                    Text("Switch Host…")
                        .font(WarrenTypography.body)
                }
                .buttonStyle(WarrenSecondaryButtonStyle())
                .warrenSemanticElement(
                    id: "connection.switch-host",
                    role: .button,
                    label: "Switch Host",
                    action: onSwitchHost
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.label)
    }

}

struct WarrenDesktopPaneView<TerminalSurface: View>: View {
    var paneID: String = ""
    let workspace: Workspace?
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
    /// True when this pane is the one actually receiving keystrokes.
    ///
    /// Separate from `isActive`, which says this is the selected pane. The two
    /// part company whenever the keyboard is somewhere else in the window — the
    /// embedded editor, the command palette, Settings — and the focus mark has
    /// to follow the keys rather than the selection, or it claims the terminal
    /// is taking input that is going into a document.
    var isKeyboardFocused: Bool = true
    /// True while this pane is shown alone over the others, which stay
    /// mounted but hidden beneath it.
    var isZoomed: Bool = false
    /// How many panes the layout holds, for the zoomed pane's "1 / N" mark.
    var paneCount: Int = 1
    var onFocus: () -> Void = {}
    var onClose: () -> Void = {}
    var onMaximize: () -> Void = {}
    var onRestoreLayout: () -> Void = {}
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    private var splitChordsEnabled = false
    @State private var isHeaderHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(spacing: 0) {
            // The header is chrome, so its presence must not depend on live
            // metadata. Gating it on a rendered title that can transiently be
            // empty changed the pane's height, which resized the PTY and made
            // a full-screen TUI repaint end to end. The fallback label below
            // keeps the height and the bar itself stable.
            if showsPaneHeader {
                paneHeader(tokens: tokens)
            }

            ZStack {
                terminalSurface
                    // AppKit-backed terminal views have a useful intrinsic grid
                    // size. Without an explicit flexible frame SwiftUI preserves
                    // that size and centers a 50-column surface inside a much
                    // larger pane. The pane owns geometry, so the renderer must
                    // accept the entire proposed content size.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .padding(.bottom, WarrenSpacing.compact)
                    .padding(.top, showsPaneHeader ? 0 : WarrenSpacing.compact)
                    .background(tokens.workbenchCardFill)

                WarrenDesktopSplitDropOverlay(paneID: paneID, canSplit: canSplit)

                // Inactive surfaces stay live and readable; a subtle wash and
                // the dimmer card border make the keyboard target unambiguous.
                if !isActive, isSplit {
                    tokens.terminalInactiveWash
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Every pane is its own card on the window backdrop. The one taking
        // keystrokes gets the brighter border; a lone pane is always it.
        .warrenCard(isFocused: isActive && isKeyboardFocused)
        .contentShape(Rectangle())
        // A click in the pane chrome (header, padding) selects the pane. It
        // must stay simultaneous so the click still reaches the terminal:
        // clicks inside the terminal body are AppKit's to route, and the
        // surface manager reports that focus change back as a pane selection.
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel \(tab.title)")
    }

    /// The card's title row: the Session's kind badge, then what it is working
    /// on. The badge already carries the kind's mark, so naming the kind again
    /// in text read as a second icon. Its controls appear on hover.
    private func paneHeader(tokens: WarrenColorTokens) -> some View {
        let icon = session.map(WarrenDesktopAppIcon.resolve) ?? WarrenDesktopAppIcon(kind: tab.kind)
        return HStack(spacing: WarrenSpacing.compact) {
            // Every pane's header reads at full strength; only the card's
            // border says which pane takes keystrokes.
            WarrenDesktopSessionKindBadge(icon: icon, size: 16)
            Text(paneHeaderTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.foreground.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if isZoomed {
                // Stays visible without hover: the other panes are hidden,
                // and nothing else on the card says so.
                Text("1 / \(paneCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tokens.treeQuietText)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(
                        tokens.foreground.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .warrenTooltip("Showing 1 of \(paneCount) panes")
                    .accessibilityLabel("Showing 1 of \(paneCount) panes")
            }
            HStack(spacing: 2) {
                paneHeaderButton(
                    systemImage: "doc.on.doc",
                    label: "Copy Full Title",
                    tokens: tokens
                ) {
                    WarrenCopyFeedback.shared.copy(fullDisplayTitle, announcing: "Copied title")
                }
                if isZoomed {
                    paneHeaderButton(
                        systemImage: "arrow.down.right.and.arrow.up.left",
                        label: "Restore Layout",
                        tokens: tokens,
                        action: onRestoreLayout
                    )
                } else if canMaximize {
                    paneHeaderButton(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        label: "Maximize Pane",
                        shortcut: Self.shortcut("⇧⌘↩", chord: "C-x 1", chordsEnabled: splitChordsEnabled),
                        tokens: tokens,
                        action: onMaximize
                    )
                }
                if canClose {
                    // Taking the pane off screen; the Session keeps running and
                    // stays in the sidebar tree.
                    paneHeaderButton(
                        systemImage: "xmark",
                        label: "Close Pane",
                        shortcut: Self.shortcut("⌘W", chord: "C-x 0", chordsEnabled: splitChordsEnabled),
                        tokens: tokens,
                        action: onClose
                    )
                }
            }
            .opacity(isHeaderHovered ? 1 : 0)
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
        .contentShape(.rect)
        .onHover { isHeaderHovered = $0 }
        .help(fullDisplayTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane context \(fullDisplayTitle)")
    }

    /// The shortcut a header button's tooltip names: the View menu's, which
    /// always works, and the C-x chord only while the opt-in chords are on.
    static func shortcut(_ menu: String, chord: String, chordsEnabled: Bool) -> String {
        chordsEnabled ? "\(menu)  \(chord)" : menu
    }

    private func paneHeaderButton(
        systemImage: String,
        label: String,
        shortcut: String? = nil,
        tokens: WarrenColorTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .warrenTooltip(label, shortcut: shortcut)
        .accessibilityLabel(label)
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
    ///
    /// A pane with a Session names it the way its sidebar row does, so the
    /// header and the row read as the same thing. The terminal's own title,
    /// with its path and branch, stays in the hover help and the copy button.
    private var paneHeaderTitle: String {
        Self.stablePaneHeaderTitle(
            rendered: session.map {
                WarrenDesktopTabTitle.sessionTitle(for: $0, worktreeRoot: workspace?.path ?? "").title
            } ?? displayTitle,
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
            : (workspace?.path ?? "")
        // A generated or manually renamed session is one placeholder value.
        // The generated default repeats the kind the icon already shows, so it
        // is suppressed whenever the directory or command carries the label.
        let generatedTitle = session?.title ?? tab.title
        return TerminalDisplayTitleContext(
            session: normalizedCustomTitle ?? ((directory.isEmpty && command.isEmpty) ? generatedTitle : ""),
            command: command,
            directory: directory,
            workspace: workspace?.name ?? "",
            branch: workspace?.branch ?? "",
            host: hostName,
            user: NSUserName(),
            os: ProcessInfo.processInfo.operatingSystemVersionString
        )
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
    /// The pane shown alone over the others, which stay mounted beneath it.
    var zoomedPaneID: String? = nil
    /// The pane drawn as a rail. Its terminal stays mounted, parked beneath
    /// its sibling, like the panes a zoom hides.
    var foldedPaneID: String? = nil
    let workspace: Workspace?
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
    /// Folds a pane into a rail: the pane, its divider's path, and the ratio
    /// the drag started from.
    var onFoldPane: (String, [Bool], Double?) -> Void = { _, _, _ in }
    /// Brings a folded pane back.
    var onUnfoldPane: (String) -> Void = { _ in }
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface
    /// Ends a zoom, showing every pane again.
    var onRestoreLayout: () -> Void = {}
    var lonePaneChrome: LonePaneChrome? = nil

    @Environment(\.warrenPaneGroupHover) private var groupHover

    var body: some View {
        GeometryReader { proxy in
            let placement = tree.placement(
                in: proxy.size,
                dividerThickness: WarrenLayoutMetrics.cardGap,
                foldedPaneID: foldedPaneID
            )
            // Every pane is a sibling here rather than a node in a recursive
            // tree. The shape of the layout therefore changes which frames the
            // panes have, and never which views they are: adding a pane leaves
            // the terminals that were already on screen mounted, so nothing
            // flashes and no pane that did not move is re-attached.
            //
            // The view identity follows the Session rather than the pane id.
            // Adopting the Host's arrangement can replace a pane's local
            // fallback identity with the one the Host assigned, and keying the
            // view by the slot would re-create the terminal for that change
            // alone. Control paths still address the pane by `pane.id`.
            ZStack(alignment: .topLeading) {
                ForEach(placement.panes, id: \.renderID) { pane in
                    // A zoomed pane takes the whole area. The others keep
                    // their frames and their terminals, hidden under it, so
                    // restoring the layout re-attaches nothing.
                    //
                    // A folded pane is parked the same way: its terminal stays
                    // mounted at the frame it would have unfolded, hidden
                    // beneath its sibling, and only its rail is drawn. The
                    // surface is never squeezed to the rail's width, so the
                    // Session is not resized for a fold and comes back as it
                    // was.
                    let isZoomed = pane.id == zoomedPaneID
                    let isParked = pane.isFolded && !isZoomed
                    let isHidden = (zoomedPaneID != nil && !isZoomed) || isParked
                    let frame = isZoomed
                        ? CGRect(origin: .zero, size: proxy.size)
                        : (pane.parkedFrame ?? pane.frame)
                    paneView(pane, isParked: isParked)
                        .warrenPanePeek(tabID: pane.item.tabID, hover: tree.count > 1 ? groupHover : nil)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(isHidden ? 0 : 1)
                        .allowsHitTesting(!isHidden)
                        .accessibilityHidden(isHidden)
                        .zIndex(isZoomed ? 1 : (isParked ? -1 : 0))
                }

                ForEach(zoomedPaneID == nil ? placement.panes.filter(\.isFolded) : [], id: \.renderID) { pane in
                    foldedRail(pane, in: placement)
                        .frame(width: pane.frame.width, height: pane.frame.height)
                        .offset(x: pane.frame.minX, y: pane.frame.minY)
                }

                // A divider beside a rail has nothing to move: the rail is the
                // way back, and it restores the ratio the divider last held.
                ForEach(zoomedPaneID == nil ? placement.dividers.filter { $0.foldedSide == nil } : []) { divider in
                    WarrenDesktopSplitDivider(
                        axis: divider.axis,
                        ratio: divider.ratio,
                        minimumRatio: divider.minimumRatio,
                        maximumRatio: divider.maximumRatio,
                        totalLength: divider.totalLength,
                        foldableSides: divider.foldableSides,
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
                        },
                        onFold: { side, restoreRatio in
                            guard let paneID = divider.leafID(on: side) else { return }
                            onFoldPane(paneID, divider.path, restoreRatio)
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

    private func resolvedTab(
        for pane: SplitLayoutPlacement.Pane,
        chrome: LonePaneChrome?
    ) -> ClientTab {
        allTabs.first { $0.id == pane.item.tabID }
            ?? chrome?.emptyTab
            ?? ClientTab(
                id: pane.item.tabID,
                title: "Terminal",
                sessionID: nil,
                kind: .shell
            )
    }

    /// The rail a folded pane leaves behind. It names the pane the way its
    /// header does, and a click brings the pane back.
    private func foldedRail(
        _ pane: SplitLayoutPlacement.Pane,
        in placement: SplitLayoutPlacement
    ) -> some View {
        let tab = resolvedTab(for: pane, chrome: nil)
        let session = tab.sessionID.flatMap(sessionLookup)
        let icon = session.map(WarrenDesktopAppIcon.resolve) ?? WarrenDesktopAppIcon(kind: tab.kind)
        let title = WarrenDesktopPaneView<TerminalSurface>.stablePaneHeaderTitle(
            rendered: session.map {
                WarrenDesktopTabTitle.sessionTitle(for: $0, worktreeRoot: workspace?.path ?? "").title
            } ?? tab.title,
            sessionTitle: session?.displayTitle ?? tab.title,
            kindName: (session?.kind ?? tab.kind).displayName
        )
        // The divider beside the rail says which way the split runs: a column
        // folds into a standing rail, a row into a header-high strip.
        let axis = placement.dividers.first { divider in
            divider.foldedSide.flatMap { divider.leafID(on: $0) } == pane.id
        }?.axis ?? .horizontal
        return WarrenDesktopFoldedPaneRail(
            axis: axis,
            icon: icon,
            title: title,
            onRestore: { onUnfoldPane(pane.id) }
        )
    }

    private func paneView(_ pane: SplitLayoutPlacement.Pane, isParked: Bool = false) -> some View {
        let paneCount = tree.count
        let chrome = paneCount == 1 ? lonePaneChrome : nil
        let resolvedTab = resolvedTab(for: pane, chrome: chrome)
        let resolvedSession = chrome?.session ?? resolvedTab.sessionID.flatMap(sessionLookup)
        // A parked pane never claims the keyboard: its terminal is hidden.
        let isActive = !isParked
            && (chrome != nil || activePaneID == nil || activePaneID == pane.id)
        return WarrenDesktopPaneView(
            paneID: pane.id,
            workspace: workspace,
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
            isKeyboardFocused: wantsTerminalFocus,
            isZoomed: paneCount > 1 && pane.id == zoomedPaneID,
            paneCount: paneCount,
            onFocus: { onSelectPane(pane.id) },
            onClose: { onClosePane(pane.id) },
            onMaximize: { onMaximizePane(pane.id) },
            onRestoreLayout: onRestoreLayout,
            terminalSurface: terminalSurface(
                WarrenDesktopTerminalContext(
                    workspace: workspace,
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
    /// The sides whose pane a pull past the minimum may fold.
    var foldableSides: Set<SplitPaneSide> = []
    let onDrag: (Double) -> Void
    let onAdjust: (Double) -> Void
    /// Folds the pane on a side; the ratio is the one the drag started from,
    /// which the rail restores.
    var onFold: (SplitPaneSide, Double?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var dragStartRatio: Double?
    @State private var snappedTarget: Double?
    /// The drag's pull past a pane's minimum, while the divider holds there.
    @State private var pull: SplitDividerPull?

    private var isSnapped: Bool { snappedTarget != nil }

    /// True while letting go would fold the held pane.
    private var releaseFolds: Bool {
        SplitLayoutTree.foldSide(releasing: pull, foldable: foldableSides) != nil
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Rectangle()
            .fill(ruleColor(tokens))
            .frame(
                width: axis == .horizontal ? 1 : nil,
                height: axis == .vertical ? 1 : nil
            )
            // Overlays never claim layout space, so the snap guides, the latch
            // highlight, and the pull indicator cannot shift the panes they are
            // drawn over.
            .overlay { snapGuides(tokens) }
            .overlay { latchHighlight(tokens) }
            .overlay { pullIndicator(tokens) }
            .padding(axis == .horizontal ? .horizontal : .vertical, 2)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            // The pointer says the divider is draggable, the same as the
            // editor split and the sidebar edge. A horizontal axis splits
            // left/right, so the edge moves sideways.
            .warrenCursor(axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
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
            .accessibilityAction(named: Text(foldActionName(.first))) {
                if foldableSides.contains(.first) { onFold(.first, nil) }
            }
            .accessibilityAction(named: Text(foldActionName(.second))) {
                if foldableSides.contains(.second) { onFold(.second, nil) }
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
                        guard let pointerRatio = pointerRatio(for: value) else { return }
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
                        let wasFolding = releaseFolds
                        pull = SplitLayoutTree.dividerPull(
                            for: pointerRatio,
                            totalLength: totalLength,
                            minimum: minimumRatio,
                            maximum: maximumRatio
                        )
                        // Crossing into the fold is a change of outcome, not of
                        // position, so it taps at a different level.
                        if releaseFolds, !wasFolding {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .levelChange,
                                performanceTime: .now
                            )
                        }
                        // The caller clamps, so past the minimum the pane holds
                        // there while the indicator shows the pull.
                        onDrag(target ?? pointerRatio)
                    }
                    .onEnded { value in
                        let startRatio = dragStartRatio
                        let finalPull = pointerRatio(for: value).flatMap {
                            SplitLayoutTree.dividerPull(
                                for: $0,
                                totalLength: totalLength,
                                minimum: minimumRatio,
                                maximum: maximumRatio
                            )
                        }
                        dragStartRatio = nil
                        snappedTarget = nil
                        // Only the indicator animates as it lets go. The panes
                        // next to it are terminals, whose geometry switches
                        // without animation.
                        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                            pull = nil
                        }
                        if let side = SplitLayoutTree.foldSide(releasing: finalPull, foldable: foldableSides) {
                            onFold(side, startRatio)
                        }
                    }
            )
    }

    /// The ratio under the pointer, unclamped, for a drag that started at
    /// `dragStartRatio`.
    private func pointerRatio(for value: DragGesture.Value) -> Double? {
        guard let dragStartRatio, totalLength > 0 else { return nil }
        let translation = axis == .horizontal
            ? value.translation.width
            : value.translation.height
        return dragStartRatio + Double(translation / totalLength)
    }

    private func foldActionName(_ side: SplitPaneSide) -> String {
        switch (axis, side) {
        case (.horizontal, .first): return "Fold Left Pane"
        case (.horizontal, .second): return "Fold Right Pane"
        case (.vertical, .first): return "Fold Top Pane"
        case (.vertical, .second): return "Fold Bottom Pane"
        }
    }

    private func ruleColor(_ tokens: WarrenColorTokens) -> Color {
        if releaseFolds { return tokens.warning }
        if pull != nil { return tokens.mutedForeground.opacity(0.8) }
        if isSnapped { return tokens.info }
        // At rest the gutter between two cards is the divider; the rule only
        // appears once the pointer is on it.
        return isHovered ? tokens.info.opacity(0.8) : .clear
    }

    /// The length a pull indicator draws for `overshoot`: it grows with the
    /// pull at a third of its rate, so it reads as tension rather than travel,
    /// and stops growing well short of the fold so it never crowds the pane.
    nonisolated static func pullIndicatorLength(for overshoot: CGFloat) -> CGFloat {
        guard overshoot.isFinite, overshoot > 0 else { return 0 }
        return min(48, overshoot * 0.35)
    }

    /// A short rule that reaches from the divider toward the pointer while the
    /// pane on that side holds at its minimum, with a tag naming what letting
    /// go does: stay at the minimum, or fold.
    @ViewBuilder
    private func pullIndicator(_ tokens: WarrenColorTokens) -> some View {
        let overshoot = pull?.overshoot ?? 0
        let length = Self.pullIndicatorLength(for: overshoot)
        let direction: CGFloat = pull?.side == .second ? 1 : -1
        let color = releaseFolds ? tokens.warning : tokens.mutedForeground.opacity(0.6)
        let heldLength = pull.map { pull in
            pull.side == .first
                ? CGFloat(minimumRatio) * totalLength
                : CGFloat(1 - maximumRatio) * totalLength
        } ?? 0
        ZStack {
            Capsule()
                .fill(color)
                .frame(
                    width: axis == .horizontal ? length : 2,
                    height: axis == .vertical ? length : 2
                )
                .offset(
                    x: axis == .horizontal ? direction * length / 2 : 0,
                    y: axis == .vertical ? direction * length / 2 : 0
                )
            Text(releaseFolds ? "Fold" : "\(Int(heldLength.rounded())) pt")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(releaseFolds ? tokens.warning : tokens.mutedForeground)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, WarrenSpacing.small)
                .padding(.vertical, WarrenSpacing.xxs)
                .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(tokens.cardBorder, lineWidth: 1)
                }
                .offset(
                    x: axis == .horizontal ? 0 : 36,
                    y: axis == .horizontal ? 22 : 0
                )
        }
        .opacity(pull == nil ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
