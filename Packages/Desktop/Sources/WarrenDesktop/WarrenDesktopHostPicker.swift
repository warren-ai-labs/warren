import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// The measurements shared by the Host picker and the panels menu, from the
/// adopted Workbench spec: one floating surface, one row shape.
enum WarrenDesktopMenuMetrics {
    static let radius: CGFloat = 10
    static let inset: CGFloat = 4
    static let rowRadius: CGFloat = 6
    /// A one-line row.
    static let rowHeight: CGFloat = 30
    /// A row with a title and a second line.
    static let twoLineRowHeight: CGFloat = 40
    static let rowHorizontalPadding: CGFloat = 8
    static let iconSize: CGFloat = 16
    /// The column a leading glyph occupies: a tile is 20 wide, an SF Symbol is
    /// centered in the same 20 so rows never shift their text column.
    static let glyphSlot: CGFloat = 20
    static let iconSpacing: CGFloat = 9
    static let dividerSpacing: CGFloat = 4
    static let headerHeight: CGFloat = 26
    static let headerTracking: CGFloat = 0.4
    static let actionSize: CGFloat = 22
    static let statusDotSize: CGFloat = 7
    /// Between the control that opens a surface and the surface.
    static let anchorGap: CGFloat = 4

    /// A shortcut key: one cap per key.
    static let keycapHeight: CGFloat = 18
    static let keycapMinWidth: CGFloat = 18
    static let keycapPadding: CGFloat = 4
    static let keycapRadius: CGFloat = 4
    static let keycapSpacing: CGFloat = 2

    /// The leading column a single-choice list keeps for its checkmark.
    static let checkColumnWidth: CGFloat = 14
    static let checkSpacing: CGFloat = 7

    /// A Host's tile.
    static let tileSize: CGFloat = 20
    static let tileRadius: CGFloat = 5

    /// The default width of a menu list.
    static let menuWidth: CGFloat = 248
}

/// How every floating chrome surface comes and goes: it fades in while it
/// drops the last few points into place on a quick spring, and only fades
/// when Reduce Motion is on.
enum WarrenDesktopPopMotion {
    static let travel: CGFloat = 6
    static let scale: CGFloat = 0.98
    static let spring = Animation.spring(response: 0.22, dampingFraction: 0.78)
    static let fade = Animation.easeOut(duration: 0.14)

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : spring
    }

    /// `edge` is the side the surface hangs from: it grows out of that edge.
    static func transition(edge: VerticalEdge = .top, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let anchor: UnitPoint = edge == .top ? .top : .bottom
        let offset = edge == .top ? -travel : travel
        return .asymmetric(
            insertion: .modifier(
                active: WarrenDesktopPopModifier(offset: offset, scale: scale, opacity: 0, anchor: anchor),
                identity: WarrenDesktopPopModifier(offset: 0, scale: 1, opacity: 1, anchor: anchor)
            ),
            // Leaving is quicker and travels less, so a dismissed surface
            // gets out of the way rather than performing.
            removal: .modifier(
                active: WarrenDesktopPopModifier(offset: offset / 2, scale: 1, opacity: 0, anchor: anchor),
                identity: WarrenDesktopPopModifier(offset: 0, scale: 1, opacity: 1, anchor: anchor)
            )
        )
    }

    /// A drilled-in page slides in from the trailing side; going back slides
    /// it out the way it came.
    static func pageTransition(isForward: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = 16
        return .asymmetric(
            insertion: .offset(x: isForward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: isForward ? -distance : distance).combined(with: .opacity)
        )
    }
}

struct WarrenDesktopPopModifier: ViewModifier {
    let offset: CGFloat
    let scale: CGFloat
    let opacity: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .offset(y: offset)
            .opacity(opacity)
    }
}

/// The floating surface of a chrome menu: the Host picker and the panels
/// menu. A plain list with no title bar, like a native menu.
struct WarrenDesktopMenuSurface<Content: View>: View {
    let width: CGFloat
    let content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .warrenMenuSurface(width: width)
    }
}

/// The hairline between groups of a menu.
struct WarrenDesktopMenuDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        Rectangle()
            .fill(WarrenDesktopMenuPalette.resolved(for: colorScheme).divider)
            .frame(height: 1)
            // Full-bleed: the surface's own inset is cancelled so the hairline
            // reaches both container edges, as the spec draws it.
            .padding(.horizontal, -WarrenDesktopMenuMetrics.inset)
            .padding(.vertical, WarrenDesktopMenuMetrics.dividerSpacing)
            .accessibilityHidden(true)
    }
}

