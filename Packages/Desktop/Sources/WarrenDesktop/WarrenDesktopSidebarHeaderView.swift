import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopSidebarHeader: View {
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let onToggle: () -> Void
    let onCommandPalette: () -> Void
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
    @State private var isHostRowHovered = false

    init(
        updateStatus: WarrenDesktopUpdateStatus,
        onUpdateAction: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onCommandPalette: @escaping () -> Void,
        host: WarrenDesktopSidebarHostIdentity? = nil,
        isHostPickerPresented: Bool = false,
        isPublicAccessOn: Bool = false,
        onToggleHostPicker: (() -> Void)? = nil
    ) {
        self.updateStatus = updateStatus
        self.onUpdateAction = onUpdateAction
        self.onToggle = onToggle
        self.onCommandPalette = onCommandPalette
        self.host = host
        self.isHostPickerPresented = isHostPickerPresented
        self.isPublicAccessOn = isPublicAccessOn
        self.onToggleHostPicker = onToggleHostPicker
    }

    var body: some View {
        workspaceHeader
            .background(WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial).workbenchCardFill)
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
                            // 13 rather than the design's 13.5, like a
                            // Session title: a Chinese name sets larger.
                            WarrenDesktopTreeTypography.scriptText(
                                host?.name ?? "This Mac",
                                latin: WarrenTypography.hostHeaderName,
                                wide: WarrenTypography.hostHeaderNameWide
                            )
                                // The column's own title, so it takes the
                                // solid ink rather than a fade of it: a fade
                                // here had to be re-tuned whenever the ground
                                // moved.
                                .foregroundStyle(tokens.foreground)
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
                        if let host, !host.subtitle.isEmpty {
                            // "This Mac", "Remote · Studio", or how the
                            // connection is doing. The address is a detail for
                            // the hover card, not the header.
                            HostSubtitleLine(
                                subtitle: host.subtitle,
                                color: tokens.treeQuietText,
                                stateColor: host.connectionState.isConnected
                                    ? nil
                                    : Self.toneColor(host.connectionTone, tokens: tokens)
                            )
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
            // The same hover card a Session wears: the row already shows the
            // name, so the card adds the route and the connection's state.
            .warrenDetailHover { host?.detailRows ?? [] }
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

            // The shared chrome button, so search wears the same weight,
            // hover and keyboard focus ring as every other chrome control.
            WarrenDesktopChromeButton(
                systemImage: "magnifyingglass",
                label: "Search",
                hint: "Search projects, sessions and commands",
                action: onCommandPalette,
                shortcut: "⌘K"
            )
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
            .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
            .foregroundStyle(tokens.treeQuietText)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(tokens.success)
                    .frame(width: 6, height: 6)
                    .padding(1)
                    .background(Circle().fill(tokens.workbenchCardFill))
                    .offset(x: 3, y: 3)
            }
            .padding(.leading, 4)
            .warrenTooltip("Public Access is on")
            .accessibilityLabel("Public Access on")
            .accessibilityHidden(true)
    }

    /// The Host's tile, the same lettered square the collapsed rail's Host
    /// button and the foot's Host stack draw, with its reachability on the
    /// corner.
    private func hostTile(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopHostInitialTile(
            name: host?.name ?? "This Mac",
            size: WarrenDesktopSidebarMetrics.hostTileSize,
            reachability: host.map { WarrenDesktopHostReachability($0.connectionState) }
        )
    }

    static func toneColor(_ tone: WarrenDesktopConnectionTone, tokens: WarrenColorTokens) -> Color {
        switch tone {
        case .success: tokens.success
        case .info: tokens.treeQuietText
        case .warning: tokens.warning
        case .destructive: tokens.destructive
        }
    }

    private func buildMarker(isCompact: Bool = false) -> some View {
        WarrenDesktopBuildBadge(
            updateStatus: .none,
            showsBuildMarker: true,
            isCompact: isCompact,
            onUpdateAction: onUpdateAction
        )
    }
}

/// What the sidebar's Host row says about the Host this window works on.
struct WarrenDesktopSidebarHostIdentity: Equatable {
    let name: String
    /// "This Mac", "Remote · Studio" and the like.
    let subtitle: String
    let isLocal: Bool
    let connectionState: WarrenDesktopConnectionState
    /// How the window reaches the Host (`127.0.0.1:8789`, an SSH alias),
    /// shown on the hover card only.
    var address: String? = nil

    var connectionLabel: String {
        WarrenDesktopConnectionPresentation(connectionState).label
    }

    /// The Host's hover card.
    var detailRows: [WarrenDesktopDetailCard.Row] {
        var rows: [WarrenDesktopDetailCard.Row] = [
            .init(label: "Host", value: name, style: .text),
            .init(label: "Where", value: isLocal ? "This Mac" : "Remote", style: .text),
        ]
        if let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            rows.append(.init(label: "Address", value: address))
        }
        rows.append(.init(label: "Status", value: connectionLabel, style: .text))
        return rows
    }

    var connectionTone: WarrenDesktopConnectionTone {
        WarrenDesktopConnectionPresentation(connectionState).tone
    }

    /// The row's title is the Host's own name, so the row names the machine
    /// rather than the connection. The endpoint's label moves to the subtitle
    /// when it says something the name does not. Its address never does: an
    /// `ip:port` under the name was noise, and the hover card carries it.
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
            return (label.isEmpty ? "This Mac" : label, nil)
        }
        let labelIsDistinct = !label.isEmpty
            && label.caseInsensitiveCompare(host) != .orderedSame
            && !["local", "remote"].contains(label.lowercased())
        return (host, labelIsDistinct ? label : nil)
    }

    /// The subtitle: where the Host is, then what it is, or how the
    /// connection is doing while it is not connected.
    static func subtitle(
        isLocal: Bool,
        detail: String?,
        connectionState: WarrenDesktopConnectionState
    ) -> String {
        let place = isLocal ? "This Mac" : "Remote"
        guard connectionState.isConnected else {
            return "\(place) · \(WarrenDesktopConnectionPresentation(connectionState).label)"
        }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? place : "\(place) · \(trimmed)"
    }
}

/// The Host row's second line, split so only its detail can truncate. A
/// connection that is not up draws its state in the state's tone.
private struct HostSubtitleLine: View {
    let subtitle: String
    let color: Color
    var stateColor: Color? = nil

    private var parts: (place: String, detail: String?) {
        let pieces = subtitle.components(separatedBy: " · ")
        guard pieces.count > 1 else { return (subtitle, nil) }
        return (pieces[0], pieces.dropFirst().joined(separator: " · "))
    }

    var body: some View {
        let parts = parts
        HStack(spacing: 4) {
            Text(parts.place)
                .fixedSize(horizontal: true, vertical: false)
            if let detail = parts.detail {
                Text("·")
                    .opacity(0.7)
                    .fixedSize(horizontal: true, vertical: false)
                Text(detail)
                    .foregroundStyle(stateColor ?? color)
                    .truncationMode(.tail)
            }
        }
        .font(WarrenTypography.hostHeaderMeta)
        .foregroundStyle(color)
        .lineLimit(1)
    }
}
