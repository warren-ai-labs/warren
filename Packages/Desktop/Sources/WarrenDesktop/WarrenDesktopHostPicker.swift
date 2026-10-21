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
    @State private var isHovered = false

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Button(action: refresh) {
            Group {
                // The shared spinner rather than a `repeatForever` rotation:
                // it is frame-limited, and it follows Reduce Motion as the
                // setting changes instead of reading it once on appear.
                if isChecking {
                    WarrenLoadingIndicator(size: 12, accessibilityLabel: "Checking hosts")
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
            }
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

/// The panel under the sidebar's Host row: what this window's Host offers,
/// and nothing about other Hosts, which are switched and managed at the
/// sidebar's foot.
///
/// Retry or stop while the connection is failing or still trying, then
/// Public Access, which drills into the Web panel, and Settings.
struct WarrenDesktopCurrentHostPanel: View {
    let connectionState: WarrenDesktopConnectionState
    let onRetry: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void
    var publicAccess: WarrenDesktopHostPanelPublicAccess? = nil
    var onSettings: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?
    @State private var showsPublicAccess = false

    private typealias Metrics = WarrenDesktopMenuMetrics

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Group {
            if showsPublicAccess, let publicAccess {
                VStack(alignment: .leading, spacing: 0) {
                    WarrenDesktopMenuBackRow(
                        title: "Public Access",
                        backLabel: "Back to host",
                        onBack: { showsPublicAccess = false }
                    )
                    WarrenDesktopMenuDivider()
                    publicAccess.content
                }
                .transition(
                    WarrenDesktopPopMotion.pageTransition(isForward: true, reduceMotion: reduceMotion)
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    connectionAction(tokens: tokens)
                    if let publicAccess {
                        publicAccessRow(publicAccess, tokens: tokens)
                    }
                    if let onSettings {
                        settingsRow(onSettings, tokens: tokens)
                    }
                }
                .padding(.vertical, 4)
                .transition(
                    WarrenDesktopPopMotion.pageTransition(isForward: false, reduceMotion: reduceMotion)
                )
            }
        }
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
                                .background(Circle().fill(isHot ? palette.hotRing : palette.surface))
                                .offset(x: 3, y: 3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Public Access")
                        .font(WarrenTypography.popoverItem)
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
        // The inline copy button only exists under the pointer, so assistive
        // technology reaches the same command as an action on the row.
        .accessibilityActions {
            if publicAccess.isOn, let url = publicAccess.url {
                Button("Copy public address") { publicAccess.copy(url) }
            }
        }
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
                .accessibilityHidden(!isHot)
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
                    .font(WarrenTypography.popoverItem)
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
        let rowID = "action.\(systemImage)"
        let isHot = hoveredID == rowID
        // Drawn like the Public Access and Settings rows below it: the same
        // glyph size, and the same hover colours.
        return Button(action: action) {
            HStack(spacing: Metrics.iconSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isHot ? palette.iconHover : palette.icon)
                    .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                Text(title)
                    .font(WarrenTypography.popoverItem)
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .onHover { hoveredID = $0 ? rowID : (hoveredID == rowID ? nil : hoveredID) }
        .accessibilityHint(hint)
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

