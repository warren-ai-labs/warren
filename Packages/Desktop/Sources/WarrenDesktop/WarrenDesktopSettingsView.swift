import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain

private extension WarrenDesktopSettingsSection {
    var iconName: String {
        switch self {
        case .terminalFont: "terminal"
        case .terminalTitle: "textformat"
        case .terminalRuntime: "cpu"
        case .presets: "hammer"
        case .workspaces: "arrow.triangle.branch"
        case .externalIDEs: "chevron.left.forwardslash.chevron.right"
        case .publicAccess: "globe"
        }
    }

    var detail: String {
        switch self {
        case .terminalFont: "Applied to every terminal surface."
        case .terminalTitle: "Build a title from live Session metadata."
        case .terminalRuntime: "Engine that owns new sessions on the headless daemon."
        case .presets: "Choose visible presets and customize every launch command."
        case .workspaces: "How projects import worktrees and enter sessions."
        case .externalIDEs: "IDEs the workspace menu can open worktrees in."
        case .publicAccess: "Reach this host's Web UI through a self-hosted gnar Edge."
        }
    }

    var searchTerms: [String] {
        switch self {
        case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
        case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
        case .terminalRuntime: [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
        case .presets: [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "trae", "agent", "visible", "hidden"]
        case .workspaces: [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "shell", "AI", "Claude", "Codex"]
        case .externalIDEs: [rawValue, detail, "ide", "editor", "vscode", "goland", "android", "custom", "path", "open"]
        case .publicAccess: [rawValue, detail, "gnar", "edge", "endpoint", "invite key", "approval key", "enrollment key", "tunnel", "internet"]
        }
    }

    var isTerminalSection: Bool {
        self != .publicAccess
    }
}

/// Settings mirror Superset's route layout: a slim window-chrome row on top,
/// a 224pt sidebar with Back/title/search/grouped navigation on the left, and
/// a page-headed detail column (`max-w-5xl`) on the right.
struct WarrenDesktopSettingsView: View {
    let onBack: () -> Void
    let hostName: String
    let webStatus: WarrenDesktopWebStatus
    let onWebTest: ((String, String, String, String) -> Void)?
    let onWebStop: (() -> Void)?
    let defaultRuntime: String?
    let onSetRuntime: (String) -> Void
    let autoOpenShell: Bool
    let onSetAutoOpenShell: (Bool) -> Void
    let autoStartAI: Bool
    let onSetAutoStartAI: (Bool) -> Void

    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var fontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var fontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.presetCommandShell)
    private var shellCommand = ""
    @AppStorage(WarrenPreferenceKey.presetCommandClaude)
    private var claudeCommand = "claude"
    @AppStorage(WarrenPreferenceKey.presetCommandCodex)
    private var codexCommand = "codex --dangerously-bypass-hook-trust"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    private var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    private var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
    @State private var publicAccessEdgeURL = ""
    @State private var publicAccessAccountName = ""
    @State private var publicAccessInviteKey = ""
    @State private var publicAccessApprovalKey = ""
    @State private var publicAccessKeyKind: PublicAccessKeyKind = .invite
    @State private var publicAccessUseDefaultTunnel = true
    @State private var publicAccessMaskedKeyKind: PublicAccessKeyKind?
    @State private var publicAccessSubmittedKeyKind: PublicAccessKeyKind?
    @State private var copiedSettingsSection: WarrenDesktopSettingsSection?
    @Environment(\.colorScheme) private var colorScheme

    /// A deeplink can select a page and prefill its non-secret or explicitly
    /// shared Public Access setup values. The key is never persisted by this
    /// view, but a link containing it must still be treated as a credential.
    var initialSettingsSection: WarrenDesktopSettingsSection?
    var publicAccessPrefill: WarrenDesktopPublicAccessPrefill?

    private enum PublicAccessKeyKind: String, CaseIterable, Identifiable {
        case approval
        case invite

        var id: String { rawValue }

        var title: String {
            switch self {
            case .approval: "Approval Key"
            case .invite: "Invite Key"
            }
        }

        var accessibilityTitle: String { title }
    }

    private typealias SettingsSection = WarrenDesktopSettingsSection

    @State private var selectedSection: SettingsSection = .terminalFont
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var installedIDEs: [InstalledIDE] = []
    @State private var customIDEs = WarrenDesktopCustomIDEStore.load()

