import SwiftUI
import Foundation
import WarrenDesignSystem

/// Stable user-facing terminology for the Relay-owned public route.
public enum WarrenPublicAccessCopy {
    public static let title = "Public Access"
    public static let relayURL = "Relay URL"
    public static let publicHostname = "Public hostname"
    public static let pathPrefix = "Path prefix"
    public static let publicEndpoint = "Public Endpoint"
    public static let resetLocalSetup = "Reset local route"
}

/// The non-secret Relay enrollment metadata reported by a Host daemon.
///
/// The daemon token remains in the Host credential store and is never part of
/// this projection. `relayPublicKey` is a pinned public signing key reported by
/// the daemon for diagnostics and route trust decisions.
public struct WarrenDesktopRelaySettings: Hashable, Sendable {
    public var enabled: Bool
    public var relayURL: String
    public var hostID: String
    public var routeID: String
    public var relayKeyID: String
    public var relayPublicKey: String
    public var lastError: String

    public init(
        enabled: Bool = false,
        relayURL: String = "",
        hostID: String = "",
        routeID: String = "",
        relayKeyID: String = "",
        relayPublicKey: String = "",
        lastError: String = ""
    ) {
        self.enabled = enabled
        self.relayURL = relayURL
        self.hostID = hostID
        self.routeID = routeID
        self.relayKeyID = relayKeyID
        self.relayPublicKey = relayPublicKey
        self.lastError = lastError
    }

    public var isEnrolled: Bool {
        !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A safe client-facing Relay invite produced by the local Host daemon. The
/// URL contains no Host ID or access capability; those are resolved by Relay
/// only after the recipient opens the invite.
public struct WarrenDesktopRelayInvite: Hashable, Sendable {
    public let url: URL
    public let expiresAt: Date?
    public let expiresIn: Int

    public init(url: URL, expiresAt: Date? = nil, expiresIn: Int = 0) {
        self.url = url
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
    }
}

public struct WarrenDesktopWebStatus: Hashable, Sendable {
    public var isRunning: Bool
    public var localURL: URL?
    /// The same Web UI reachable from devices on the local network.
    public var lanURL: URL?
    public var secureURL: URL?
    /// Relay origin used for the public route.
    public var relayURL: URL?
    /// Relay Host identity and route metadata.
    public var relayHostID: String?
    public var routeID: String?
    public var publicHostname: String?
    public var pathPrefix: String?
    public var authMode: String?
    /// The persisted user intent reported by the headless daemon. This is
    /// distinct from `canControl`, which only gates the Desktop controls.
    public var publicAccessEnabled: Bool
    /// True after Warren has authenticated to Relay and read the route.
    public var publicAccessAuthenticated: Bool
    public var canControl: Bool
    /// True while Relay reports an enabled public route. Independent of
    /// `isRunning`, which only reflects local Web reachability.
    public var tunnelRunning: Bool
    public var publicAccessBusy: Bool
    public var publicAccessError: String?

    public init(
        isRunning: Bool = false,
        localURL: URL? = nil,
        lanURL: URL? = nil,
        secureURL: URL? = nil,
        canControl: Bool = true,
        tunnelRunning: Bool = false,
        relayURL: URL? = nil,
        relayHostID: String? = nil,
        routeID: String? = nil,
        publicHostname: String? = nil,
        pathPrefix: String? = nil,
        authMode: String? = nil,
        publicAccessEnabled: Bool = false,
        publicAccessAuthenticated: Bool = false,
        publicAccessBusy: Bool = false,
        publicAccessError: String? = nil
    ) {
        self.isRunning = isRunning
        self.localURL = localURL
        self.lanURL = lanURL
        self.secureURL = secureURL
        self.relayURL = relayURL
        self.relayHostID = relayHostID
        self.routeID = routeID
        self.publicHostname = publicHostname
        self.pathPrefix = pathPrefix
        self.authMode = authMode
        self.publicAccessEnabled = publicAccessEnabled
        self.publicAccessAuthenticated = publicAccessAuthenticated
        self.canControl = canControl
        self.tunnelRunning = tunnelRunning
        self.publicAccessBusy = publicAccessBusy
        self.publicAccessError = publicAccessError
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
        case .publicAccess: WarrenPublicAccessCopy.publicEndpoint
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .local: "Local Web"
        case .lan: "LAN Web"
        case .publicAccess: WarrenPublicAccessCopy.publicEndpoint
        }
    }

    var canOpenInBrowser: Bool {
        self == .local || self == .publicAccess
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
    static func addresses(
        for status: WarrenDesktopWebStatus,
        includeLocalURL: Bool = true
    ) -> [WarrenDesktopWebAddress] {
        var addresses: [WarrenDesktopWebAddress] = []

        if includeLocalURL {
            append(.local, url: status.localURL, to: &addresses)
        }
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
    public let canControl: Bool
    public let canCopyLocalWebURL: Bool
    public let onStart: () -> Void
    /// Opens the canonical Public Access setup page in Settings.
    public let onOpenSettings: (() -> Void)?
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void
    public let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        status: WarrenDesktopWebStatus,
        canControl: Bool = true,
        canCopyLocalWebURL: Bool = true,
        onStart: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil,
        onStop: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onCopyURL: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.status = status
        self.canControl = canControl
        self.canCopyLocalWebURL = canCopyLocalWebURL
        self.onStart = onStart
        self.onOpenSettings = onOpenSettings
        self.onStop = onStop
        self.onOpenURL = onOpenURL
        self.onCopyURL = onCopyURL
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let addresses = presentedAddresses
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens, showsDismiss: true, showsTitle: true)
            WarrenDesktopChromeDivider()
            panelContent(addresses: addresses, tokens: tokens)
        }
        .frame(width: WarrenLayoutMetrics.webPopoverWidth, alignment: .leading)
        .warrenPresentationSurface(role: .popover, cornerRadius: WarrenRadius.base)
    }

