import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

private extension WarrenDesktopSettingsSection {
    var iconName: String {
        switch self {
        case .terminalFont: "terminal"
        case .terminalTitle: "textformat"
        case .terminalRuntime: "cpu"
        case .aiTitles: "sparkles"
        case .presets: "hammer"
        case .workspaces: "arrow.triangle.branch"
        case .notifications: "bell"
        case .externalIDEs: "macwindow"
        case .relay: "point.3.connected.trianglepath.dotted"
        case .publicAccess: "globe"
        }
    }

    var detail: String {
        switch self {
        case .terminalFont: "Applied to every terminal surface."
        case .terminalTitle: "Auxiliary context below the preset bar."
        case .terminalRuntime: "Engine that owns new sessions on the headless daemon."
        case .aiTitles: "Generate concise titles from the opening exchange."
        case .presets: "Choose visible presets and customize every launch command."
        case .workspaces: "How projects import worktrees and enter sessions."
        case .notifications: "Choose how Warren alerts you when background Agents finish."
        case .externalIDEs: "Choose the IDE button default and manage workspace editors."
        case .relay: "Connect this Host to an independently deployed Warren Relay."
        case .publicAccess: "Reach this host's Web UI through the Warren Relay."
        }
    }

    var searchTerms: [String] {
        switch self {
        case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
        case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
        case .terminalRuntime: [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
        case .aiTitles: [rawValue, detail, "openai", "api", "model", "base", "key", "summary", "automatic"]
        case .presets: [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "opencode", "trae", "agent", "visible", "hidden"]
        case .workspaces: [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "shell", "AI", "Claude", "Codex"]
        case .notifications: [rawValue, detail, "sound", "audio", "chime", "agent", "complete", "background"]
        case .externalIDEs: [rawValue, detail, "ide", "editor", "embedded", "code-server", "default", "vscode", "goland", "android", "custom", "path", "open"]
        case .relay: [rawValue, detail, "owned", "relay", "enrollment", "ticket", "host", "signing key", "remote"]
        case .publicAccess: [rawValue, detail, "relay", "route", "hostname", "path", "endpoint", "tunnel", "internet"]
        }
    }

    var isTerminalSection: Bool {
        self != .notifications && self != .relay && self != .publicAccess
    }
}

/// Settings mirror Superset's route layout: a slim window-chrome row on top,
/// a 224pt sidebar with Back/title/search/grouped navigation on the left, and
/// a page-headed detail column (`max-w-5xl`) on the right.
struct WarrenDesktopSettingsView: View {
    let onBack: () -> Void
    let hostName: String
    let webStatus: WarrenDesktopWebStatus
    let onWebTest: ((String, String) -> Void)?
    let onWebStop: (() -> Void)?
    let onWebReset: (() -> Void)?
    let onRelayEnroll: ((String, String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    let defaultRuntime: String?
    let onSetRuntime: (String) -> Void
    let autoOpenShell: Bool
    let onSetAutoOpenShell: (Bool) -> Void
    let autoStartAI: Bool
    let onSetAutoStartAI: (Bool) -> Void
    let openAIBaseURL: String
    let openAIModel: String
    let openAITitleEnabled: Bool
    let onSetOpenAISetting: (String, String) -> Void
    let onTestOpenAI: @MainActor (String, String, String?) async throws -> Void

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
    @AppStorage(WarrenPreferenceKey.presetCommandOpenCode)
    private var opencodeCommand = "opencode"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    private var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    private var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    private var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.agentCompletionSoundEnabled)
    private var agentCompletionSoundEnabled = true
    @State private var openAIBaseURLDraft = ""
    @State private var openAIModelDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var openAITestStatus: OpenAITestStatus = .idle
    @State private var publicAccessHostname = ""
    @State private var publicAccessPathPrefix = ""
    @State private var relayEnrollmentTicket = ""
    @State private var relayEnrollmentBusy = false
    @State private var relayEnrollmentError: String?
    @State private var copiedSettingsSection: WarrenDesktopSettingsSection?
    @Environment(\.colorScheme) private var colorScheme

    /// A deeplink can select a page and prefill its non-secret or explicitly
    /// shared Public Access setup values. The key is never persisted by this
    /// view, but a link containing it must still be treated as a credential.
    var initialSettingsSection: WarrenDesktopSettingsSection?
    var publicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    var relayPrefill: WarrenDesktopRelayPrefill?

    private enum OpenAITestStatus {
        case idle
        case testing
        case succeeded
        case failed(String)

        var isTesting: Bool {
            if case .testing = self { return true }
            return false
        }
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
        .onChange(of: initialSettingsSection) { _ in
            applyDeepLinkPrefill()
        }
        .onChange(of: publicAccessPrefill) { _ in
            applyDeepLinkPrefill()
        }
        .onChange(of: relayPrefill) { _ in
            applyDeepLinkPrefill()
        }
        .onChange(of: searchQuery) { _ in
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
        let terminalSections = visibleSections.filter(\.isTerminalSection)
        let notificationSections = visibleSections.filter { $0 == .notifications }
        let webSections = visibleSections.filter { $0 == .relay || $0 == .publicAccess }
        return VStack(alignment: .leading, spacing: 0) {
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
                    if !terminalSections.isEmpty {
                        groupLabel("Terminal", tokens: tokens)
                    }
                    ForEach(terminalSections) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    if !notificationSections.isEmpty {
                        groupLabel("Notifications", tokens: tokens)
                    }
                    ForEach(notificationSections) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    if !webSections.isEmpty {
                        groupLabel("Web", tokens: tokens)
                    }
                    ForEach(webSections) { section in
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
                case .aiTitles:
                    aiTitlesSection(tokens: tokens)
                case .presets:
                    presetsSection(tokens: tokens)
                case .workspaces:
                    workspacesSection(tokens: tokens)
                case .notifications:
                    notificationsSection(tokens: tokens)
                case .externalIDEs:
                    externalIDEsSection(tokens: tokens)
                case .relay:
                    relaySection(tokens: tokens)
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
                    opencodeCommand = "opencode"
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
        settingsSection("Pane auxiliary title", section: .terminalTitle, tokens: tokens) {
            Text("Tab owns the primary title. This template drives the auxiliary bar below the preset row (session name · directory · command by default). Custom session names fill the {session} placeholder; each value is shortened to fit the pane.")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            settingsInputField(
                "Auxiliary template",
                text: $titleTemplate,
                placeholder: TerminalDisplayTitleTemplate.defaultValue.rawValue
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
        case .opencode:
            settingsInputField("OpenCode", text: $opencodeCommand, placeholder: "opencode")
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

    private func notificationsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Agent completion sound", section: .notifications, tokens: tokens) {
            Toggle("Play a sound when an Agent completes", isOn: $agentCompletionSoundEnabled)
                .toggleStyle(.switch)
                .font(WarrenTypography.settingsControl)
                .accessibilityIdentifier("settings.notifications.agent-completion-sound")
            Text(
                "Warren plays one short system sound for a successful Agent turn in a background pane. "
                    + "Failed and aborted turns stay silent, as does the Agent currently visible in an active window."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            Button("Play test sound") {
                WarrenDesktopNotificationSound.playAgentCompletionSoundIfEnabled()
            }
            .buttonStyle(.bordered)
            .disabled(!agentCompletionSoundEnabled)
            .accessibilityIdentifier("settings.notifications.play-test-sound")
        }
    }

    private func externalIDEsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("External IDEs", section: .externalIDEs, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Toggle(
                    "Open Embedded Editor directly from the IDE button",
                    isOn: $embeddedEditorDefaultIDE
                )
                .toggleStyle(.switch)
                .font(WarrenTypography.settingsControl)
                .accessibilityIdentifier("settings.external-ides.embedded-editor-default")
                Text(
                    "When off, the IDE button opens the IDE picker. This is the "
                        + "same default shown in the IDE menu."
                )
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            }

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

    private func relaySection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Relay", section: .relay, tokens: tokens) {
            Text("Relay is Warren's owner-controlled transport. Public Access uses the same enrolled Host and route service.")
                .font(WarrenTypography.settingsBody)
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if let relayPrefill {
                if let relayURL = relayPrefill.relayURL {
                    settingsValueRow("Relay URL", value: relayURL, tokens: tokens)
                }
                if let hostID = relayPrefill.hostID {
                    settingsValueRow("Host ID", value: hostID, tokens: tokens)
                }
                if let relayKeyID = relayPrefill.relayKeyID {
                    settingsValueRow("Signing key", value: relayKeyID, tokens: tokens)
                }
                if let enrollmentTicket = relayPrefill.enrollmentTicket {
                    SecureField("Enrollment ticket (one time)", text: $relayEnrollmentTicket)
                        .textFieldStyle(.roundedBorder)
                        .font(WarrenTypography.settingsControl)
                        .accessibilityLabel("Relay enrollment ticket")
                        .accessibilityIdentifier("settings.relay.enrollment-ticket")
                        .onAppear { relayEnrollmentTicket = enrollmentTicket }

                    HStack(spacing: WarrenSpacing.compact) {
                        Button(relayEnrollmentBusy ? "Enrolling…" : "Enroll Relay") {
                            guard let relayURL = relayPrefill.relayURL,
                                  let hostID = relayPrefill.hostID,
                                  !relayEnrollmentTicket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  let onRelayEnroll else { return }
                            relayEnrollmentBusy = true
                            relayEnrollmentError = nil
                            onRelayEnroll(relayURL, hostID, relayEnrollmentTicket) { result in
                                Task { @MainActor in
                                    relayEnrollmentBusy = false
                                    switch result {
                                    case .success:
                                        // The ticket is one-time; do not leave
                                        // it visible or reusable after the
                                        // daemon has consumed it.
                                        relayEnrollmentTicket = ""
                                        relayEnrollmentError = nil
                                    case let .failure(error):
                                        relayEnrollmentError = error.localizedDescription
                                    }
                                }
                            }
                        }
                        .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                        .disabled(relayEnrollmentBusy || onRelayEnroll == nil)
                        .accessibilityIdentifier("settings.relay.enroll")

                        if relayEnrollmentBusy {
                            WarrenStatusIndicator(
                                color: tokens.info,
                                isActive: true,
                                accessibilityLabel: "Enrolling Relay"
                            )
                        }
                    }
                }
                if let relayEnrollmentError, !relayEnrollmentError.isEmpty {
                    Text(relayEnrollmentError)
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Relay enrollment error: \(relayEnrollmentError)")
                }
                Text("This link carries a short-lived enrollment ticket. Consume it with `warren relay enroll` or the Headless Relay setup flow, then discard the link.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Create a Host on your Relay, then open its Warren setup link or run `warren relay enroll` with the one-time enrollment ticket. The daemon token remains the only Host Secret.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsValueRow(_ label: String, value: String, tokens: WarrenColorTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.small) {
            Text(label)
                .font(WarrenTypography.settingsBody)
                .foregroundStyle(tokens.mutedForeground)
            Text(value)
                .font(WarrenTypography.settingsControl)
                .foregroundStyle(tokens.foreground)
                .textSelection(.enabled)
        }
    }

    private func publicAccessSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Public Access", section: .publicAccess, tokens: tokens) {
            Text("Expose this host's Web UI through its enrolled Warren Relay. Leave the hostname and path blank to let Relay allocate safe defaults.")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                Text(WarrenPublicAccessCopy.publicHostname)
                    .font(WarrenTypography.settingsBody)
                TextField("Relay-assigned hostname", text: $publicAccessHostname)
                    .textFieldStyle(.roundedBorder)
                    .font(WarrenTypography.settingsControl)
                    .accessibilityLabel(WarrenPublicAccessCopy.publicHostname)
                    .accessibilityIdentifier("settings.public-access.public-hostname")

                Text(WarrenPublicAccessCopy.pathPrefix)
                    .font(WarrenTypography.settingsBody)
                TextField("/", text: $publicAccessPathPrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(WarrenTypography.settingsControl)
                    .accessibilityLabel(WarrenPublicAccessCopy.pathPrefix)
                    .accessibilityIdentifier("settings.public-access.path-prefix")
            }
            .disabled(webStatus.publicAccessBusy)

            if let relayURL = webStatus.relayURL {
                settingsValueRow(WarrenPublicAccessCopy.relayURL, value: relayURL.absoluteString, tokens: tokens)
            }
            if let hostID = webStatus.relayHostID, !hostID.isEmpty {
                settingsValueRow("Host ID", value: hostID, tokens: tokens)
            }
            if let routeID = webStatus.routeID, !routeID.isEmpty {
                settingsValueRow("Route ID", value: routeID, tokens: tokens)
            }
            if let authMode = webStatus.authMode, !authMode.isEmpty {
                settingsValueRow("Auth mode", value: authMode, tokens: tokens)
            }

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
                    onWebTest?(
                        publicAccessHostname.trimmingCharacters(in: .whitespacesAndNewlines),
                        publicAccessPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                .disabled(webStatus.publicAccessBusy || onWebTest == nil)
                .accessibilityIdentifier("settings.public-access.save-test")
            }

            if let publicEndpoint = webStatus.secureURL {
                settingsValueRow(WarrenPublicAccessCopy.publicEndpoint, value: publicEndpoint.absoluteString, tokens: tokens)
            }

            if hasPublicAccessSetup {
                HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.compact) {
                    Button(WarrenPublicAccessCopy.resetLocalSetup) {
                        onWebReset?()
                    }
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                    .disabled(webStatus.publicAccessBusy || onWebReset == nil)
                    .accessibilityIdentifier("settings.public-access.reset")

                    Text("Disables the Relay route and clears its local metadata. The Relay Host enrollment remains available.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Public Access and owner Relay traffic use the same Relay Host enrollment and Host Secret.")
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
        .onChange(of: webStatus.publicHostname) { _ in seedPublicAccessFields() }
        .onChange(of: webStatus.pathPrefix) { _ in seedPublicAccessFields() }
        .onChange(of: webStatus.publicAccessEnabled) { _ in clearPublicAccessFieldsIfReset() }
        .onChange(of: webStatus.publicAccessAuthenticated) { _ in clearPublicAccessFieldsIfReset() }
    }

    private var publicAccessActionTitle: String {
        if webStatus.publicAccessBusy { return "Testing…" }
        return "Save & Test"
    }

    private var hasPublicAccessSetup: Bool {
        webStatus.publicAccessAuthenticated
            || webStatus.publicAccessEnabled
            || webStatus.relayURL != nil
            || webStatus.relayHostID != nil
            || webStatus.routeID != nil
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

        relay = section == .relay ? relayPrefill : nil

        guard let url = WarrenDesktopSettingsDeepLink(
            section: section,
            publicAccess: publicAccess,
            relay: relay
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
        if let publicAccessPrefill {
            if let publicHostname = publicAccessPrefill.publicHostname {
                publicAccessHostname = publicHostname
            }
            if let pathPrefix = publicAccessPrefill.pathPrefix {
                publicAccessPathPrefix = pathPrefix
            }
        }

        if let relayPrefill {
            relayEnrollmentTicket = relayPrefill.enrollmentTicket ?? ""
        }
    }

    private func seedPublicAccessFields() {
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

    private func clearPublicAccessFieldsIfReset() {
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

        }
    }

    private func aiTitlesSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("AI session titles", section: .aiTitles, tokens: tokens) {
            Text(
                "Use an OpenAI-compatible API to suggest a concise title from the opening exchange."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
                WarrenInputField(
                    "API base URL",
                    text: $openAIBaseURLDraft,
                    placeholder: "https://api.openai.com/v1",
                    onSubmit: { saveOpenAIField("openaiBaseURL", openAIBaseURLDraft) }
                )
                WarrenInputField(
                    "Model",
                    text: $openAIModelDraft,
                    placeholder: "gpt-4o-mini",
                    onSubmit: { saveOpenAIField("openaiModel", openAIModelDraft) }
                )
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    Text("API key")
                        .font(WarrenTypography.settingsBody)
                        .foregroundStyle(tokens.mutedForeground)
                    SecureField("Leave blank to keep the saved key", text: $openAIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(WarrenTypography.settingsControl)
                        .accessibilityLabel("API key")
                }
                HStack(spacing: WarrenSpacing.compact) {
                    Button("Save API settings") {
                        saveOpenAISettings()
                    }
                    .buttonStyle(.bordered)
                    .font(WarrenTypography.settingsAction)
                    .accessibilityIdentifier("settings.ai-titles.save")

                    Button(openAITestStatus.isTesting ? "Testing…" : "Test connection") {
                        testOpenAISettings()
                    }
                    .buttonStyle(.bordered)
                    .font(WarrenTypography.settingsAction)
                    .disabled(openAITestStatus.isTesting)
                    .accessibilityIdentifier("settings.ai-titles.test")
                    .warrenSemanticElement(
                        id: "settings.ai-titles.test",
                        role: .button,
                        label: "Test AI title connection",
                        isEnabled: !openAITestStatus.isTesting,
                        action: testOpenAISettings
                    )

                    Text("The key is stored only by the Warren host and is never returned to clients.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch openAITestStatus {
                case .idle, .testing:
                    EmptyView()
                case .succeeded:
                    Text("Connection succeeded. Save the settings to use this endpoint for new titles.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.success)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message):
                    Text("Connection failed: \(message)")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(
                isOn: Binding(
                    get: { openAITitleEnabled },
                    set: { onSetOpenAISetting("openaiTitleEnabled", $0 ? "true" : "false") }
                )
            ) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("Generate titles automatically")
                        .font(WarrenTypography.settingsControl)
                    Text("Disabled by default. Warren generates a title after the opening exchange when enabled.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.ai-titles.enabled")
        }
        .onAppear(perform: seedOpenAIFields)
    }

    private func saveOpenAIField(_ key: String, _ value: String) {
        onSetOpenAISetting(key, value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveOpenAISettings() {
        saveOpenAIField("openaiBaseURL", openAIBaseURLDraft)
        saveOpenAIField("openaiModel", openAIModelDraft)
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            onSetOpenAISetting("openaiKey", key)
            openAIKeyDraft = ""
        }
    }

    private func testOpenAISettings() {
        guard !openAITestStatus.isTesting else { return }
        let baseURL = openAIBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = openAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        openAITestStatus = .testing
        Task { @MainActor in
            do {
                try await onTestOpenAI(baseURL, model, key.isEmpty ? nil : key)
                openAITestStatus = .succeeded
            } catch {
                openAITestStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func seedOpenAIFields() {
        openAIBaseURLDraft = openAIBaseURL
        openAIModelDraft = openAIModel
        openAIKeyDraft = ""
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
