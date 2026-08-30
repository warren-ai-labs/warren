import SwiftUI
import AppKit

struct WarrenSSHHostPicker: View {
    @State private var hosts: [WarrenSSHHost]
    @State private var errorMessage: String?
    @State private var isLoading: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add SSH Host")
                        .font(.title3.weight(.semibold))
                    Text("Choose an alias from ~/.ssh/config to add it as an execution server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onDismiss)
            }
            .padding()

            Divider()

            if isLoading {
                loadingState
            } else if hosts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(hosts) { host in
                        hostRow(host)
                    }
                }
                .listStyle(.inset)
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task {
            guard loadOnAppear else { return }
            await refreshHosts()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Reading SSH config…")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Looking for hosts in ~/.ssh/config and its Include files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(errorMessage == nil ? "No SSH Hosts" : "Unable to read SSH config")
                .font(.headline)
            Text(errorMessage ?? "Add a Host entry to ~/.ssh/config and try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if errorMessage != nil {
                Text("Fix the file permissions or syntax, then retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Example ~/.ssh/config")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Host my-vps\n  HostName 203.0.113.10\n  User root\n  Port 22")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)
            HStack(spacing: 8) {
                Button("Open ~/.ssh/config") { openSSHConfig() }
                Button("Refresh") { refreshHostsInTask() }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Edits to ~/.ssh/config appear without restarting Warren.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing SSH hosts")
            } else {
                Button("Refresh") { refreshHostsInTask() }
                    .font(.caption)
            }
            Button("Open ~/.ssh/config") { openSSHConfig() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func hostRow(_ host: WarrenSSHHost) -> some View {
        if host.supported {
            Button(action: { onConfigure(host) }) {
                hostRowContent(host)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure SSH host \(host.name)")
            .accessibilityValue("\(host.user) at \(host.host), port \(host.port)")
            .accessibilityHint("Add this host as an execution server")
        } else {
            hostRowContent(host)
                .accessibilityElement(children: .contain)
        }
    }

    private func hostRowContent(_ host: WarrenSSHHost) -> some View {
        HStack(spacing: 10) {
            Image(systemName: host.supported ? "server.rack" : "exclamationmark.triangle")
                .foregroundStyle(host.supported ? Color.accentColor : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.body.weight(.medium))
                Text("\(host.user)@\(host.host):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = host.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !host.supported {
                    Text(fallbackText(for: host))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if host.supported {
                    Text("Configure")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button("Copy Fallback") {
                        copyFallback(for: host)
                    }
                    .font(.caption)
                }
            }
        }
        .opacity(host.supported ? 1 : 0.92)
    }

    private func openSSHConfig() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            // Ensure ~/.ssh exists and reveal it in Finder
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