    /// Content used by More's inline detail view. The outer More surface owns
    /// the close affordance and elevation, so this variant deliberately
    /// omits the Web panel's second border and duplicate close button.
    @ViewBuilder
    var inlineContent: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let addresses = presentedAddresses
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens, showsDismiss: false, showsTitle: false)
            WarrenDesktopChromeDivider()
            panelContent(addresses: addresses, tokens: tokens)
        }
    }

    private func header(
        tokens: WarrenColorTokens,
        showsDismiss: Bool,
        showsTitle: Bool
    ) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            if showsTitle {
                Image(systemName: "globe")
                    .font(WarrenTypography.navigationGroup)
                    .foregroundStyle(tokens.foreground)
                    .accessibilityHidden(true)
                Text("Web")
                    .font(WarrenTypography.popoverTitle)
                    .foregroundStyle(tokens.foreground)
            }
            Spacer()
            WarrenStatusIndicator(
                color: status.isRunning ? tokens.success : tokens.mutedForeground,
                accessibilityLabel: status.isRunning ? "Web is running" : "Web is stopped"
            )
            .accessibilityHidden(true)
            Text(status.isRunning ? "Running" : "Stopped")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
            if showsDismiss {
                WarrenDesktopWebIconButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Close Web panel",
                    accessibilityHint: "Dismiss the Web panel",
                    action: onDismiss
                )
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
    }

    @ViewBuilder
    private func panelContent(
        addresses: [WarrenDesktopWebAddress],
        tokens: WarrenColorTokens
    ) -> some View {
        if addresses.isEmpty {
            unavailableContent(tokens: tokens)
        } else {
            content(addresses: addresses, tokens: tokens)
        }
    }

    private var presentedAddresses: [WarrenDesktopWebAddress] {
        WarrenDesktopWebAddressPresentation.addresses(
            for: status,
            includeLocalURL: canCopyLocalWebURL
        )
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
                    onCopy: onCopyURL
                )
            }

            WarrenDesktopChromeDivider()
                .padding(.vertical, WarrenSpacing.xs)

            if status.secureURL == nil {
                publicAccessSetupHint(tokens: tokens)
            }

            WarrenDesktopWebPublicAccessRow(
                isActive: status.secureURL != nil,
                isAuthenticated: status.publicAccessAuthenticated,
                isEnabled: canControl && status.canControl && !status.publicAccessBusy,
                isBusy: status.publicAccessBusy,
                hasError: status.publicAccessError != nil,
                onStart: {
                    if status.publicAccessAuthenticated {
                        onStart()
                    } else if let onOpenSettings {
                        onOpenSettings()
                    }
                },
                onStop: onStop
            )

            if let error = status.publicAccessError, !error.isEmpty {
                Text(error)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Public Access error: \(error)")
            }
        }
        .padding(WarrenSpacing.medium)
    }

    private func publicAccessSetupHint(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text(WarrenPublicAccessCopy.title)
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground)
            Text("Configure Public Access in Settings.")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if let onOpenSettings {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.popoverItem))
                    .accessibilityIdentifier("public-access.open-settings")
            }
        }
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
    let onCopy: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let displayURL = address.kind == .publicAccess
            ? endpointWithoutFragment(address.url)
            : address.url
        HStack(spacing: WarrenSpacing.xs) {
            Text(address.kind.title)
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: address.kind == .publicAccess ? 104 : 36, alignment: .leading)
            Text(displayURL.absoluteString)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onOpen {
                WarrenDesktopWebIconButton(
                    systemImage: "arrow.up.right.square",
                    glyphSize: 14,
                    accessibilityLabel: "Open \(address.kind.accessibilityTitle) address",
                    accessibilityHint: "Open this address in the default browser",
                    action: onOpen
                )
            }
            WarrenDesktopWebIconButton(
                systemImage: "doc.on.doc",
                accessibilityLabel: "Copy \(address.kind.accessibilityTitle) address",
                accessibilityHint: "Copy this address to the clipboard",
                action: { onCopy(displayURL) }
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
        .accessibilityLabel("\(address.kind.accessibilityTitle) address: \(displayURL.absoluteString)")
    }

    private func endpointWithoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }
}

