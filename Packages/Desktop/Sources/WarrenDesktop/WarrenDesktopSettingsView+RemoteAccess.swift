import AppKit
import CoreImage
import SwiftUI
import WarrenDesignSystem

/// Settings → Remote Access: the Host's serverless (Bolthole) path to a phone.
///
/// This page answers one question the Relay page cannot: whether this Mac is
/// reachable through a stateless relay it does not operate, and which relay that
/// is. Everything here is the `remote.*` WebSocket API of the Host; the connect
/// code stays on the Host and the paired devices hold their own tokens.
extension WarrenDesktopSettingsView {
    func remoteAccessSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Connection") {
                remoteAccessStatusRow(palette: palette)

                WarrenSettingsRowDivider()

                remoteAccessDetails(palette: palette)
            }

            WarrenSettingsGroup(
                "Share with iPhone",
                footnote: "The link carries the connect code and one pairing invite, so treat it like a "
                    + "password until it expires. Scanning it adds that device to Devices below."
            ) {
                HStack(spacing: 12) {
                    Button(remoteShareBusy ? "Preparing…" : (remoteShare == nil ? "Create Link" : "New Link")) {
                        createRemoteShare()
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .disabled(
                        remoteShareBusy
                            || !remoteAccess.enabled
                            || onRemoteShare == nil
                    )
                    .accessibilityIdentifier("settings.remote.share")

                    if !remoteAccess.enabled {
                        Text("Turn remote access on first.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.meta)
                    }

                    Spacer(minLength: 0)

                    Button("Rotate Code…") {
                        requestRotateRemoteCode()
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .danger))
                    .disabled(remoteRotateBusy || onRotateRemote == nil)
                    .accessibilityIdentifier("settings.remote.rotate")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if let remoteShare {
                    WarrenSettingsRowDivider()
                    remoteShareReveal(remoteShare, palette: palette)
                }

                if let remoteShareError, !remoteShareError.isEmpty {
                    WarrenSettingsRowDivider()
                    WarrenSettingsStatusLine(tone: .failed, text: remoteShareError, isError: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                if let remoteRotateError, !remoteRotateError.isEmpty {
                    WarrenSettingsRowDivider()
                    WarrenSettingsStatusLine(tone: .failed, text: remoteRotateError, isError: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }

            WarrenSettingsGroup("Devices", accessory: "Paired through a share link") {
                if remoteAccess.devices == 0 {
                    WarrenSettingsEmptyRow(text: "No phone or browser has paired remotely yet.")
                } else {
                    WarrenSettingsListRow(
                        title: remoteAccess.devices == 1 ? "1 device" : "\(remoteAccess.devices) devices",
                        subtitle: "Each one authenticates with its own token on the Host.",
                        leading: {
                            Image(systemName: "iphone")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.inkQuiet)
                                .frame(width: 18)
                        },
                        trailing: { EmptyView() }
                    )
                }
            }
        }
        .onAppear { onLoadRemoteAccess?() }
        .onChange(of: remoteAccess) { _ in refreshRemoteShareQRCode() }
        .onChange(of: remoteShare) { _ in refreshRemoteShareQRCode() }
    }

    /// The page's header row: a dot, the relay carrying traffic, and the switch
    /// that opens or closes the path.
    func remoteAccessStatusRow(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 12) {
            WarrenSettingsStatusDot(
                tone: remoteAccessTone,
                ring: palette.box
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(remoteAccess.enabled
                    ? (remoteAccess.effectiveRelayURL.isEmpty ? "Serverless relay" : remoteAccess.effectiveRelayURL)
                    : "Not available remotely")
                    .font(remoteAccess.enabled
                        ? .system(size: 12.5, design: .monospaced)
                        : .system(size: 13))
                    .foregroundStyle(palette.inkBody)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(remoteAccess.stateText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.meta)
                    .fixedSize(horizontal: false, vertical: true)
                if remoteAccess.enabled, !remoteAccess.lastError.isEmpty {
                    Text(remoteAccess.lastError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.meta)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            WarrenSettingsSwitch(
                isOn: Binding(
                    get: { remoteAccess.enabled },
                    set: { setRemoteAccess(enabled: $0) }
                )
            )
            .disabled(remoteEnabledBusy || onSetRemoteEnabled == nil)
            .accessibilityLabel("Remote access")
            .accessibilityIdentifier("settings.remote.switch")
            .warrenSemanticElement(
                id: "settings.remote.switch",
                role: .button,
                label: "Remote access",
                value: remoteAccess.enabled ? "On" : "Off",
                isEnabled: !remoteEnabledBusy && onSetRemoteEnabled != nil,
                action: { setRemoteAccess(enabled: !remoteAccess.enabled) }
            )
        }
        .warrenSemanticElement(id: "settings.remote.status", role: .group, label: "Remote access")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
    }

    var remoteAccessTone: WarrenStatusTone {
        guard remoteAccess.enabled else { return .failed }
        switch remoteAccess.state.lowercased() {
        case "connected": return .ok
        case "error": return .failed
        default: return .warning
        }
    }

    /// The read-out that separates the two paths: which relay, whose relay, and
    /// how the Host authenticates pairings.
    func remoteAccessDetails(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenSettingsRow("Relay") {
                WarrenSettingsReadout(value: remoteAccess.effectiveRelayURL.isEmpty
                    ? "—"
                    : remoteAccess.effectiveRelayURL)
            }

            WarrenSettingsRowDivider()

            WarrenSettingsRow("Relay source", description: "Set when remote access is enabled.") {
                Text(remoteAccess.relaySourceText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.inkBody)
                    .accessibilityIdentifier("settings.remote.relay-source")
                    .warrenSemanticElement(
                        id: "settings.remote.relay-source",
                        role: .text,
                        label: remoteAccess.relaySourceText
                    )
            }

            WarrenSettingsRowDivider()

            WarrenSettingsRow("Pairing") {
                Text("End-to-end encrypted; the relay only forwards ciphertext.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.meta)
            }
        }
    }

    func remoteShareReveal(_ share: WarrenDesktopRemoteShare, palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsReveal {
            HStack(alignment: .top, spacing: 18) {
                if let image = remoteShareQRCode {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 108, height: 108)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(share.url.absoluteString)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(palette.inkBody)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    Text(remoteShareExpiryText(share))
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.meta)
                    WarrenSettingsCountdownBar(
                        expiresAt: share.expiresAt,
                        total: share.expiresIn
                    )
                    .frame(maxWidth: 220)
                    Button {
                        copyRemoteShare(share)
                    } label: {
                        let copied = copyFeedback.confirms(Self.remoteShareCopySource)
                        HStack(spacing: 6) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                            Text(copied ? "Copied" : "Copy Link")
                        }
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                }
            }
        }
    }

    func remoteShareExpiryText(_ share: WarrenDesktopRemoteShare) -> String {
        if let expiresAt = share.expiresAt {
            guard expiresAt > Date() else { return "Expired" }
            return "Expires \(expiresAt.formatted(date: .omitted, time: .standard))"
        }
        if share.expiresIn > 0 {
            return "Expires in \(formatPairingTTL(share.expiresIn))"
        }
        return "Expires soon"
    }

    static let remoteShareCopySource = "settings.remote.share.copy"

    func refreshRemoteShareQRCode() {
        guard let share = remoteShare else {
            remoteShareQRCode = nil
            return
        }
        remoteShareQRCode = qrCodeImage(for: share.url.absoluteString)
    }

    func copyRemoteShare(_ share: WarrenDesktopRemoteShare) {
        copyFeedback.copy(share.url.absoluteString, confirmingIn: Self.remoteShareCopySource)
    }

    func setRemoteAccess(enabled: Bool) {
        guard !remoteEnabledBusy, let onSetRemoteEnabled else { return }
        remoteEnabledBusy = true
        // A link made while remote access was on cannot work once it is off.
        if !enabled { clearRemoteShare() }
        onSetRemoteEnabled(enabled)
        // The switch reflects the Host, not the click: the page reloads the
        // reported state instead of assuming the request succeeded.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            remoteEnabledBusy = false
            onLoadRemoteAccess?()
        }
    }

    func createRemoteShare() {
        guard !remoteShareBusy, let onRemoteShare else { return }
        remoteShareBusy = true
        remoteShareError = nil
        onRemoteShare { result in
            Task { @MainActor in
                remoteShareBusy = false
                switch result {
                case .success(let share):
                    remoteShare = share
                    refreshRemoteShareQRCode()
                case .failure(let error):
                    remoteShareError = error.localizedDescription
                }
            }
        }
    }

    func clearRemoteShare() {
        remoteShare = nil
        remoteShareQRCode = nil
        remoteShareError = nil
    }

    func rotateRemoteCode() {
        guard !remoteRotateBusy, let onRotateRemote else { return }
        remoteRotateBusy = true
        remoteRotateError = nil
        // Rotation invalidates the open link with the code it carried.
        clearRemoteShare()
        onRotateRemote { result in
            Task { @MainActor in
                remoteRotateBusy = false
                if case let .failure(error) = result {
                    remoteRotateError = error.localizedDescription
                }
                onLoadRemoteAccess?()
            }
        }
    }
}
