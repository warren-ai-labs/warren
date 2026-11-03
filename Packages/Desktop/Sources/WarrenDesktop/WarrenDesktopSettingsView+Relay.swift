import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopSettingsView {
    // MARK: - Relay

    func relaySection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Connection") {
                HStack(spacing: 12) {
                    WarrenSettingsStatusDot(
                        tone: relaySettings.isEnrolled
                            ? (relaySettings.enabled ? .ok : .warning)
                            : .failed,
                        ring: palette.box
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relaySettings.isEnrolled
                            ? (relaySettings.relayURL.isEmpty ? "Relay" : relaySettings.relayURL)
                            : "Not configured")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(palette.inkBody)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(relaySettings.isEnrolled
                            ? "Enrolled. Reconnects on its own after sleep."
                            : "Enter an enrollment key from your Relay administrator to connect this Host.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.meta)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if relaySettings.isEnrolled {
                        // The word "Paused" said the same thing while being a
                        // control the reader had to find elsewhere.
                        WarrenSettingsSwitch(
                            isOn: Binding(
                                get: { relaySettings.enabled },
                                set: { onSetRelayEnabled?($0) }
                            )
                        )
                        .disabled(onSetRelayEnabled == nil || relayResetBusy)
                        .accessibilityLabel("Relay")
                        .accessibilityIdentifier("settings.relay.switch")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 48)

                WarrenSettingsRowDivider()

                relayConnectionForm(palette: palette)
                    .warrenSemanticElement(
                        id: "settings.relay.connection",
                        role: .group,
                        label: "Relay connection"
                    )
            }

            if relaySettings.isEnrolled {
                WarrenSettingsGroup("Share with iPhone") {
                    WarrenSettingsRow(
                        "Pairing Invite",
                        description: "A reusable link for Warren on iPhone or any browser."
                    ) {
                        Button(relayInviteBusy ? "Preparing…" : "Create Invite") {
                            createRelayInvite()
                        }
                        .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                        .disabled(relayInviteBusy || onRelayPairing == nil)
                        .accessibilityIdentifier("settings.relay.share")
                        .warrenSemanticElement(
                            id: "settings.relay.share",
                            role: .button,
                            label: "Share with iPhone",
                            isEnabled: !relayInviteBusy && onRelayPairing != nil,
                            action: createRelayInvite
                        )
                    }

                    if let relayInvite {
                        WarrenSettingsRowDivider()
                        relayInviteReveal(relayInvite, palette: palette)
                    }

                    if let relayInviteError, !relayInviteError.isEmpty {
                        WarrenSettingsRowDivider()
                        WarrenSettingsStatusLine(tone: .failed, text: relayInviteError, isError: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }

                relayDevicesSection(palette: palette)
            }
        }
        .onAppear(perform: seedRelayFields)
        .onChange(of: relaySettings) { _ in seedRelayFields() }
    }

    func relayConnectionForm(palette: WarrenSettingsPalette) -> some View {
        // Rows carry their own inset, like every other group's. The form used
        // to be padded again on top of that, so its labels and fields sat 14pt
        // in from the status row above them and from every other page.
        VStack(alignment: .leading, spacing: 0) {
            WarrenSettingsRow("Relay URL") {
                WarrenSettingsTextField(
                    placeholder: "https://relay.example.com",
                    text: $relayRegistrationURL,
                    monospaced: true,
                    width: WarrenSettingsMetrics.fieldWidth,
                    accessibilityID: "settings.relay.join-url"
                )
                .warrenSemanticElement(id: "settings.relay.join-url", role: .text, label: "Relay URL")
            }

            WarrenSettingsRowDivider()

            WarrenSettingsRow("Enrollment key") {
                WarrenSettingsTextField(
                    placeholder: "XXXX-XXXX-XXXX-XXXX",
                    text: $relayEnrollmentKey,
                    isSecure: true,
                    monospaced: true,
                    width: WarrenSettingsMetrics.fieldWidth,
                    accessibilityID: "settings.relay.enrollment-key"
                )
                .warrenSemanticElement(id: "settings.relay.enrollment-key", role: .text, label: "Relay enrollment key")
            }

            WarrenSettingsRowDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button(relayEnrollmentBusy ? "Connecting…" : "Connect Relay") {
                        enrollRelay()
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .disabled(
                        relayEnrollmentBusy
                            || relayResetBusy
                            || onRelayEnroll == nil
                            || relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || relayEnrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("settings.relay.connect")
                    .warrenSemanticElement(
                        id: "settings.relay.connect",
                        role: .button,
                        label: "Connect Relay",
                        isEnabled: !relayEnrollmentBusy
                            && !relayResetBusy
                            && onRelayEnroll != nil
                            && !relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !relayEnrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: enrollRelay
                    )

                    Spacer()

                    Button("Reset Enrollment…") {
                        confirmation = .resetRelay
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .danger))
                    .disabled(relayEnrollmentBusy || relayResetBusy || onResetRelay == nil)
                    .accessibilityIdentifier("settings.relay.reset")
                    .warrenSemanticElement(
                        id: "settings.relay.reset",
                        role: .button,
                        label: "Reset local Relay enrollment",
                        isEnabled: !relayEnrollmentBusy && !relayResetBusy && onResetRelay != nil,
                        action: { confirmation = .resetRelay }
                    )
                }

                if let relayEnrollmentError, !relayEnrollmentError.isEmpty {
                    WarrenSettingsStatusLine(tone: .failed, text: relayEnrollmentError, isError: true)
                }
                if !relaySettings.lastError.isEmpty {
                    WarrenSettingsStatusLine(tone: .warning, text: relaySettings.lastError)
                }
                if let relayResetError, !relayResetError.isEmpty {
                    WarrenSettingsStatusLine(tone: .failed, text: relayResetError, isError: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    func relayInviteReveal(_ invite: WarrenDesktopRelayInvite, palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsReveal {
            HStack(alignment: .top, spacing: 18) {
                if let image = relayInviteQRCode {
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
                    Text(invite.url.absoluteString)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(palette.inkBody)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                    Text(relayInviteExpiryText(invite))
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.meta)
                    WarrenSettingsCountdownBar(
                        expiresAt: invite.expiresAt,
                        total: invite.expiresIn
                    )
                    .frame(maxWidth: 220)
                    Button {
                        copyRelayInvite(invite)
                    } label: {
                        let copied = copyFeedback.confirms(Self.relayInviteCopySource)
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

    func relayDevicesSection(palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsGroup("Devices", accessory: "Phones and browsers with access") {
            if relayDevices.isEmpty {
                WarrenSettingsEmptyRow(text: "No other devices are currently associated.")
            } else {
                ForEach(Array(relayDevices.enumerated()), id: \.element.id) { index, device in
                    let name = device.clientID.isEmpty ? "Native device" : device.clientID
                    if index > 0 { WarrenSettingsRowDivider() }
                    WarrenSettingsListRow(
                        title: name,
                        subtitle: device.lastSeenAt.map { "Last active \($0.formatted(.relative(presentation: .named)))" } ?? "Last active unavailable",
                        leading: {
                            Image(systemName: "iphone")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.inkQuiet)
                                .frame(width: 18)
                        },
                        trailing: {
                            Button("Revoke…") {
                                confirmation = .revokeDevice(id: device.id, name: name)
                            }
                            .buttonStyle(WarrenSettingsButtonStyle(kind: .danger))
                            .disabled(onRevokeRelayDevice == nil)
                            .accessibilityIdentifier("settings.relay.device.revoke.\(device.id)")
                        }
                    )
                    if let error = relayRevokeErrors[device.id] {
                        WarrenSettingsStatusLine(tone: .failed, text: error, isError: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .onAppear { onLoadRelayDevices?() }
    }

    // MARK: - LAN pairing

    func lanPairingSection(palette: WarrenSettingsPalette) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            lanPairingContent(at: timeline.date, palette: palette)
        }
    }

    func lanPairingContent(at date: Date, palette: WarrenSettingsPalette) -> some View {
        let isOpen = lanPairingIsOpen(at: date)
        return VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup(
                "Pairing window",
                footnote: "Only trust an iPhone you can see. The window closes on its own; turning it off ends it early."
            ) {
                WarrenSettingsToggleRow(
                    title: "Pairing Window",
                    description: "Opens a short window in which an iPhone on this network can pair with a PIN.",
                    isOn: Binding(
                        get: { isOpen },
                        set: { setLANPairing(enabled: $0) }
                    ),
                    isEnabled: !lanPairingBusy && onLANPairing != nil,
                    accessibilityID: "settings.lan-pairing.toggle"
                )

                if isOpen {
                    WarrenSettingsRowDivider()
                    WarrenSettingsReveal {
                        HStack(spacing: 18) {
                            Text(lanPairing.pin.isEmpty ? "------" : lanPairing.pin)
                                .font(.system(size: 28, weight: .medium, design: .monospaced))
                                .tracking(3)
                                .foregroundStyle(palette.ink)
                                .accessibilityLabel("Pairing PIN \(lanPairing.pin)")
                                .accessibilityIdentifier("settings.lan-pairing.pin")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enter this PIN on the iPhone.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.meta)
                                Text(lanPairingExpiryText(at: date))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.meta)
                                WarrenSettingsCountdownBar(
                                    expiresAt: lanPairing.expiresAt,
                                    total: lanPairing.expiresIn
                                )
                                .frame(width: 180)
                            }
                        }
                    }
                }

                if let lanPairingError, !lanPairingError.isEmpty {
                    WarrenSettingsRowDivider()
                    WarrenSettingsStatusLine(tone: .failed, text: lanPairingError, isError: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        .warrenSemanticElement(id: "settings.lan-pairing", role: .group, label: "LAN pairing")
    }

    func lanPairingIsOpen(at date: Date) -> Bool {
        guard lanPairing.enabled else { return false }
        if let expiresAt = lanPairing.expiresAt {
            return expiresAt > date
        }
        return lanPairing.expiresIn > 0
    }

    func lanPairingExpiryText(at date: Date) -> String {
        if let expiresAt = lanPairing.expiresAt {
            guard expiresAt > date else { return "Expired" }
            return "Expires \(expiresAt.formatted(date: .omitted, time: .standard))"
        }
        if lanPairing.expiresIn > 0 {
            return "Expires in \(formatPairingTTL(lanPairing.expiresIn))"
        }
        return "Expires soon"
    }

    func formatPairingTTL(_ seconds: Int) -> String {
        if seconds >= 60 { return "\(max(1, seconds / 60)) min" }
        return "\(max(1, seconds)) sec"
    }

    func setLANPairing(enabled: Bool) {
        guard !lanPairingBusy, let onLANPairing else { return }
        lanPairingBusy = true
        lanPairingError = nil
        onLANPairing(enabled) { result in
            Task { @MainActor in
                lanPairingBusy = false
                if case let .failure(error) = result {
                    lanPairingError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Public access

    /// The page's own state, as a header row: a dot, what it is serving, and a
    /// switch at the tail. The word "Enabled" told the same thing while also
    /// being a control the user had to find elsewhere.
    func publicAccessStatusRow(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 12) {
            WarrenSettingsStatusDot(
                tone: webStatus.tunnelRunning
                    ? .ok
                    : ((webStatus.publicAccessError?.isEmpty == false) ? .failed : .warning),
                ring: palette.box
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(webStatus.tunnelRunning
                    ? (webStatus.secureURL?.absoluteString ?? webStatus.publicHostname ?? "")
                    : "Not published")
                    // An address is code; the state is a sentence.
                    .font(webStatus.tunnelRunning
                        ? .system(size: 12.5, design: .monospaced)
                        : .system(size: 13))
                    .foregroundStyle(palette.inkBody)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(webStatus.tunnelRunning
                    ? "Anyone with the link can open this Host's Web UI."
                    : "Turn on to publish at the route below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            WarrenSettingsSwitch(
                isOn: Binding(
                    get: { webStatus.tunnelRunning },
                    set: { publish in
                        if publish {
                            onWebTest?(
                                publicAccessHostname.trimmingCharacters(in: .whitespacesAndNewlines),
                                publicAccessPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        } else {
                            onWebStop?()
                        }
                    }
                )
            )
            .disabled(webStatus.publicAccessBusy || onWebTest == nil || onWebStop == nil)
            .accessibilityLabel("Public Access")
            .accessibilityIdentifier("settings.public-access.switch")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
    }

    func publicAccessSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                WarrenSettingsGroup {
                    publicAccessStatusRow(palette: palette)
                }

                WarrenSettingsGroup(
                    "Route",
                    footnote: "Public Access and the owner's Relay traffic share this host's Relay enrollment and Host Secret."
                ) {
                    WarrenSettingsRow("Public Hostname", description: "Assigned by your Relay.") {
                        WarrenSettingsTextField(
                            placeholder: "Relay-assigned hostname",
                            text: $publicAccessHostname,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            accessibilityID: "settings.public-access.public-hostname"
                        )
                    }
                    WarrenSettingsRowDivider()
                    WarrenSettingsRow("Path Prefix") {
                        WarrenSettingsTextField(
                            placeholder: "/",
                            text: $publicAccessPathPrefix,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            accessibilityID: "settings.public-access.path-prefix"
                        )
                    }
                    if let relayURL = webStatus.relayURL {
                        WarrenSettingsRowDivider()
                        WarrenSettingsRow(WarrenPublicAccessCopy.relayURL) {
                            WarrenSettingsReadout(value: relayURL.absoluteString)
                        }
                    }
                    if let publicEndpoint = webStatus.secureURL {
                        WarrenSettingsRowDivider()
                        WarrenSettingsRow(WarrenPublicAccessCopy.publicEndpoint) {
                            WarrenSettingsReadout(value: publicEndpoint.absoluteString, copyable: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(publicAccessActionTitle) {
                        onWebTest?(
                            publicAccessHostname.trimmingCharacters(in: .whitespacesAndNewlines),
                            publicAccessPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .primary))
                    .disabled(webStatus.publicAccessBusy || onWebTest == nil)
                    .accessibilityIdentifier("settings.public-access.save-test")

                    Button("Turn Off") {
                        onWebStop?()
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .disabled(!webStatus.tunnelRunning || onWebStop == nil)
                    .accessibilityIdentifier("settings.public-access.stop")

                    if hasPublicAccessSetup {
                        Button("Reset") {
                            onWebReset?()
                        }
                        .buttonStyle(WarrenSettingsButtonStyle(kind: .plain))
                        .disabled(webStatus.publicAccessBusy || onWebReset == nil)
                        .accessibilityIdentifier("settings.public-access.reset")
                    }

                    statusLabel(palette: palette)
                }
                .padding(.leading, 14)
            }
        }
        .onAppear(perform: seedPublicAccessFields)
        .onChange(of: webStatus.publicHostname) { _ in seedPublicAccessFields() }
        .onChange(of: webStatus.pathPrefix) { _ in seedPublicAccessFields() }
        .onChange(of: webStatus.publicAccessEnabled) { _ in clearPublicAccessFieldsIfReset() }
        .onChange(of: webStatus.publicAccessAuthenticated) { _ in clearPublicAccessFieldsIfReset() }
    }

    @ViewBuilder
    func statusLabel(palette: WarrenSettingsPalette) -> some View {
        if webStatus.publicAccessBusy {
            WarrenSettingsStatusLine(tone: .busy, text: "Testing connection…")
        } else if let error = webStatus.publicAccessError, !error.isEmpty {
            WarrenSettingsStatusLine(tone: .failed, text: error, isError: true)
        } else if webStatus.tunnelRunning {
            WarrenSettingsStatusLine(tone: .ok, text: "Public Access is on")
        } else if webStatus.publicAccessAuthenticated {
            WarrenSettingsStatusLine(tone: .ok, text: "Connected")
        }
    }

    var publicAccessActionTitle: String {
        webStatus.publicAccessBusy ? "Testing…" : "Save & Test"
    }

    var hasPublicAccessSetup: Bool {
        webStatus.publicAccessAuthenticated
            || webStatus.publicAccessEnabled
            || webStatus.relayURL != nil
            || webStatus.relayHostID != nil
            || webStatus.routeID != nil
    }

    // MARK: - Relay actions

    func createRelayInvite() {
        guard !relayInviteBusy, let onRelayPairing else { return }
        relayInviteBusy = true
        relayInviteError = nil
        onRelayPairing { result in
            Task { @MainActor in
                relayInviteBusy = false
                switch result {
                case let .success(value):
                    relayInvite = value
                    relayInviteQRCode = qrCodeImage(for: value.url.absoluteString)
                    relayInviteError = nil
                case let .failure(error):
                    relayInviteError = error.localizedDescription
                }
            }
        }
    }

    static let relayInviteCopySource = "settings.relay-invite"

    func copyRelayInvite(_ invite: WarrenDesktopRelayInvite) {
        copyFeedback.copy(invite.url.absoluteString, confirmingIn: Self.relayInviteCopySource)
    }

    func relayInviteExpiryText(_ invite: WarrenDesktopRelayInvite) -> String {
        if let expiresAt = invite.expiresAt {
            return "Reusable until " + expiresAt.formatted(date: .abbreviated, time: .shortened)
        }
        if invite.expiresIn > 0 {
            return "Reusable for " + formatRelayInviteTTL(invite.expiresIn)
        }
        return "Reusable invite"
    }

    func formatRelayInviteTTL(_ seconds: Int) -> String {
        let duration = TimeInterval(seconds)
        if duration >= 24 * 60 * 60 && seconds % (24 * 60 * 60) == 0 {
            return "\(seconds / (24 * 60 * 60)) days"
        }
        if duration >= 60 * 60 && seconds % (60 * 60) == 0 {
            return "\(seconds / (60 * 60)) hours"
        }
        return "\(max(1, seconds / 60)) minutes"
    }

    @ViewBuilder
    func qrCodeImage(for value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    func enrollRelay() {
        guard !relayEnrollmentBusy, let onRelayEnroll else { return }
        let relayURL = relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let enrollmentKey = relayEnrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relayURL.isEmpty, !enrollmentKey.isEmpty else { return }
        relayEnrollmentBusy = true
        relayEnrollmentError = nil
        onRelayEnroll(relayURL, enrollmentKey) { result in
            Task { @MainActor in
                relayEnrollmentBusy = false
                switch result {
                case .success:
                    relayEnrollmentKey = ""
                    relayEnrollmentError = nil
                case let .failure(error):
                    relayEnrollmentError = error.localizedDescription
                }
            }
        }
    }

    func revokeRelayDevice(_ id: String) {
        guard let onRevokeRelayDevice else { return }
        relayRevokeErrors[id] = nil
        onRevokeRelayDevice(id) { result in
            Task { @MainActor in
                if case let .failure(error) = result {
                    relayRevokeErrors[id] = "Could not revoke: \(error.localizedDescription)"
                }
                onLoadRelayDevices?()
            }
        }
    }

    func resetRelay() {
        guard !relayResetBusy, let onResetRelay else { return }
        relayResetBusy = true
        relayResetError = nil
        onResetRelay { result in
            Task { @MainActor in
                relayResetBusy = false
                switch result {
                case .success:
                    relayRegistrationURL = ""
                    relayEnrollmentKey = ""
                    relayEnrollmentError = nil
                    relayResetError = nil
                case let .failure(error):
                    relayResetError = error.localizedDescription
                }
            }
        }
    }

    func seedRelayFields() {
        guard relayPrefill == nil else { return }
        if relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            relayRegistrationURL = relaySettings.relayURL
        }
    }

}
