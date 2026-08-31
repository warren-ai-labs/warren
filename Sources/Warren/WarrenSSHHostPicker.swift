import SwiftUI
import AppKit
import WarrenDesignSystem

struct WarrenSSHHostPicker: View {
    @State private var hosts: [WarrenSSHHost]
    @State private var errorMessage: String?
    @State private var isLoading: Bool
    @State private var hoveredHostName: String?
    @FocusState private var closeButtonFocused: Bool

    let onConfigure: (WarrenSSHHost) -> Void
    let onDismiss: () -> Void
    let onRefresh: () async -> WarrenSSHHostCatalog.LoadResult
    private let loadOnAppear: Bool

    init(
        hosts: [WarrenSSHHost],
        errorMessage: String? = nil,
        loadOnAppear: Bool = false,
        onConfigure: @escaping (WarrenSSHHost) -> Void,
        onDismiss: @escaping () -> Void,
        onRefresh: @escaping () async -> WarrenSSHHostCatalog.LoadResult = {
            await Task.detached(priority: .utility) {
                WarrenSSHHostCatalog.loadResult(from: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"))
            }.value
        }
    ) {
        _hosts = State(initialValue: hosts)
        _errorMessage = State(initialValue: errorMessage)
        _isLoading = State(initialValue: loadOnAppear)
        self.onConfigure = onConfigure
        self.onDismiss = onDismiss
        self.onRefresh = onRefresh
        self.loadOnAppear = loadOnAppear
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            content(tokens: tokens)

            footer(tokens: tokens)
        }
        .frame(width: 560)
        .frame(minHeight: 440, idealHeight: 500, maxHeight: 620)
        .warrenPresentationSurface(role: .sheet, cornerRadius: WarrenRadius.large)
        .onExitCommand(perform: onDismiss)
        .task {
            guard loadOnAppear else { return }
            await refreshHosts()
        }
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(alignment: .top, spacing: WarrenSpacing.medium) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text("Add SSH Host")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text("Choose an alias from ~/.ssh/config to add it as an execution server.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: WarrenSpacing.standard)

            Button("Cancel", action: onDismiss)
                .font(.system(size: 14, weight: .regular))
                .buttonStyle(WarrenChromeButtonStyle(isFocused: closeButtonFocused))
                .focused($closeButtonFocused)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Close Add SSH Host")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.medium)
    }

    @ViewBuilder
    private func content(tokens: WarrenColorTokens) -> some View {
        if isLoading {
            loadingState(tokens: tokens)
        } else if hosts.isEmpty {
            emptyState(tokens: tokens)
        } else {
            hostList(tokens: tokens)
        }
    }

    private func loadingState(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.medium) {
            WarrenBrailleSpinner(size: 22, accessibilityLabel: "Reading SSH config")
            Text("Reading SSH config…")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(tokens.foreground)
            Text("Looking for hosts in ~/.ssh/config and its Include files.")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .padding(WarrenSpacing.large)
        .accessibilityElement(children: .combine)
    }

    private func emptyState(tokens: WarrenColorTokens) -> some View {
        let hasError = errorMessage != nil
        return VStack(spacing: WarrenSpacing.medium) {
            Text(hasError ? "Unable to read SSH config" : "No SSH hosts found")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(hasError ? tokens.destructive : tokens.foreground)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(tokens.destructive)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("SSH config error: \(errorMessage)")
            } else {
                Text("Add a Host entry to ~/.ssh/config and refresh this list.")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("No SSH hosts found")
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text("Example ~/.ssh/config")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                Text("Host my-vps\n  HostName 203.0.113.10\n  User root\n  Port 22")
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(tokens.foreground)
                    .lineSpacing(2)
                    .padding(WarrenSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tokens.inputSurface)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    .overlay {
                        RoundedRectangle(cornerRadius: WarrenRadius.small)
                            .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
                    }
            }
            .frame(maxWidth: 420)
            .padding(.top, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .padding(.horizontal, WarrenSpacing.large)
        .accessibilityElement(children: .contain)
    }

    private func hostList(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text("SSH HOSTS")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                    .tracking(0.8)
                Spacer(minLength: WarrenSpacing.standard)
                Text("\(hosts.count) \(hosts.count == 1 ? "host" : "hosts")")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
            }

            ScrollView {
                LazyVStack(spacing: WarrenSpacing.xs) {
                    ForEach(hosts) { host in
                        hostRow(host, tokens: tokens)
                    }
                }
                .padding(WarrenSpacing.xs)
            }
            .frame(minHeight: 260, maxHeight: 380)
            .background(tokens.inputSurface)
            .clipShape(.rect(cornerRadius: WarrenRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.medium)
                    .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
            }
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func hostRow(_ host: WarrenSSHHost, tokens: WarrenColorTokens) -> some View {
        let isHovered = hoveredHostName == host.name
        if host.supported {
            Button(action: { onConfigure(host) }) {
                hostRowContent(host, tokens: tokens, isHovered: isHovered)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hoveredHostName = isHovering ? host.name : nil
            }
            .accessibilityLabel("Configure SSH host \(host.name)")
            .accessibilityValue("\(host.user) at \(host.host), port \(host.port)")
            .accessibilityHint("Add this host as an execution server")
        } else {
            hostRowContent(host, tokens: tokens, isHovered: isHovered)
                .onHover { isHovering in
                    hoveredHostName = isHovering ? host.name : nil
                }
                .accessibilityElement(children: .contain)
        }
    }

    private func hostRowContent(
        _ host: WarrenSSHHost,
        tokens: WarrenColorTokens,
        isHovered: Bool
    ) -> some View {
        return HStack(alignment: .top, spacing: WarrenSpacing.medium) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                HStack(spacing: WarrenSpacing.small) {
                    Text(host.name)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)

                    Text(host.supported ? "Ready" : "Unsupported")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(host.supported ? tokens.mutedForeground : tokens.warning)
                }

                Text("\(host.user)@\(host.host):\(host.port)")
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let message = host.message {
                    Text(message)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(tokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !host.supported {
                    Text(fallbackText(for: host))
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: WarrenSpacing.medium)

            if host.supported {
                Text("Configure")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tokens.foreground)
                    .padding(.top, WarrenSpacing.xs)
            } else {
                Button {
                    copyFallback(for: host)
                } label: {
                    Text("Copy Fallback")
                        .font(.system(size: 12, weight: .light))
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: .system(size: 12, weight: .light)))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHint("Copy an external SSH forwarding command")
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? tokens.fillHover : Color.clear)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .opacity(host.supported ? 1 : 0.92)
    }

    private func footer(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            HStack(spacing: WarrenSpacing.medium) {
                Text("Changes to ~/.ssh/config appear without restarting Warren.")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Open SSH Config", action: openSSHConfig)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: .system(size: 14, weight: .light)))

                Button("Refresh", action: refreshHostsInTask)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: .system(size: 14, weight: .light)))
                    .disabled(isLoading)
            }
            .padding(.horizontal, WarrenSpacing.large)
            .padding(.vertical, WarrenSpacing.medium)
        }
    }

    private func openSSHConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // Ensure ~/.ssh exists and reveal it in Finder.
            let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(sshDir)
        }
    }

    private func refreshHostsInTask() {
        guard !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            await refreshHosts()
        }
    }

    private func refreshHosts() async {
        let result = await onRefresh()
        guard !Task.isCancelled else { return }
        hosts = result.hosts
        errorMessage = result.error
        isLoading = false
    }

    private func fallbackText(for host: WarrenSSHHost) -> String {
        if let kind = host.proxyKind {
            return "Fallback: run ssh -L 8789:127.0.0.1:8789 \(shellQuote(host.name)) externally (OpenSSH will apply its configured \(kind)), then add the local forward with 'warren endpoint add'."
        }
        return "Fallback: keep an external local forward and add it with 'warren endpoint add'."
    }

    private func copyFallback(for host: WarrenSSHHost) {
        let quotedName = shellQuote(host.name)
        let cmd = "ssh -L 8789:127.0.0.1:8789 \(quotedName)  # then: warren endpoint add \(quotedName) --url http://127.0.0.1:8789 --token '<TOKEN>' --use"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
