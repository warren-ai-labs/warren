import AppKit
import CoreImage
import SwiftUI
import WarrenDesignSystem

/// Settings → Access → Serverless relay: the Host's Bolthole path to a phone
/// or a browser.
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
                "Share",
                footnote: "Scan the QR code with Warren on iPhone, or open the Web link in any browser. "
                    + "Both carry the connect code and one pairing invite, so treat them like a "
                    + "password until they expire."
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
                        Text("Turn on Serverless relay first.")
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
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if let remoteShare {
                    WarrenSettingsRowDivider()
                    remoteShareReveal(remoteShare, palette: palette)
                }

                if let remoteShareError, !remoteShareError.isEmpty {
                    WarrenSettingsRowDivider()
                    WarrenSettingsStatusLine(tone: .failed, text: remoteShareError, isError: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                if let remoteRotateError, !remoteRotateError.isEmpty {
                    WarrenSettingsRowDivider()
                    WarrenSettingsStatusLine(tone: .failed, text: remoteRotateError, isError: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
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
                Text(remoteAccess.enabled ? remoteAccess.displayedRelay : "Serverless relay is off")
                    .font(remoteAccess.enabled && remoteAccess.isSelfHostedRelay
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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

    /// Which relay carries the serverless path: the official one, or the
    /// user's own. Choosing "My own" reveals a URL field; nothing changes on the
    /// Host until that URL is applied.
    func remoteAccessDetails(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenSettingsRow(
                "Relay",
                description: remoteRelayUsesOwn
                    ? "Your own Bolthole relay. The deploy guide above shows how to run one."
                    : "The official relay needs no setup."
            ) {
                WarrenSettingsSegmented(
                    options: [(false, "Official"), (true, "My own")],
                    selection: Binding(
                        get: { remoteRelayUsesOwn },
                        set: { chooseOwnRemoteRelay($0) }
                    ),
                    accessibilityID: "settings.remote.relay-choice"
                )
                .disabled(remoteEnabledBusy || onSetRemoteRelay == nil)
            }

            WarrenSettingsRowDivider()

            if remoteRelayUsesOwn {
                WarrenSettingsRow("Relay URL") {
                    HStack(spacing: 8) {
                        WarrenSettingsTextField(
                            placeholder: "https://relay.example.com",
                            text: $remoteCustomRelayURL,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            accessibilityID: "settings.remote.relay-url"
                        )
                        // Shown only when there is something to apply, so a
                        // relay already in use reads as a value, not a form.
                        if canApplyOwnRemoteRelay {
                            Button("Use") { applyOwnRemoteRelay() }
                                .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                                .fixedSize()
                                .accessibilityIdentifier("settings.remote.relay-apply")
                        }
                    }
                }
            } else {
                // The official relay's address is not shown: it gives an
                // onlooker nothing to use, and the Host already knows it.
                WarrenSettingsRow("Relay URL") {
                    Text("Built in")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.meta)
                        .accessibilityIdentifier("settings.remote.relay-source")
                        .warrenSemanticElement(
                            id: "settings.remote.relay-source",
                            role: .text,
                            label: remoteAccess.relaySourceText
                        )
                }
            }
        }
        .onAppear(perform: seedRemoteRelayURL)
        .onChange(of: remoteAccess) { _ in seedRemoteRelayURL() }
    }

    /// "My own" is shown while the Host carries its own relay, or while the
    /// user has picked it and not yet applied a URL.
    var remoteRelayUsesOwn: Bool {
        remoteAccess.isSelfHostedRelay || remoteRelayChoosingOwn
    }

    var canApplyOwnRemoteRelay: Bool {
        let value = remoteCustomRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, onSetRemoteRelay != nil, !remoteEnabledBusy,
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else {
            return false
        }
        return !(remoteAccess.isSelfHostedRelay && remoteAccess.enabled && value == remoteAccess.configuredRelayURL)
    }

    func chooseOwnRemoteRelay(_ own: Bool) {
        if own {
            remoteRelayChoosingOwn = true
            return
        }
        remoteRelayChoosingOwn = false
        // Going back to the official relay only touches the Host when it is on
        // another one; picking "Official" on a Host already using it is a no-op.
        if remoteAccess.isSelfHostedRelay {
            applyRemoteRelay("default")
        }
    }

    func applyOwnRemoteRelay() {
        guard canApplyOwnRemoteRelay else { return }
        applyRemoteRelay(remoteCustomRelayURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func applyRemoteRelay(_ value: String) {
        guard !remoteEnabledBusy, let onSetRemoteRelay else { return }
        remoteEnabledBusy = true
        // A link names the relay it was made for, so it stops working here.
        clearRemoteShare()
        onSetRemoteRelay(value)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            remoteEnabledBusy = false
            remoteRelayChoosingOwn = false
            onLoadRemoteAccess?()
        }
    }

    func seedRemoteRelayURL() {
        if remoteAccess.isSelfHostedRelay, remoteCustomRelayURL.isEmpty {
            remoteCustomRelayURL = remoteAccess.configuredRelayURL
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
                    // The link is not printed: it names the relay and carries
                    // the connect code, and the QR code and the copy buttons
                    // hand it on without putting it on screen.
                    Text("Scan with Warren on iPhone, or copy a link.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.inkBody)
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
                            Text(copied ? "Copied" : "Copy App Link")
                        }
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    if let webURL = share.webURL {
                        Button {
                            copyFeedback.copy(webURL.absoluteString, confirmingIn: Self.remoteShareWebCopySource)
                        } label: {
                            let copied = copyFeedback.confirms(Self.remoteShareWebCopySource)
                            HStack(spacing: 6) {
                                Image(systemName: copied ? "checkmark" : "globe").font(.system(size: 11))
                                Text(copied ? "Copied" : "Copy Web Link")
                            }
                        }
                        .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                        .help("Opens this Host in a browser, end-to-end encrypted through the relay.")
                        .accessibilityIdentifier("settings.remote.share.copy-web")
                    }
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
    static let remoteShareWebCopySource = "settings.remote.share.copy-web"

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