/// Refreshes every Host's probe; spins while one is running.
struct WarrenDesktopHostRefreshButton: View {
    let isChecking: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(isChecking && !reduceMotion ? 360 : 0))
                .animation(
                    isChecking && !reduceMotion
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: isChecking
                )
                .opacity(isChecking && reduceMotion ? 0.5 : 1)
                .frame(width: WarrenDesktopMenuMetrics.actionSize, height: WarrenDesktopMenuMetrics.actionSize)
                // The menu spec's inline action: #8A8A8A at rest, a press
                // wash under the pointer, like every other header action.
                .foregroundStyle(isHovered ? palette.iconHover : palette.actionGlyph)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? palette.pressFill : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .warrenTooltip("Check all hosts")
        .accessibilityLabel("Check all hosts")
        .accessibilityValue(isChecking ? "Checking" : "")
        .warrenSemanticElement(
            id: "endpoint.check",
            role: .button,
            label: "Check all hosts",
            action: refresh
        )
    }

    private func refresh() {
        WarrenDesktopEndpointOption.requestProbe(force: true)
    }
}

/// Public Access as the Host panel shows it: whether the public route is up,
/// its address while it is, and the Web panel page to drill into.
struct WarrenDesktopHostPanelPublicAccess {
    let isOn: Bool
    let url: URL?
    /// The Web panel content, shown behind a return row when the row is opened.
    let content: AnyView
    let copy: (URL) -> Void

    /// The public address without its scheme, as it is read aloud and shown.
    static func displayAddress(_ url: URL) -> String {
        var text = url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// The Host list: the window's Host first, then every other one in the order
/// they were added. Each row is two lines, the Host's name and its route, and
/// the probe's result is only a dot on the tile; the full text is in the
/// row's tooltip. The order never follows status, so rows do not jump while
/// probes land.
///
/// Shared by the sidebar's Host picker and the Execution Server page of the
/// panels menu.
struct WarrenDesktopEndpointPopoverContent: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onSetSidebarVisibility: (String, Bool) -> Void
    let onCustomizeDisplayName: (WarrenDesktopEndpointOption) -> Void
    let onAddSSHHost: () -> Void
    let onRetry: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    /// The Add SSH Host page, supplied by the app. Without it, the list's
    /// add entry falls back to `onAddSSHHost`.
    var sshHostPage: WarrenDesktopSSHHostPageModel? = nil
    /// Public Access and Settings are Host-level entries in this panel, below
    /// the list. The list itself is the execution-server selector.
    var publicAccess: WarrenDesktopHostPanelPublicAccess? = nil
    var onSettings: (() -> Void)? = nil

    init(
        connectionState: WarrenDesktopConnectionState,
        endpoints: [WarrenDesktopEndpointOption],
        selectedID: String,
        onSelect: @escaping (String) -> Void,
        onSetSidebarVisibility: @escaping (String, Bool) -> Void,
        onCustomizeDisplayName: @escaping (WarrenDesktopEndpointOption) -> Void = { _ in },
        onAddSSHHost: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        sshHostPage: WarrenDesktopSSHHostPageModel? = nil,
        publicAccess: WarrenDesktopHostPanelPublicAccess? = nil,
        onSettings: (() -> Void)? = nil,
        initialShowsAddHost: Bool = false
    ) {
        self.connectionState = connectionState
        self.endpoints = endpoints
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onSetSidebarVisibility = onSetSidebarVisibility
        self.onCustomizeDisplayName = onCustomizeDisplayName
        self.onAddSSHHost = onAddSSHHost
        self.onRetry = onRetry
        self.onStop = onStop
        self.onDismiss = onDismiss
        self.sshHostPage = sshHostPage
        self.publicAccess = publicAccess
        self.onSettings = onSettings
        _showsAddHost = State(initialValue: initialShowsAddHost)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?
    @State private var isAddHovered = false
    @State private var showsAddHost: Bool
    @State private var showsPublicAccess = false

    private typealias Metrics = WarrenDesktopMenuMetrics

    static func isChecking(_ endpoints: [WarrenDesktopEndpointOption]) -> Bool {
        endpoints.contains { $0.probeState == .checking }
    }

    /// The window's Host leads; the rest keep the catalog's order.
    static func ordered(
        _ endpoints: [WarrenDesktopEndpointOption],
        selectedID: String
    ) -> [WarrenDesktopEndpointOption] {
        endpoints.filter { $0.id == selectedID } + endpoints.filter { $0.id != selectedID }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Group {
            if showsAddHost, let sshHostPage {
                VStack(alignment: .leading, spacing: 0) {
                    returnRow(title: "Add SSH Host") { showsAddHost = false }
                    WarrenDesktopMenuDivider()
                    WarrenDesktopSSHHostListView(model: sshHostPage)
                }
                .transition(
                    WarrenDesktopPopMotion.pageTransition(isForward: true, reduceMotion: reduceMotion)
                )
            } else if showsPublicAccess, let publicAccess {
                VStack(alignment: .leading, spacing: 0) {
                    returnRow(title: "Public Access") { showsPublicAccess = false }
                    WarrenDesktopMenuDivider()
                    publicAccess.content
                }
                .transition(
                    WarrenDesktopPopMotion.pageTransition(isForward: true, reduceMotion: reduceMotion)
                )
            } else {
                hostList(tokens: tokens)
                    .transition(
                        WarrenDesktopPopMotion.pageTransition(isForward: false, reduceMotion: reduceMotion)
                    )
            }
        }
        .onAppear {
            // Opening the list checks the Hosts again unless the last
            // results are still fresh; the refresh button always does.
            WarrenDesktopEndpointOption.requestProbe(force: false)
        }
    }

    private func hostList(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: "HOSTS") {
                WarrenDesktopHostRefreshButton(isChecking: Self.isChecking(endpoints))
            }

            connectionAction(tokens: tokens)

            ForEach(Self.ordered(endpoints, selectedID: selectedID)) { endpoint in
                endpointRow(endpoint, tokens: tokens)
            }

            if publicAccess != nil || onSettings != nil {
                WarrenDesktopMenuDivider()
            }
            if let publicAccess {
                publicAccessRow(publicAccess, tokens: tokens)
            }
            if let onSettings {
                settingsRow(onSettings, tokens: tokens)
            }

            WarrenDesktopMenuDivider()

            addHostRow()
        }
    }

