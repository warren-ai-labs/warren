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
    /// A monochrome SF Symbol for the navigation item. The design drops the
    /// coloured tile: colour means status in Warren, so settings navigation
    /// stays grey and only a status dot carries a colour.
    var symbol: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .terminal: "terminal"
        case .splits: "rectangle.split.2x1"
        case .presets: "play.rectangle"
        case .externalIDEs: "chevron.left.forwardslash.chevron.right"
        case .notifications: "bell"
        case .workspaces: "arrow.triangle.branch"
        case .terminalRuntime: "server.rack"
        case .aiTitles: "sparkles"
        case .usage: "chart.bar"
        case .relay: "antenna.radiowaves.left.and.right"
        case .lanPairing: "wifi"
        case .publicAccess: "globe"
        }
    }

    /// The sentence beside the scope chip: what this page governs.
    var detail: String {
        switch self {
        case .appearance: "Other clients keep their own appearance."
        case .terminal: "Applied to every terminal surface."
        case .splits: "Split panes and their keyboard shortcuts."
        case .presets: "Which presets show, in what order, and what each one runs."
        case .externalIDEs: "What the IDE button opens, and which editors it lists."
        case .notifications: "How Warren tells you an Agent needs you or finished."
        case .workspaces: "Empty-workspace behavior and per-project setup scripts."
        case .terminalRuntime: "The engine that owns new sessions on the daemon."
        case .aiTitles: "Naming sessions from their opening exchange."
        case .usage: "Token consumption and its equivalent API cost."
        case .relay: "Enroll this Host and share it with iPhone."
        case .lanPairing: "A temporary PIN window for a trusted iPhone."
        case .publicAccess: "Share this Host's Web UI at a public address."
        }
    }

    /// How wide the page's column may grow before it stops and centres.
    var contentMaxWidth: CGFloat {
        switch self {
        case .usage: 1160
        // A row reads label to control in one glance at this width.
        default: 640
        }
    }

    var searchTerms: [String] {
        switch self {
        case .appearance:
            [rawValue, detail, "appearance", "theme", "light", "dark", "system", "color", "colour",
             "palette", "contrast", "glass", "translucent window", "transparency", "translucent",
             "blur", "sidebar", "tasks", "app icon", "icon", "dock", "caramel", "charcoal", "ember",
             "paper", "cream"]
        case .terminal:
            [rawValue, detail, "terminal", "font", "family", "size", "typography", "title", "template",
             "placeholder", "preview", "auxiliary"]
        case .splits:
            [rawValue, detail, "split", "pane", "emacs", "chord", "C-x", "keyboard", "shortcut"]
        case .presets:
            [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "opencode",
             "pi", "qoder", "antigravity", "trae", "agent", "visible", "hidden", "acp", "chat", "cli",
             "interface"]
        case .externalIDEs:
            [rawValue, detail, "ide", "editor", "embedded", "code-server", "default", "vscode", "goland",
             "android", "custom", "path", "open"]
        case .notifications:
            [rawValue, detail, "sound", "audio", "chime", "agent", "complete", "background", "approval",
             "badge", "dock", "alert", "waiting"]
        case .workspaces:
            [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "setup",
             "script", "environment", "env", "variables", "WARREN", "shell", "AI", "Claude", "Codex",
             "sidebar", "tasks", "visibility"]
        case .terminalRuntime:
            [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
        case .aiTitles:
            [rawValue, detail, "openai", "api", "model", "base", "key", "summary", "automatic"]
        case .usage:
            [rawValue, detail, "usage", "overview", "token", "tokens", "cost", "spend", "price",
             "pricing", "stats", "statistics", "heatmap", "quota", "budget", "cache", "models.dev",
             "claude", "codex", "rebuild", "history"]
        case .relay:
            [rawValue, detail, "relay", "connect", "enrollment", "ticket", "host", "remote", "iphone", "qr"]
        case .lanPairing:
            [rawValue, detail, "pairing", "pin", "lan", "bonjour", "iphone", "mobile", "discovery", "security"]
        case .publicAccess:
            [rawValue, detail, "relay", "route", "hostname", "path", "endpoint", "tunnel", "internet", "web"]
        }
    }
}

