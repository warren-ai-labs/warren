import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

public struct WarrenDesktopRelayDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let clientID: String
    public let createdAt: Date?
    public let lastSeenAt: Date?

    public init(id: String, clientID: String, createdAt: Date?, lastSeenAt: Date?) {
        self.id = id
        self.clientID = clientID
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

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
        case .splits: "rectangle.split.2x1"
        case .aiTitles: "sparkles"
        case .presets: "hammer"
        case .workspaces: "arrow.triangle.branch"
        case .notifications: "bell"
        case .externalIDEs: "macwindow"
        case .usageOverview: "chart.bar.xaxis"
        case .usage: "chart.line.uptrend.xyaxis"
        case .relay: "point.3.connected.trianglepath.dotted"
        case .lanPairing: "lock.shield"
        case .publicAccess: "globe"
        }
    }

    var detail: String {
        switch self {
        case .terminalFont: "Applied to every terminal surface."
        case .terminalTitle: "Auxiliary context below the preset bar."
        case .terminalRuntime: "Engine that owns new sessions on the headless daemon."
        case .splits: "Split panes and their keyboard shortcuts."
        case .aiTitles: "Generate concise titles from the opening exchange."
        case .presets: "Choose visible presets and customize every launch command."
        case .workspaces: "Configure workspace behavior and task visibility."
        case .notifications: "Choose how Warren alerts you when background Agents finish."
        case .externalIDEs: "Choose the IDE button default and manage workspace editors."
        case .usageOverview: "Review daily totals, activity heatmap, and cost breakdowns."
        case .usage: "Token consumption per Agent, with equivalent API cost."
        case .relay: "Connect once and share with iPhone."
        case .lanPairing: "Arm a temporary PIN window for a trusted iPhone."
        case .publicAccess: "Publish this Host's Web UI through the enrolled Relay."
        }
    }

    var searchTerms: [String] {
        switch self {
        case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
        case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
        case .terminalRuntime: [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
        case .splits: [rawValue, detail, "split", "pane", "emacs", "chord", "C-x", "keyboard", "shortcut"]
        case .aiTitles: [rawValue, detail, "openai", "api", "model", "base", "key", "summary", "automatic"]
        case .presets: [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "opencode", "pi", "trae", "agent", "visible", "hidden"]
        case .workspaces: [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "setup", "script", "environment", "env", "variables", "WARREN", "shell", "AI", "Claude", "Codex", "sidebar", "tasks", "visibility"]
        case .notifications: [rawValue, detail, "sound", "audio", "chime", "agent", "complete", "background"]
        case .externalIDEs: [rawValue, detail, "ide", "editor", "embedded", "code-server", "default", "vscode", "goland", "android", "custom", "path", "open"]
        case .usageOverview: [rawValue, detail, "usage", "overview", "token", "tokens", "cost", "spend", "price", "pricing", "stats", "statistics", "heatmap", "quota", "budget", "cache", "models.dev", "claude", "codex", "rebuild", "history"]
        case .usage: [rawValue, detail, "usage", "token", "tokens", "cost", "spend", "price", "pricing", "stats", "statistics", "heatmap", "quota", "budget", "cache", "models.dev", "claude", "codex"]
        case .relay: [rawValue, detail, "relay", "connect", "enrollment", "ticket", "host", "remote", "iphone", "qr"]
        case .lanPairing: [rawValue, detail, "pairing", "pin", "lan", "bonjour", "iphone", "mobile", "discovery", "security"]
        case .publicAccess: [rawValue, detail, "relay", "route", "hostname", "path", "endpoint", "tunnel", "internet"]
        }
    }

    var isTerminalSection: Bool {
        self != .notifications && self != .usageOverview && self != .usage && self != .relay
            && self != .lanPairing && self != .publicAccess
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
    let onRelayEnroll: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?
    let onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)?
    let lanPairing: WarrenDesktopLANPairing
    let onLANPairing: ((Bool, @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void) -> Void)?
    let relaySettings: WarrenDesktopRelaySettings
    let onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    let relayDevices: [WarrenDesktopRelayDevice]
    let onLoadRelayDevices: (() -> Void)?
    let onRevokeRelayDevice: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)?
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
    let projectGroups: [WarrenDesktopProjectGroup]
    let onSetProjectSetupScript: (ProjectID, String) -> Void
    let usageStats: WarrenUsageStats
    let usageState: WarrenUsageLoadState
    /// Requests a fetch for the given day range and optional detail day.
    /// Optional so hosts that do not wire usage simply show the section's
    /// empty state.
    let onLoadUsage: ((Int, String?, Bool) -> Void)?
    /// Replaces only the Host's derived Usage projections from retained Agent
    /// history. The settings page asks for confirmation before invoking it.
    let onRebuildUsage: ((@escaping (Result<Void, Error>) -> Void) -> Void)?

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
    @AppStorage(WarrenPreferenceKey.presetCommandPi)
    private var piCommand = "pi"
    @AppStorage(WarrenPreferenceKey.presetCommandQoder)
    private var qoderCommand = "qoder"
    @AppStorage(WarrenPreferenceKey.presetCommandAntigravity)
    private var antigravityCommand = "agy"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    private var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    private var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    private var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.embeddedEditorOpenLinks)
    private var embeddedEditorOpenLinks = false
    @AppStorage(WarrenPreferenceKey.agentCompletionSoundEnabled)
    private var agentCompletionSoundEnabled = true
    @AppStorage(WarrenPreferenceKey.usageRange)
    private var usageRange = WarrenUsageRange.month
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    private var showsTasks = true
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    private var splitChordsEnabled = false
    @State private var openAIBaseURLDraft = ""
    @State private var openAIModelDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var openAITestStatus: OpenAITestStatus = .idle
    @State private var publicAccessHostname = ""
    @State private var publicAccessPathPrefix = ""
    @State private var relayRegistrationURL = ""
    @State private var relayEnrollmentKey = ""
    @State private var relayResetBusy = false
    @State private var relayResetError: String?
    @State private var relayEnrollmentBusy = false
    @State private var relayEnrollmentError: String?
    @State private var relayInvite: WarrenDesktopRelayInvite?
    @State private var relayInviteBusy = false
    @State private var relayInviteError: String?
    @State private var relayInviteQRPresented = false
    @State private var lanPairingBusy = false
    @State private var lanPairingError: String?
    @State private var usageRebuildConfirmation = false
    @State private var usageRebuildBusy = false
    @State private var usageRebuildError: String?
    /// The day picked in either Usage surface, shared so Overview can open the
    /// Detail page on the day the person clicked.
    @State private var usageSelectedDay: String?
    @State private var copiedSettingsSection: WarrenDesktopSettingsSection?
    @Environment(\.colorScheme) private var colorScheme

    /// A deeplink can select a page and prefill the Relay URL and bounded-use
    /// enrollment key. The key is consumed only when the user starts joining.
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
        onRelayEnroll: ((String, String, @escaping (Result<Void, Error>) -> Void) -> Void)?,
        onRelayPairing: ((@escaping (Result<WarrenDesktopRelayInvite, Error>) -> Void) -> Void)? = nil,
        lanPairing: WarrenDesktopLANPairing = .init(),
        onLANPairing: ((Bool, @escaping (Result<WarrenDesktopLANPairing, Error>) -> Void) -> Void)? = nil,
        relaySettings: WarrenDesktopRelaySettings = .init(),
        onResetRelay: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        relayDevices: [WarrenDesktopRelayDevice] = [],
        onLoadRelayDevices: (() -> Void)? = nil,
        onRevokeRelayDevice: ((String, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
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
        projectGroups: [WarrenDesktopProjectGroup] = [],
        onSetProjectSetupScript: @escaping (ProjectID, String) -> Void = { _, _ in },
        usageStats: WarrenUsageStats = WarrenUsageStats(),
        usageState: WarrenUsageLoadState = .idle,
        onLoadUsage: ((Int, String?, Bool) -> Void)? = nil,
        onRebuildUsage: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
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
        self.lanPairing = lanPairing
        self.onLANPairing = onLANPairing
        self.relaySettings = relaySettings
        self.onResetRelay = onResetRelay
        self.relayDevices = relayDevices
        self.onLoadRelayDevices = onLoadRelayDevices
        self.onRevokeRelayDevice = onRevokeRelayDevice
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
        if !projectGroups.isEmpty {
            self.projectGroups = projectGroups
            self.projects = projectGroups.map(\.project)
        } else {
            self.projects = projects
            self.projectGroups = projects.map { WarrenDesktopProjectGroup(project: $0) }
        }
        self.onSetProjectSetupScript = onSetProjectSetupScript
        self.usageStats = usageStats
        self.usageState = usageState
        self.onLoadUsage = onLoadUsage
        self.onRebuildUsage = onRebuildUsage
        self.initialSettingsSection = initialSettingsSection
        self.publicAccessPrefill = publicAccessPrefill
        self.relayPrefill = relayPrefill
        _selectedSection = State(initialValue: initialSettingsSection ?? .terminalFont)
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
        let appearanceGroup = visibleSections.filter {
            $0 == .terminalFont || $0 == .terminalTitle || $0 == .terminalRuntime || $0 == .splits
        }
        let workflowGroup = visibleSections.filter {
            $0 == .presets || $0 == .workspaces || $0 == .externalIDEs
        }
        let aiGroup = visibleSections.filter {
            $0 == .aiTitles || $0 == .notifications
        }
        let remoteGroup = visibleSections.filter {
            $0 == .relay || $0 == .lanPairing || $0 == .publicAccess
        }
        let usageSections = visibleSections.filter {
            $0 == .usageOverview || $0 == .usage
        }

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .regular))
                    Text("Back to app")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .accessibilityLabel("Back to Warren")

            Text("Settings")
                .font(WarrenTypography.screenTitle)
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)

            searchField(tokens: tokens)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(tokens.border.opacity(0.35))
                .frame(height: WarrenSpacing.hairline)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !appearanceGroup.isEmpty {
                        groupLabel("Appearance & Terminal", tokens: tokens)
                        ForEach(appearanceGroup) { section in
                            navigationItem(section, tokens: tokens)
                        }
                    }

                    if !workflowGroup.isEmpty {
                        groupLabel("Workflow & Presets", tokens: tokens)
                        ForEach(workflowGroup) { section in
                            navigationItem(section, tokens: tokens)
                        }
                    }

                    if !aiGroup.isEmpty {
                        groupLabel("Intelligence & Alerts", tokens: tokens)
                        ForEach(aiGroup) { section in
                            navigationItem(section, tokens: tokens)
                        }
                    }

                    if !remoteGroup.isEmpty {
                        groupLabel("Remote Access", tokens: tokens)
                        ForEach(remoteGroup) { section in
                            navigationItem(section, tokens: tokens)
                        }
                    }

                    if !usageSections.isEmpty {
                        groupLabel("Observability", tokens: tokens)
                        usageRootNavigationItem(tokens: tokens)
                    }

                    if visibleSections.isEmpty {
                        VStack(spacing: WarrenSpacing.compact) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20))
                                .foregroundStyle(tokens.mutedForeground.opacity(0.5))
                            Text("No settings match your search")
                                .font(.system(size: 12))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, WarrenSpacing.large)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, WarrenSpacing.medium)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.sidebarSurface)
    }

    private func usageViewTabs(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 2) {
            usageTabButton(
                title: "Overview",
                icon: "chart.bar.xaxis",
                section: .usageOverview,
                isSelected: selectedSection == .usageOverview,
                id: "settings.usage.view.Overview",
                tokens: tokens
            )

            usageTabButton(
                title: "Usage",
                icon: "chart.xyaxis.line",
                section: .usage,
                isSelected: selectedSection == .usage,
                id: "settings.usage.view.Usage",
                tokens: tokens
            )
        }
        .padding(3)
        .background(tokens.chromeSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
    }

    private func usageTabButton(
        title: String,
        icon: String,
        section: SettingsSection,
        isSelected: Bool,
        id: String,
        tokens: WarrenColorTokens
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
            }
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? tokens.muted.opacity(0.85) : Color.clear)
            )
            .overlay(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier(id)
        .warrenSemanticElement(
            id: id,
            role: .button,
            label: title,
            isSelected: isSelected,
            action: { selectedSection = section }
        )
    }

    private func usageRootNavigationItem(tokens: WarrenColorTokens) -> some View {
        let isSelected = selectedSection == .usageOverview || selectedSection == .usage
        return Button {
            if selectedSection != .usage && selectedSection != .usageOverview {
                selectedSection = .usageOverview
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .accessibilityHidden(true)

                Text("Usage")
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? tokens.fillSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Usage")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("settings.section.Usage")
        .warrenSemanticElement(
            id: "settings.section.Usage",
            role: .button,
            label: "Usage",
            isSelected: isSelected,
            action: {
                if selectedSection != .usage && selectedSection != .usageOverview {
                    selectedSection = .usageOverview
                }
            }
        )
    }

    private func groupLabel(_ title: String, tokens: WarrenColorTokens) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(tokens.mutedForeground.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func searchField(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 14)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(tokens.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    searchFocused ? tokens.highlight.opacity(0.65) : tokens.border.opacity(0.40),
                    lineWidth: WarrenSpacing.hairline
                )
        }
    }

    private func navigationItem(
        _ section: SettingsSection,
        tokens: WarrenColorTokens,
        semanticID: String? = nil
    ) -> some View {
        let isSelected = selectedSection == section
        let itemID = semanticID ?? "settings.section.\(section.id)"
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.iconName)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .accessibilityHidden(true)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? tokens.fillSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier(itemID)
        .warrenSemanticElement(
            id: itemID,
            role: .button,
            label: section.rawValue,
            isSelected: isSelected,
            action: { selectedSection = section }
        )
    }

    private func detailPanel(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch selectedSection {
                case .terminalFont:
                    terminalFontSection(tokens: tokens)
                case .terminalTitle:
                    terminalTitleSection(tokens: tokens)
                case .terminalRuntime:
                    terminalRuntimeSection(tokens: tokens)
                case .splits:
                    splitsSection(tokens: tokens)
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
                case .usageOverview:
                    usageOverviewSection(tokens: tokens)
                case .usage:
                    usageSection(tokens: tokens)
                case .relay:
                    relaySection(tokens: tokens)
                case .lanPairing:
                    lanPairingSection(tokens: tokens)
                case .publicAccess:
                    publicAccessSection(tokens: tokens)
                }

                // Scoped to the sections it actually resets. It reads as an
                // available action on any page it appears on, which is wrong on
                // a read-only panel like Usage.
                if selectedSection.isTerminalSection {
                    Button {
                        titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                        fontFamily = TerminalFontPreference.defaultFamily
                        fontSize = TerminalFontPreference.defaultSize
                        shellCommand = ""
                        claudeCommand = "claude"
                        codexCommand = "codex --dangerously-bypass-hook-trust"
                        opencodeCommand = "opencode"
                        piCommand = "pi"
                        traeCommand = "trae-cli interactive"
                        presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
                        hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text("Restore terminal defaults")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.top, WarrenSpacing.medium)
                    .accessibilityIdentifier("settings.restore-defaults")
                }
            }
            .frame(maxWidth: WarrenLayoutMetrics.settingsContentWideMaxWidth)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
            .id(selectedSection)
        }
    }

    private func terminalFontSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal font", section: .terminalFont, tokens: tokens) {
            WarrenSettingsCard(tokens: tokens) {
                WarrenSettingsRow("Font family", description: "Typeface applied to every terminal surface", tokens: tokens) {
                    WarrenSettingsInput(
                        TerminalFontPreference.defaultFamily,
                        text: $fontFamily,
                        monospaced: true,
                        tokens: tokens
                    )
                    .frame(width: 320)
                }

                WarrenSettingsCardDivider(tokens: tokens)

                WarrenSettingsRow("Font size", description: "Point size for terminal text rendering", tokens: tokens) {
                    HStack(spacing: WarrenSpacing.compact) {
                        Text("\(Self.fontSizeLabel(fontSize)) pt")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(tokens.fillHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(tokens.border.opacity(0.35), lineWidth: WarrenSpacing.hairline)
                            )
                        Stepper("", value: $fontSize, in: 8...32, step: 1)
                            .labelsHidden()
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Terminal Preview", description: "Live preview rendered with selected typography", tokens: tokens)

                VStack(spacing: 0) {
                    // Titlebar / tab header matching Superset FontPreview
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tokens.success)
                            .frame(width: 8, height: 8)
                        Text("Terminal")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                        Spacer()
                        Text("zsh")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tokens.fillHover)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(tokens.chromeSurface)

                    Rectangle()
                        .fill(tokens.border.opacity(0.35))
                        .frame(height: WarrenSpacing.hairline)

                    // Terminal body with authentic multi-line shell session
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("~/workspace $")
                                .foregroundStyle(tokens.highlight)
                            Text("mastra dev")
                                .foregroundStyle(tokens.foreground)
                        }
                        Text("→ Loaded 3 tools · 1 agent · 0 workflows")
                            .foregroundStyle(tokens.mutedForeground)

                        HStack(spacing: 6) {
                            Text("~/workspace $")
                                .foregroundStyle(tokens.highlight)
                            Text("bun test")
                                .foregroundStyle(tokens.foreground)
                        }
                        HStack(spacing: 6) {
                            Text("✓")
                                .foregroundStyle(tokens.success)
                            Text("14 tests passed · 0.24s")
                                .foregroundStyle(tokens.foreground.opacity(0.9))
                        }

                        HStack(spacing: 6) {
                            Text("~/workspace $")
                                .foregroundStyle(tokens.highlight)
                            Text("git status --short")
                                .foregroundStyle(tokens.foreground)
                        }
                        HStack(spacing: 6) {
                            Text(" M")
                                .foregroundStyle(tokens.warning)
                            Text("src/settings/appearance.tsx")
                                .foregroundStyle(tokens.mutedForeground)
                        }

                        HStack(spacing: 4) {
                            Text("~/workspace $")
                                .foregroundStyle(tokens.highlight)
                            Rectangle()
                                .fill(tokens.foreground)
                                .frame(width: 8, height: 14)
                        }
                    }
                    .font(.custom(normalizedFont.family, size: normalizedFont.size))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tokens.background)
                }
                .clipShape(RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                        .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
                )
            }
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
            WarrenSettingsCard(tokens: tokens) {
                WarrenSettingsRow(
                    "Auxiliary template",
                    description: "Custom format string driving the auxiliary bar below preset buttons",
                    tokens: tokens
                ) {
                    WarrenSettingsInput(
                        TerminalDisplayTitleTemplate.defaultValue.rawValue,
                        text: $titleTemplate,
                        monospaced: true,
                        tokens: tokens
                    )
                    .frame(width: 380)
                }

                WarrenSettingsCardDivider(tokens: tokens)

                WarrenSettingsRow(
                    "Evaluated preview",
                    description: "Sample rendering using current workspace context",
                    tokens: tokens
                ) {
                    Text(preview)
                        .font(WarrenTypography.compactCode)
                        .foregroundStyle(tokens.highlight)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tokens.highlight.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Template Placeholders", description: "Click any token to insert into template", tokens: tokens)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 155), spacing: WarrenSpacing.compact)],
                    alignment: .leading,
                    spacing: WarrenSpacing.compact
                ) {
                    ForEach(TerminalDisplayTitleTemplate.placeholders, id: \.token) { placeholder in
                        Button {
                            if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
                            titleTemplate += placeholder.token
                        } label: {
                            HStack {
                                Text(placeholder.token)
                                    .font(WarrenTypography.compactCode)
                                    .foregroundStyle(tokens.foreground)
                                Spacer()
                                Text(placeholder.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(tokens.chromeSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(tokens.border.opacity(0.35), lineWidth: WarrenSpacing.hairline)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func presetsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Launch commands", section: .presets, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Session Presets Order & Visibility", description: "This order controls the preset buttons; opening a workspace preserves it.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 {
                            WarrenSettingsCardDivider(tokens: tokens)
                        }
                        HStack(spacing: WarrenSpacing.compact) {
                            WarrenDesktopPresetIcon(preset: preset)
                                .frame(width: 18, height: 18)
                            Text(preset.presetBarTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                            Spacer()
                            Toggle("Show \(preset.presetBarTitle)", isOn: presetVisibilityBinding(for: preset))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityIdentifier("settings.preset-visibility.\(preset.id)")

                            HStack(spacing: 4) {
                                presetMoveButton(
                                    preset: preset,
                                    direction: -1,
                                    symbolName: "chevron.up",
                                    disabled: index == 0,
                                    tokens: tokens
                                )
                                presetMoveButton(
                                    preset: preset,
                                    direction: 1,
                                    symbolName: "chevron.down",
                                    disabled: index == orderedPresets.count - 1,
                                    tokens: tokens
                                )
                            }
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, 10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Launch Commands", description: "Commands executed when launching new sessions for each agent.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 {
                            WarrenSettingsCardDivider(tokens: tokens)
                        }
                        presetCommandRow(for: preset, tokens: tokens)
                    }
                }
            }

            Text(
                "Hidden presets stay configurable here but do not appear in the "
                    + "preset bar. Commands are typed into a plain shell after it opens, so "
                    + "quitting an agent with Ctrl+C / Ctrl+D keeps the "
                    + "terminal tab alive. Leave Shell empty for a bare "
                    + "terminal."
            )
            .font(.system(size: 12))
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
        }
    }

    private func presetCommandRow(for preset: WarrenDesktopSessionPreset, tokens: WarrenColorTokens) -> some View {
        let binding: Binding<String> = {
            switch preset.request.kind {
            case .shell: return $shellCommand
            case .claude: return $claudeCommand
            case .codex: return $codexCommand
            case .opencode: return $opencodeCommand
            case .pi: return $piCommand
            case .qoder: return $qoderCommand
            case .antigravity: return $antigravityCommand
            case .trae: return $traeCommand
            case .custom: return .constant("")
            }
        }()
        let placeholder: String = {
            switch preset.request.kind {
            case .shell: return "default shell (empty)"
            case .claude: return "claude"
            case .codex: return "codex --dangerously-bypass-hook-trust"
            case .opencode: return "opencode"
            case .pi: return "pi"
            case .qoder: return "qoder"
            case .antigravity: return "agy"
            case .trae: return "trae-cli interactive"
            case .custom: return ""
            }
        }()

        return HStack(spacing: WarrenSpacing.standard) {
            HStack(spacing: WarrenSpacing.compact) {
                WarrenDesktopPresetIcon(preset: preset)
                    .frame(width: 16, height: 16)
                Text(preset.presetBarTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground)
            }
            .frame(width: 150, alignment: .leading)

            WarrenSettingsInput(placeholder, text: binding, monospaced: true, tokens: tokens)
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, 10)
    }

    private func workspaceScriptRow(
        _ project: Project,
        tokens: WarrenColorTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(alignment: .center, spacing: WarrenSpacing.small) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(tokens.primary)

                Text(project.name)
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)

                Text(project.rootPath)
                    .font(WarrenTypography.compactCode)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }

            HStack(spacing: WarrenSpacing.compact) {
                WarrenSettingsInput(
                    "scripts/setup.sh",
                    text: Binding(
                        get: { setupScriptValues[project.id] ?? project.setupScript ?? "" },
                        set: { setupScriptValues[project.id] = $0 }
                    ),
                    monospaced: true,
                    tokens: tokens
                )
                .accessibilityIdentifier("settings.project.setup-script.\(project.id)")

                Button("Save") {
                    saveSetupScript(for: project)
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                .accessibilityIdentifier("settings.workspaces.setup-script.save.\(project.id)")

                Button("Clear") {
                    setupScriptValues[project.id] = ""
                    onSetProjectSetupScript(project.id, "")
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.settingsAction)
                .foregroundStyle(tokens.mutedForeground)
                .disabled((setupScriptValues[project.id] ?? project.setupScript ?? "").isEmpty)
                .accessibilityIdentifier("settings.project.setup-script.clear.\(project.id)")
            }
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, 10)
        .accessibilityIdentifier("settings.project.card.\(project.id)")
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
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(tokens.fillHover)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? tokens.mutedForeground.opacity(0.3) : tokens.mutedForeground)
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
        case .pi:
            settingsInputField("Pi", text: $piCommand, placeholder: "pi")
        case .qoder:
            settingsInputField("Qoder", text: $qoderCommand, placeholder: "qoder")
        case .antigravity:
            settingsInputField("Antigravity", text: $antigravityCommand, placeholder: "agy")
        case .trae:
            WarrenInputField("Trae", text: $traeCommand, placeholder: "trae-cli interactive")
        case .custom:
            EmptyView()
        }
    }

    private func workspacesSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Workspaces", section: .workspaces, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Navigation & Startup", description: "Configure sidebar items and actions when opening workspaces.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow(
                        title: "Show Tasks",
                        subtitle: "Keep Tasks visible above Projects in the desktop sidebar.",
                        tokens: tokens
                    ) {
                        Toggle("Show Tasks", isOn: $showsTasks)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.workspaces.show-tasks")
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    WarrenSettingsRow(
                        title: "Open Shell on Empty Workspace",
                        subtitle: "Double-clicking an empty workspace creates a plain Shell session if automatic AI startup is not active.",
                        tokens: tokens
                    ) {
                        Toggle("Open a Shell when opening an empty workspace", isOn: Binding(
                            get: { autoOpenShell },
                            set: { onSetAutoOpenShell($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.workspaces.auto-open-shell")
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    WarrenSettingsRow(
                        title: "Start First AI on Empty Workspace",
                        subtitle: "Selecting an empty workspace automatically launches the first configured AI agent in Launch commands order.",
                        tokens: tokens
                    ) {
                        Toggle("Start the first AI when entering an empty workspace", isOn: Binding(
                            get: { autoStartAI },
                            set: { onSetAutoStartAI($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.workspaces.auto-start-ai")
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Workspace Setup Scripts", description: "Run scripts during workspace creation to initialize project environments.", tokens: tokens)

                if projects.isEmpty {
                    WarrenSettingsCard(tokens: tokens) {
                        Text("No repositories or workspaces are configured on this Host yet.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(WarrenSpacing.standard)
                    }
                } else {
                    WarrenSettingsCard(tokens: tokens) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 {
                                WarrenSettingsCardDivider(tokens: tokens)
                            }
                            workspaceScriptRow(project, tokens: tokens)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Setup Script Environment", description: "Variables added to the inherited daemon environment. First two positional arguments are main repo path and worktree path.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    ForEach(WarrenSetupScriptContract.environmentVariables, id: \.name) { variable in
                        if variable.id != (WarrenSetupScriptContract.environmentVariables.first?.id ?? "") {
                            WarrenSettingsCardDivider(tokens: tokens)
                        }
                        HStack(alignment: .center, spacing: WarrenSpacing.standard) {
                            Text(variable.name)
                                .font(WarrenTypography.compactCode)
                                .foregroundStyle(tokens.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(tokens.primary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .frame(width: 220, alignment: .leading)

                            Text(variable.description)
                                .font(.system(size: 12))
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, 10)
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
            WarrenSettingsCard(tokens: tokens) {
                WarrenSettingsRow(
                    title: "Play Completion Sound",
                    subtitle: "Warren plays a short system sound when an Agent turn completes in a background pane. Active window and aborted turns stay silent.",
                    tokens: tokens
                ) {
                    HStack(spacing: WarrenSpacing.compact) {
                        Button("Play test sound") {
                            WarrenDesktopNotificationSound.playAgentCompletionSoundIfEnabled()
                        }
                        .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                        .disabled(!agentCompletionSoundEnabled)
                        .accessibilityIdentifier("settings.notifications.play-test-sound")

                        Toggle("Play a sound when an Agent completes", isOn: $agentCompletionSoundEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.notifications.agent-completion-sound")
                    }
                }
            }
        }
    }

    private func usageOverviewSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Usage", section: .usageOverview, tokens: tokens) {
            VStack(alignment: .leading, spacing: 20) {
                usageViewTabs(tokens: tokens)

                WarrenDesktopUsageOverviewPanel(
                    stats: usageStats,
                    state: usageState,
                    tokens: tokens,
                    range: $usageRange,
                    selectedDay: $usageSelectedDay,
                    onLoad: { days, day, force in onLoadUsage?(days, day, force) },
                    onOpenDetail: { _ in selectedSection = .usage }
                )
                .onAppear { onLoadUsage?(usageRange.days, usageSelectedDay, false) }

                VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                    WarrenSettingsSectionHeader("Maintenance", description: "Rebuild cached aggregate statistics from session event history.", tokens: tokens)
                    usageRebuildSection(tokens: tokens)
                }
            }
        }
        .alert("Rebuild Usage data?", isPresented: $usageRebuildConfirmation) {
            Button("Rebuild Usage data", role: .destructive) {
                rebuildUsage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Warren will delete the current daily and intraday Usage aggregates "
                    + "and rebuild them from retained Agent history. The Agent journal "
                    + "and all other databases will remain unchanged."
            )
        }
    }

    private func usageSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Usage", section: .usage, tokens: tokens) {
            VStack(alignment: .leading, spacing: 20) {
                usageViewTabs(tokens: tokens)

                WarrenDesktopUsagePanel(
                    stats: usageStats,
                    state: usageState,
                    tokens: tokens,
                    range: $usageRange,
                    selectedDay: $usageSelectedDay,
                    onLoad: { days, day, force in onLoadUsage?(days, day, force) }
                )
                .onAppear { onLoadUsage?(usageRange.days, usageSelectedDay, false) }
            }
        }
    }

    private func usageRebuildSection(tokens: WarrenColorTokens) -> some View {
        WarrenSettingsCard(tokens: tokens) {
            WarrenSettingsRow(
                title: "Rebuild Usage Data",
                subtitle: "Use this once after upgrading if historical days are present but token totals are incomplete. Only aggregate cache is affected.",
                tokens: tokens
            ) {
                HStack(spacing: WarrenSpacing.compact) {
                    if usageRebuildBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(usageRebuildBusy ? "Rebuilding…" : "Rebuild Usage data") {
                        usageRebuildConfirmation = true
                    }
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                    .disabled(usageRebuildBusy || onRebuildUsage == nil)
                    .accessibilityIdentifier("settings.usage.rebuild")
                }
            }

            if let usageRebuildError, !usageRebuildError.isEmpty {
                WarrenSettingsCardDivider(tokens: tokens)
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.destructive)
                    Text("Usage rebuild failed: \(usageRebuildError)")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.compact)
                .accessibilityIdentifier("settings.usage.rebuild.error")
            }
        }
    }

    private func rebuildUsage() {
        guard !usageRebuildBusy, let onRebuildUsage else { return }
        usageRebuildBusy = true
        usageRebuildError = nil
        onRebuildUsage { result in
            DispatchQueue.main.async {
                usageRebuildBusy = false
                switch result {
                case .success:
                    onLoadUsage?(usageRange.days, usageSelectedDay, true)
                case .failure(let error):
                    usageRebuildError = error.localizedDescription
                }
            }
        }
    }

    private func externalIDEsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("External IDEs", section: .externalIDEs, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Editor Preferences", description: "Default behaviors for opening files and projects.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow(
                        title: "Embedded Editor by Default",
                        subtitle: "Open Embedded Editor directly from the IDE button without opening the picker menu.",
                        tokens: tokens
                    ) {
                        Toggle(
                            "Open Embedded Editor directly from the IDE button",
                            isOn: $embeddedEditorDefaultIDE
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.external-ides.embedded-editor-default")
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    WarrenSettingsRow(
                        title: "Open Terminal Links in Embedded Editor",
                        subtitle: "⌘-clicking file paths or file URLs in the terminal opens them in the Embedded Editor.",
                        tokens: tokens
                    ) {
                        Toggle(
                            "Open terminal links in Embedded Editor by default",
                            isOn: $embeddedEditorOpenLinks
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.external-ides.embedded-editor-open-links")
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Installed IDEs", description: "Applications detected on this Mac.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    if installedIDEs.isEmpty {
                        Text("No supported IDEs found on this Mac.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(WarrenSpacing.standard)
                    } else {
                        ForEach(Array(installedIDEs.enumerated()), id: \.element.id) { index, ide in
                            if index > 0 {
                                WarrenSettingsCardDivider(tokens: tokens)
                            }
                            ideRow(icon: ide.icon, name: ide.name, path: ide.path, tokens: tokens)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                HStack {
                    WarrenSettingsSectionHeader("Custom IDEs", description: "Custom app bundles or executables that accept directory paths.", tokens: tokens)
                    Spacer()
                    Button {
                        addCustomIDE()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                            Text("Add IDE…")
                        }
                    }
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                    .accessibilityIdentifier("settings.external-ides.add")
                }

                WarrenSettingsCard(tokens: tokens) {
                    if customIDEs.isEmpty {
                        Text("No custom IDEs added yet.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(WarrenSpacing.standard)
                    } else {
                        ForEach(Array(customIDEs.enumerated()), id: \.element.id) { index, ide in
                            if index > 0 {
                                WarrenSettingsCardDivider(tokens: tokens)
                            }
                            customIDERow(ide: ide, tokens: tokens)
                        }
                    }
                }
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
            .padding(.horizontal, WarrenSpacing.xxs)
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
        HStack(spacing: WarrenSpacing.standard) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
            Text(name)
                .font(WarrenTypography.settingsBodyEmphasis)
                .foregroundStyle(tokens.foreground)
            Spacer()
            Text(path)
                .font(WarrenTypography.compactCode)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.compact)
    }

    private func customIDERow(
        ide: WarrenDesktopCustomIDE,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: WarrenSpacing.standard) {
            Image(nsImage: WarrenDesktopExternalIDEIcon.normalized(
                NSWorkspace.shared.icon(forFile: ide.path)
            ))
            .resizable()
            .scaledToFit()
            .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                   height: WarrenLayoutMetrics.externalIDEIconSize)
            Text(ide.name)
                .font(WarrenTypography.settingsBodyEmphasis)
                .foregroundStyle(tokens.foreground)
            Spacer()
            Text(ide.path)
                .font(WarrenTypography.compactCode)
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
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.compact)
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
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Host Connection", description: "Connect this Host once to Relay, then pair with iPhone or browsers. Warren reconnects automatically.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    HStack(spacing: WarrenSpacing.standard) {
                        WarrenStatusIndicator(
                            color: relayStatusColor(tokens: tokens),
                            isActive: relayEnrollmentBusy || relayResetBusy,
                            accessibilityLabel: relayStatusLabel
                        )
                        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                            Text(relayStatusLabel)
                                .font(WarrenTypography.settingsBodyEmphasis)
                                .foregroundStyle(tokens.foreground)
                            Text(relaySettings.isEnrolled
                                ? "Connected. You can share this Host with iPhone or browsers."
                                : "Enter an enrollment key from your Relay administrator to connect this Host.")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(WarrenSpacing.standard)

                    WarrenSettingsCardDivider(tokens: tokens)

                    relayConnectionForm(tokens: tokens)
                }
            }

            if relaySettings.isEnrolled {
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    WarrenSettingsSectionHeader("Share with iPhone", description: "Create a reusable pairing invite for iPhone or any browser.", tokens: tokens)

                    WarrenSettingsCard(tokens: tokens) {
                        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
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
                                            .font(WarrenTypography.compactCode)
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
                        .padding(WarrenSpacing.standard)
                    }
                }

                relayDevicesSection(tokens: tokens)
            }
        }
        .onAppear(perform: seedRelayFields)
        .onChange(of: relaySettings) { _ in seedRelayFields() }
        .popover(isPresented: $relayInviteQRPresented) {
            relayInviteQRPopover()
        }
    }

    private func lanPairingSection(tokens: WarrenColorTokens) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            lanPairingContent(at: timeline.date, tokens: tokens)
        }
    }

    private func lanPairingContent(at date: Date, tokens: WarrenColorTokens) -> some View {
        let isOpen = lanPairingIsOpen(at: date)
        return settingsSection("LAN pairing", section: .lanPairing, tokens: tokens) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    WarrenSettingsSectionHeader("Pairing Status", description: "Enable a temporary window when an iPhone is ready to pair on the local network.", tokens: tokens)

                    WarrenSettingsCard(tokens: tokens) {
                        HStack(spacing: WarrenSpacing.standard) {
                            WarrenStatusIndicator(
                                color: isOpen ? tokens.success : tokens.mutedForeground,
                                isActive: lanPairingBusy,
                                accessibilityLabel: isOpen ? "Pairing window open" : "Pairing window closed"
                            )
                            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                Text(isOpen ? "Pairing window open" : "Pairing window closed")
                                    .font(WarrenTypography.settingsBodyEmphasis)
                                    .foregroundStyle(tokens.foreground)
                                Text(isOpen
                                    ? "Enter the PIN on iPhone now. This window is not enabled by discovery."
                                    : "No iPhone can pair until you explicitly open a window.")
                                    .font(WarrenTypography.settingsSupporting)
                                    .foregroundStyle(tokens.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)

                            HStack(spacing: WarrenSpacing.compact) {
                                Button(isOpen ? "Regenerate PIN" : "Enable LAN pairing") {
                                    setLANPairing(enabled: true)
                                }
                                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                                .disabled(lanPairingBusy || onLANPairing == nil)
                                .accessibilityIdentifier("settings.lan-pairing.enable")

                                if isOpen {
                                    Button("Disable pairing", role: .destructive) {
                                        setLANPairing(enabled: false)
                                    }
                                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                                    .disabled(lanPairingBusy || onLANPairing == nil)
                                    .accessibilityIdentifier("settings.lan-pairing.disable")
                                }

                                if lanPairingBusy {
                                    WarrenStatusIndicator(
                                        color: tokens.info,
                                        isActive: true,
                                        accessibilityLabel: "Updating LAN pairing"
                                    )
                                }
                            }
                        }
                        .padding(WarrenSpacing.standard)

                        if isOpen {
                            WarrenSettingsCardDivider(tokens: tokens)

                            VStack(spacing: WarrenSpacing.small) {
                                Text("PAIRING PIN")
                                    .font(WarrenTypography.settingsMeta)
                                    .foregroundStyle(tokens.mutedForeground)
                                    .tracking(1.5)

                                Text(lanPairing.pin.isEmpty ? "------" : lanPairing.pin)
                                    .font(.system(size: 38, weight: .light, design: .monospaced))
                                    .foregroundStyle(tokens.primary)
                                    .textSelection(.enabled)
                                    .accessibilityLabel("Pairing PIN \(lanPairing.pin)")
                                    .accessibilityIdentifier("settings.lan-pairing.pin")

                                Text(lanPairingExpiryText(at: date))
                                    .font(WarrenTypography.settingsSupporting)
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarrenSpacing.large)
                            .background(tokens.fillHover.opacity(0.3))
                        }
                    }
                    .warrenSemanticElement(
                        id: "settings.lan-pairing",
                        role: .group,
                        label: "LAN pairing"
                    )
                }

                if let lanPairingError, !lanPairingError.isEmpty {
                    Text(lanPairingError)
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("LAN pairing error: \(lanPairingError)")
                }

                Text(
                    "The PIN is shown only in this Desktop settings window. Pairing issues a scoped iPhone token; it does not expose the Host token or open pairing automatically."
                )
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, WarrenSpacing.xxs)
            }
        }

    private func lanPairingIsOpen(at date: Date) -> Bool {
        guard lanPairing.enabled else { return false }
        if let expiresAt = lanPairing.expiresAt {
            return expiresAt > date
        }
        return lanPairing.expiresIn > 0
    }

    private func lanPairingExpiryText(at date: Date) -> String {
        if let expiresAt = lanPairing.expiresAt {
            guard expiresAt > date else { return "Expired" }
            return "Expires \(expiresAt.formatted(date: .omitted, time: .standard))"
        }
        if lanPairing.expiresIn > 0 {
            return "Expires in \(formatPairingTTL(lanPairing.expiresIn))"
        }
        return "Expires soon"
    }

    private func formatPairingTTL(_ seconds: Int) -> String {
        if seconds >= 60 {
            return "\(max(1, seconds / 60)) min"
        }
        return "\(max(1, seconds)) sec"
    }

    private func setLANPairing(enabled: Bool) {
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

    private func relayConnectionForm(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            HStack(spacing: WarrenSpacing.standard) {
                Text("Relay URL")
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                    .frame(width: 130, alignment: .leading)

                TextField("https://relay.example.com", text: $relayRegistrationURL)
                    .textFieldStyle(.plain)
                    .font(WarrenTypography.compactCode)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(tokens.inputSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.border.opacity(0.55), lineWidth: 1))
                    .accessibilityLabel("Relay URL")
                    .accessibilityIdentifier("settings.relay.join-url")
                    .warrenSemanticElement(
                        id: "settings.relay.join-url",
                        role: .text,
                        label: "Relay URL"
                    )
            }

            HStack(spacing: WarrenSpacing.standard) {
                Text("Enrollment key")
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                    .frame(width: 130, alignment: .leading)

                SecureField("XXXX-XXXX-XXXX-XXXX", text: $relayEnrollmentKey)
                    .textFieldStyle(.plain)
                    .font(WarrenTypography.compactCode)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(tokens.inputSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.border.opacity(0.55), lineWidth: 1))
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Relay enrollment key")
                    .accessibilityIdentifier("settings.relay.enrollment-key")
                    .warrenSemanticElement(
                        id: "settings.relay.enrollment-key",
                        role: .text,
                        label: "Relay enrollment key"
                    )
            }

            HStack(spacing: WarrenSpacing.compact) {
                Button(relayEnrollmentBusy ? "Connecting…" : "Connect Relay") {
                    enrollRelay()
                }
                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
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

                if relayEnrollmentBusy {
                    WarrenStatusIndicator(
                        color: tokens.info,
                        isActive: true,
                        accessibilityLabel: "Connecting to Relay"
                    )
                }

                Spacer()

                Button("Reset local enrollment", role: .destructive) {
                    resetRelay()
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                .disabled(relayEnrollmentBusy || relayResetBusy || onResetRelay == nil)
                .accessibilityIdentifier("settings.relay.reset")
                .warrenSemanticElement(
                    id: "settings.relay.reset",
                    role: .button,
                    label: "Reset local Relay enrollment",
                    isEnabled: !relayEnrollmentBusy && !relayResetBusy && onResetRelay != nil,
                    action: resetRelay
                )
            }

            if let relayEnrollmentError, !relayEnrollmentError.isEmpty {
                Text(relayEnrollmentError)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Relay enrollment error: \(relayEnrollmentError)")
            }

            if !relaySettings.lastError.isEmpty {
                Text(relaySettings.lastError)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Relay error: \(relaySettings.lastError)")
            }

            if let relayResetError, !relayResetError.isEmpty {
                Text(relayResetError)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Relay reset error: \(relayResetError)")
            }
        }
        .padding(WarrenSpacing.standard)
        .warrenSemanticElement(
            id: "settings.relay.connection",
            role: .group,
            label: "Relay connection"
        )
    }

    private func relayDevicesSection(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            HStack {
                WarrenSettingsSectionHeader("Connected Devices", description: "Phones and browsers with active access to this Host.", tokens: tokens)
                Spacer()
                Button {
                    onLoadRelayDevices?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                .accessibilityLabel("Refresh connected devices")
            }

            WarrenSettingsCard(tokens: tokens) {
                if relayDevices.isEmpty {
                    Text("No other devices are currently associated.")
                        .font(WarrenTypography.settingsSupporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(WarrenSpacing.standard)
                } else {
                    ForEach(Array(relayDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 {
                            WarrenSettingsCardDivider(tokens: tokens)
                        }
                        HStack(spacing: WarrenSpacing.standard) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .foregroundStyle(tokens.primary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                Text(device.clientID.isEmpty ? "Native device" : device.clientID)
                                    .font(WarrenTypography.settingsBodyEmphasis)
                                    .foregroundStyle(tokens.foreground)
                                if let lastSeenAt = device.lastSeenAt {
                                    Text("Last active \(lastSeenAt, style: .relative)")
                                        .font(WarrenTypography.settingsMeta)
                                        .foregroundStyle(tokens.mutedForeground)
                                } else {
                                    Text("Last active unavailable")
                                        .font(WarrenTypography.settingsMeta)
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                onRevokeRelayDevice?(device.id) { _ in
                                    onLoadRelayDevices?()
                                }
                            }
                            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(onRevokeRelayDevice == nil)
                            .accessibilityIdentifier("settings.relay.device.revoke.\(device.id)")
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                    }
                }
            }
        }
        .onAppear { onLoadRelayDevices?() }
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

    private func enrollRelay() {
        guard !relayEnrollmentBusy,
              let onRelayEnroll else { return }
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
                    // Remove the bearer value as soon as the daemon confirms
                    // the claim, even when the key allows more than one use.
                    relayEnrollmentKey = ""
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

    private func seedRelayFields() {
        guard relayPrefill == nil else { return }
        if relayRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            relayRegistrationURL = relaySettings.relayURL
        }
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
                .font(WarrenTypography.settingsBodyEmphasis)
                .foregroundStyle(tokens.foreground)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(WarrenTypography.compactCode)
                .foregroundStyle(tokens.mutedForeground)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func publicAccessSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Public Access", section: .publicAccess, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("Public Routing", description: "Expose this host's Web UI through its enrolled Warren Relay.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                        HStack(spacing: WarrenSpacing.standard) {
                            Text(WarrenPublicAccessCopy.publicHostname)
                                .font(WarrenTypography.settingsBodyEmphasis)
                                .foregroundStyle(tokens.foreground)
                                .frame(width: 140, alignment: .leading)

                            TextField("Relay-assigned hostname", text: $publicAccessHostname)
                                .textFieldStyle(.plain)
                                .font(WarrenTypography.compactCode)
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(tokens.inputSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.border.opacity(0.55), lineWidth: 1))
                                .accessibilityLabel(WarrenPublicAccessCopy.publicHostname)
                                .accessibilityIdentifier("settings.public-access.public-hostname")
                        }

                        HStack(spacing: WarrenSpacing.standard) {
                            Text(WarrenPublicAccessCopy.pathPrefix)
                                .font(WarrenTypography.settingsBodyEmphasis)
                                .foregroundStyle(tokens.foreground)
                                .frame(width: 140, alignment: .leading)

                            TextField("/", text: $publicAccessPathPrefix)
                                .textFieldStyle(.plain)
                                .font(WarrenTypography.compactCode)
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                                .background(tokens.inputSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.border.opacity(0.55), lineWidth: 1))
                                .accessibilityLabel(WarrenPublicAccessCopy.pathPrefix)
                                .accessibilityIdentifier("settings.public-access.path-prefix")
                        }
                    }
                    .disabled(webStatus.publicAccessBusy)
                    .padding(WarrenSpacing.standard)

                    if let relayURL = webStatus.relayURL {
                        WarrenSettingsCardDivider(tokens: tokens)
                        settingsValueRow(WarrenPublicAccessCopy.relayURL, value: relayURL.absoluteString, tokens: tokens)
                            .padding(.horizontal, WarrenSpacing.standard)
                            .padding(.vertical, WarrenSpacing.compact)
                    }

                    if let publicEndpoint = webStatus.secureURL {
                        WarrenSettingsCardDivider(tokens: tokens)
                        settingsValueRow(WarrenPublicAccessCopy.publicEndpoint, value: publicEndpoint.absoluteString, tokens: tokens)
                            .padding(.horizontal, WarrenSpacing.standard)
                            .padding(.vertical, WarrenSpacing.compact)
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    HStack(spacing: WarrenSpacing.compact) {
                        WarrenStatusIndicator(
                            color: publicAccessStatusColor(tokens: tokens),
                            isActive: webStatus.publicAccessBusy,
                            accessibilityLabel: publicAccessStatusLabel
                        )
                        Text(publicAccessStatusLabel)
                            .font(WarrenTypography.settingsBodyEmphasis)
                            .foregroundStyle(tokens.foreground)
                        Spacer(minLength: 0)

                        if hasPublicAccessSetup {
                            Button(WarrenPublicAccessCopy.resetLocalSetup) {
                                onWebReset?()
                            }
                            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                            .disabled(webStatus.publicAccessBusy || onWebReset == nil)
                            .accessibilityIdentifier("settings.public-access.reset")
                        }

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
                    .padding(WarrenSpacing.standard)
                }
            }

            if let error = webStatus.publicAccessError, !error.isEmpty {
                Text(error)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Public Access error: \(error)")
            }

            Text("Public Access and owner Relay traffic use the same Relay Host enrollment and Host Secret.")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, WarrenSpacing.xxs)
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
                relayURL: relaySettings.relayURL
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
            if let enrollmentKey = relayPrefill.enrollmentKey {
                relayEnrollmentKey = enrollmentKey
            }
            // A settings link is a convenience for filling the form. Never
            // consume its bearer key merely by opening the link; the user must
            // explicitly press Connect.
        } else {
            seedRelayFields()
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
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Engine Preference", description: "Underlying terminal emulation engine used for newly created sessions.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow(
                        title: "Default Runtime",
                        subtitle: "libghostty-vt snapshots match the client exactly; detached server keeps sessions alive across daemon upgrades.",
                        tokens: tokens
                    ) {
                        Picker("Default runtime", selection: runtimeSelection) {
                            Text("ghostline (recommended)").tag("ghostline")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .font(WarrenTypography.settingsControl)
                        .accessibilityIdentifier("settings.terminal-runtime.picker")
                    }
                }
            }

            Text(
                "This is a headless-daemon setting: the Desktop and Web are "
                    + "only clients, and sessions keep the engine they were "
                    + "created with. Changing the default affects newly "
                    + "created sessions only."
            )
            .font(WarrenTypography.settingsSupporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, WarrenSpacing.xxs)
        }
    }

    private func splitsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Splits", section: .splits, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Keyboard Shortcuts", description: "Standard macOS shortcuts for organizing terminal panes.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    let shortcuts: [(String, String)] = [
                        ("Split Right", "⌘D"),
                        ("Split Below", "⇧⌘D"),
                        ("Close Split Pane", "⇧⌘W"),
                        ("Maximize Pane", "⇧⌘↩"),
                        ("Cycle Pane Focus", "⌘]")
                    ]
                    ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            WarrenSettingsCardDivider(tokens: tokens)
                        }
                        HStack {
                            Text(item.0)
                                .font(WarrenTypography.settingsBodyEmphasis)
                                .foregroundStyle(tokens.foreground)
                            Spacer()
                            Text(item.1)
                                .font(WarrenTypography.compactCode)
                                .foregroundStyle(tokens.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tokens.fillHover)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(tokens.border.opacity(0.5), lineWidth: 1))
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Chords & Sequences", description: "Alternative Emacs-style pane management keys.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow(
                        title: "Emacs C-x Split Chords",
                        subtitle: "Adds C-x 2, C-x 3, C-x 0, C-x 1, and C-x o. While enabled, C-x is intercepted by Warren and not sent to the terminal. C-g cancels, C-x C-x sends literal C-x.",
                        tokens: tokens
                    ) {
                        Toggle("Emacs C-x split chords", isOn: $splitChordsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.splits.emacs-chords")
                    }
                }
            }
        }
    }

    private func aiTitlesSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("AI session titles", section: .aiTitles, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                WarrenSettingsSectionHeader("API Configuration", description: "OpenAI-compatible endpoint used to summarize session openings into titles.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow("API Base URL", description: "OpenAI-compatible endpoint", tokens: tokens) {
                        WarrenSettingsInput(
                            "https://api.openai.com/v1",
                            text: $openAIBaseURLDraft,
                            monospaced: true,
                            tokens: tokens,
                            onSubmit: { saveOpenAIField("openaiBaseURL", openAIBaseURLDraft) }
                        )
                        .frame(width: 380)
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    WarrenSettingsRow("Model", description: "OpenAI model name", tokens: tokens) {
                        WarrenSettingsInput(
                            "gpt-4o-mini",
                            text: $openAIModelDraft,
                            monospaced: true,
                            tokens: tokens,
                            onSubmit: { saveOpenAIField("openaiModel", openAIModelDraft) }
                        )
                        .frame(width: 380)
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    WarrenSettingsRow("API Key", description: "Key stored only on this host", tokens: tokens) {
                        WarrenSettingsInput(
                            "Leave blank to keep saved key",
                            text: $openAIKeyDraft,
                            isSecure: true,
                            monospaced: true,
                            tokens: tokens
                        )
                        .frame(width: 380)
                        .accessibilityLabel("API key")
                    }

                    WarrenSettingsCardDivider(tokens: tokens)

                    HStack(spacing: WarrenSpacing.compact) {
                        Button("Save API settings") {
                            saveOpenAISettings()
                        }
                        .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.settingsAction))
                        .accessibilityIdentifier("settings.ai-titles.save")

                        Button(openAITestStatus.isTesting ? "Testing…" : "Test connection") {
                            testOpenAISettings()
                        }
                        .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.settingsAction))
                        .disabled(openAITestStatus.isTesting)
                        .accessibilityIdentifier("settings.ai-titles.test")
                        .warrenSemanticElement(
                            id: "settings.ai-titles.test",
                            role: .button,
                            label: "Test AI title connection",
                            isEnabled: !openAITestStatus.isTesting,
                            action: testOpenAISettings
                        )

                        Spacer()

                        Text("Key is stored only on the host.")
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(WarrenSpacing.standard)

                    switch openAITestStatus {
                    case .idle, .testing:
                        EmptyView()
                    case .succeeded:
                        WarrenSettingsCardDivider(tokens: tokens)
                        HStack(spacing: WarrenSpacing.compact) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(tokens.success)
                            Text("Connection succeeded. Save settings to use this endpoint.")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.success)
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                    case .failed(let message):
                        WarrenSettingsCardDivider(tokens: tokens)
                        HStack(spacing: WarrenSpacing.compact) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(tokens.destructive)
                            Text("Connection failed: \(message)")
                                .font(WarrenTypography.settingsSupporting)
                                .foregroundStyle(tokens.destructive)
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                WarrenSettingsSectionHeader("Automation", description: "Enable background title generation when sessions are started.", tokens: tokens)

                WarrenSettingsCard(tokens: tokens) {
                    WarrenSettingsRow(
                        title: "Generate Titles Automatically",
                        subtitle: "Warren sends the initial prompt to the configured LLM to generate a concise title for each new conversation.",
                        tokens: tokens
                    ) {
                        Toggle(
                            "Generate titles automatically",
                            isOn: Binding(
                                get: { openAITitleEnabled },
                                set: { onSetOpenAISetting("openaiTitleEnabled", $0 ? "true" : "false") }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.ai-titles.enabled")
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                HStack(alignment: .top, spacing: WarrenSpacing.large) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(WarrenTypography.settingsSectionTitle)
                            .foregroundStyle(tokens.foreground)
                        Text(section.detail)
                            .font(WarrenTypography.settingsSupporting)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: WarrenSpacing.standard)
                    if section != .relay {
                        Button {
                            copySettingsDeepLink(for: section)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedSettingsSection == section ? "checkmark" : "link")
                                    .font(.system(size: 11, weight: .medium))
                                Text(
                                    copiedSettingsSection == section
                                        ? "Copied"
                                        : (section == .publicAccess ? "Copy setup link" : "Copy link")
                                )
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(tokens.fillHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(tokens.border.opacity(0.35), lineWidth: WarrenSpacing.hairline)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tokens.foreground)
                        .help("Copy a Warren settings link")
                        .accessibilityLabel(
                            section == .publicAccess
                                ? "Copy Public Access setup link"
                                : "Copy \(section.rawValue) settings link"
                        )
                        .accessibilityIdentifier("settings.section.\(section.deepLinkValue).deeplink")
                    }
                }

                Rectangle()
                    .fill(tokens.border.opacity(0.4))
                    .frame(height: WarrenSpacing.hairline)
            }
            .padding(.bottom, 2)

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
