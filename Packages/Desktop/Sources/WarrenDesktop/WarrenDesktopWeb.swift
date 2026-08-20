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

public struct WarrenDesktopWebMenu: View {
    public let status: WarrenDesktopWebStatus
    public let canShare: Bool
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        status: WarrenDesktopWebStatus,
        canShare: Bool = true,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onCopyURL: @escaping (URL) -> Void
    ) {
        self.status = status
        self.canShare = canShare
        self.onStart = onStart
        self.onStop = onStop
        self.onOpenURL = onOpenURL
        self.onCopyURL = onCopyURL
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Menu {
            Text(status.isRunning ? "Web is running" : "Web is stopped")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
            Divider()
            if let url = status.localURL {
                Button("Open Web UI") { onOpenURL(url) }
                Button("Copy Web Address") { onCopyURL(url) }
            } else {
                Button("Local Web is unavailable") {}
                    .disabled(true)
            }
            if let lanURL = status.lanURL {
                Button("Copy LAN Address") { onCopyURL(lanURL) }
            }
            if let secureURL = status.secureURL {
                Button("Copy Public Address") { onCopyURL(secureURL) }
                if canShare && status.canControl {
                    Button("Stop Public Sharing") { onStop() }
                }
            } else if canShare && status.canControl {
                Button("Start Public Sharing") { onStart() }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .foregroundStyle(
            status.tunnelRunning
                ? tokens.info
                : (status.isRunning ? tokens.success : tokens.mutedForeground)
        )
        .accessibilityLabel("Web")
        .accessibilityHint(
            status.tunnelRunning
                ? "Public sharing is on"
                : (status.isRunning ? "Web is running" : "Web is stopped")
        )
    }
}
