import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopSettingsView {
    // MARK: - Navigation

    func navigationPanel(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField(palette: palette)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !thisMacSections.isEmpty {
                        sectionGroup(title: "THIS MAC", sections: thisMacSections, palette: palette)
                    }
                    if !hostSections.isEmpty {
                        hostGroup(palette: palette)
                    }
                    if visibleSections.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20))
                                .foregroundStyle(palette.inkQuiet.opacity(0.5))
                            Text("No settings match your search")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.inkQuiet)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            versionFooter(palette: palette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: selectedSection)
    }

    /// The running bundle's version at the foot of the navigation, so a
    /// screenshot of Settings says which build is being configured without
    /// opening About.
    func versionFooter(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 4) {
            Text("Version")
                .foregroundStyle(palette.inkFaint)
            Text(Self.appVersion)
                .foregroundStyle(palette.inkQuiet)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        // Lines up with the section headings above, not with the card edge.
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.version")
        .warrenSemanticElement(
            id: "settings.version",
            role: .text,
            label: "Warren version \(Self.appVersion)"
        )
    }

    func searchField(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.inkFaint)
                .frame(width: 14)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.inkBody)
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkFaint)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        // As with every settings field, a click anywhere on the box focuses it.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = true }
        }
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                .strokeBorder(searchFocused ? palette.focusRing : palette.cardBorder, lineWidth: 1)
        }
        .shadow(color: searchFocused ? palette.focusRing.opacity(0.55) : .clear, radius: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    func sectionGroup(
        title: String,
        sections: [SettingsSection],
        palette: WarrenSettingsPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(palette.inkFaint)
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    navigationItem(section, palette: palette)
                }
            }
        }
    }

    func hostGroup(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            hostRow(palette: palette)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(hostSections.enumerated()), id: \.element) { _, section in
                    if section == .relay {
                        Spacer().frame(height: 12)
                    }
                    navigationItem(section, palette: palette)
                }
            }
        }
    }

    @ViewBuilder
    func navigationItem(_ section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        if section == .lanPairing, lanPairing.enabled {
            // An open pairing window expires on a clock, not on a state
            // change, so its tile re-reads the time while it is open.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                navigationItem(section, status: navigationStatus(for: section, at: timeline.date), palette: palette)
            }
        } else {
            navigationItem(section, status: navigationStatus(for: section), palette: palette)
        }
    }

    func navigationItem(
        _ section: SettingsSection,
        status: WarrenStatusTone?,
        palette: WarrenSettingsPalette
    ) -> some View {
        WarrenSettingsNavItem(
            section: section,
            status: status,
            isSelected: selectedSection == section,
            palette: palette,
            selectionNamespace: selectionNamespace,
            // A search flattens the two groups into one list of matches, so each
            // row has to say which scope it belongs to again.
            scopeLabel: isSearching ? (section.scope == .thisMac ? "This Mac" : currentHostLabel) : nil,
            onSelect: { selectedSection = section }
        )
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one status a page can carry on its navigation tile, as of `date`.
    func navigationStatus(for section: SettingsSection, at date: Date = Date()) -> WarrenStatusTone? {
        switch section {
        case .relay:
            guard relaySettings.isEnrolled else { return nil }
            return relaySettings.enabled ? .ok : .warning
        case .publicAccess:
            if webStatus.publicAccessBusy { return .busy }
            return webStatus.tunnelRunning || webStatus.publicAccessAuthenticated ? .ok : nil
        case .lanPairing:
            // The window closes on its own; the dot goes with it rather than
            // waiting for the next roster update to clear `enabled`.
            return lanPairingIsOpen(at: date) ? .warning : nil
        case .aiTitles:
            if openAITestStatus.isTesting { return .busy }
            if openAITestStatus.failure != nil { return .failed }
            return nil
        default:
            return nil
        }
    }

    var currentHostLabel: String {
        hostOptions.first { $0.id == selectedHostID }?.label ?? hostName
    }

    func hostRow(palette: WarrenSettingsPalette) -> some View {
        let hasChoices = hostOptions.count > 1 && onSelectHost != nil
        // The same heading as THIS MAC above it, so the two groups read as
        // one list; the dot says how the Host's connection is doing.
        let row = HStack(spacing: 6) {
            Text(currentHostLabel.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(palette.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)
            connectionDot(hostOptions.first { $0.id == selectedHostID }?.probeState, palette: palette)
            Spacer(minLength: 6)
            if hasChoices {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.inkFaint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 18)
        .contentShape(Rectangle())

        return Group {
            if hasChoices {
                Button {
                    hostPickerPresented.toggle()
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings apply to")
                .accessibilityValue(currentHostLabel)
                .warrenMenuPanel(isPresented: $hostPickerPresented, width: WarrenDesktopMenuMetrics.menuWidth) {
                    hostPickerPanel(palette: palette)
                }
            } else {
                row
            }
        }
    }

    func hostPickerPanel(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hostOptions) { option in
                Button {
                    onSelectHost?(option.id)
                    // A choice ends the menu, as in every other picker.
                    hostPickerPresented = false
                } label: {
                    HStack(spacing: WarrenDesktopMenuMetrics.checkSpacing) {
                        // The menu's leading check column, so the tiles and
                        // names line up whichever Host is current.
                        WarrenDesktopMenuCheckColumn(isChecked: option.id == selectedHostID)
                        // The Host's initial, in the quiet tier and in no box:
                        // the menu's own rows name a Host the same way.
                        Text(String(option.label.prefix(1)).lowercased())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.inkFaint)
                            .frame(width: 20, height: 20)
                            .overlay(alignment: .bottomTrailing) {
                                connectionDot(option.probeState, palette: palette)
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.inkBody)
                                .lineLimit(1)
                            if let detail = option.detail {
                                Text(detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.meta)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, WarrenDesktopMenuMetrics.iconSpacing - WarrenDesktopMenuMetrics.checkSpacing)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: option.detail == nil
                            ? WarrenDesktopMenuMetrics.rowHeight
                            : WarrenDesktopMenuMetrics.twoLineRowHeight,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(WarrenDesktopMenuRowStyle())
                .accessibilityAddTraits(option.id == selectedHostID ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    func connectionDot(
        _ state: WarrenDesktopEndpointOption.ProbeState?,
        palette: WarrenSettingsPalette
    ) -> some View {
        switch state {
        case .reachable:
            dot(palette.success, ring: palette.card)
        case .failed:
            dot(palette.dangerText, ring: palette.card)
        case .checking:
            dot(palette.inkQuiet, ring: palette.card)
        case .unknown, .none:
            EmptyView()
        }
    }

    func dot(_ color: Color, ring: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay { Circle().strokeBorder(ring, lineWidth: 1.5) }
            .accessibilityHidden(true)
    }

    // MARK: - Shared plumbing

    var orderedPresets: [WarrenDesktopSessionPreset] {
        WarrenDesktopSessionPreset.orderedPinned(by: presetOrder)
    }

    func presetVisibilityBinding(for preset: WarrenDesktopSessionPreset) -> Binding<Bool> {
        Binding(
            get: { !WarrenDesktopSessionPreset.normalizedHidden(hiddenPresets).contains(preset.id) },
            set: { visible in
                hiddenPresets = WarrenDesktopSessionPreset.settingVisibility(
                    of: preset.id,
                    visible: visible,
                    in: hiddenPresets
                )
            }
        )
    }

    var agentInterfaceSelection: Binding<WarrenAgentInterface> {
        Binding(
            get: { WarrenAgentInterface(storedValue: agentInterfaceRawValue) },
            set: { agentInterfaceRawValue = $0.rawValue }
        )
    }

    var appearanceSelection: Binding<WarrenAppearanceMode> {
        Binding(
            get: { WarrenAppearanceMode(storedValue: appearanceModeRawValue) },
            set: { mode in
                appearanceModeRawValue = mode.rawValue
                WarrenDesktopAppearance.apply(mode)
            }
        )
    }

    var appIconSelection: Binding<WarrenAppIconColorway> {
        Binding(
            get: { WarrenAppIconColorway(storedValue: appIconRawValue) },
            set: { colorway in
                appIconRawValue = colorway.rawValue
                WarrenDesktopDockIcon.apply(colorway)
            }
        )
    }

    var normalizedFont: TerminalFontPreference {
        TerminalFontPreference(family: fontFamily, size: fontSize)
    }

    var renderedTitle: String {
        TerminalDisplayTitleTemplate(rawValue: titleTemplate).render(.init(
            session: "Claude", command: "claude", directory: "/Users/me/Workspace/warren",
            workspace: "warren", branch: "main", host: "MacBook Pro", user: "me", os: "macOS"
        ))
    }

    /// The title line under a pane's header, shown in the Terminal preview bar.
    var preview: String {
        renderedTitle
    }

    /// Every installed family opened as an `NSFont` to test its pitch. Done
    /// once per launch: as a computed property it ran on every render of the
    /// Terminal page, which is the page Settings opens on.
    @MainActor static let installedMonospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        .sorted()
    }()

    var monospacedFamilies: [String] {
        var result = Self.installedMonospacedFamilies
        if !result.contains(fontFamily) {
            result.insert(fontFamily, at: 0)
        }
        return result
    }

}
