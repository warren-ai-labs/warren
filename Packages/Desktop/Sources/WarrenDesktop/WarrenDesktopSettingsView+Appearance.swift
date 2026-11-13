import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopSettingsView {
    // MARK: - Appearance

    func appearanceSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Window") {
                WarrenSettingsRow(
                    "Color scheme",
                    description: "System follows macOS. Light uses Ember Paper for the window and the terminal, with an ANSI palette tuned for light backgrounds."
                ) {
                    WarrenSettingsPicker(
                        label: "Color scheme",
                        value: appearanceSelection.wrappedValue.displayName,
                        options: WarrenAppearanceMode.allCases.map {
                            ($0, $0.displayName, Self.appearanceSublabel($0))
                        },
                        selection: appearanceSelection,
                        accessibilityID: "settings.appearance.mode"
                    )
                }

                WarrenSettingsRowDivider()

                WarrenSettingsToggleRow(
                    title: "Translucent Window",
                    description: reduceTransparency
                        ? "Locked while Reduce Transparency is on in macOS Accessibility settings."
                        : "Lets the desktop show through the window, including behind terminals.",
                    isOn: $liquidGlassEnabled,
                    isEnabled: !reduceTransparency,
                    accessibilityID: "settings.appearance.liquid-glass"
                )
            }

            WarrenSettingsGroup("App Icon") {
                HStack(spacing: 14) {
                    ForEach(WarrenAppIconColorway.allCases, id: \.self) { colorway in
                        AppIconChoice(
                            colorway: colorway,
                            isSelected: appIconSelection.wrappedValue == colorway
                        ) {
                            appIconSelection.wrappedValue = colorway
                        }
                        .accessibilityIdentifier("settings.appearance.app-icon.\(colorway.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)

                Text("Changes the icon in the Dock and the app switcher while Warren is running. Finder keeps the Caramel icon.")
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(palette.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }

            WarrenSettingsGroup("Sidebar") {
                WarrenSettingsToggleRow(
                    title: "Show Tasks",
                    description: "Keep Tasks above Projects in the sidebar.",
                    isOn: $showsTasks,
                    accessibilityID: "settings.appearance.show-tasks"
                )
            }
        }
    }

    static func appearanceSublabel(_ mode: WarrenAppearanceMode) -> String {
        switch mode {
        case .system: "Follows macOS"
        case .light: "Ember Paper"
        case .dark: "Ember"
        }
    }

    // MARK: - Splits

    func splitsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Shortcuts") {
                let shortcuts: [(String, [String])] = [
                    ("Split Right", ["⌘", "D"]),
                    ("Split Below", ["⇧", "⌘", "D"]),
                    ("Close Pane", ["⌘", "W"]),
                    ("Maximize Pane", ["⇧", "⌘", "⏎"]),
                    ("Cycle Pane Focus", ["⌘", "]"]),
                ]
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, item in
                    if index > 0 { WarrenSettingsRowDivider() }
                    WarrenSettingsRow(item.0) {
                        WarrenSettingsKeycaps(keys: item.1)
                    }
                }
            }

            WarrenSettingsGroup("Emacs chords") {
                WarrenSettingsToggleRow(
                    title: "C-x Split Chords",
                    description: "Adds C-x 2, C-x 3, C-x 0, C-x 1 and C-x o. While on, Warren takes C-x instead of the terminal. C-g cancels; C-x C-x sends a literal C-x.",
                    isOn: $splitChordsEnabled,
                    accessibilityID: "settings.splits.emacs-chords"
                )
            }
        }
    }

    // MARK: - Notifications

    func notificationsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Agent needs you") {
                WarrenSettingsToggleRow(
                    title: "Notify While Warren Is in the Background",
                    description: "A macOS notification when an Agent stops for an approval or a question. An approval can be allowed or rejected from the notification. Muting the notice center silences these too.",
                    isOn: $agentAttentionAlertsEnabled,
                    accessibilityID: "settings.notifications.agent-attention-alerts"
                )
                WarrenSettingsRowDivider()
                WarrenSettingsToggleRow(
                    title: "Count Waiting Sessions on the Dock Icon",
                    description: "The Dock badge shows how many Sessions on this Host are waiting on you.",
                    isOn: $agentAttentionDockBadgeEnabled,
                    accessibilityID: "settings.notifications.agent-attention-dock-badge"
                )
            }
            WarrenSettingsGroup("Agent completion") {
                WarrenSettingsToggleRow(
                    title: "Play Completion Sound",
                    description: "A short system sound when an Agent turn finishes in a background pane. The active window and aborted turns stay silent.",
                    isOn: $agentCompletionSoundEnabled,
                    accessibilityID: "settings.notifications.agent-completion-sound"
                )
            }
        }
    }

    // MARK: - Deep links

    func copySettingsDeepLink(for section: SettingsSection) {
        let publicAccess: WarrenDesktopPublicAccessPrefill?
        let relay: WarrenDesktopRelayPrefill?
        if section == .publicAccess {
            let publicHostname = publicAccessHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathPrefix = publicAccessPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            publicAccess = WarrenDesktopPublicAccessPrefill(
                publicHostname: publicHostname.isEmpty ? webStatus.publicHostname : publicHostname,
                pathPrefix: pathPrefix.isEmpty ? webStatus.pathPrefix : pathPrefix
            )
        } else {
            publicAccess = nil
        }

        if section == .relay {
            relay = relayPrefill ?? WarrenDesktopRelayPrefill(relayURL: relaySettings.relayURL)
        } else {
            relay = nil
        }

        guard let url = WarrenDesktopSettingsDeepLink(
            section: section,
            publicAccess: publicAccess,
            relay: relay
        ).url else { return }
        copyFeedback.copy(url.absoluteString, confirmingIn: Self.deepLinkCopySource(section))
    }

    static func deepLinkCopySource(_ section: SettingsSection) -> String {
        "settings.deeplink.\(section.rawValue)"
    }

    func applyDeepLinkPrefill() {
        if let initialSettingsSection {
            selectedSection = initialSettingsSection
        }
        if let publicAccessPrefill {
            if let publicHostname = publicAccessPrefill.publicHostname {
                publicAccessHostname = publicHostname
            }
            if let pathPrefix = publicAccessPrefill.pathPrefix {
                publicAccessPathPrefix = pathPrefix
            }
        }

        if let relayPrefill {
            if let relayURL = relayPrefill.relayURL { relayRegistrationURL = relayURL }
            if let enrollmentKey = relayPrefill.enrollmentKey { relayEnrollmentKey = enrollmentKey }
        } else {
            seedRelayFields()
        }
    }

    func seedPublicAccessFields() {
        if publicAccessHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let publicHostname = webStatus.publicHostname,
           !publicHostname.isEmpty {
            publicAccessHostname = publicHostname
        }
        if publicAccessPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let pathPrefix = webStatus.pathPrefix,
           !pathPrefix.isEmpty {
            publicAccessPathPrefix = pathPrefix
        }
    }

    func clearPublicAccessFieldsIfReset() {
        guard !webStatus.publicAccessEnabled,
              !webStatus.publicAccessAuthenticated,
              webStatus.relayURL == nil,
              webStatus.relayHostID == nil,
              webStatus.routeID == nil else {
            return
        }
        publicAccessHostname = ""
        publicAccessPathPrefix = ""
    }

    // MARK: - Custom IDEs

    func addCustomIDE() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an editor app bundle or executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ide = WarrenDesktopCustomIDE(name: Self.displayName(for: url), path: url.path)
        customIDEs.append(ide)
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    func removeCustomIDE(_ ide: WarrenDesktopCustomIDE) {
        customIDEs.removeAll { $0.id == ide.id }
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    static func displayName(for url: URL) -> String {
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func probeInstalledIDEs() -> [InstalledIDE] {
        WarrenDesktopExternalIDE.supported.compactMap { ide in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ide.bundleIdentifier) else {
                return nil
            }
            return InstalledIDE(
                id: ide.id.rawValue,
                name: ide.name,
                path: url.path,
                icon: WarrenDesktopExternalIDEIcon.normalized(
                    NSWorkspace.shared.icon(forFile: url.path),
                    opticalScale: WarrenDesktopExternalIDEIcon.opticalScale(for: ide.id.rawValue)
                )
            )
        }
    }
}
