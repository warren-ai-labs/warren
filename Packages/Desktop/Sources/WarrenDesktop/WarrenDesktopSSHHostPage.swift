import SwiftUI

/// One SSH alias from `~/.ssh/config`, in the shape the Add SSH Host page
/// draws. The Desktop never reads the SSH catalog itself; the app maps its
/// own model into this.
public struct WarrenDesktopSSHHostOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// `user@host:port`, monospaced on the row.
    public let route: String
    public let isSupported: Bool
    /// Why an unsupported alias cannot be added, shown as its tooltip.
    public let reason: String?

    public init(
        id: String,
        name: String,
        route: String,
        isSupported: Bool,
        reason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.route = route
        self.isSupported = isSupported
        self.reason = reason
    }
}

public struct WarrenDesktopSSHHostLoadResult: Sendable {
    public let hosts: [WarrenDesktopSSHHostOption]
    public let error: String?

    public init(hosts: [WarrenDesktopSSHHostOption], error: String? = nil) {
        self.hosts = hosts
        self.error = error
    }
}

/// What the app supplies so the Desktop can draw the Add SSH Host page
/// without knowing the SSH catalog or how an alias becomes an endpoint.
public struct WarrenDesktopSSHHostPageModel {
    public let load: () async -> WarrenDesktopSSHHostLoadResult
    public let onAdd: (WarrenDesktopSSHHostOption) -> Void
    public let onCopyFallback: (WarrenDesktopSSHHostOption) -> Void
    public let onOpenConfig: () -> Void

    public init(
        load: @escaping () async -> WarrenDesktopSSHHostLoadResult,
        onAdd: @escaping (WarrenDesktopSSHHostOption) -> Void,
        onCopyFallback: @escaping (WarrenDesktopSSHHostOption) -> Void,
        onOpenConfig: @escaping () -> Void
    ) {
        self.load = load
        self.onAdd = onAdd
        self.onCopyFallback = onCopyFallback
        self.onOpenConfig = onOpenConfig
    }
}

/// The Add SSH Host page: the aliases in `~/.ssh/config`, drawn on the menu
/// grid. Selecting one adds it; an alias OpenSSH cannot forward is a disabled
/// row with a Copy Fallback action on hover.
struct WarrenDesktopSSHHostListView: View {
    let model: WarrenDesktopSSHHostPageModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var hosts: [WarrenDesktopSSHHostOption] = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var hoveredID: String?

    private typealias Metrics = WarrenDesktopMenuMetrics

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: "SSH HOSTS") {
                // The header's one action, on the shared inline button so it
                // hovers and tooltips like every other menu action.
                WarrenDesktopMenuInlineButton(
                    systemImage: "arrow.clockwise",
                    label: "Refresh SSH hosts",
                    action: refreshInTask
                )
                .disabled(isLoading)
                .opacity(isLoading ? 0.42 : 1)
            }

            content(palette: palette)

            WarrenDesktopMenuDivider()

            openConfigRow(palette: palette)
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private func content(palette: WarrenDesktopMenuPalette) -> some View {
        if isLoading && hosts.isEmpty {
            messageRow("Reading SSH config…", palette: palette)
        } else if let error, hosts.isEmpty {
            messageRow(error, palette: palette, isError: true)
        } else if hosts.isEmpty {
            messageRow("No SSH hosts found in ~/.ssh/config.", palette: palette)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hosts) { host in
                        hostRow(host, palette: palette)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func messageRow(
        _ text: String,
        palette: WarrenDesktopMenuPalette,
        isError: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(isError ? palette.dangerText : palette.meta)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func hostRow(_ host: WarrenDesktopSSHHostOption, palette: WarrenDesktopMenuPalette) -> some View {
        let isHot = hoveredID == host.id
        if host.isSupported {
            Button {
                model.onAdd(host)
            } label: {
                hostRowContent(host, palette: palette, isHot: isHot)
            }
            .buttonStyle(WarrenDesktopMenuRowStyle())
            .help(host.route)
            .accessibilityLabel("Add SSH host \(host.name)")
            .accessibilityValue(host.route)
            .accessibilityHint("Add this Host to Warren")
            .onHover { hover in hoveredID = hover ? host.id : (hoveredID == host.id ? nil : hoveredID) }
        } else {
            hostRowContent(host, palette: palette, isHot: isHot)
                .overlay(alignment: .trailing) {
                    WarrenDesktopMenuInlineButton(
                        systemImage: "doc.on.doc",
                        label: "Copy Fallback",
                        action: { model.onCopyFallback(host) }
                    )
                    .padding(.trailing, Metrics.rowHorizontalPadding - 2)
                    .opacity(isHot ? 1 : 0)
                }
                .help(host.reason ?? "This alias cannot be forwarded by OpenSSH")
                .accessibilityElement(children: .contain)
                .onHover { hover in hoveredID = hover ? host.id : (hoveredID == host.id ? nil : hoveredID) }
        }
    }

    private func hostRowContent(
        _ host: WarrenDesktopSSHHostOption,
        palette: WarrenDesktopMenuPalette,
        isHot: Bool
    ) -> some View {
        HStack(spacing: Metrics.iconSpacing) {
            WarrenDesktopMenuTile(
                initial: String(host.name.prefix(1)).lowercased(),
                isFailed: !host.isSupported,
                isHot: isHot
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHot && host.isSupported ? palette.rowHoverText : palette.rowText)
                Text(host.route)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.meta)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.twoLineRowHeight, alignment: .leading)
        .contentShape(.rect)
        .opacity(host.isSupported ? 1 : 0.42)
    }

    private func openConfigRow(palette: WarrenDesktopMenuPalette) -> some View {
        Button(action: model.onOpenConfig) {
            HStack(spacing: Metrics.iconSpacing) {
                WarrenDesktopMenuRowIcon(systemImage: "doc.text")
                Text("Open ~/.ssh/config")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.rowText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .accessibilityLabel("Open SSH config")
    }

    private func refreshInTask() {
        guard !isLoading else { return }
        isLoading = true
        Task { await refresh() }
    }

    private func refresh() async {
        let result = await model.load()
        guard !Task.isCancelled else { return }
        hosts = result.hosts
        error = result.error
        isLoading = false
    }
}
