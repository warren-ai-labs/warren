import SwiftUI
import Foundation
import WarrenDesignSystem

public struct WarrenDesktopWebStatus: Hashable, Sendable {
    public var isRunning: Bool
    public var localURL: URL?
    /// The same Web UI reachable from devices on the local network, for
    /// example `http://192.168.1.23:8789/#t=<token>`.
    public var lanURL: URL?
    public var secureURL: URL?
    public var canControl: Bool
    /// True while the daemon reports a live public tunnel
    /// (gnar/cloudflared/tailscale). Independent of `isRunning`, which only
    /// reflects local Web reachability.
    public var tunnelRunning: Bool

    public init(
        isRunning: Bool = false,
        localURL: URL? = nil,
        lanURL: URL? = nil,
        secureURL: URL? = nil,
        canControl: Bool = true,
        tunnelRunning: Bool = false
    ) {
        self.isRunning = isRunning
        self.localURL = localURL
        self.lanURL = lanURL
        self.secureURL = secureURL
        self.canControl = canControl
        self.tunnelRunning = tunnelRunning
    }
}

enum WarrenDesktopWebAddressKind: String, Hashable, Sendable {
    case local
    case lan
    case publicAccess

    var title: String {
        switch self {
        case .local: "Local"
        case .lan: "LAN"
        case .publicAccess: "Public"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .local: "Local Web"
        case .lan: "LAN Web"
        case .publicAccess: "Public Web"
        }
    }

    var canOpenInBrowser: Bool {
        self == .local
    }
}

struct WarrenDesktopWebAddress: Identifiable, Hashable, Sendable {
    let kind: WarrenDesktopWebAddressKind
    let url: URL

    var id: String {
        "\(kind.rawValue):\(url.absoluteString)"
    }
}

/// Keeps link selection separate from the SwiftUI layout so every reported
/// address remains visible and duplicate local/LAN links do not waste space.
enum WarrenDesktopWebAddressPresentation {
    static func addresses(for status: WarrenDesktopWebStatus) -> [WarrenDesktopWebAddress] {
        var addresses: [WarrenDesktopWebAddress] = []

        append(.local, url: status.localURL, to: &addresses)
        append(.lan, url: status.lanURL, to: &addresses)
        append(.publicAccess, url: status.secureURL, to: &addresses)

        return addresses
    }

    private static func append(
        _ kind: WarrenDesktopWebAddressKind,
        url: URL?,
        to addresses: inout [WarrenDesktopWebAddress]
    ) {
        guard let url, !addresses.contains(where: { $0.url == url }) else { return }
        addresses.append(.init(kind: kind, url: url))
    }
}

public struct WarrenDesktopWebPanel: View {
    public let status: WarrenDesktopWebStatus
    public let canShare: Bool
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void
    public let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        status: WarrenDesktopWebStatus,
        canShare: Bool = true,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onCopyURL: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.status = status
        self.canShare = canShare
        self.onStart = onStart
        self.onStop = onStop
        self.onOpenURL = onOpenURL
        self.onCopyURL = onCopyURL
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let addresses = WarrenDesktopWebAddressPresentation.addresses(for: status)
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)
            WarrenDesktopChromeDivider()
            if addresses.isEmpty {
                unavailableContent(tokens: tokens)
            } else {
                content(addresses: addresses, tokens: tokens)
            }
        }
        .frame(width: WarrenLayoutMetrics.webPopoverWidth, alignment: .leading)
        .warrenPresentationSurface(role: .popover, cornerRadius: WarrenRadius.base)
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "globe")
                .font(WarrenTypography.navigationGroup)
                .foregroundStyle(tokens.foreground)
                .accessibilityHidden(true)
            Text("Web")
                .font(WarrenTypography.popoverTitle)
                .foregroundStyle(tokens.foreground)
            Spacer()
            WarrenStatusIndicator(
                color: status.isRunning ? tokens.success : tokens.mutedForeground,
                accessibilityLabel: status.isRunning ? "Web is running" : "Web is stopped"
            )
            .accessibilityHidden(true)
            Text(status.isRunning ? "Running" : "Stopped")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
            WarrenDesktopWebIconButton(
                systemImage: "xmark",
                accessibilityLabel: "Close Web panel",
                accessibilityHint: "Dismiss the Web panel",
                action: onDismiss
            )
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
    }

    private func content(
        addresses: [WarrenDesktopWebAddress],
        tokens: WarrenColorTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            ForEach(addresses) { address in
                WarrenDesktopWebAddressRow(
                    address: address,
                    onOpen: address.kind.canOpenInBrowser
                        ? { onOpenURL(address.url) }
                        : nil,
                    onCopy: { onCopyURL(address.url) }
                )
            }

            WarrenDesktopChromeDivider()
                .padding(.vertical, WarrenSpacing.xs)

            WarrenDesktopWebSharingRow(
                isActive: status.secureURL != nil,
                isEnabled: canShare && status.canControl,
                onStart: onStart,
                onStop: onStop
            )
        }
        .padding(WarrenSpacing.medium)
    }

    private func unavailableContent(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "globe.badge.xmark")
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text("Web is unavailable")
                    .font(WarrenTypography.popoverItem)
                    .foregroundStyle(tokens.foreground)
                Text("Connect to a local Web endpoint to get a link.")
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(WarrenSpacing.medium)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web is unavailable. Connect to a local Web endpoint to get a link.")
    }
}

private struct WarrenDesktopWebAddressRow: View {
    let address: WarrenDesktopWebAddress
    let onOpen: (() -> Void)?
    let onCopy: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            Text(address.kind.title)
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 36, alignment: .leading)
            Text(address.url.absoluteString)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onOpen {
                WarrenDesktopWebIconButton(
                    systemImage: "arrow.up.right.square",
                    accessibilityLabel: "Open \(address.kind.accessibilityTitle) address",
                    accessibilityHint: "Open this address in the default browser",
                    action: onOpen
                )
            }
            WarrenDesktopWebIconButton(
                systemImage: "doc.on.doc",
                accessibilityLabel: "Copy \(address.kind.accessibilityTitle) address",
                accessibilityHint: "Copy this address to the clipboard",
                action: onCopy
            )
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(minHeight: 32)
        .background(tokens.inputSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.small)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(address.kind.accessibilityTitle) address: \(address.url.absoluteString)")
    }
}

private struct WarrenDesktopWebSharingRow: View {
    let isActive: Bool
    let isEnabled: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "globe")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(isActive ? tokens.info : tokens.mutedForeground)
                .accessibilityHidden(true)
            Text("Public sharing")
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground)
            Spacer(minLength: 0)
            Text(isActive ? "On" : "Off")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(isActive ? tokens.info : tokens.mutedForeground)
            WarrenDesktopWebCommandButton(
                title: isActive ? "Stop" : "Share",
                isEnabled: isEnabled,
                isEmphasized: isActive,
                accessibilityLabel: isActive
                    ? "Stop public sharing"
                    : "Share the Web UI publicly"
            ) {
                if isActive {
                    onStop()
                } else {
                    onStart()
                }
            }
        }
        .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Public sharing")
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

/// Compact text action used for the one stateful control in the Web panel.
private struct WarrenDesktopWebCommandButton: View {
    let title: String
    var isEnabled = true
    var isEmphasized = false
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Text(title)
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(isEmphasized ? tokens.info : tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    isEmphasized ? tokens.info.opacity(0.12) : Color.clear
                )
                .contentShape(.rect)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WarrenDesktopWebIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .focused($isFocused)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .help(accessibilityLabel)
    }
}