private struct WarrenDesktopWebPublicAccessRow: View {
    let isActive: Bool
    let isAuthenticated: Bool
    let isEnabled: Bool
    let isBusy: Bool
    let hasError: Bool
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
            Text(WarrenPublicAccessCopy.title)
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground)
            Spacer(minLength: 0)
            Text(isBusy ? "Working…" : (isActive ? "On" : "Off"))
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(isActive ? tokens.info : tokens.mutedForeground)
            WarrenDesktopWebCommandButton(
                title: isBusy
                    ? "Working…"
                    : (hasError && !isActive
                        ? "Retry"
                        : (isActive ? "Disable" : (isAuthenticated ? "Start" : "Configure"))),
                isEnabled: isEnabled,
                isEmphasized: isActive,
                accessibilityLabel: isActive
                    ? "Disable Public Access"
                    : (isAuthenticated
                        ? (hasError ? "Retry Public Access" : "Start Public Access")
                        : (hasError ? "Retry Public Access" : "Configure Public Access"))
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
        .accessibilityLabel(WarrenPublicAccessCopy.title)
        .accessibilityValue(isBusy ? "Working" : (isActive ? "On" : "Off"))
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
    var glyphSize: CGFloat = 11
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .medium))
                .frame(
                    width: WarrenLayoutMetrics.sidebarActionButtonSize,
                    height: WarrenLayoutMetrics.sidebarActionButtonSize
                )
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(
            width: WarrenLayoutMetrics.sidebarActionButtonSize,
            height: WarrenLayoutMetrics.sidebarActionButtonSize
        )
        .focused($isFocused)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .help(accessibilityLabel)
    }
}
