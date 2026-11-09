import SwiftUI
import WarrenDesignSystem

/// Settings → Access: every way another device reaches this Host, grouped by
/// where that device is.
///
/// From anywhere there are two relays, and both can be on at once:
/// - Serverless relay: Bolthole, end-to-end encrypted, with an official relay
///   so it works with no setup. Recommended.
/// - Server relay: a Warren Relay the user runs. There is no official one; it
///   trades setup for steadier, lower-latency sessions. Its Public Web link
///   lives inside it because it only works through that Relay.
///
/// On this network, a PIN pairs an iPhone without any relay.
extension WarrenDesktopSettingsView {
    /// How to run your own Bolthole relay (Cloudflare Workers, a binary, or Docker).
    static let serverlessRelayDeployGuide = URL(string: "https://github.com/abcdlsj/bolthole/blob/main/docs/deploy.md")!
    /// How to run a Warren Relay service.
    static let serverRelayDeployGuide = URL(string: "https://github.com/warren-ai-labs/warren/blob/main/RelayService/README.md")!

    func accessSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Not sure? Turn on Serverless relay. Use Server relay only if you run your own server "
                + "and want steadier, lower-latency sessions. Both can be on.")
                .font(WarrenTypography.settingsMeta)
                .foregroundStyle(palette.meta)
                .fixedSize(horizontal: false, vertical: true)
                // A paragraph, not a rule: at the page's full width this ran a
                // 150-character line, which no one reads.
                .frame(maxWidth: WarrenSettingsMetrics.readingWidth, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.controlBorder).frame(width: 2)
                }

            VStack(alignment: .leading, spacing: 28) {
                accessGroupLabel("From anywhere", palette: palette)

                accessHeading(
                    "Serverless relay",
                    tag: "Recommended",
                    detail: "End-to-end encrypted through a relay that cannot read your traffic. "
                        + "The official relay needs no setup.",
                    guide: Self.serverlessRelayDeployGuide,
                    guideLabel: "Run your own",
                    palette: palette
                )
                remoteAccessSection(palette: palette)

                accessHeading(
                    "Server relay",
                    detail: "A Relay you run on your own server, for steadier sessions and lower latency. "
                        + "There is no official one.",
                    guide: Self.serverRelayDeployGuide,
                    guideLabel: "Deploy guide",
                    palette: palette
                )
                relaySection(palette: palette)

                accessHeading(
                    "Public Web link",
                    detail: "Anyone with the link opens this Host's Web UI. Works through Server relay only.",
                    palette: palette
                )
                .padding(.leading, 14)
                if relaySettings.isEnrolled {
                    publicAccessSection(palette: palette)
                        .padding(.leading, 14)
                } else {
                    Text("Set up Server relay first.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.meta)
                        .padding(.leading, 14)
                        .accessibilityIdentifier("settings.public-access.needs-relay")
                }
            }

            VStack(alignment: .leading, spacing: 28) {
                accessGroupLabel("On this network", palette: palette)

                accessHeading(
                    "Pair on this network",
                    detail: "Pair an iPhone on the same Wi‑Fi with a PIN. No relay involved.",
                    palette: palette
                )
                lanPairingSection(palette: palette)
            }
        }
    }

    func accessGroupLabel(_ title: String, palette: WarrenSettingsPalette) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(palette.meta)
            .accessibilityAddTraits(.isHeader)
    }

    /// A block label inside the Access page. It matches a group title so the
    /// blocks read as one page rather than as several pages stapled together.
    func accessHeading(
        _ title: String,
        tag: String? = nil,
        detail: String,
        guide: URL? = nil,
        guideLabel: String = "",
        palette: WarrenSettingsPalette
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.inkBody)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(palette.meta)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(palette.controlBorder, lineWidth: 1)
                            }
                    }
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.meta)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let guide {
                Link(destination: guide) {
                    HStack(spacing: 2) {
                        Text(guideLabel)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.inkBody)
                }
                .help(guide.absoluteString)
                .accessibilityIdentifier("settings.access.guide.\(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .warrenSemanticElement(id: "settings.access.\(title)", role: .text, label: title)
    }
}