    private var visibleSections: [SettingsSection] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchTerms.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            chromeRow(tokens: tokens)

            WarrenDesktopChromeDivider()

            HStack(spacing: 0) {
                navigationPanel(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.settingsNavigationWidth)

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline)

                detailPanel(tokens: tokens)
            }
        }
        .background(tokens.background)
        .onExitCommand(perform: onBack)
        .onAppear(perform: applyDeepLinkPrefill)
        .onChange(of: initialSettingsSection) { _, _ in
            applyDeepLinkPrefill()
        }
        .onChange(of: publicAccessPrefill) { _, _ in
            applyDeepLinkPrefill()
        }
        .onChange(of: searchQuery) { _, _ in
            if !visibleSections.contains(selectedSection), let first = visibleSections.first {
                selectedSection = first
            }
        }
    }

    private func chromeRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 0) {
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset, alignment: .leading)

            WarrenDesktopWindowDragRegion()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .background(tokens.chromeSurface)
    }

    private func navigationPanel(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .regular))
                    Text("Back")
                }
                .font(WarrenTypography.settingsNavigationItem)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle())
            .padding(.horizontal, WarrenSpacing.xs)
            .accessibilityLabel("Back to Warren")

            Text("Settings")
                .font(WarrenTypography.settingsScreenTitle)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.top, WarrenSpacing.standard)
                .padding(.bottom, WarrenSpacing.large)

            searchField(tokens: tokens)
                .padding(.horizontal, WarrenSpacing.xs)
                .padding(.bottom, WarrenSpacing.medium)

            ScrollView {
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    groupLabel("Terminal", tokens: tokens)
                    ForEach(visibleSections.filter(\.isTerminalSection)) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    groupLabel("Web", tokens: tokens)
                    ForEach(visibleSections.filter { !$0.isTerminalSection }) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    if visibleSections.isEmpty {
                        Text("No settings match your search")
                            .font(WarrenTypography.settingsBody)
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarrenSpacing.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.sidebarSurface)
    }

    private func groupLabel(_ title: String, tokens: WarrenColorTokens) -> some View {
        Text(title)
            .font(WarrenTypography.settingsGroupLabel)
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.top, WarrenSpacing.large)
            .padding(.bottom, WarrenSpacing.small)
    }

    private func searchField(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 16)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(WarrenTypography.settingsControl)
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.settingsAction)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(height: WarrenLayoutMetrics.settingsSearchHeight)
        .background(tokens.muted.opacity(0.45))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.row)
                .stroke(searchFocused ? tokens.ring : .clear, lineWidth: WarrenSpacing.hairline)
        }
    }

    private func navigationItem(
        _ section: SettingsSection,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: section.iconName)
                    .font(.system(size: 12, weight: .light))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .accessibilityHidden(true)

                Text(section.rawValue)
                    .font(isSelected
                        ? WarrenTypography.settingsNavigationItemActive
                        : WarrenTypography.settingsNavigationItem)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("settings.section.\(section.id)")
    }

    private func detailPanel(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxlarge) {
                switch selectedSection {
                case .terminalFont:
                    terminalFontSection(tokens: tokens)
                case .terminalTitle:
                    terminalTitleSection(tokens: tokens)
                case .terminalRuntime:
                    terminalRuntimeSection(tokens: tokens)
                case .presets:
                    presetsSection(tokens: tokens)
                case .workspaces:
                    workspacesSection(tokens: tokens)
                case .externalIDEs:
                    externalIDEsSection(tokens: tokens)
                case .publicAccess:
                    publicAccessSection(tokens: tokens)
                }

                Button("Restore terminal defaults") {
                    titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                    fontFamily = TerminalFontPreference.defaultFamily
                    fontSize = TerminalFontPreference.defaultSize
                    shellCommand = ""
                    claudeCommand = "claude"
                    codexCommand = "codex --dangerously-bypass-hook-trust"
                    traeCommand = "trae-cli interactive"
                    presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
                    hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.settingsAction)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.top, WarrenSpacing.medium)
                .accessibilityIdentifier("settings.restore-defaults")
            }
            .frame(maxWidth: WarrenLayoutMetrics.settingsContentMaxWidth, alignment: .leading)
            .padding(.horizontal, WarrenSpacing.xlarge)
            .padding(.vertical, WarrenSpacing.xxlarge)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(selectedSection)
        }
    }

    private func terminalFontSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal font", section: .terminalFont, tokens: tokens) {
            HStack(alignment: .bottom, spacing: WarrenSpacing.xlarge) {
                settingsInputField(
                    "Font family",
                    text: $fontFamily,
                    placeholder: TerminalFontPreference.defaultFamily
                )
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    Text("Size").font(WarrenTypography.settingsBody)
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Self.fontSizeLabel(fontSize)) pt")
                            .font(WarrenTypography.settingsControl)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                .frame(width: 150)
            }
            Text("$  The quick brown fox  0123456789  中文  │─└")
                .font(.custom(normalizedFont.family, size: normalizedFont.size))
                .foregroundStyle(tokens.foreground)
                .padding(WarrenSpacing.xlarge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tokens.fillHover)
                .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        }
    }

    private static func fontSizeLabel(_ value: Double) -> String {
        let safe = value.isFinite
            ? min(max(value, 8), 32)
            : TerminalFontPreference.defaultSize
        return String(Int(safe))
    }

    private func terminalTitleSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal title", section: .terminalTitle, tokens: tokens) {
            settingsInputField(
                "Title template",
                text: $titleTemplate,
                placeholder: "Title template"
            )
            Text(preview)
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: WarrenSpacing.compact)],
                alignment: .leading,
                spacing: WarrenSpacing.compact
            ) {
                ForEach(TerminalDisplayTitleTemplate.placeholders, id: \.token) { placeholder in
                    Button {
                        if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
                        titleTemplate += placeholder.token
                    } label: {
                        HStack {
                            Text(placeholder.token).font(WarrenTypography.settingsMeta)
                            Spacer()
                            Text(placeholder.description)
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .padding(WarrenSpacing.compact)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func presetsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Launch commands", section: .presets, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Session order")
                    .font(WarrenTypography.settingsBody)
                Text("This order controls the preset buttons; opening a workspace never changes it.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: WarrenSpacing.small) {
                    ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                        HStack(spacing: WarrenSpacing.compact) {
                            WarrenDesktopPresetIcon(preset: preset)
                                .frame(width: 16, height: 16)
                            Text(preset.presetBarTitle)
                                .font(WarrenTypography.settingsBody)
                            Spacer()
                            Toggle("Show \(preset.presetBarTitle)", isOn: presetVisibilityBinding(for: preset))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .accessibilityIdentifier("settings.preset-visibility.\(preset.id)")
                            presetMoveButton(
                                preset: preset,
                                direction: -1,
                                symbolName: "arrow.up",
                                disabled: index == 0,
                                tokens: tokens
                            )
                            presetMoveButton(
                                preset: preset,
                                direction: 1,
                                symbolName: "arrow.down",
                                disabled: index == orderedPresets.count - 1,
                                tokens: tokens
                            )
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .frame(minHeight: 38)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
                ForEach(orderedPresets) { preset in
                    presetCommandField(for: preset)
                }
            }
            Text(
                "Hidden presets stay configurable here but do not appear in the "
                    + "preset bar. Commands are typed into a plain shell after it opens, so "
                    + "quitting an agent with Ctrl+C / Ctrl+D keeps the "
                    + "terminal tab alive. Leave Shell empty for a bare "
                    + "terminal."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var orderedPresets: [WarrenDesktopSessionPreset] {
        WarrenDesktopSessionPreset.orderedPinned(by: presetOrder)
    }

    private func presetVisibilityBinding(for preset: WarrenDesktopSessionPreset) -> Binding<Bool> {
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

    private func settingsInputField(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        monospaced: Bool = true
    ) -> some View {
        WarrenInputField(
            label,
            text: text,
            placeholder: placeholder,
            monospaced: monospaced,
            labelFont: WarrenTypography.settingsBody,
            inputFont: WarrenTypography.settingsControl
        )
    }

    private func presetMoveButton(
        preset: WarrenDesktopSessionPreset,
        direction: Int,
        symbolName: String,
        disabled: Bool,
        tokens: WarrenColorTokens
    ) -> some View {
        let directionLabel = direction < 0 ? "up" : "down"
        return Button {
            presetOrder = WarrenDesktopSessionPreset.moving(preset.id, by: direction, in: presetOrder)
        } label: {
            Image(systemName: symbolName)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.mutedForeground)
        .disabled(disabled)
        .accessibilityLabel("Move \(preset.presetBarTitle) \(directionLabel)")
        .accessibilityIdentifier("settings.preset-order.\(preset.id).\(directionLabel)")
    }

    @ViewBuilder
    private func presetCommandField(for preset: WarrenDesktopSessionPreset) -> some View {
        switch preset.request.kind {
        case .shell:
            settingsInputField("Shell", text: $shellCommand, placeholder: "default shell (empty)")
        case .claude:
            settingsInputField("Claude", text: $claudeCommand, placeholder: "claude")
        case .codex:
            settingsInputField(
                "Codex",
                text: $codexCommand,
                placeholder: "codex --dangerously-bypass-hook-trust"
            )
        case .trae:
            WarrenInputField("Trae", text: $traeCommand, placeholder: "trae-cli interactive")
        case .custom:
            EmptyView()
        }
    }

    private func workspacesSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Workspaces", section: .workspaces, tokens: tokens) {
            Toggle("Open a Shell when opening an empty workspace", isOn: Binding(
                get: { autoOpenShell },
                set: { onSetAutoOpenShell($0) }
            ))
            .toggleStyle(.switch)
            .font(WarrenTypography.settingsControl)
            .accessibilityIdentifier("settings.workspaces.auto-open-shell")
            Text(
                "Double-clicking an empty workspace is the explicit open action. "
                    + "When this is enabled, it creates one Shell. If automatic "
                    + "AI startup is also enabled, the AI rule wins and no second "
                    + "Shell is created. Explicit New Session and preset buttons "
                    + "always create the requested session."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Start the first AI when entering an empty workspace", isOn: Binding(
                get: { autoStartAI },
                set: { onSetAutoStartAI($0) }
            ))
            .toggleStyle(.switch)
            .font(WarrenTypography.settingsControl)
            .accessibilityIdentifier("settings.workspaces.auto-start-ai")
            Text(
                "Selecting a workspace, selecting a project, or using the Command "
                    + "Palette starts the first AI in Launch commands order. This "
                    + "does not run during navigation restore. If both options are "
                    + "enabled, this AI startup takes precedence over the Shell "
                    + "option on a double-click, preventing duplicate sessions."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Git worktree import is configured per project. Use a project's "
                    + "context menu to enable automatic import (no confirmation) "
                    + "or choose Import Existing Worktrees… for a one-time selection."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func externalIDEsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("External IDEs", section: .externalIDEs, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Installed").font(WarrenTypography.settingsBody)
                if installedIDEs.isEmpty {
                    Text("No supported IDEs found on this Mac.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                }
                ForEach(installedIDEs) { ide in
                    ideRow(icon: ide.icon, name: ide.name, path: ide.path, tokens: tokens)
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Custom").font(WarrenTypography.settingsBody)
                if customIDEs.isEmpty {
                    Text("No custom IDEs yet.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                }
                ForEach(customIDEs) { ide in
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(nsImage: WarrenDesktopExternalIDEIcon.normalized(
                            NSWorkspace.shared.icon(forFile: ide.path)
                        ))
                            .resizable()
                            .scaledToFit()
                            .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                                   height: WarrenLayoutMetrics.externalIDEIconSize)
                        Text(ide.name).font(WarrenTypography.settingsBody)
                        Spacer()
                        Text(ide.path)
                            .font(WarrenTypography.settingsMeta)
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(role: .destructive) {
                            removeCustomIDE(ide)
                        } label: {
                            Image(systemName: "trash")
                            .font(WarrenTypography.settingsMeta)
                                .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                                       height: WarrenLayoutMetrics.sidebarActionButtonSize)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityLabel("Remove \(ide.name)")
                    }
                    .padding(WarrenSpacing.compact)
                    .background(tokens.fillHover)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                }
                Button {
                    addCustomIDE()
                } label: {
                    Label("Add IDE…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.settingsAction)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityIdentifier("settings.external-ides.add")
            }

            Text(
                "The workspace menu lists IDEs installed on this Mac plus "
                    + "your custom entries. A custom entry can be an app "
                    + "bundle or an executable that opens a directory, for "
                    + "example /usr/local/bin/code."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            installedIDEs = Self.probeInstalledIDEs()
        }
    }

    private func ideRow(
        icon: NSImage,
        name: String,
        path: String,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
            Text(name).font(WarrenTypography.settingsBody)
            Spacer()
            Text(path)
                .font(WarrenTypography.settingsMeta)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(WarrenSpacing.compact)
        .background(tokens.fillHover)
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
    }

    private func addCustomIDE() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an IDE app bundle or executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ide = WarrenDesktopCustomIDE(name: Self.displayName(for: url), path: url.path)
        customIDEs.append(ide)
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    private func removeCustomIDE(_ ide: WarrenDesktopCustomIDE) {
        customIDEs.removeAll { $0.id == ide.id }
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    private static func displayName(for url: URL) -> String {
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func probeInstalledIDEs() -> [InstalledIDE] {
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

    private func publicAccessSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Public Access", section: .publicAccess, tokens: tokens) {
            Text(
                "Reach this Mac's Web UI through a self-hosted gnar Edge. Save the non-secret "
                    + "configuration here, then use Save & Test to finish the first gnar "
                    + "authentication. Choose one Invite Key or Approval Key. Keys stay in memory, go "
                    + "directly to gnar, and are never saved by Warren."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                isOn: $publicAccessUseDefaultTunnel
            ) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text(WarrenPublicAccessCopy.defaultTunnel)
                        .font(WarrenTypography.settingsBody)
                    Text("Turn this on to configure Warren's built-in gnar tunnel.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(webStatus.publicAccessBusy)
            .accessibilityIdentifier("settings.public-access.use-default-tunnel")
            .onChange(of: publicAccessUseDefaultTunnel) { _, enabled in
                guard !enabled else { return }
                publicAccessInviteKey = ""
                publicAccessApprovalKey = ""
                publicAccessMaskedKeyKind = nil
                publicAccessSubmittedKeyKind = nil
                if webStatus.tunnelRunning {
                    onWebStop?()
                }
            }

            if publicAccessUseDefaultTunnel {
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    Text(WarrenPublicAccessCopy.edgeURL)
                        .font(WarrenTypography.settingsBody)
                    HStack(spacing: WarrenSpacing.small) {
                        TextField(edgeURLPlaceholder, text: $publicAccessEdgeURL)
                            .textFieldStyle(.roundedBorder)
                            .font(WarrenTypography.settingsControl)
                            .accessibilityLabel(WarrenPublicAccessCopy.edgeURL)
                            .accessibilityIdentifier("settings.public-access.edge-url")
                        pasteButton(
                            accessibilityLabel: "Paste Edge URL",
                            accessibilityIdentifier: "settings.public-access.edge-url.paste"
                        ) {
                            publicAccessEdgeURL = pastedText() ?? publicAccessEdgeURL
                        }
                    }

                    if let defaultEdgeURL = webStatus.defaultEdgeURL {
                        Text(
                            publicAccessEdgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Built-in default: \(defaultEdgeURL.absoluteString)"
                                : "Clear the custom URL to use the built-in default: \(defaultEdgeURL.absoluteString)"
                        )
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Account name")
                        .font(WarrenTypography.settingsBody)
                    HStack(spacing: WarrenSpacing.small) {
                        TextField(accountNamePlaceholder, text: $publicAccessAccountName)
                            .textFieldStyle(.roundedBorder)
                            .font(WarrenTypography.settingsControl)
                            .accessibilityLabel("gnar account name")
                            .accessibilityIdentifier("settings.public-access.account-name")
                        pasteButton(
                            accessibilityLabel: "Paste account name",
                            accessibilityIdentifier: "settings.public-access.account-name.paste"
                        ) {
                            publicAccessAccountName = pastedText() ?? publicAccessAccountName
                        }
                    }

                    if let accountName = webStatus.effectiveAccountName,
                       !accountName.isEmpty {
                        Text(
                            webStatus.usingDefaultAccount
                                ? "Default account name: \(accountName)"
                                : "Configured account name: \(accountName)"
                        )
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Key type", selection: $publicAccessKeyKind) {
                        ForEach(PublicAccessKeyKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .font(WarrenTypography.settingsControl)
                    .accessibilityIdentifier("settings.public-access.key-kind")

                    Text("Enter one key only. Approval Key and Invite Key are two ways to enroll this host.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)

                    publicAccessKeyField(tokens: tokens)

                    Text(
                        "After a successful test, leave both keys empty; gnar's persisted "
                            + "account token will be reused."
                    )
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Setup links include the selected key so recipients can authenticate. "
                            + "Treat a copied link like the key itself."
                    )
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(webStatus.publicAccessBusy)

                HStack(spacing: WarrenSpacing.compact) {
                    WarrenStatusIndicator(
                        color: publicAccessStatusColor(tokens: tokens),
                        isActive: webStatus.publicAccessBusy,
                        accessibilityLabel: publicAccessStatusLabel
                    )
                    Text(publicAccessStatusLabel)
                        .font(WarrenTypography.settingsBody)
                        .foregroundStyle(tokens.foreground)
                    Spacer(minLength: 0)
                    Button(publicAccessActionTitle) {
                        let edgeURL = publicAccessEdgeURL
                        let accountName = publicAccessAccountName
                        let inviteKey = publicAccessKeyKind == .invite ? publicAccessInviteKey : ""
                        let approvalKey = publicAccessKeyKind == .approval ? publicAccessApprovalKey : ""
                        publicAccessSubmittedKeyKind =
                            inviteKey.isEmpty && approvalKey.isEmpty ? nil : publicAccessKeyKind
                        onWebTest?(edgeURL, accountName, inviteKey, approvalKey)
                    }
                    .buttonStyle(
                        WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction)
                    )
                    .disabled(
                        webStatus.publicAccessBusy
                            || onWebTest == nil
                    )
                    .accessibilityIdentifier("settings.public-access.save-test")
                }
            } else {
                Text("Turn on Use default tunnel (gnar) to enter the Edge URL and enrollment key.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.xs) {
                Text("Public Access uses the open-source gnar worker and self-hosted Edge.")
                if let gnarURL = URL(string: WarrenPublicAccessCopy.gnarProjectURL) {
                    Link("View gnar on GitHub", destination: gnarURL)
                        .foregroundStyle(tokens.info)
                }
            }
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            if let error = webStatus.publicAccessError, !error.isEmpty {
                Text(error)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Public Access error: \(error)")
            }
        }
        .onAppear(perform: seedPublicAccessFields)
        .onChange(of: webStatus.configuredEdgeURL) { _, _ in
            seedPublicAccessFields()
        }
        .onChange(of: webStatus.configuredAccountName) { _, _ in
            seedPublicAccessFields()
        }
        .onChange(of: webStatus.publicAccessAuthenticated) { _, authenticated in
            guard authenticated else { return }
            guard let submittedKeyKind = publicAccessSubmittedKeyKind else { return }
            publicAccessInviteKey = ""
            publicAccessApprovalKey = ""
            publicAccessMaskedKeyKind = submittedKeyKind
            publicAccessSubmittedKeyKind = nil
        }
        .onChange(of: webStatus.tunnelRunning) { _, running in
            if running {
                publicAccessUseDefaultTunnel = true
            }
        }
    }

    @ViewBuilder
    private func publicAccessKeyField(tokens: WarrenColorTokens) -> some View {
        switch publicAccessKeyKind {
        case .approval:
            Text(WarrenPublicAccessCopy.approvalKey)
                .font(WarrenTypography.settingsBody)
            HStack(spacing: WarrenSpacing.small) {
                SecureField(
                    publicAccessMaskedKeyKind == .approval ? "••••••••" : "Enter Approval Key",
                    text: publicAccessKeyBinding(.approval)
                )
                .textFieldStyle(.roundedBorder)
                .font(WarrenTypography.settingsControl)
                .accessibilityLabel(PublicAccessKeyKind.approval.accessibilityTitle)
                .accessibilityIdentifier("settings.public-access.approval-key")
                pasteButton(
                    accessibilityLabel: "Paste Approval Key",
                    accessibilityIdentifier: "settings.public-access.approval-key.paste"
                ) {
                    pastePublicAccessKey(.approval)
                }
            }
        case .invite:
            Text(WarrenPublicAccessCopy.inviteKey)
                .font(WarrenTypography.settingsBody)
            HStack(spacing: WarrenSpacing.small) {
                SecureField(
                    publicAccessMaskedKeyKind == .invite ? "••••••••" : "Enter Invite Key",
                    text: publicAccessKeyBinding(.invite)
                )
                .textFieldStyle(.roundedBorder)
                .font(WarrenTypography.settingsControl)
                .accessibilityLabel(PublicAccessKeyKind.invite.accessibilityTitle)
                .accessibilityIdentifier("settings.public-access.invite-key")
                pasteButton(
                    accessibilityLabel: "Paste Invite Key",
                    accessibilityIdentifier: "settings.public-access.invite-key.paste"
                ) {
                    pastePublicAccessKey(.invite)
                }
            }

            Text("Use the invite secret from gnar, not its key name. Invite secrets must be at least 12 characters.")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }

        if publicAccessMaskedKeyKind == publicAccessKeyKind {
            Text("A key was accepted. gnar keeps the account token; Warren does not retain the key.")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pasteButton(
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .regular))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func pastedText() -> String? {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pastePublicAccessKey(_ kind: PublicAccessKeyKind) {
        guard let value = pastedText() else { return }
        publicAccessKeyBinding(kind).wrappedValue = value
    }

    private func publicAccessKeyBinding(_ kind: PublicAccessKeyKind) -> Binding<String> {
        Binding(
            get: {
                switch kind {
                case .approval: publicAccessApprovalKey
                case .invite: publicAccessInviteKey
                }
            },
            set: { value in
                publicAccessMaskedKeyKind = nil
                publicAccessSubmittedKeyKind = nil
                switch kind {
                case .approval: publicAccessApprovalKey = value
                case .invite: publicAccessInviteKey = value
                }
            }
        )
    }

    private var publicAccessActionTitle: String {
        if webStatus.publicAccessBusy { return "Testing…" }
        return "Save & Test"
    }

    private var publicAccessStatusLabel: String {
        if webStatus.publicAccessBusy { return "Testing connection…" }
        if webStatus.publicAccessError != nil { return "Connection failed" }
        if webStatus.tunnelRunning { return "Public Access is on" }
        if webStatus.publicAccessAuthenticated { return "Connected" }
        return "Not tested"
    }

    private func publicAccessStatusColor(tokens: WarrenColorTokens) -> Color {
        if webStatus.publicAccessBusy { return tokens.info }
        if webStatus.publicAccessError != nil { return tokens.warning }
        if webStatus.publicAccessAuthenticated { return tokens.success }
        return tokens.mutedForeground
    }

    private func copySettingsDeepLink(for section: SettingsSection) {
        let publicAccess: WarrenDesktopPublicAccessPrefill?
        if section == .publicAccess {
            let edgeURL = publicAccessEdgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountName = publicAccessAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let inviteKey = publicAccessKeyKind == .invite
                ? publicAccessInviteKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let approvalKey = publicAccessKeyKind == .approval
                ? publicAccessApprovalKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            publicAccess = WarrenDesktopPublicAccessPrefill(
                edgeURL: edgeURL.isEmpty
                    ? (webStatus.defaultEdgeURL?.absoluteString ?? edgeURLPlaceholder)
                    : edgeURL,
                accountName: accountName.isEmpty
                    ? (webStatus.effectiveAccountName ?? accountNamePlaceholder)
                    : accountName,
                keyKind: publicAccessKeyKind == .invite ? .invite : .approval,
                inviteKey: inviteKey.isEmpty ? nil : inviteKey,
                approvalKey: approvalKey.isEmpty ? nil : approvalKey
            )
        } else {
            publicAccess = nil
        }

        guard let url = WarrenDesktopSettingsDeepLink(
            section: section,
            publicAccess: publicAccess
        ).url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedSettingsSection = section
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedSettingsSection == section {
                copiedSettingsSection = nil
            }
        }
    }

    private func applyDeepLinkPrefill() {
        if let initialSettingsSection {
            selectedSection = initialSettingsSection
        }
        guard let publicAccessPrefill else { return }

        publicAccessUseDefaultTunnel = true
        if let edgeURL = publicAccessPrefill.edgeURL {
            publicAccessEdgeURL = edgeURL
        }
        if let accountName = publicAccessPrefill.accountName {
            publicAccessAccountName = accountName
        }
        if let keyKind = publicAccessPrefill.keyKind {
            publicAccessKeyKind = keyKind == .invite ? .invite : .approval
        }
        if let inviteKey = publicAccessPrefill.inviteKey {
            publicAccessInviteKey = inviteKey
            publicAccessMaskedKeyKind = nil
            publicAccessSubmittedKeyKind = nil
        }
        if let approvalKey = publicAccessPrefill.approvalKey {
            publicAccessApprovalKey = approvalKey
            publicAccessMaskedKeyKind = nil
            publicAccessSubmittedKeyKind = nil
        }
    }

    private var edgeURLPlaceholder: String {
        webStatus.defaultEdgeURL?.absoluteString ?? "https://tunnel.example.com"
    }

    private var accountNamePlaceholder: String {
        webStatus.effectiveAccountName ?? (hostName.isEmpty ? "this-host" : hostName)
    }

    private func seedPublicAccessFields() {
        if publicAccessEdgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let edgeURL = webStatus.configuredEdgeURL?.absoluteString,
           !edgeURL.isEmpty {
            publicAccessEdgeURL = edgeURL
        }
        if publicAccessAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let accountName = webStatus.configuredAccountName,
           !accountName.isEmpty {
            publicAccessAccountName = accountName
        }
        if webStatus.publicAccessAuthenticated,
           publicAccessMaskedKeyKind == nil,
           publicAccessInviteKey.isEmpty,
           publicAccessApprovalKey.isEmpty {
            // The bootstrap key is intentionally not persisted. A generic
            // masked placeholder still communicates that gnar is enrolled
            // when Settings is reopened without echoing which secret was used.
            publicAccessMaskedKeyKind = .invite
        }
    }

    private var runtimeSelection: Binding<String> {
        Binding(
            get: { defaultRuntime ?? "ghostline" },
            set: { onSetRuntime($0) }
        )
    }

    private func terminalRuntimeSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal runtime", section: .terminalRuntime, tokens: tokens) {
            Picker("Default runtime", selection: runtimeSelection) {
                Text("ghostline (recommended)").tag("ghostline")
                Text("tmux").tag("tmux")
            }
            .pickerStyle(.segmented)
            .font(WarrenTypography.settingsControl)
            .accessibilityIdentifier("settings.terminal-runtime.picker")

            Text(
                "This is a headless-daemon setting: the Desktop and Web are "
                    + "only clients, and sessions keep the engine they were "
                    + "created with. Changing the default affects newly "
                    + "created sessions only."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            Text("ghostline (recommended)").font(WarrenTypography.settingsBody).foregroundStyle(tokens.foreground)
            Text(
                "Server-side libghostty-vt snapshots match the client exactly; "
                    + "a detached server keeps sessions alive across daemon "
                    + "upgrades; input reaches the PTY verbatim."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            Text("tmux").font(WarrenTypography.settingsBody).foregroundStyle(tokens.foreground)
            Text(
                "Mature and battle-tested, but adds a middle layer that "
                    + "re-parses and re-renders output, translates input keys, "
                    + "and can misalign colored history on replay."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        section: SettingsSection,
        tokens: WarrenColorTokens,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
            HStack(alignment: .top, spacing: WarrenSpacing.large) {
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    Text(title).font(WarrenTypography.settingsSectionTitle)
                    Text(section.detail)
                        .font(WarrenTypography.settingsBody)
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer(minLength: WarrenSpacing.standard)
                Button {
                    copySettingsDeepLink(for: section)
                } label: {
                    Label(
                        copiedSettingsSection == section
                            ? "Copied"
                            : (section == .publicAccess ? "Copy setup link" : "Copy link"),
                        systemImage: copiedSettingsSection == section
                            ? "checkmark"
                            : "link"
                    )
                }
                .buttonStyle(.bordered)
                .font(WarrenTypography.settingsSupporting)
                .help("Copy a Warren settings link")
                .accessibilityLabel(
                    section == .publicAccess
                        ? "Copy Public Access setup link"
                        : "Copy \(section.rawValue) settings link"
                )
                .accessibilityIdentifier("settings.section.\(section.deepLinkValue).deeplink")
            }
            .padding(.bottom, WarrenSpacing.small)
            content()
        }
    }

    private var normalizedFont: TerminalFontPreference {
        TerminalFontPreference(family: fontFamily, size: fontSize)
    }

    private var preview: String {
        "Preview: " + TerminalDisplayTitleTemplate(rawValue: titleTemplate).render(.init(
            session: "Claude", command: "claude", directory: "/Users/me/Workspace/warren",
            workspace: "warren", branch: "main", host: "MacBook Pro", user: "me", os: "macOS"
        ))
    }
}

private struct InstalledIDE: Identifiable {
    let id: String
    let name: String
    let path: String
    let icon: NSImage
}
