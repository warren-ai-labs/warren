import SwiftUI
import WarrenDesignSystem

/// Settings → Access: every way another device reaches this Host.
///
/// These used to be four pages that each repeated the same skeleton — a way in,
/// a short-lived credential to pair with, and a list of what got in. They are
/// now four blocks of one page, in the order a person meets them:
///
/// 1. **Serverless relay** — the Bolthole path that needs no service to run.
/// 2. **Relay** — the enrolled Relay (the v2 service) for hosts that run one.
/// 3. **LAN pairing** — the PIN window for a device on this network.
/// 4. **Public access** — publishing this Host's Web UI to anyone with a link.
///
/// Public access keeps its own wording and warnings inside the block, because
/// publishing a page is a different promise from pairing a device.
extension WarrenDesktopSettingsView {
    func accessSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            accessHeading(
                "Serverless relay",
                detail: "End-to-end encrypted through a stateless relay. No service to run.",
                palette: palette
            )
            remoteAccessSection(palette: palette)

            accessHeading(
                "Relay",
                detail: "Enrol this Host with a Relay you operate, then share it with an invite.",
                palette: palette
            )
            relaySection(palette: palette)

            accessHeading(
                "LAN pairing",
                detail: "A short PIN window for a device on this network.",
                palette: palette
            )
            lanPairingSection(palette: palette)

            accessHeading(
                "Public access",
                detail: "Publish this Host's Web UI at an address anyone can open.",
                palette: palette
            )
            publicAccessSection(palette: palette)
        }
    }

    /// A block label inside the Access page. It matches a group title so the
    /// four blocks read as one page rather than as four pages stapled together.
    func accessHeading(_ title: String, detail: String, palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.inkBody)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .warrenSemanticElement(id: "settings.access.\(title)", role: .text, label: title)
    }
}