    /// The return row a drilled-in page leads with.
    private func returnRow(title: String, onBack: @escaping () -> Void) -> some View {
        WarrenDesktopMenuBackRow(title: title, backLabel: "Back to hosts", onBack: onBack)
    }

    private func addSSHHost() {
        if sshHostPage != nil {
            withAnimation(WarrenDesktopPopMotion.animation(reduceMotion: reduceMotion)) {
                showsAddHost = true
                showsPublicAccess = false
            }
            return
        }
        onAddSSHHost()
        onDismiss()
    }

    /// The Host-level Public Access entry. Two lines while it is on, so the
    /// address is visible; the copy control appears on hover, as the spec draws
    /// it.
    private func publicAccessRow(
        _ publicAccess: WarrenDesktopHostPanelPublicAccess,
        tokens: WarrenColorTokens
    ) -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let isHot = hoveredID == "public-access"
        let open: () -> Void = {
            withAnimation(WarrenDesktopPopMotion.animation(reduceMotion: reduceMotion)) {
                showsPublicAccess = true
                showsAddHost = false
            }
        }
        return Button(action: open) {
            HStack(spacing: Metrics.iconSpacing) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isHot ? palette.iconHover : palette.icon)
                    .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                    .overlay(alignment: .bottomTrailing) {
                        if publicAccess.isOn {
                            Circle()
                                .fill(tokens.success)
                                .frame(width: 7, height: 7)
                                .padding(1.5)
                                .background(Circle().fill(isHot ? palette.hoverFill : palette.surface))
                                .offset(x: 3, y: 3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Public Access")
                        .font(.system(size: 13))
                        .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                    if publicAccess.isOn, let url = publicAccess.url {
                        Text(WarrenDesktopHostPanelPublicAccess.displayAddress(url))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                WarrenDesktopMenuChevron()
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: publicAccess.isOn && publicAccess.url != nil
                    ? Metrics.twoLineRowHeight
                    : Metrics.rowHeight,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .onHover { hoveredID = $0 ? "public-access" : (hoveredID == "public-access" ? nil : hoveredID) }
        .accessibilityLabel("Public Access")
        .accessibilityValue(publicAccess.isOn ? "On" : "Off")
        .warrenSemanticElement(
            id: "endpoint.public-access",
            role: .button,
            label: "Public Access",
            value: publicAccess.isOn ? "On" : "Off",
            action: open
        )
        .overlay(alignment: .trailing) {
            if publicAccess.isOn, let url = publicAccess.url {
                let copy: () -> Void = { publicAccess.copy(url) }
                WarrenDesktopMenuInlineButton(
                    systemImage: "doc.on.doc",
                    label: "Copy public address",
                    isActive: false,
                    action: copy
                )
                .opacity(isHot ? 1 : 0)
                .padding(.trailing, Metrics.rowHorizontalPadding - 2)
                .warrenTooltip("Copy public address")
                .warrenSemanticElement(
                    id: "endpoint.public-access.copy",
                    role: .button,
                    label: "Copy public address",
                    action: copy
                )
            }
        }
    }

    /// The Settings entry, with the key cap the app menu also uses.
    private func settingsRow(
        _ onSettings: @escaping () -> Void,
        tokens: WarrenColorTokens
    ) -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let isHot = hoveredID == "settings"
        let action: () -> Void = {
            onSettings()
            onDismiss()
        }
        return Button(action: action) {
            HStack(spacing: Metrics.iconSpacing) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isHot ? palette.iconHover : palette.icon)
                    .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                Text("Settings…")
                    .font(.system(size: 13))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                Spacer(minLength: 0)
                WarrenDesktopMenuKeycaps(keys: "⌘,")
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .onHover { hoveredID = $0 ? "settings" : (hoveredID == "settings" ? nil : hoveredID) }
        .accessibilityLabel("Settings")
        .warrenSemanticElement(
            id: "endpoint.settings",
            role: .button,
            label: "Settings",
            action: action
        )
    }

    /// The list's one add entry. It follows Settings, so it keeps Settings'
    /// leading edge rather than the Hosts' check column above.
    private func addHostRow() -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let isHot = isAddHovered
        return Button(action: addSSHHost) {
            HStack(spacing: Metrics.iconSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.addText)
                    .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                Text("Add SSH host…")
                    .font(.system(size: 12))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.addText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .onHover { isAddHovered = $0 }
        .accessibilityLabel("Add SSH host")
        .warrenSemanticElement(
            id: "endpoint.add-ssh-host",
            role: .button,
            label: "Add SSH host",
            action: addSSHHost
        )
    }

    /// Retry or stop for the window's own connection, when it has failed or
    /// is still trying. Everything else about it is the first row's dot.
    @ViewBuilder
    private func connectionAction(tokens: WarrenColorTokens) -> some View {
        if connectionState == .failed || connectionState == .disconnected {
            actionRow(
                systemImage: "arrow.clockwise",
                title: "Retry connection",
                hint: "Try the selected Host again",
                tokens: tokens,
                action: onRetry
            )
        } else if connectionState == .connecting || connectionState == .reconnecting {
            actionRow(
                systemImage: "stop.circle",
                title: "Stop connection",
                hint: "Stop connecting to the selected Host",
                tokens: tokens,
                action: onStop
            )
        }
    }

    private func actionRow(
        systemImage: String,
        title: String,
        hint: String,
        tokens: WarrenColorTokens,
        action: @escaping () -> Void
    ) -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        return Button(action: action) {
            HStack(spacing: Metrics.iconSpacing) {
                HStack(spacing: Metrics.checkSpacing) {
                    WarrenDesktopMenuCheckColumn(isChecked: false)
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.icon)
                        .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                }
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.rowText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .accessibilityHint(hint)
    }

    private func endpointRow(
        _ endpoint: WarrenDesktopEndpointOption,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = endpoint.id == selectedID
        let isHot = hoveredID == endpoint.id || forceHover
        let presentation = WarrenDesktopHostPickerRow(endpoint: endpoint, isSelected: isSelected)
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let select: () -> Void = {
            onSelect(endpoint.id)
            onDismiss()
        }

        return Button(action: select) {
            HStack(spacing: Metrics.iconSpacing) {
                HStack(spacing: Metrics.checkSpacing) {
                    WarrenDesktopMenuCheckColumn(isChecked: isSelected)
                    WarrenDesktopMenuTile(
                        initial: presentation.initial,
                        isFailed: presentation.state == .failed,
                        status: status(for: presentation.state, tokens: tokens),
                        isHot: isHot
                    )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                    if let route = presentation.route {
                        Text(route)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.meta)
                            .truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            // The membership pill overlays the row's end; keep the name and
            // route clear of it so neither runs under the pill.
            .padding(.trailing, WarrenDesktopSidebarMembershipPill.reservedWidth)
            .frame(
                maxWidth: .infinity,
                minHeight: presentation.route == nil ? Metrics.rowHeight : Metrics.twoLineRowHeight,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle(forceHover: forceHover))
        .help(presentation.tooltip)
        .accessibilityLabel(presentation.name)
        .accessibilityValue(
            [isSelected ? "Selected" : nil, endpoint.probeStatus, endpoint.connectionError]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        .warrenSemanticElement(
            id: "endpoint.\(endpoint.id)",
            role: .button,
            label: endpoint.label,
            value: [endpoint.probeStatus, endpoint.connectionError].compactMap { $0 }.joined(separator: "\n"),
            isSelected: isSelected,
            action: select
        )
        .warrenContextMenu([
            .button(title: "Rename Host…") {
                onCustomizeDisplayName(endpoint)
            }
        ])
        .overlay(alignment: .trailing) {
            sidebarMembership(endpoint, isSelected: isSelected, isHot: isHot, tokens: tokens)
                .padding(.trailing, Metrics.rowHorizontalPadding)
        }
        .onHover { inside in
            if inside {
                hoveredID = endpoint.id
            } else if hoveredID == endpoint.id {
                hoveredID = nil
            }
        }
    }

    /// The probe's result as a corner dot, or `nil` when there is none.
    private func status(
        for state: WarrenDesktopEndpointOption.ProbeState,
        tokens: WarrenColorTokens
    ) -> WarrenDesktopMenuStatus? {
        switch state {
        case .reachable: .ok(tokens.success)
        case .failed: .failed(tokens.destructive)
        case .checking: .checking
        case .unknown: nil
        }
    }

    /// Whether this Host's tree is shown in the sidebar too: a small switch
    /// pill at the row's end. It stays on screen while the Host is in the
    /// sidebar and appears on hover while it is not; the window's own Host
    /// is always in the sidebar, so its pill is a quiet tag rather than a
    /// button.
    @ViewBuilder
    private func sidebarMembership(
        _ endpoint: WarrenDesktopEndpointOption,
        isSelected: Bool,
        isHot: Bool,
        tokens: WarrenColorTokens
    ) -> some View {
        let isDisplayed = endpoint.isDisplayedInSidebar
        if isSelected && !isDisplayed {
            WarrenDesktopSidebarMembershipPill(state: .implied, isRowHot: isHot, action: nil)
                .help("\(endpoint.label) is in the sidebar while it is the window's Host")
                .accessibilityHidden(true)
        } else {
            let label = isDisplayed
                ? "Remove \(endpoint.label) from Sidebar"
                : "Add \(endpoint.label) to Sidebar"
            let toggle: () -> Void = { onSetSidebarVisibility(endpoint.id, !isDisplayed) }
            WarrenDesktopSidebarMembershipPill(
                state: isDisplayed ? .on : .off,
                isRowHot: isHot,
                action: toggle
            )
            .warrenTooltip(label)
            .accessibilityLabel(label)
            .accessibilityValue(isDisplayed ? "In sidebar" : "Not in sidebar")
            .accessibilityHint("This does not change the active Host")
            .warrenSemanticElement(
                id: "endpoint.\(endpoint.id).sidebar",
                role: .button,
                label: label,
                isSelected: isDisplayed,
                action: toggle
            )
        }
    }
}

/// The Host row's "in the sidebar" switch: a capsule that reads as a state
/// first and a button second.
///
/// Off, it is an outlined "+ Sidebar" that only shows on the row's hover. On,
/// it is a filled "✓ Sidebar" that stays put, and under the pointer its check
/// turns into a minus so the click's effect is visible before it happens.
/// The label never changes, so the pill keeps one width in every state and
/// the row text beside it never reflows.
struct WarrenDesktopSidebarMembershipPill: View {
    enum Membership: Equatable {
        case off
        case on
        /// In the sidebar because it is the window's Host; not a button.
        case implied
    }

    let state: Membership
    let isRowHot: Bool
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// What the row keeps clear at its trailing edge for the pill.
    static let reservedWidth: CGFloat = 70
    static let height: CGFloat = 20

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Group {
            if let action {
                Button(action: action) { pill(palette: palette) }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
            } else {
                pill(palette: palette)
            }
        }
        .opacity(state == .off && !isRowHot ? 0 : 1)
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: state)
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: isHovered)
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: isRowHot)
    }

    private func pill(palette: WarrenDesktopMenuPalette) -> some View {
        let shape = Capsule(style: .continuous)
        return HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 9, height: 9)
                .contentTransition(.opacity)
            Text("Sidebar")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(foreground(palette))
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(shape.fill(fill(palette)))
        .overlay(shape.strokeBorder(border(palette), lineWidth: 1))
        .contentShape(shape)
        .fixedSize()
    }

    private var glyph: String {
        switch state {
        case .off: "plus"
        case .on: isHovered ? "minus" : "checkmark"
        case .implied: "checkmark"
        }
    }

    private func foreground(_ palette: WarrenDesktopMenuPalette) -> Color {
        switch state {
        case .off: isHovered ? palette.rowHoverText : palette.secondaryGlyph
        case .on: isHovered ? palette.rowHoverText : palette.rowText
        case .implied: palette.meta
        }
    }

    private func fill(_ palette: WarrenDesktopMenuPalette) -> Color {
        switch state {
        case .off: isHovered ? palette.hoverFill : .clear
        case .on: isHovered ? palette.pressFill : palette.hoverFill
        case .implied: .clear
        }
    }

    private func border(_ palette: WarrenDesktopMenuPalette) -> Color {
        switch state {
        case .off: isHovered ? palette.pressBorder : palette.hoverBorder
        case .on: isHovered ? palette.pressBorder : palette.hoverBorder
        case .implied: palette.divider
        }
    }
}

/// What one Host row says, worked out from the endpoint: the name, the route
/// line, the dot, and the tooltip that carries everything the row leaves out.
struct WarrenDesktopHostPickerRow: Equatable {
    let name: String
    let initial: String
    let route: String?
    let state: WarrenDesktopEndpointOption.ProbeState
    let tooltip: String

