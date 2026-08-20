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

public struct WarrenDesktopWebPanel: View {
    public let status: WarrenDesktopWebStatus
    public let canShare: Bool
    public let onStart: () -> Void
    public let onStop: () -> Void
    public let onOpenURL: (URL) -> Void
    public let onCopyURL: (URL) -> Void
    public let onDismiss: () -> Void

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
        let tokens = WarrenColorTokens.resolved(for: .dark)
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)
            WarrenDesktopChromeDivider()
            if let url = status.localURL {
                content(url: url, tokens: tokens)
            } else {
                Text("Local Web is unavailable")
                    .font(WarrenTypography.popoverItem)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
        .frame(width: 340, alignment: .leading)
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
            Circle()
                .fill(status.isRunning ? tokens.success : tokens.mutedForeground)
                .frame(width: 7, height: 7)
            Text(status.isRunning ? "Running" : "Stopped")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(WarrenTypography.popoverMeta)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.mutedForeground)
            .accessibilityLabel("Close Web panel")
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.medium)
    }

    private func content(url: URL, tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            Text("Local address")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.6)

            webAddressField(url, tokens: tokens)

            HStack(spacing: WarrenSpacing.compact) {
                WarrenDesktopWebCommandButton(
                    title: "Open",
                    accessibilityLabel: "Open the web UI"
                ) {
                    onOpenURL(url)
                }
                WarrenDesktopWebCommandButton(
                    title: "Copy",
                    accessibilityLabel: "Copy the web address"
                ) {
                    onCopyURL(url)
                }
                WarrenDesktopWebCommandButton(
                    title: "Copy LAN",
                    isEnabled: status.lanURL != nil,
                    accessibilityLabel: "Copy the LAN web address"
                ) {
                    if let lanURL = status.lanURL {
                        onCopyURL(lanURL)
                    }
                }
                WarrenDesktopWebCommandButton(
                    title: status.secureURL == nil ? "Share" : "Stop",
                    isEnabled: canShare && status.canControl,
                    isEmphasized: status.secureURL != nil,
                    accessibilityLabel: status.secureURL == nil
                        ? "Share the Web UI publicly"
                        : "Stop public sharing"
                ) {
                    if status.secureURL == nil {
                        onStart()
                    } else {
                        onStop()
                    }
                }
            }

            if let secureURL = status.secureURL {
                Text("Public access")
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, WarrenSpacing.small)
                webAddressField(secureURL, tokens: tokens, copyAction: { onCopyURL(secureURL) })
            }
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.large)
    }

    private func webAddressField(
        _ url: URL,
        tokens: WarrenColorTokens,
        copyAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "link")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            Text(url.absoluteString)
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let copyAction {
                Button(action: copyAction) {
                    Image(systemName: "doc.on.doc")
                        .font(WarrenTypography.popoverMeta)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Copy web address")
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(minHeight: 38)
        .background(tokens.inputSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.small)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web address: \(url.absoluteString)")
    }
}

/// Inline command button used by the Web panel. Four equal-width commands
/// share one quiet row: plain text, a soft hover wash, and no border chrome.
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
                .frame(
                    maxWidth: .infinity,
                    minHeight: 34
                )
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
