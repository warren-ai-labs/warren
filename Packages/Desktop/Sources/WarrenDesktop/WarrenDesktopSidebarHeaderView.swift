import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopSidebarHeader: View {
    let chromeMode: WarrenDesktopChromeMode
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let onToggle: () -> Void
    let onCommandPalette: () -> Void
    var showsActiveOnly: Bool = false
    var onToggleActiveOnly: () -> Void = {}
    /// The Host this window is working on, named at the top of the sidebar.
    var host: WarrenDesktopSidebarHostIdentity? = nil
    /// Whether the Host panel is open. The window root presents it, hanging
    /// from this row, like every other chrome surface. It offers this Host's
    /// own controls; other Hosts live at the sidebar's foot.
    var isHostPickerPresented: Bool = false
    /// Opens or closes the Host panel, or `nil` when it is not offered.
    var onToggleHostPicker: (() -> Void)? = nil
    /// Whether Public Access is serving this Host, for the globe beside the
    /// Host name.
    var isPublicAccessOn: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var isHostRowHovered = false

    init(
        chromeMode: WarrenDesktopChromeMode,
        updateStatus: WarrenDesktopUpdateStatus,
        onUpdateAction: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onCommandPalette: @escaping () -> Void,
        showsActiveOnly: Bool = false,
        onToggleActiveOnly: @escaping () -> Void = {},
        host: WarrenDesktopSidebarHostIdentity? = nil,
        isHostPickerPresented: Bool = false,
        isPublicAccessOn: Bool = false,
        onToggleHostPicker: (() -> Void)? = nil
    ) {
        self.chromeMode = chromeMode
        self.updateStatus = updateStatus
        self.onUpdateAction = onUpdateAction
        self.onToggle = onToggle
        self.onCommandPalette = onCommandPalette
        self.showsActiveOnly = showsActiveOnly
        self.onToggleActiveOnly = onToggleActiveOnly
        self.host = host
        self.isHostPickerPresented = isHostPickerPresented
        self.isPublicAccessOn = isPublicAccessOn
        self.onToggleHostPicker = onToggleHostPicker
    }

    var body: some View {
        Group {
            if chromeMode == .workspace {
                workspaceHeader
            } else {
                expandedDashboardHeader
            }
        }
        .background(
            chromeMode == .workspace
                ? WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial).workbenchCardFill
                : .clear
        )
    }

    /// The top of the sidebar card: the window's traffic lights, then the Host
    /// this window works on, with search and the active-only filter beside it.
    private var workspaceHeader: some View {
        VStack(spacing: 0) {
            trafficRow
            hostRow
        }
    }

    private var trafficRow: some View {
        HStack(spacing: WarrenSpacing.xs) {
            // The window is borderless, so Warren draws its own lights inside
            // the sidebar card.
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset - 12, alignment: .leading)
                .padding(.leading, 12)

            WarrenDesktopWindowDragRegion()
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityHidden(true)

            if WarrenBuildVariant.isBuild {
                // The provenance marker is the row's only disposable child: the
                // full form while the rail can carry it, then the compact one,
                // then nothing, so a narrow rail never widens the column.
                ViewThatFits(in: .horizontal) {
                    buildMarker()
                    buildMarker(isCompact: true)
                    EmptyView()
                }
            }

        }
        .frame(height: WarrenDesktopSidebarMetrics.headerTrafficRowHeight)
    }

    private var hostRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return HStack(spacing: 10) {
            Button {
                onToggleHostPicker?()
            } label: {
                HStack(spacing: 10) {
                    hostTile(tokens: tokens)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(host?.name ?? "This Mac")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tokens.foreground.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if isPublicAccessOn {
                                publicAccessGlobe(tokens: tokens)
                            }
                            if onToggleHostPicker != nil {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(tokens.treeQuietText)
                                    .opacity(isHostRowHovered || isHostPickerPresented ? 1 : 0)
                                    .animation(
                                        WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
                                        value: isHostRowHovered || isHostPickerPresented
                                    )
                                    .accessibilityHidden(true)
                            }
                        }
                        if let subtitle = host?.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.treeQuietText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isHostPickerPresented
                                ? tokens.treeRowSelected
                                : (isHostRowHovered && onToggleHostPicker != nil ? tokens.treeRowHover : .clear)
                        )
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHostRowHovered = $0 }
            .help(host.map { "\($0.name) · \($0.connectionLabel)" } ?? "Host")
            .accessibilityLabel("Host \(host?.name ?? "")")
            .accessibilityValue(host?.connectionLabel ?? "")
            .warrenSemanticElement(
                id: "sidebar.host",
                role: .button,
                label: "Host \(host?.name ?? "")",
                value: host?.connectionLabel ?? "",
                isEnabled: onToggleHostPicker != nil,
                isSelected: isHostPickerPresented,
                action: { if !isHostPickerPresented { onToggleHostPicker?() } }
            )

            headerButton(
                systemImage: "magnifyingglass",
                label: "Search",
                hint: "Search projects, sessions and commands (⌘K)",
                action: onCommandPalette
            )
            .focused($searchFocused)
        }
        // The button's own 8pt inset keeps the tile on the rows' 16pt line.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: WarrenDesktopSidebarMetrics.headerHostRowHeight)
    }

    /// The Public Access indicator: a quiet globe with the green dot at its
    /// corner, shown only while Public Access is on.
    private func publicAccessGlobe(tokens: WarrenColorTokens) -> some View {
        Image(systemName: "globe")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(tokens.treeQuietText)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(tokens.success)
                    .frame(width: 6, height: 6)
                    .padding(1)
                    .background(Circle().fill(tokens.workbenchCardFill))
                    .offset(x: 3, y: 3)
            }
            .padding(.leading, 5)
            .warrenTooltip("Public Access is on")
            .accessibilityLabel("Public Access on")
            .accessibilityHidden(true)
    }

    /// The Host's tile: a laptop for this Mac, a server for anything else,
    /// with the connection's state as a dot on its corner.
    private func hostTile(tokens: WarrenColorTokens) -> some View {
        let size = WarrenDesktopSidebarMetrics.hostTileSize
        return Image(systemName: host?.isLocal == false ? "server.rack" : "display")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(tokens.foreground.opacity(0.8))
            .frame(width: size, height: size)
            .background(
                tokens.foreground.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(host.map { connectionColor($0.connectionTone, tokens: tokens) } ?? tokens.success)
                    .frame(width: 8, height: 8)
                    .padding(2)
                    .background(tokens.workbenchCardFill, in: Circle())
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
    }

    private func connectionColor(
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

    private func headerButton(
        systemImage: String,
        label: String,
        hint: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .frame(width: 28, height: 28)
        .foregroundStyle(tint ?? tokens.mutedForeground.opacity(0.85))
        .warrenTooltip(hint)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func buildMarker(isCompact: Bool = false) -> some View {
        WarrenDesktopBuildBadge(
            updateStatus: .none,
            showsBuildMarker: true,
            isCompact: isCompact,
            onUpdateAction: onUpdateAction
        )
    }

    private var expandedDashboardHeader: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return HStack(spacing: WarrenSpacing.xs) {
            WarrenDesktopChromeButton(
                systemImage: "sidebar.leading",
                label: "Collapse sidebar",
                hint: "Collapse the sidebar to icons",
                action: onToggle,
                shortcut: "⌘B"
            )

            WarrenDesktopChromeButton(
                systemImage: showsActiveOnly ? "bolt.horizontal.fill" : "bolt.horizontal",
                label: showsActiveOnly ? "Show all workspaces" : "Filter active workspaces",
                hint: showsActiveOnly ? "Show all workspaces" : "Show only workspaces with active sessions",
                action: onToggleActiveOnly,
                tint: showsActiveOnly ? tokens.highlight : nil
            )

            Spacer(minLength: 0)
        }
        .frame(height: WarrenLayoutMetrics.sidebarHeaderRowHeight)
        .padding(.horizontal, WarrenSpacing.compact)
    }
}

/// What the sidebar's Host row says about the Host this window works on.
struct WarrenDesktopSidebarHostIdentity: Equatable {
    let name: String
    /// "Local · Mac Studio", "Remote · fsn1-dev" and the like.
    let subtitle: String
    let isLocal: Bool
    let connectionState: WarrenDesktopConnectionState

    var connectionLabel: String {
        WarrenDesktopConnectionPresentation(connectionState).label
    }

    var connectionTone: WarrenDesktopConnectionTone {
        WarrenDesktopConnectionPresentation(connectionState).tone
    }

    /// The row's title is the Host's own name, so the row names the machine
    /// rather than the connection. The endpoint's label moves to the subtitle
    /// when it says something the name does not; otherwise its address does.
    static func names(
        hostName: String,
        endpointLabel: String?,
        endpointDetail: String?
    ) -> (name: String, detail: String?) {
        var host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.lowercased().hasSuffix(".local") {
            host = String(host.dropLast(".local".count))
        }
        let label = endpointLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else {
            return (label.isEmpty ? "This Mac" : label, endpointDetail)
        }
        let labelIsDistinct = !label.isEmpty
            && label.caseInsensitiveCompare(host) != .orderedSame
            && !["local", "remote"].contains(label.lowercased())
        return (host, labelIsDistinct ? label : endpointDetail)
    }

    /// The subtitle: where the Host is, then what it is, or how the
    /// connection is doing while it is not connected.
    static func subtitle(
        isLocal: Bool,
        detail: String?,
        connectionState: WarrenDesktopConnectionState
    ) -> String {
        let place = isLocal ? "Local" : "Remote"
        guard connectionState.isConnected else {
            return "\(place) · \(WarrenDesktopConnectionPresentation(connectionState).label)"
        }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? place : "\(place) · \(trimmed)"
    }
}