    init(endpoint: WarrenDesktopEndpointOption, isSelected: Bool) {
        let name = Self.name(for: endpoint)
        self.name = name
        initial = String(name.prefix(1)).lowercased()
        route = Self.route(for: endpoint)
        // The window's own connection outranks a probe: a Host that fails to
        // attach is red whatever its health endpoint says.
        if isSelected, endpoint.connectionError != nil {
            state = .failed
        } else {
            state = endpoint.probeState
        }
        tooltip = ([name, route] + Self.probeLines(endpoint.probeStatus) + [endpoint.connectionError])
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The machine's name for this Mac's own endpoint while it still carries
    /// the default "Local" label, so the row and the sidebar's Host row name
    /// the same thing. "Local" moves to the route line.
    static func name(
        for endpoint: WarrenDesktopEndpointOption,
        machineName: String = WarrenDesktopHostPickerRow.machineName
    ) -> String {
        let label = endpoint.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint.isLocal, label.isEmpty || label.lowercased() == "local" else {
            return label.isEmpty ? endpoint.id : label
        }
        var machine = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if machine.lowercased().hasSuffix(".local") {
            machine = String(machine.dropLast(".local".count))
        }
        return machine.isEmpty || machine == "localhost" ? "Local" : machine
    }

    /// Read once: resolving the host name can block on the network.
    static let machineName = ProcessInfo.processInfo.hostName

    /// One line on where the Host is: "Local · 127.0.0.1:8789",
    /// "SSH · beelink", or the address.
    static func route(for endpoint: WarrenDesktopEndpointOption) -> String? {
        let detail = endpoint.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if endpoint.isLocal {
            return detail.isEmpty ? "Local" : "Local · \(detail)"
        }
        return detail.isEmpty ? nil : detail
    }

    private static func probeLines(_ status: String?) -> [String?] {
        guard let status else { return [] }
        return status.split(separator: "\n").map { String($0) }
    }
}

