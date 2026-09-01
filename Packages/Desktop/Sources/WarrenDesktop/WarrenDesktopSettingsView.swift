import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

private enum WarrenSetupScriptContract {
    struct EnvironmentVariable: Identifiable {
        let name: String
        let description: String

        var id: String { name }
    }

    static let environmentVariables = [
        EnvironmentVariable(name: "WARREN_PROJECT_ID", description: "The Warren project ID."),
        EnvironmentVariable(name: "WARREN_PROJECT_NAME", description: "The project name."),
        EnvironmentVariable(name: "WARREN_PROJECT_PATH", description: "The main repository path."),
        EnvironmentVariable(name: "WARREN_MAIN_REPO_PATH", description: "Alias for the main repository path."),
        EnvironmentVariable(name: "WARREN_WORKSPACE_ID", description: "The newly created Workspace ID."),
        EnvironmentVariable(name: "WARREN_WORKSPACE_NAME", description: "The newly created Workspace name."),
        EnvironmentVariable(name: "WARREN_WORKSPACE_PATH", description: "The new Worktree path."),
        EnvironmentVariable(name: "WARREN_WORKTREE_PATH", description: "Alias for the new Worktree path."),
        EnvironmentVariable(name: "WARREN_WORKSPACE_BRANCH", description: "The new Worktree branch."),
        EnvironmentVariable(name: "WARREN_TASK_ID", description: "The Task ID, or empty when unattached."),
        EnvironmentVariable(name: "WARREN_SETUP_SCRIPT", description: "The resolved setup script path."),
    ]
}

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
        case .workspaces: "Configure workspace behavior and task visibility."
        case .notifications: "Choose how Warren alerts you when background Agents finish."
        case .externalIDEs: "Choose the IDE button default and manage workspace editors."
        case .relay: "Connect once and share with iPhone."
        case .publicAccess: "Publish this Host's Web UI through the enrolled Relay."
        }
    }

    var searchTerms: [String] {
        switch self {
        case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
        case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
        case .terminalRuntime: [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
        case .aiTitles: [rawValue, detail, "openai", "api", "model", "base", "key", "summary", "automatic"]
        case .presets: [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "opencode", "trae", "agent", "visible", "hidden"]
        case .workspaces: [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "setup", "script", "environment", "env", "variables", "WARREN", "shell", "AI", "Claude", "Codex", "sidebar", "tasks", "visibility"]
        case .notifications: [rawValue, detail, "sound", "audio", "chime", "agent", "complete", "background"]
        case .externalIDEs: [rawValue, detail, "ide", "editor", "embedded", "code-server", "default", "vscode", "goland", "android", "custom", "path", "open"]
        case .relay: [rawValue, detail, "relay", "connect", "enrollment", "ticket", "host", "remote", "iphone", "qr"]
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
    let onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)?
    let relaySettings: WarrenDesktopRelaySettings
    let onSetRelaySettings: ((WarrenDesktopRelaySettings, @escaping (Result<Void, Error>) -> Void) -> Void)?
    let onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
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
    let projects: [Project]
    let onSetProjectSetupScript: (ProjectID, String) -> Void

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
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    private var showsTasks = true
    @State private var openAIBaseURLDraft = ""
    @State private var openAIModelDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var openAITestStatus: OpenAITestStatus = .idle
    @State private var publicAccessHostname = ""
    @State private var publicAccessPathPrefix = ""
    @State private var relayURLDraft = ""
    @State private var relayEnabledDraft = false
    @State private var relaySetupLinkDraft = ""
    @State private var relayRegistrationURL = ""
    @State private var relayRegistrationHostID = ""
    @State private var relayEnrollmentTicket = ""
    @State private var relaySettingsBusy = false
    @State private var relayResetBusy = false
    @State private var relaySettingsError: String?
    @State private var relayEnrollmentBusy = false
    @State private var relayEnrollmentError: String?
    @State private var relayInvite: WarrenDesktopRelayInvite?
    @State private var relayInviteBusy = false
    @State private var relayInviteError: String?
    @State private var relayInviteQRPresented = false
    @State private var relayRegistrationExpanded = false
    @State private var relayDetailsExpanded = false
    @State private var relayAutoEnrollmentKey: String?
    @State private var copiedSettingsSection: WarrenDesktopSettingsSection?
    @Environment(\.colorScheme) private var colorScheme

    /// A deeplink can select a page and provide its non-secret or explicitly
    /// shared setup values. Complete Relay setup links are consumed
    /// automatically; the ticket is never persisted by this view.
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
    @State private var setupScriptValues: [ProjectID: String] = [:]

    @MainActor
    init(
        onBack: @escaping () -> Void,
        hostName: String,
        webStatus: WarrenDesktopWebStatus,
        onWebTest: ((String, String) -> Void)?,
        onWebStop: (() -> Void)?,
        onWebReset: (() -> Void)?,
        onRelayEnroll: ((String, String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?,
        onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)? = nil,
        relaySettings: WarrenDesktopRelaySettings = .init(),
        onSetRelaySettings: ((WarrenDesktopRelaySettings, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        defaultRuntime: String?,
        onSetRuntime: @escaping (String) -> Void,
        autoOpenShell: Bool,
        onSetAutoOpenShell: @escaping (Bool) -> Void,
        autoStartAI: Bool,
        onSetAutoStartAI: @escaping (Bool) -> Void,
        openAIBaseURL: String,
        openAIModel: String,
        openAITitleEnabled: Bool,
        onSetOpenAISetting: @escaping (String, String) -> Void,
        onTestOpenAI: @escaping @MainActor (String, String, String?) async throws -> Void,
        projects: [Project] = [],
        onSetProjectSetupScript: @escaping (ProjectID, String) -> Void = { _, _ in },
        initialSettingsSection: WarrenDesktopSettingsSection? = nil,
        publicAccessPrefill: WarrenDesktopPublicAccessPrefill? = nil,
        relayPrefill: WarrenDesktopRelayPrefill? = nil
    ) {
        self.onBack = onBack
        self.hostName = hostName
        self.webStatus = webStatus
        self.onWebTest = onWebTest
        self.onWebStop = onWebStop
        self.onWebReset = onWebReset
        self.onRelayEnroll = onRelayEnroll
        self.onRelayPairing = onRelayPairing
        self.relaySettings = relaySettings
        self.onSetRelaySettings = onSetRelaySettings
        self.onResetRelay = onResetRelay
        self.defaultRuntime = defaultRuntime
        self.onSetRuntime = onSetRuntime
        self.autoOpenShell = autoOpenShell
        self.onSetAutoOpenShell = onSetAutoOpenShell
        self.autoStartAI = autoStartAI
        self.onSetAutoStartAI = onSetAutoStartAI
        self.openAIBaseURL = openAIBaseURL
        self.openAIModel = openAIModel
        self.openAITitleEnabled = openAITitleEnabled
        self.onSetOpenAISetting = onSetOpenAISetting
        self.onTestOpenAI = onTestOpenAI
        self.projects = projects
        self.onSetProjectSetupScript = onSetProjectSetupScript
        self.initialSettingsSection = initialSettingsSection
        self.publicAccessPrefill = publicAccessPrefill
        self.relayPrefill = relayPrefill
    }

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
                        groupLabel("Remote access", tokens: tokens)
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

    private func setupScriptRow(
        _ project: Project,
        tokens: WarrenColorTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            Text(project.name)
                .font(WarrenTypography.settingsBody)
            Text("Path relative to the repository root, or an absolute path")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
            settingsInputField(
                "Setup script",
                text: Binding(
                    get: { setupScriptValues[project.id] ?? project.setupScript ?? "" },
                    set: { setupScriptValues[project.id] = $0 }
                ),
                placeholder: "scripts/setup.script"
            )
            .accessibilityIdentifier("settings.project.setup-script.\(project.id)")
            HStack(spacing: WarrenSpacing.compact) {
                Button("Clear") {
                    setupScriptValues[project.id] = ""
                    onSetProjectSetupScript(project.id, "")
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.settingsAction)
                .foregroundStyle(tokens.mutedForeground)
                .disabled((setupScriptValues[project.id] ?? project.setupScript ?? "").isEmpty)
                .accessibilityIdentifier("settings.project.setup-script.clear.\(project.id)")
                Button("Save") {
                    saveSetupScript(for: project)
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                .accessibilityIdentifier("settings.workspaces.setup-script.save.\(project.id)")
            }
        }
        .padding(.bottom, WarrenSpacing.small)
    }

    private func saveSetupScript(for project: Project) {
        onSetProjectSetupScript(
            project.id,
            setupScriptValues[project.id] ?? project.setupScript ?? ""
        )
    }

    private func syncSetupScriptValues() {
        for project in projects where setupScriptValues[project.id] == nil {
            setupScriptValues[project.id] = project.setupScript ?? ""
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
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Sidebar visibility")
                    .font(WarrenTypography.settingsBody)
                Toggle("Show Tasks", isOn: $showsTasks)
                    .toggleStyle(.switch)
                    .font(WarrenTypography.settingsControl)
                    .accessibilityIdentifier("settings.workspaces.show-tasks")
                Text(
                    "Choose whether Tasks remains visible above Projects in the desktop sidebar."
                )
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            }

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

            VStack(alignment: .leading, spacing: WarrenSpacing.large) {
                Text("Repository setup scripts")
                    .font(WarrenTypography.settingsSectionTitle)
                if projects.isEmpty {
                    Text("No repositories are configured on this Host yet.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                } else {
                    ForEach(projects) { project in
                        setupScriptRow(project, tokens: tokens)
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                Text("Setup script environment")
                    .font(WarrenTypography.settingsSectionTitle)
                Text(
                    "Warren adds the following variables to the inherited daemon environment. "
                        + "The first two positional arguments are the main repository path and the new Worktree path; custom arguments follow."
                )
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    ForEach(WarrenSetupScriptContract.environmentVariables) { variable in
                        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.standard) {
                            Text(variable.name)
                                .font(WarrenTypography.settingsSupporting)
                                .monospaced()
                                .frame(width: 230, alignment: .leading)
                            Text(variable.description)
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.setup-script.environment.\(variable.id)")
                    }
                }
            }
        }
        .onAppear { syncSetupScriptValues() }
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
            Text("Connect this Host once, then share a QR with iPhone. Warren reconnects automatically.")
                .font(WarrenTypography.settingsBody)
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: WarrenSpacing.large) {
                HStack(spacing: WarrenSpacing.small) {
                    WarrenStatusIndicator(
                        color: relayStatusColor(tokens: tokens),
                        isActive: relaySettingsBusy,
                        accessibilityLabel: relayStatusLabel
                    )
                    VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                        Text(relayStatusLabel)
                            .font(WarrenTypography.settingsSectionTitle)
                            .foregroundStyle(tokens.foreground)
                        Text(relaySettings.isEnrolled
                            ? "Connected. You can share this Host with iPhone."
                            : "Open the setup link from your administrator and Warren will connect automatically.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if relaySettings.isEnrolled {
                    VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                        Text("Share with iPhone")
                            .font(WarrenTypography.settingsSectionTitle)
                            .foregroundStyle(tokens.foreground)
                        Text("Create one reusable invite for iPhone or any browser. It stays valid for the sharing window and can be used on multiple devices.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: WarrenSpacing.compact) {
                            Button(relayInviteBusy ? "Preparing…" : "Share with iPhone") {
                                createRelayInvite()
                            }
                            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(relayInviteBusy || onRelayPairing == nil)
                            .accessibilityIdentifier("settings.relay.share")
                            .warrenSemanticElement(
                                id: "settings.relay.share",
                                role: .button,
                                label: "Share with iPhone",
                                isEnabled: !relayInviteBusy && onRelayPairing != nil,
                                action: createRelayInvite
                            )

                            if relayInviteBusy {
                                WarrenStatusIndicator(
                                    color: tokens.info,
                                    isActive: true,
                                    accessibilityLabel: "Creating Relay pairing link"
                                )
                            }
                        }

                        if let relayInvite {
                            HStack(alignment: .top, spacing: WarrenSpacing.compact) {
                                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                                    Text(relayInvite.url.absoluteString)
                                        .font(WarrenTypography.settingsControl)
                                        .foregroundStyle(tokens.foreground)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Text(relayInviteExpiryText(relayInvite))
                                        .font(WarrenTypography.settingsSupporting)
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                                Spacer(minLength: 0)
                                Button("Copy") { copyRelayInvite(relayInvite) }
                                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                                Button("Show QR") { relayInviteQRPresented = true }
                                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                            }
                            .padding(WarrenSpacing.compact)
                            .background(tokens.fillHover)
                            .clipShape(.rect(cornerRadius: WarrenRadius.small))
                        }

                        if let relayInviteError, !relayInviteError.isEmpty {
                            Text(relayInviteError)
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Relay pairing error: \(relayInviteError)")
                        }
                    }
                }

                DisclosureGroup(isExpanded: $relayDetailsExpanded) {
                    VStack(alignment: .leading, spacing: WarrenSpacing.large) {
                        Text("These settings are managed automatically when you open a setup link. Change them only for a managed or troubleshooting workflow.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Relay URL")
                            .font(WarrenTypography.settingsBody)
                            .foregroundStyle(tokens.mutedForeground)
                        TextField("https://relay.example.com", text: $relayURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(WarrenTypography.settingsControl)
                            .accessibilityLabel("Relay URL")
                            .accessibilityIdentifier("settings.relay.url")

                        Toggle("Enable Relay connection", isOn: $relayEnabledDraft)
                            .toggleStyle(.switch)
                            .disabled(relaySettingsBusy || relayResetBusy)
                            .accessibilityIdentifier("settings.relay.enabled")

                        HStack(spacing: WarrenSpacing.compact) {
                            Button(relaySettingsBusy ? "Saving…" : "Save connection") {
                                saveRelaySettings()
                            }
                            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(relaySettingsBusy || relayResetBusy || onSetRelaySettings == nil)
                            .accessibilityIdentifier("settings.relay.save")
                            .warrenSemanticElement(
                                id: "settings.relay.save",
                                role: .button,
                                label: "Save Relay settings",
                                isEnabled: !relaySettingsBusy && !relayResetBusy && onSetRelaySettings != nil,
                                action: saveRelaySettings
                            )

                            if relaySettingsBusy {
                                WarrenStatusIndicator(
                                    color: tokens.info,
                                    isActive: true,
                                    accessibilityLabel: "Saving Relay settings"
                                )
                            }
                        }

                        if !relaySettings.isEnrolled {
                            Text("No connection is configured yet. Open the setup link from your administrator.")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !relaySettings.lastError.isEmpty {
                            Text(relaySettings.lastError)
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Relay error: \(relaySettings.lastError)")
                        }

                        if hasRelayDetails {
                            Text("Host identity and signing keys are managed automatically and are hidden from this page.")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.relay.details")
                        }

                        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.compact) {
                            Button("Reset local enrollment", role: .destructive) {
                                resetRelay()
                            }
                            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(relaySettingsBusy || relayResetBusy || onResetRelay == nil)
                            .accessibilityIdentifier("settings.relay.reset")
                            .warrenSemanticElement(
                                id: "settings.relay.reset",
                                role: .button,
                                label: "Reset local Relay enrollment",
                                isEnabled: !relaySettingsBusy && !relayResetBusy && onResetRelay != nil,
                                action: resetRelay
                            )

                            Text("Clears this device's connection. The shared Relay record is not revoked.")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, WarrenSpacing.small)
                } label: {
                    VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                        Text("Advanced connection settings")
                            .font(WarrenTypography.settingsBody)
                            .foregroundStyle(tokens.foreground)
                        Text("For managed setups and troubleshooting")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
                .accessibilityIdentifier("settings.relay.details")
                .warrenSemanticElement(
                    id: "settings.relay.details",
                    role: .button,
                    label: "Advanced connection settings",
                    isSelected: relayDetailsExpanded,
                    action: { relayDetailsExpanded.toggle() }
                )
            }

            if let relaySettingsError, !relaySettingsError.isEmpty {
                Text(relaySettingsError)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Relay settings error: \(relaySettingsError)")
            }

            if !relaySettings.isEnrolled || relayPrefill != nil {
                DisclosureGroup(isExpanded: $relayRegistrationExpanded) {
                    VStack(alignment: .leading, spacing: WarrenSpacing.large) {
                        Text("If the setup link did not open automatically, paste it here. Warren keeps the Host credential in the daemon.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)

                        SecureField("Paste Warren setup link", text: $relaySetupLinkDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(WarrenTypography.settingsControl)
                            .accessibilityLabel("Warren Relay setup link")
                            .accessibilityIdentifier("settings.relay.setup-link")
                            .warrenSemanticElement(
                                id: "settings.relay.setup-link",
                                role: .text,
                                label: "Warren Relay setup link"
                            )

                        HStack(spacing: WarrenSpacing.compact) {
                            Button(relayEnrollmentBusy
                                ? "Connecting…"
                                : (relaySettings.isEnrolled ? "Replace connection" : "Connect Relay")) {
                                enrollRelayFromSetupLink()
                            }
                            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(
                                relayEnrollmentBusy
                                    || relaySettingsBusy
                                    || onRelayEnroll == nil
                                    || relaySetupLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                            .accessibilityIdentifier("settings.relay.reregister")
                            .warrenSemanticElement(
                                id: "settings.relay.reregister",
                                role: .button,
                                label: relaySettings.isEnrolled ? "Replace Relay connection" : "Connect Relay",
                                isEnabled: !relayEnrollmentBusy
                                    && !relaySettingsBusy
                                    && onRelayEnroll != nil
                                    && !relaySetupLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                action: enrollRelayFromSetupLink
                            )

                            if relayEnrollmentBusy {
                                WarrenStatusIndicator(
                                    color: tokens.info,
                                    isActive: true,
                                    accessibilityLabel: "Connecting to Relay"
                                )
                            }
                        }

                        if let relayEnrollmentError, !relayEnrollmentError.isEmpty {
                            Text(relayEnrollmentError)
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Relay enrollment error: \(relayEnrollmentError)")
                        }
                    }
                    .padding(.top, WarrenSpacing.small)
                } label: {
                    VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                        Text(relaySettings.isEnrolled ? "Replace connection manually" : "Use a setup link manually")
                            .font(WarrenTypography.settingsSectionTitle)
                            .foregroundStyle(tokens.foreground)
                        Text(relaySettings.isEnrolled
                            ? "Use this only when an administrator gives you a replacement setup link."
                            : "Normally, opening the setup link connects this Host automatically.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("settings.relay.registration")
                .warrenSemanticElement(
                    id: "settings.relay.registration",
                    role: .button,
                    label: relaySettings.isEnrolled ? "Replace connection manually" : "Use a setup link manually",
                    isSelected: relayRegistrationExpanded,
                    action: { relayRegistrationExpanded.toggle() }
                )
            }
        }
        .onAppear(perform: seedRelayFields)
        .onChange(of: relaySettings) { _ in seedRelayFields() }
        .popover(isPresented: $relayInviteQRPresented) {
            relayInviteQRPopover()
        }
    }

    private func createRelayInvite() {
        guard !relayInviteBusy, let onRelayPairing else { return }
        relayInviteBusy = true
        relayInviteError = nil
        onRelayPairing { result in
            Task { @MainActor in
                relayInviteBusy = false
                switch result {
                case let .success(value):
                    relayInvite = value
                    relayInviteError = nil
                    // The common path is scanning immediately. Keep the link
                    // available for copying, but present the QR as soon as it
                    // has been created so users do not need a second pairing
                    // step.
                    relayInviteQRPresented = true
                case let .failure(error):
                    relayInviteError = error.localizedDescription
                }
            }
        }
    }

    private func copyRelayInvite(_ invite: WarrenDesktopRelayInvite) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
    }

    private func relayInviteExpiryText(_ invite: WarrenDesktopRelayInvite) -> String {
        if let expiresAt = invite.expiresAt {
            return "Reusable until " + expiresAt.formatted(date: .abbreviated, time: .shortened)
        }
        if invite.expiresIn > 0 {
            return "Reusable for " + formatRelayInviteTTL(invite.expiresIn)
        }
        return "Reusable invite"
    }

    private func formatRelayInviteTTL(_ seconds: Int) -> String {
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
    private func relayInviteQRPopover() -> some View {
        VStack(spacing: WarrenSpacing.compact) {
            if let relayInvite,
               let image = qrCodeImage(for: relayInvite.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(WarrenSpacing.small)
                    .background(Color.white)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                Text("Scan with Warren on iPhone")
                    .font(WarrenTypography.settingsBody)
                Text(relayInviteExpiryText(relayInvite))
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(.secondary)
            } else {
                Text("QR code unavailable")
                    .font(WarrenTypography.settingsBody)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 300)
    }

    private func qrCodeImage(for value: String) -> NSImage? {
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

    private func saveRelaySettings() {
        guard !relaySettingsBusy, let onSetRelaySettings else { return }
        var value = relaySettings
        value.enabled = relayEnabledDraft
        value.relayURL = relayURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        relaySettingsBusy = true
        relaySettingsError = nil
        onSetRelaySettings(value) { result in
            Task { @MainActor in
                relaySettingsBusy = false
                switch result {
                case .success:
                    relaySettingsError = nil
                case let .failure(error):
                    relaySettingsError = error.localizedDescription
                }
            }
        }
    }

    private func enrollRelay() {
        guard !relayEnrollmentBusy,
              let onRelayEnroll else { return }
        let relayURL = relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = relayRegistrationHostID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticket = relayEnrollmentTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relayURL.isEmpty, !hostID.isEmpty, !ticket.isEmpty else { return }
        relayEnrollmentBusy = true
        relayEnrollmentError = nil
        onRelayEnroll(relayURL, hostID, ticket) { result in
            Task { @MainActor in
                relayEnrollmentBusy = false
                switch result {
                case .success:
                    // Enrollment tickets are one-time credentials. Remove the
                    // value as soon as the daemon confirms it was consumed.
                    relaySetupLinkDraft = ""
                    relayEnrollmentTicket = ""
                    relayEnrollmentError = nil
                case let .failure(error):
                    relayEnrollmentError = error.localizedDescription
                }
            }
        }
    }

    private func resetRelay() {
        guard !relayResetBusy, let onResetRelay else { return }
        relayResetBusy = true
        relaySettingsError = nil
        onResetRelay { result in
            Task { @MainActor in
                relayResetBusy = false
                switch result {
                case .success:
                    relayURLDraft = ""
                    relayEnabledDraft = false
                    relaySetupLinkDraft = ""
                    relayRegistrationURL = ""
                    relayRegistrationHostID = ""
                    relayEnrollmentTicket = ""
                    relayEnrollmentError = nil
                    relaySettingsError = nil
                case let .failure(error):
                    relaySettingsError = error.localizedDescription
                }
            }
        }
    }

    private func enrollRelayFromSetupLink() {
        let value = relaySetupLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let deepLink = WarrenDesktopSettingsDeepLink(url: url),
              deepLink.section == .relay,
              let prefill = deepLink.relay,
              let relayURL = prefill.relayURL,
              let hostID = prefill.hostID,
              let ticket = prefill.enrollmentTicket else {
            relayEnrollmentError = "Paste a Warren Relay setup link from your administrator."
            return
        }
        relayRegistrationURL = relayURL
        relayRegistrationHostID = hostID
        relayEnrollmentTicket = ticket
        enrollRelay()
    }

    private func seedRelayFields() {
        relayURLDraft = relaySettings.relayURL
        relayEnabledDraft = relaySettings.enabled
        guard relayPrefill == nil else { return }
        if relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            relayRegistrationURL = relaySettings.relayURL
        }
        if relayRegistrationHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            relayRegistrationHostID = relaySettings.hostID
        }
    }

    private var hasRelayDetails: Bool {
        !relaySettings.hostID.isEmpty
            || !relaySettings.routeID.isEmpty
            || !relaySettings.relayKeyID.isEmpty
            || !relaySettings.relayPublicKey.isEmpty
    }

    private var relayStatusLabel: String {
        guard relaySettings.isEnrolled else { return "Not configured" }
        return relaySettings.enabled ? "Relay enabled" : "Relay paused"
    }

    private func relayStatusColor(tokens: WarrenColorTokens) -> Color {
        guard relaySettings.isEnrolled else { return tokens.mutedForeground }
        return relaySettings.enabled ? tokens.success : tokens.warning
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

        if section == .relay {
            relay = relayPrefill ?? WarrenDesktopRelayPrefill(
                relayURL: relaySettings.relayURL,
                hostID: relaySettings.hostID,
                relayKeyID: relaySettings.relayKeyID,
                relayPublicKey: relaySettings.relayPublicKey
            )
        } else {
            relay = nil
        }

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
            if let relayURL = relayPrefill.relayURL {
                relayRegistrationURL = relayURL
            }
            if let hostID = relayPrefill.hostID {
                relayRegistrationHostID = hostID
            }
            relayEnrollmentTicket = relayPrefill.enrollmentTicket ?? ""
            autoEnrollRelayFromPrefill(relayPrefill)
        } else {
            seedRelayFields()
        }
    }

    private func autoEnrollRelayFromPrefill(_ prefill: WarrenDesktopRelayPrefill) {
        guard relayEnrollmentError == nil,
              let relayURL = prefill.relayURL,
              let hostID = prefill.hostID,
              let ticket = prefill.enrollmentTicket,
              onRelayEnroll != nil else {
            return
        }
        let key = relayURL + "\n" + hostID + "\n" + ticket
        guard relayAutoEnrollmentKey != key else { return }
        relayAutoEnrollmentKey = key
        // The prefill fields are state-backed. Defer until SwiftUI has
        // committed them so the enrollment request uses the link values the
        // user opened.
        DispatchQueue.main.async {
            enrollRelay()
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
                if section != .relay {
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