/// The redesigned Settings surface: a 256pt navigation card and a content card
/// on the window's black ground. The navigation is split into the preferences
/// that belong to this Mac and the values that belong to the selected Host, so
/// "which machine am I editing" is answered before a page is read.
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
    /// Turns the enrolled Relay on or off. Enrollment is kept either way, so
    /// this is the switch on the connection row, not a lifecycle command.
    let onSetRelayEnabled: ((Bool) -> Void)?
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
    let onLoadUsage: ((Int, String?, Bool) -> Void)?
    let onRebuildUsage: ((@escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void) -> Void)?

    /// The Hosts the window knows about, and the one its values currently come
    /// from. Empty means a single-Host window: the host row is a read-out.
    var hostOptions: [WarrenDesktopEndpointOption]
    var selectedHostID: String?
    var onSelectHost: ((String) -> Void)?

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
    @AppStorage(WarrenPreferenceKey.agentInterface)
    private var agentInterfaceRawValue = WarrenAgentInterface.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    private var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.embeddedEditorOpenLinks)
    private var embeddedEditorOpenLinks = false
    @AppStorage(WarrenPreferenceKey.agentCompletionSoundEnabled)
    private var agentCompletionSoundEnabled = true
    @AppStorage(WarrenPreferenceKey.agentAttentionAlertsEnabled)
    private var agentAttentionAlertsEnabled = true
    @AppStorage(WarrenPreferenceKey.agentAttentionDockBadgeEnabled)
    private var agentAttentionDockBadgeEnabled = true
    @AppStorage(WarrenPreferenceKey.usageRange)
    private var usageRange = WarrenUsageRange.month
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    private var showsTasks = true
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    private var splitChordsEnabled = false
    @AppStorage(WarrenPreferenceKey.appearanceMode)
    private var appearanceModeRawValue = WarrenAppearanceMode.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.appearanceLiquidGlass)
    private var liquidGlassEnabled = false
    @AppStorage(WarrenPreferenceKey.appearanceAppIcon)
    private var appIconRawValue = WarrenAppIconColorway.defaultValue.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
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
    /// The invite's QR code, made once when the invite arrives. Generated in
    /// the body, Core Image ran again on every render of the Relay page.
    @State private var relayInviteQRCode: NSImage?
    @State private var relayInviteBusy = false
    @State private var relayInviteError: String?
    @State private var lanPairingBusy = false
    @State private var lanPairingError: String?
    /// The one blocking confirmation the page is showing, if any.
    @State private var confirmation: SettingsConfirmation?
    /// Why the last Revoke of a Relay device failed, by device.
    @State private var relayRevokeErrors: [String: String] = [:]
    @State private var hostPickerPresented = false
    @State private var usageRebuildBusy = false
    @State private var usageRebuildError: String?
    @State private var usageRebuildSummary: WarrenUsageRebuildSummary?
    @State private var usageSelectedDay: String?
    @State private var usageShowsDetail = false
    @ObservedObject private var copyFeedback = WarrenCopyFeedback.shared
    @Environment(\.colorScheme) private var colorScheme

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

        var failure: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    private typealias SettingsSection = WarrenDesktopSettingsSection

    @State private var selectedSection: SettingsSection = .terminal
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var installedIDEs: [InstalledIDE] = []
    /// Read when the External IDEs page appears. A `@State` default runs on
    /// every initialisation of this view, which the root view repeats on each
    /// render, so decoding the store there cost a defaults read and a JSON
    /// decode per frame.
    @State private var customIDEs: [WarrenDesktopCustomIDE] = []
    /// The editor the IDE button opens. The same key the root view uses, so
    /// the checkmark here and the button's action can never disagree.
    @AppStorage("warren.desktop.externalIDEID") private var externalIDEID = ""
    @State private var setupScriptValues: [ProjectID: String] = [:]
    @State private var editingSetupScriptProjectID: ProjectID?
    @State private var editingPresetID: String?
    /// The preset being dragged, so it can be lifted while the pointer carries
    /// it and the row it is over can take it.
    @State private var draggedPresetID: String?
    /// The preset row that holds the keyboard, which is what makes ⌥↑ / ⌥↓
    /// unambiguous: they act on the row the user is standing on.
    @FocusState private var focusedPresetID: String?

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
        onSetRelayEnabled: ((Bool) -> Void)? = nil,
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
        onRebuildUsage: ((@escaping (Result<WarrenUsageRebuildSummary, Error>) -> Void) -> Void)? = nil,
        initialSettingsSection: WarrenDesktopSettingsSection? = nil,
        publicAccessPrefill: WarrenDesktopPublicAccessPrefill? = nil,
        relayPrefill: WarrenDesktopRelayPrefill? = nil,
        hostOptions: [WarrenDesktopEndpointOption] = [],
        selectedHostID: String? = nil,
        onSelectHost: ((String) -> Void)? = nil
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
        self.onSetRelayEnabled = onSetRelayEnabled
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
        self.hostOptions = hostOptions
        self.selectedHostID = selectedHostID ?? hostOptions.first?.id
        self.onSelectHost = onSelectHost
        _selectedSection = State(initialValue: initialSettingsSection ?? .terminal)
    }

    private var visibleSections: [SettingsSection] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchTerms.contains { $0.lowercased().contains(needle) }
        }
    }

    private var thisMacSections: [SettingsSection] {
        visibleSections.filter { $0.scope == .thisMac }
    }

    private var hostSections: [SettingsSection] {
        visibleSections.filter { $0.scope == .host }
    }

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(spacing: 8) {
            navigationPanel(palette: palette)
                .frame(width: 220)
            detailPanel(palette: palette)
        }
        .padding(8)
        .background(palette.windowBackdrop)
        .overlay { setupScriptDialogLayer }
        // Dialogs hang from the page's root, not from the scrolled content
        // that asked for them: a confirmation opened from the foot of a long
        // page is placed against the window, never above the visible area.
        .overlay { confirmationDialogLayer }
        .onExitCommand(perform: onBack)
        .onAppear(perform: applyDeepLinkPrefill)
        .onChange(of: initialSettingsSection) { _ in applyDeepLinkPrefill() }
        .onChange(of: publicAccessPrefill) { _ in applyDeepLinkPrefill() }
        .onChange(of: relayPrefill) { _ in applyDeepLinkPrefill() }
        .onChange(of: searchQuery) { _ in
            if !visibleSections.contains(selectedSection), let first = visibleSections.first {
                selectedSection = first
            }
        }
    }

    // MARK: - Navigation

    private func navigationPanel(palette: WarrenSettingsPalette) -> some View {
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
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func searchField(palette: WarrenSettingsPalette) -> some View {
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
        .padding(.horizontal, 10)
        .frame(height: 30)
        // As with every settings field, a click anywhere on the box focuses it.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = true }
        }
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchFocused ? palette.focusRing : palette.cardBorder, lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func sectionGroup(
        title: String,
        sections: [SettingsSection],
        palette: WarrenSettingsPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(palette.inkFaint)
                .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    navigationItem(section, palette: palette)
                }
            }
        }
    }

    private func hostGroup(palette: WarrenSettingsPalette) -> some View {
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
    private func navigationItem(_ section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
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

    private func navigationItem(
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

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one status a page can carry on its navigation tile, as of `date`.
    private func navigationStatus(for section: SettingsSection, at date: Date = Date()) -> WarrenStatusTone? {
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

    private var currentHostLabel: String {
        hostOptions.first { $0.id == selectedHostID }?.label ?? hostName
    }

    private func hostRow(palette: WarrenSettingsPalette) -> some View {
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

    private func hostPickerPanel(palette: WarrenSettingsPalette) -> some View {
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
                        Text(String(option.label.prefix(1)).lowercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.inkBody)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.controlFill))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(palette.controlSelectedBorder, lineWidth: 1)
                            }
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
    private func connectionDot(
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

    private func dot(_ color: Color, ring: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay { Circle().strokeBorder(ring, lineWidth: 1.5) }
            .accessibilityHidden(true)
    }

    // MARK: - Detail

    private func detailPanel(palette: WarrenSettingsPalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(for: selectedSection, palette: palette)
                pageContent(for: selectedSection, palette: palette)
            }
            // The column follows the window up to the page's own limit, then
            // stays centred. A form stops at a reading width, past which a row's
            // label and its control drift so far apart that the eye loses the
            // pairing; Usage is charts and figures and keeps growing. The column
            // used to stop at 656pt for every page and hug the left edge, so a
            // wider window only added empty space on the right while a year of
            // the activity calendar still did not fit.
            .frame(maxWidth: selectedSection.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
            .id(selectedSection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
    }

    private func pageHeader(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.ink)
                scopeRow(for: section, palette: palette)
            }

            Spacer(minLength: 12)

            headerAccessory(for: section, palette: palette)
        }
    }

    @ViewBuilder
    private func scopeRow(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 7) {
            if section.scope == .thisMac {
                Text("This Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkQuiet)
            } else {
                hostScopeChip(palette: palette)
            }
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(palette.inkFaint)
            Text(section.detail)
                .font(.system(size: 12))
                .foregroundStyle(palette.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Host a page applies to, named the way "This Mac" is, with the
    /// connection dot after it.
    private func hostScopeChip(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 6) {
            Text(currentHostLabel)
                .font(.system(size: 12))
                .foregroundStyle(palette.inkBody)
                .lineLimit(1)
            connectionDot(hostOptions.first { $0.id == selectedHostID }?.probeState, palette: palette)
        }
    }

    @ViewBuilder
    private func headerAccessory(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        switch section {
        case .usage:
            WarrenSettingsSegmented(
                options: WarrenUsageRange.allCases.map { ($0, $0.rawValue) },
                selection: $usageRange,
                accessibilityID: "settings.usage.range"
            )
        case .relay, .lanPairing:
            EmptyView()
        default:
            copyLinkButton(for: section, palette: palette)
        }
    }

    private func copyLinkButton(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        let copied = copyFeedback.confirms(Self.deepLinkCopySource(section))
        return Button {
            copySettingsDeepLink(for: section)
        } label: {
            Image(systemName: copied ? "checkmark" : "link")
                .font(.system(size: 14))
                .foregroundStyle(palette.inkQuiet)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section == .publicAccess ? "Copy setup link" : "Copy link")
        .accessibilityLabel(section == .publicAccess ? "Copy Public Access setup link" : "Copy \(section.rawValue) settings link")
        .accessibilityIdentifier("settings.section.\(section.deepLinkValue).deeplink")
    }

    @ViewBuilder
    private func pageContent(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        switch section {
        case .appearance: appearanceSection(palette: palette)
        case .terminal: terminalSection(palette: palette)
        case .splits: splitsSection(palette: palette)
        case .presets: presetsSection(palette: palette)
        case .externalIDEs: externalIDEsSection(palette: palette)
        case .notifications: notificationsSection(palette: palette)
        case .workspaces: workspacesSection(palette: palette)
        case .terminalRuntime: terminalRuntimeSection(palette: palette)
        case .aiTitles: aiTitlesSection(palette: palette)
        case .usage: usageSection(palette: palette)
        case .relay: relaySection(palette: palette)
        case .lanPairing: lanPairingSection(palette: palette)
        case .publicAccess: publicAccessSection(palette: palette)
        }
    }

    // MARK: - Appearance

    private func appearanceSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Window", footnote: "System follows macOS. Light uses Ember Paper for the window and the terminal, with an ANSI palette tuned for light backgrounds.") {
                WarrenSettingsRow("Color scheme") {
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

            WarrenSettingsGroup("App Icon", footnote: "Changes the icon in the Dock and the app switcher while Warren is running. Finder keeps the Caramel icon.") {
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
                .padding(.horizontal, 14)
                .padding(.top, 14)
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

    private static func appearanceSublabel(_ mode: WarrenAppearanceMode) -> String {
        switch mode {
        case .system: "Follows macOS"
        case .light: "Ember Paper"
        case .dark: "Ember"
        }
    }

    // MARK: - Terminal

    private func terminalSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Font") {
                WarrenSettingsRow("Family") {
                    WarrenSettingsPicker(
                        label: "Font family",
                        value: fontFamily,
                        options: monospacedFamilies.map { ($0, $0, nil) },
                        selection: $fontFamily,
                        monospaced: true,
                        sourceNote: "Monospaced fonts on this Mac",
                        accessibilityID: "settings.terminal.font-family"
                    )
                }

                WarrenSettingsRowDivider()

                WarrenSettingsRow("Size") {
                    WarrenSettingsStepper(
                        value: $fontSize,
                        range: 9...24,
                        unit: "pt",
                        display: { String(Int($0.rounded())) },
                        accessibilityID: "settings.terminal.font-size"
                    )
                }

                WarrenSettingsRowDivider()

                TerminalFontPreview(preference: normalizedFont, palette: palette, title: preview)
            }

            WarrenSettingsGroup("Pane title", accessory: "The line under each pane's header") {
                VStack(alignment: .leading, spacing: 6) {
                    WarrenSettingsTextField(
                        placeholder: TerminalDisplayTitleTemplate.defaultValue.rawValue,
                        text: $titleTemplate,
                        monospaced: true,
                        accessibilityID: "settings.terminal.title-template"
                    )
                    HStack(spacing: 6) {
                        Text("↳")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(palette.inkFaint)
                            .accessibilityHidden(true)
                        Text(renderedTitle)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(palette.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityLabel("Preview \(renderedTitle)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                WarrenSettingsRowDivider()

                FlowingChips(
                    tokens: TerminalDisplayTitleTemplate.placeholders.map { ($0.token, $0.description) },
                    palette: palette,
                    onInsert: insertPlaceholder
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Button("Restore Terminal Defaults") {
                titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                fontFamily = TerminalFontPreference.defaultFamily
                fontSize = TerminalFontPreference.defaultSize
            }
            .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
            .padding(.leading, 14)
            .accessibilityIdentifier("settings.restore-defaults")

            crossLink(
                "The engine that runs new Sessions is a Host setting, in",
                to: .terminalRuntime,
                palette: palette,
                identifier: "settings.terminal.goto-runtime"
            )
        }
    }

    private func insertPlaceholder(_ token: String) {
        if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
        titleTemplate += token
    }

    // MARK: - Splits

    private func splitsSection(palette: WarrenSettingsPalette) -> some View {
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

    // MARK: - Launch commands

    private func presetsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Agent interface") {
                WarrenSettingsRow(
                    "Launch As",
                    description: "Claude, Codex and OpenCode can run as their CLI or as a Chat over ACP. Ask each time shows both under the clicked preset."
                ) {
                    WarrenSettingsSegmented(
                        options: WarrenAgentInterface.allCases.map { ($0, $0.displayName) },
                        selection: agentInterfaceSelection,
                        accessibilityID: "settings.agent-interface.picker"
                    )
                }
            }

            WarrenSettingsGroup(
                "Presets",
                accessory: "Order here is the order in the + menu",
                footnote: "Commands are typed into a plain shell after it opens, so quitting an agent with Ctrl-C or Ctrl-D keeps the tab alive. Leave Shell empty for a bare terminal. Hidden presets keep their command. Click a row to edit it."
            ) {
                ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { WarrenSettingsRowDivider() }
                    mergedPresetRow(preset, index: index, palette: palette)
                }
            }
        }
    }

    /// One row per preset, carrying its order, its visibility, and its command:
    /// the two old lists read as the same list to a user, so they are one now.
    /// Clicking the row (outside its controls) opens the command editor under it.
    private func mergedPresetRow(
        _ preset: WarrenDesktopSessionPreset,
        index: Int,
        palette: WarrenSettingsPalette
    ) -> some View {
        let isVisible = !WarrenDesktopSessionPreset.normalizedHidden(hiddenPresets).contains(preset.id)
        let isEditing = editingPresetID == preset.id
        let isEditable = preset.request.kind != .browser && preset.request.kind != .custom
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    guard isEditable else { return }
                    editingPresetID = isEditing ? nil : preset.id
                } label: {
                    HStack(spacing: 10) {
                        WarrenDesktopPresetIcon(preset: preset)
                            .frame(width: 18, height: 18)
                            .opacity(isVisible ? 1 : 0.45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.presetBarTitle)
                                .font(.system(size: 13))
                                .foregroundStyle(isVisible ? palette.inkBody : palette.inkFaint)
                            Text(presetCommandSummary(preset))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(palette.meta)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .focusable()
                .focused($focusedPresetID, equals: preset.id)

                HStack(spacing: 4) {
                    presetMoveButton(preset: preset, direction: -1, symbolName: "arrow.up", disabled: index == 0)
                    presetMoveButton(preset: preset, direction: 1, symbolName: "arrow.down", disabled: index == orderedPresets.count - 1)
                }
                WarrenSettingsSwitch(isOn: presetVisibilityBinding(for: preset))
                    .accessibilityLabel("Show \(preset.presetBarTitle)")
                    .accessibilityIdentifier("settings.preset-visibility.\(preset.id)")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(
                draggedPresetID == preset.id ? palette.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .shadow(
                color: .black.opacity(draggedPresetID == preset.id ? 0.45 : 0),
                radius: 10,
                y: 8
            )
            .draggable(preset.id) {
                Text(preset.presetBarTitle)
                    .font(.system(size: 12))
                    .padding(6)
                    .background(palette.card)
                    .onAppear { draggedPresetID = preset.id }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let dragged = ids.first, dragged != preset.id else { return false }
                presetOrder = WarrenDesktopSessionPreset.moving(
                    dragged,
                    before: preset.id,
                    in: presetOrder
                )
                return true
            }
            .overlay(alignment: .leading) {
                // ⌥↑ / ⌥↓ belong to the row the keyboard is on. The buttons carry
                // the shortcuts and draw nothing.
                if focusedPresetID == preset.id {
                    HStack(spacing: 0) {
                        Button("") {
                            presetOrder = WarrenDesktopSessionPreset.moving(
                                preset.id,
                                by: -1,
                                in: presetOrder
                            )
                        }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                        Button("") {
                            presetOrder = WarrenDesktopSessionPreset.moving(
                                preset.id,
                                by: 1,
                                in: presetOrder
                            )
                        }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }

            if isEditing {
                WarrenSettingsTextField(
                    placeholder: commandPlaceholder(for: preset),
                    text: commandBinding(for: preset),
                    monospaced: true,
                    onSubmit: { editingPresetID = nil },
                    accessibilityID: "settings.preset-command.\(preset.id)"
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: isEditing)
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: draggedPresetID)
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            draggedPresetID = nil
            return false
        }
    }

    private func presetCommandSummary(_ preset: WarrenDesktopSessionPreset) -> String {
        if preset.request.kind == .browser { return "Launched by the Host" }
        let command = commandBinding(for: preset).wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? "Empty: bare terminal" : command
    }

    private func commandBinding(for preset: WarrenDesktopSessionPreset) -> Binding<String> {
        switch preset.request.kind {
        case .shell: return $shellCommand
        case .claude: return $claudeCommand
        case .codex: return $codexCommand
        case .opencode: return $opencodeCommand
        case .pi: return $piCommand
        case .qoder: return $qoderCommand
        case .antigravity: return $antigravityCommand
        case .trae: return $traeCommand
        case .custom, .browser: return .constant("")
        }
    }

    private func commandPlaceholder(for preset: WarrenDesktopSessionPreset) -> String {
        switch preset.request.kind {
        case .shell: return "Empty: bare terminal"
        case .claude: return "claude"
        case .codex: return "codex --dangerously-bypass-hook-trust"
        case .opencode: return "opencode"
        case .pi: return "pi"
        case .qoder: return "qoder"
        case .antigravity: return "agy"
        case .trae: return "trae-cli interactive"
        case .custom, .browser: return ""
        }
    }

    private func presetMoveButton(
        preset: WarrenDesktopSessionPreset,
        direction: Int,
        symbolName: String,
        disabled: Bool
    ) -> some View {
        let directionLabel = direction < 0 ? "up" : "down"
        return Button {
            presetOrder = WarrenDesktopSessionPreset.moving(preset.id, by: direction, in: presetOrder)
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Move \(preset.presetBarTitle) \(directionLabel)")
        .accessibilityIdentifier("settings.preset-order.\(preset.id).\(directionLabel)")
    }

    // MARK: - Editors

    /// The single-choice column: which editor Open in Editor uses. Empty for
    /// the rows that are not it, so every name keeps the same column.
    private func editorCheck(_ isSelected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WarrenSettingsPalette.resolved(for: colorScheme).ink)
            .frame(width: 14)
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }

    private func externalIDEsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Embedded editor") {
                WarrenSettingsToggleRow(
                    title: "Open Embedded Editor by Default",
                    description: "The IDE button opens it directly instead of showing the picker.",
                    isOn: $embeddedEditorDefaultIDE,
                    accessibilityID: "settings.external-ides.embedded-editor-default"
                )
                WarrenSettingsRowDivider()
                WarrenSettingsToggleRow(
                    title: "Open Terminal Links in Embedded Editor",
                    description: "⌘-click a file path or file URL in the terminal to open it there.",
                    isOn: $embeddedEditorOpenLinks,
                    accessibilityID: "settings.external-ides.embedded-editor-open-links"
                )
            }

            WarrenSettingsGroup("Found on this Mac", footnote: "The list is whatever Warren detects.") {
                if installedIDEs.isEmpty {
                    WarrenSettingsEmptyRow(text: "No supported editors found on this Mac.")
                } else {
                    ForEach(Array(installedIDEs.enumerated()), id: \.element.id) { index, ide in
                        if index > 0 { WarrenSettingsRowDivider() }
                        Button { externalIDEID = ide.id } label: {
                            WarrenSettingsListRow(
                                title: ide.name,
                                subtitle: ide.path,
                                leading: {
                                    HStack(spacing: 8) {
                                        editorCheck(externalIDEID == ide.id)
                                        Image(nsImage: ide.icon)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                    }
                                },
                                trailing: { EmptyView() }
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(ide.name) for Open in Editor")
                        .accessibilityAddTraits(externalIDEID == ide.id ? [.isSelected] : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                WarrenSettingsGroup("Custom") {
                    if customIDEs.isEmpty {
                        WarrenSettingsEmptyRow(text: "No custom editors yet.")
                    } else {
                        ForEach(Array(customIDEs.enumerated()), id: \.element.id) { index, ide in
                            if index > 0 { WarrenSettingsRowDivider() }
                            let optionID = "custom:\(ide.id.uuidString)"
                            Button { externalIDEID = optionID } label: {
                                WarrenSettingsListRow(
                                    title: ide.name,
                                    subtitle: ide.path,
                                    leading: {
                                        HStack(spacing: 8) {
                                            editorCheck(externalIDEID == optionID)
                                            Image(nsImage: WarrenDesktopExternalIDEIcon.normalized(
                                                NSWorkspace.shared.icon(forFile: ide.path)
                                            ))
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                        }
                                    },
                                    trailing: {
                                        WarrenSettingsInlineButton(systemImage: "trash", label: "Remove \(ide.name)") {
                                            removeCustomIDE(ide)
                                        }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(ide.name) for Open in Editor")
                            .accessibilityAddTraits(externalIDEID == optionID ? [.isSelected] : [])
                        }
                    }
                }

                Button {
                    addCustomIDE()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("Add Editor…")
                    }
                }
                .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                .padding(.leading, 14)
                .accessibilityIdentifier("settings.external-ides.add")
            }
        }
        .onAppear {
            customIDEs = WarrenDesktopCustomIDEStore.load()
            // Launch Services lookups and icon renders on the main thread:
            // probe once per page lifetime rather than on every visit.
            if installedIDEs.isEmpty {
                installedIDEs = Self.probeInstalledIDEs()
            }
        }
    }

    // MARK: - Notifications

    private func notificationsSection(palette: WarrenSettingsPalette) -> some View {
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

    // MARK: - Workspaces

    private func workspacesSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Empty workspace") {
                WarrenSettingsToggleRow(
                    title: "Start the First Agent",
                    description: "Selecting an empty workspace launches the first Agent in Launch Commands order.",
                    isOn: Binding(get: { autoStartAI }, set: { onSetAutoStartAI($0) }),
                    accessibilityID: "settings.workspaces.auto-start-ai"
                )
                WarrenSettingsRowDivider()
                WarrenSettingsToggleRow(
                    title: "Open a Shell",
                    description: autoStartAI
                        ? "Off while the first Agent starts on its own."
                        : "Double-clicking an empty workspace opens a plain Shell.",
                    isOn: Binding(get: { autoOpenShell }, set: { onSetAutoOpenShell($0) }),
                    isEnabled: !autoStartAI,
                    accessibilityID: "settings.workspaces.auto-open-shell"
                )
            }

            WarrenSettingsGroup("Setup scripts", accessory: "Runs when a worktree is created") {
                if projects.isEmpty {
                    WarrenSettingsEmptyRow(text: "No repositories are configured on this Host yet.")
                } else {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { WarrenSettingsRowDivider() }
                        setupScriptRow(project, palette: palette)
                    }
                }
            }

            WarrenSettingsGroup("Script environment") {
                environmentRow(code: "$1  $2", description: "Main repository path, then the new worktree path.", palette: palette)
                ForEach(WarrenSetupScriptContract.environmentVariables) { variable in
                    WarrenSettingsRowDivider()
                    environmentRow(code: variable.name, description: variable.description, palette: palette)
                }
            }
        }
        .onAppear { syncSetupScriptValues() }
    }

    private func setupScriptRow(_ project: Project, palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsListRow(
            title: project.name,
            subtitle: setupScriptSummary(project),
            leading: { EmptyView() },
            trailing: {
                Button("Edit…") { editingSetupScriptProjectID = project.id }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .accessibilityLabel("Edit setup script for \(project.name)")
            }
        )
    }

    /// The row says only what fits: the script's first line and how many more
    /// there are, or that there is none. The whole script is in the dialog.
    private func setupScriptSummary(_ project: Project) -> String {
        let script = setupScriptValues[project.id] ?? project.setupScript ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No script"
        }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        return lines.count > 1 ? "\(first)  +\(lines.count - 1) lines" : first
    }

    @ViewBuilder
    private var setupScriptDialogLayer: some View {
        if let id = editingSetupScriptProjectID,
           let project = projects.first(where: { $0.id == id }) {
            WarrenDesktopSetupScriptDialog(
                script: Binding(
                    get: { setupScriptValues[id] ?? project.setupScript ?? "" },
                    set: { setupScriptValues[id] = $0 }
                ),
                onClear: {
                    setupScriptValues[id] = ""
                    onSetProjectSetupScript(id, "")
                    editingSetupScriptProjectID = nil
                },
                onCancel: { editingSetupScriptProjectID = nil },
                onSave: {
                    saveSetupScript(for: project)
                    editingSetupScriptProjectID = nil
                }
            )
        }
    }

    private func environmentRow(code: String, description: String, palette: WarrenSettingsPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Wide enough for the longest name, WARREN_WORKSPACE_BRANCH, so
            // no variable is cut short.
            WarrenDesktopCodeChip(text: code)
                .fixedSize()
                .frame(width: 196, alignment: .leading)
            Text(description)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    // MARK: - Terminal runtime

    /// The two pages whose names are easy to confuse point at each other, so a
    /// reader who opened the wrong one is one click from the right one.
    private func crossLink(
        _ text: String,
        to section: SettingsSection,
        palette: WarrenSettingsPalette,
        identifier: String
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.inkQuiet)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.inkFaint)
                Text(section.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.inkBody)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .accessibilityIdentifier(identifier)
    }

    private func terminalRuntimeSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            terminalRuntimeEngine(palette: palette)
            crossLink(
                "Font and title template are set per Mac in",
                to: .terminal,
                palette: palette,
                identifier: "settings.terminal-runtime.goto-terminal"
            )
        }
    }

    private func terminalRuntimeEngine(palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsGroup(
            "Engine",
            footnote: "Only one engine ships today, so this is a read-out instead of a picker. Sessions keep the engine they were created with; a new default applies to new sessions only."
        ) {
            WarrenSettingsRow(
                "Default Runtime",
                description: "libghostty-vt snapshots match the client exactly; the detached server keeps sessions alive across daemon upgrades."
            ) {
                Text(defaultRuntime ?? "ghostline")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(palette.inkQuiet)
                    .accessibilityIdentifier("settings.terminal-runtime.picker")
            }
        }
    }

    // MARK: - AI titles

    private func aiTitlesSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup {
                WarrenSettingsToggleRow(
                    title: "Generate Titles Automatically",
                    description: "Codex, Claude Code, OpenCode, and Qoder name their own conversations and Warren keeps those names. This switch adds a title from the LLM below whenever an agent has not named the conversation.",
                    isOn: Binding(
                        get: { openAITitleEnabled },
                        set: { onSetOpenAISetting("openaiTitleEnabled", $0 ? "true" : "false") }
                    ),
                    accessibilityID: "settings.ai-titles.enabled"
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                WarrenSettingsGroup("Endpoint", accessory: "OpenAI-compatible") {
                    WarrenSettingsRow("Base URL") {
                        WarrenSettingsTextField(
                            placeholder: "https://api.openai.com/v1",
                            text: $openAIBaseURLDraft,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.base-url"
                        )
                    }
                    WarrenSettingsRowDivider()
                    WarrenSettingsRow("Model") {
                        WarrenSettingsTextField(
                            placeholder: "gpt-4o-mini",
                            text: $openAIModelDraft,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.model"
                        )
                    }
                    WarrenSettingsRowDivider()
                    WarrenSettingsRow("API Key", description: "Stored only on this host.") {
                        WarrenSettingsTextField(
                            placeholder: "••••••••3f2a",
                            text: $openAIKeyDraft,
                            isSecure: true,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.api-key"
                        )
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        testOpenAISettings(save: true)
                    } label: {
                        HStack(spacing: 6) {
                            if openAITestStatus.isTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text(openAITestStatus.isTesting ? "Testing…" : "Save & Test")
                        }
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .primary))
                    .disabled(openAITestStatus.isTesting)
                    .accessibilityIdentifier("settings.ai-titles.save-and-test")
                    .warrenSemanticElement(
                        id: "settings.ai-titles.save-and-test",
                        role: .button,
                        label: "Save and test AI title connection",
                        isEnabled: !openAITestStatus.isTesting,
                        action: { testOpenAISettings(save: true) }
                    )

                    Button("Test") {
                        testOpenAISettings(save: false)
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .disabled(openAITestStatus.isTesting || !hasUnsavedOpenAIDraft)
                    .accessibilityIdentifier("settings.ai-titles.test")
                    .warrenSemanticElement(
                        id: "settings.ai-titles.test",
                        role: .button,
                        label: "Test AI title connection",
                        isEnabled: !openAITestStatus.isTesting && hasUnsavedOpenAIDraft,
                        action: { testOpenAISettings(save: false) }
                    )

                    switch openAITestStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        WarrenSettingsStatusLine(tone: .busy, text: "Testing connection…")
                    case .succeeded:
                        WarrenSettingsStatusLine(tone: .ok, text: "Connection succeeded.")
                    case .failed(let message):
                        WarrenSettingsStatusLine(tone: .failed, text: message, isError: true)
                    }
                }
                .padding(.leading, 14)
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

    private var hasUnsavedOpenAIDraft: Bool {
        openAIBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || openAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                != openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            || !openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func testOpenAISettings(save: Bool = true) {
        guard !openAITestStatus.isTesting else { return }
        if save { saveOpenAISettings() }
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

    // MARK: - Usage

    private func usageSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if usageShowsDetail {
                Button {
                    usageShowsDetail = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.backward").font(.system(size: 11, weight: .medium))
                        Text("Back to overview")
                    }
                }
                .buttonStyle(WarrenSettingsButtonStyle(kind: .plain))
                .padding(.leading, 6)
            }

            // The panel's cards sit on the page itself. Wrapped in a settings
            // group they were boxes inside a box of the same fill, with two
            // borders and 28pt of the column spent on the wrapper's padding.
            Group {
                if usageShowsDetail {
                    WarrenDesktopUsagePanel(
                        stats: usageStats,
                        state: usageState,
                        tokens: usageTokens,
                        range: $usageRange,
                        selectedDay: $usageSelectedDay,
                        onLoad: { days, day, force in onLoadUsage?(days, day, force) },
                        mode: .detail,
                        showsRangePicker: false
                    )
                } else {
                    WarrenDesktopUsageOverviewPanel(
                        stats: usageStats,
                        state: usageState,
                        tokens: usageTokens,
                        range: $usageRange,
                        selectedDay: $usageSelectedDay,
                        onLoad: { days, day, force in onLoadUsage?(days, day, force) },
                        onOpenDetail: { day in
                            usageSelectedDay = day
                            usageShowsDetail = true
                        },
                        showsRangePicker: false
                    )
                }
            }
            .onAppear { onLoadUsage?(usageRange.days, usageSelectedDay, false) }

            WarrenSettingsGroup("Maintenance") {
                WarrenSettingsRow(
                    "Rebuild Usage Data",
                    description: "Recounts every call from the stored transcripts. Use it after upgrading, or when totals look inflated."
                ) {
                    HStack(spacing: 10) {
                        if let summary = usageRebuildSummary {
                            WarrenSettingsStatusLine(
                                tone: .ok,
                                text: WarrenUsageFormatting.rebuildOutcome(summary)
                            )
                        } else if let usageRebuildError, !usageRebuildError.isEmpty {
                            WarrenSettingsStatusLine(tone: .failed, text: usageRebuildError, isError: true)
                        } else {
                            WarrenSettingsStatusLine(
                                tone: .ok,
                                text: WarrenUsageFormatting.rebuildAge(usageStats.lastRebuild)
                            )
                        }
                        Button(usageRebuildBusy ? "Rebuilding…" : "Rebuild…") {
                            confirmation = .rebuildUsage
                        }
                        .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                        .disabled(usageRebuildBusy || onRebuildUsage == nil)
                        .accessibilityIdentifier("settings.usage.rebuild")
                    }
                }
            }
        }
    }

    /// The page's blocking confirmations. Each is a `WarrenDialog` like every
    /// other blocking flow, so its ground, padding and buttons match the rest
    /// of the app instead of arriving as a system alert.
    @ViewBuilder
    private var confirmationDialogLayer: some View {
        if let confirmation {
            confirmationLayer(for: confirmation)
        }
    }

    @ViewBuilder
    private func confirmationLayer(for confirmation: SettingsConfirmation) -> some View {
        switch confirmation {
        case .rebuildUsage:
            settingsConfirmation(
                "Rebuild Usage Data?",
                message: "Warren will re-read the transcripts of every Agent that reports token "
                    + "counts and replace those Agents' Usage aggregates. An Agent whose "
                    + "transcripts cannot be found keeps its current numbers. The Agent "
                    + "journal and all other databases remain unchanged.",
                confirmLabel: "Rebuild",
                onConfirm: rebuildUsage
            )
        case .resetRelay:
            settingsConfirmation(
                "Reset Relay Enrollment?",
                message: "This Mac forgets its Relay URL and enrollment. Phones and browsers "
                    + "paired through the Relay lose access until this Mac is enrolled again.",
                confirmLabel: "Reset",
                onConfirm: resetRelay
            )
        case .revokeDevice(let id, let name):
            settingsConfirmation(
                "Revoke \(name)?",
                message: "This device loses access to this Host through the Relay. It can pair "
                    + "again with a new invite.",
                confirmLabel: "Revoke",
                onConfirm: { revokeRelayDevice(id) }
            )
        }
    }

    private func settingsConfirmation(
        _ title: String,
        message: String,
        confirmLabel: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        WarrenDialog(title, message: message) {
            EmptyView()
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: confirmLabel,
                isDestructive: true,
                onCancel: { confirmation = nil },
                onConfirm: {
                    confirmation = nil
                    onConfirm()
                }
            )
        }
        .onExitCommand { confirmation = nil }
    }

    /// The usage panels still read the appearance tokens for their own cards.
    private var usageTokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }

    private func rebuildUsage() {
        guard !usageRebuildBusy, let onRebuildUsage else { return }
        usageRebuildBusy = true
        usageRebuildError = nil
        usageRebuildSummary = nil
        onRebuildUsage { result in
            DispatchQueue.main.async {
                usageRebuildBusy = false
                switch result {
                case .success(let summary):
                    usageRebuildSummary = summary
                    onLoadUsage?(usageRange.days, usageSelectedDay, true)
                case .failure(let error):
                    usageRebuildError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Relay

    private func relaySection(palette: WarrenSettingsPalette) -> some View {
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

    private func relayConnectionForm(palette: WarrenSettingsPalette) -> some View {
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

    private func relayInviteReveal(_ invite: WarrenDesktopRelayInvite, palette: WarrenSettingsPalette) -> some View {
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

    private func relayDevicesSection(palette: WarrenSettingsPalette) -> some View {
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

    private func lanPairingSection(palette: WarrenSettingsPalette) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            lanPairingContent(at: timeline.date, palette: palette)
        }
    }

    private func lanPairingContent(at date: Date, palette: WarrenSettingsPalette) -> some View {
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
        if seconds >= 60 { return "\(max(1, seconds / 60)) min" }
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

    // MARK: - Public access

    /// The page's own state, as a header row: a dot, what it is serving, and a
    /// switch at the tail. The word "Enabled" told the same thing while also
    /// being a control the user had to find elsewhere.
    private func publicAccessStatusRow(palette: WarrenSettingsPalette) -> some View {
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

    private func publicAccessSection(palette: WarrenSettingsPalette) -> some View {
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
    private func statusLabel(palette: WarrenSettingsPalette) -> some View {
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

    private var publicAccessActionTitle: String {
        webStatus.publicAccessBusy ? "Testing…" : "Save & Test"
    }

    private var hasPublicAccessSetup: Bool {
        webStatus.publicAccessAuthenticated
            || webStatus.publicAccessEnabled
            || webStatus.relayURL != nil
            || webStatus.relayHostID != nil
            || webStatus.routeID != nil
    }

    // MARK: - Deep links

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

    private static func deepLinkCopySource(_ section: SettingsSection) -> String {
        "settings.deeplink.\(section.rawValue)"
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
            if let relayURL = relayPrefill.relayURL { relayRegistrationURL = relayURL }
            if let enrollmentKey = relayPrefill.enrollmentKey { relayEnrollmentKey = enrollmentKey }
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

    // MARK: - Shared plumbing

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

    private var agentInterfaceSelection: Binding<WarrenAgentInterface> {
        Binding(
            get: { WarrenAgentInterface(storedValue: agentInterfaceRawValue) },
            set: { agentInterfaceRawValue = $0.rawValue }
        )
    }

    private var appearanceSelection: Binding<WarrenAppearanceMode> {
        Binding(
            get: { WarrenAppearanceMode(storedValue: appearanceModeRawValue) },
            set: { mode in
                appearanceModeRawValue = mode.rawValue
                WarrenDesktopAppearance.apply(mode)
            }
        )
    }

    private var appIconSelection: Binding<WarrenAppIconColorway> {
        Binding(
            get: { WarrenAppIconColorway(storedValue: appIconRawValue) },
            set: { colorway in
                appIconRawValue = colorway.rawValue
                WarrenDesktopDockIcon.apply(colorway)
            }
        )
    }

    private var normalizedFont: TerminalFontPreference {
        TerminalFontPreference(family: fontFamily, size: fontSize)
    }

    private var renderedTitle: String {
        TerminalDisplayTitleTemplate(rawValue: titleTemplate).render(.init(
            session: "Claude", command: "claude", directory: "/Users/me/Workspace/warren",
            workspace: "warren", branch: "main", host: "MacBook Pro", user: "me", os: "macOS"
        ))
    }

    /// The title line under a pane's header, shown in the Terminal preview bar.
    private var preview: String {
        renderedTitle
    }

    /// Every installed family opened as an `NSFont` to test its pitch. Done
    /// once per launch: as a computed property it ran on every render of the
    /// Terminal page, which is the page Settings opens on.
    @MainActor private static let installedMonospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        .sorted()
    }()

    private var monospacedFamilies: [String] {
        var result = Self.installedMonospacedFamilies
        if !result.contains(fontFamily) {
            result.insert(fontFamily, at: 0)
        }
        return result
    }

    // MARK: - Relay actions

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
                    relayInviteQRCode = qrCodeImage(for: value.url.absoluteString)
                    relayInviteError = nil
                case let .failure(error):
                    relayInviteError = error.localizedDescription
                }
            }
        }
    }

    private static let relayInviteCopySource = "settings.relay-invite"

    private func copyRelayInvite(_ invite: WarrenDesktopRelayInvite) {
        copyFeedback.copy(invite.url.absoluteString, confirmingIn: Self.relayInviteCopySource)
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

    private func revokeRelayDevice(_ id: String) {
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

    // MARK: - Custom IDEs

    private func addCustomIDE() {
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
}

// MARK: - Navigation item

private struct WarrenSettingsNavItem: View {
    let section: WarrenDesktopSettingsSection
    let status: WarrenStatusTone?
    let isSelected: Bool
    let palette: WarrenSettingsPalette
    let selectionNamespace: Namespace.ID
    /// Which scope the page belongs to. Drawn only while a search flattens the
    /// two navigation groups.
    var scopeLabel: String? = nil
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        let ring: Color = isSelected ? palette.selected : (hovering ? palette.hover : palette.card)
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? palette.ink : palette.inkQuiet)
                    .frame(width: 20)
                    .overlay(alignment: .topTrailing) {
                        if let status {
                            WarrenSettingsStatusDot(tone: status, ring: ring)
                                .offset(x: 3, y: -3)
                        }
                    }
                Text(section.rawValue)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? palette.ink : palette.inkBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let scopeLabel {
                    Text(scopeLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.selected)
                        .matchedGeometryEffect(id: "settings-selection", in: selectionNamespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("settings.section.\(section.id)")
        .warrenSemanticElement(
            id: "settings.section.\(section.id)",
            role: .button,
            label: section.rawValue,
            isSelected: isSelected,
            action: onSelect
        )
    }
}

/// A blocking question the Settings page asks before an action that cannot
/// be taken back.
private enum SettingsConfirmation: Equatable {
    case rebuildUsage
    case resetRelay
    case revokeDevice(id: String, name: String)
}

// MARK: - App icon choice

/// One colorway of the app icon, drawn at Dock size. Five of these share a
/// row, so the choice is the icon itself rather than a framed preview card.
private struct AppIconChoice: View {
    let colorway: WarrenAppIconColorway
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image = WarrenDesktopDockIcon.image(for: colorway) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 64, height: 64)
                .padding(3)
                .overlay {
                    if isSelected {
                        // The same ring a chosen appearance card carries.
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(palette.ink.opacity(0.10), lineWidth: 3)
                    }
                }

                Text(colorway.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? palette.ink : palette.inkQuiet)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(colorway.displayName) app icon")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion), value: isSelected)
    }
}

// MARK: - Appearance preview

// MARK: - Terminal preview

private struct TerminalFontPreview: View {
    let preference: TerminalFontPreference
    let palette: WarrenSettingsPalette
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(palette.success).frame(width: 8, height: 8)
                Text("zsh")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.meta)
                Spacer()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.inkQuiet)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            Rectangle().fill(palette.rowDivider).frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                line(prompt: "~/workspace $", command: "mastra dev")
                Text("→ Loaded 3 tools · 1 agent · 0 workflows")
                    .foregroundStyle(palette.inkQuiet)
                line(prompt: "~/workspace $", command: "bun test")
                HStack(spacing: 6) {
                    Text("✓").foregroundStyle(palette.success)
                    Text("14 tests passed · 0.24s").foregroundStyle(palette.inkBody)
                }
                line(prompt: "~/workspace $", command: "git status --short")
                HStack(spacing: 6) {
                    Text(" M").foregroundStyle(palette.warning)
                    Text("src/settings/appearance.tsx").foregroundStyle(palette.inkQuiet)
                }
            }
            .font(.custom(preference.family, size: preference.size))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 132, alignment: .topLeading)
            .clipped()
            .background(palette.windowBackdrop)
        }
    }

    private func line(prompt: String, command: String) -> some View {
        HStack(spacing: 6) {
            Text(prompt).foregroundStyle(palette.info)
            Text(command).foregroundStyle(palette.inkBody)
        }
    }
}

// MARK: - Flowing chips

private struct FlowingChips: View {
    let tokens: [(String, String)]
    let palette: WarrenSettingsPalette
    let onInsert: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 118), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                WarrenSettingsTokenChip(token: token.0) {
                    onInsert(token.0)
                }
                .help(token.1)
            }
        }
    }

}

private struct InstalledIDE: Identifiable {
    let id: String
    let name: String
    let path: String
    let icon: NSImage
}
