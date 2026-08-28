import SwiftUI
import AppKit

struct WarrenSSHHostPicker: View {
    let hosts: [WarrenSSHHost]
    let onConfigure: (WarrenSSHHost) -> Void
    let onDismiss: () -> Void

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

            if hosts.isEmpty {
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
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No SSH Hosts")
                .font(.headline)
            Text("Add a Host entry to ~/.ssh/config and try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                Button("Refresh") { refreshHosts() }
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
            Button("Open ~/.ssh/config") { openSSHConfig() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func hostRow(_ host: WarrenSSHHost) -> some View {
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
                    Text("Fallback: ssh -J bastion \(host.name) or keep an external 'ssh -L 8789:127.0.0.1:8789 \(host.name)' and use 'warren endpoint add'.")
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard host.supported else { return }
            onConfigure(host)
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

    private func refreshHosts() {
        // Dismiss and let the caller reload – the CompositionRoot reloads on present.
        onDismiss()
    }

    private func copyFallback(for host: WarrenSSHHost) {
        let cmd = "ssh -L 8789:127.0.0.1:8789 \(host.name)  # then: warren endpoint add \(host.name) --url http://127.0.0.1:8789 --token <token> --use"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }
}
