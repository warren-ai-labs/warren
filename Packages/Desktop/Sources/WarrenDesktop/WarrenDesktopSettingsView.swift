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

enum WarrenSetupScriptContract {
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

extension WarrenDesktopSettingsSection {
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
        case .remoteAccess: "lock.shield"
        case .access: "lock.shield"
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
        case .remoteAccess: "Reach this Host from anywhere without running a Relay."
        case .access: "How your phone or a browser reaches this Mac."
        }
    }

    /// How wide the page's column may grow before it stops.
    ///
    /// Superset's settings pages are `max-w-5xl` (1024) inside a centred
    /// column, with 16 points around every row. At 640 the cards stopped well
    /// short of the window and the right side of the page read as empty; at
    /// 1040 the card's trailing edge sits where the controls are, which is what
    /// makes a row read as one line rather than as a label with a stray field.
    /// Usage is charts and keeps more room.
    var contentMaxWidth: CGFloat {
        switch self {
        case .usage: 1240
        default: 1040
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
        case .remoteAccess:
            [rawValue, detail, "remote", "serverless", "bolthole", "relay", "iphone", "qr", "share",
             "pair", "encrypted", "self-hosted", "code", "rotate"]
        case .access:
            [rawValue, detail, "access", "reach", "remote", "serverless", "bolthole", "relay",
             "enrollment", "ticket", "lan", "pin", "pairing", "bonjour", "iphone", "mobile", "qr",
             "share", "encrypted", "self-hosted", "public", "hostname", "path", "tunnel", "web",
             "internet", "device", "revoke"]
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
    /// Serverless remote access (Bolthole) as the Host reports it.
    var remoteAccess: WarrenDesktopRemoteAccess = .init()
    var onLoadRemoteAccess: (() -> Void)?
    var onSetRemoteEnabled: ((Bool) -> Void)?
    /// Switches the serverless relay: "default" for the official one, or a URL.
    var onSetRemoteRelay: ((String) -> Void)?
    var onRemoteShare: ((@escaping (Result<WarrenDesktopRemoteShare, Error>) -> Void) -> Void)?
    var onRotateRemote: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
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
    var titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    var fontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    var fontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.presetCommandShell)
    var shellCommand = ""
    @AppStorage(WarrenPreferenceKey.presetCommandClaude)
    var claudeCommand = "claude"
    @AppStorage(WarrenPreferenceKey.presetCommandCodex)
    var codexCommand = "codex --dangerously-bypass-hook-trust"
    @AppStorage(WarrenPreferenceKey.presetCommandOpenCode)
    var opencodeCommand = "opencode"
    @AppStorage(WarrenPreferenceKey.presetCommandPi)
    var piCommand = "pi"
    @AppStorage(WarrenPreferenceKey.presetCommandQoder)
    var qoderCommand = "qoder"
    @AppStorage(WarrenPreferenceKey.presetCommandAntigravity)
    var antigravityCommand = "agy"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
    @AppStorage(WarrenPreferenceKey.agentInterface)
    var agentInterfaceRawValue = WarrenAgentInterface.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.embeddedEditorDefaultIDE)
    var embeddedEditorDefaultIDE = false
    @AppStorage(WarrenPreferenceKey.embeddedEditorOpenLinks)
    var embeddedEditorOpenLinks = false
    @AppStorage(WarrenPreferenceKey.agentCompletionSoundEnabled)
    var agentCompletionSoundEnabled = true
    @AppStorage(WarrenPreferenceKey.agentAttentionAlertsEnabled)
    var agentAttentionAlertsEnabled = true
    @AppStorage(WarrenPreferenceKey.agentAttentionDockBadgeEnabled)
    var agentAttentionDockBadgeEnabled = true
    @AppStorage(WarrenPreferenceKey.usageRange)
    var usageRange = WarrenUsageRange.month
    @AppStorage(WarrenPreferenceKey.sidebarShowTasks)
    var showsTasks = true
    @AppStorage(WarrenPreferenceKey.terminalSplitChordsEnabled)
    var splitChordsEnabled = false
    @AppStorage(WarrenPreferenceKey.appearanceMode)
    var appearanceModeRawValue = WarrenAppearanceMode.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.appearanceLiquidGlass)
    var liquidGlassEnabled = false
    @AppStorage(WarrenPreferenceKey.appearanceAppIcon)
    var appIconRawValue = WarrenAppIconColorway.defaultValue.rawValue
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Namespace var selectionNamespace
    @State var openAIBaseURLDraft = ""
    @State var openAIModelDraft = ""
    @State var openAIKeyDraft = ""
    @State var openAITestStatus: OpenAITestStatus = .idle
    @State var publicAccessHostname = ""
    @State var publicAccessPathPrefix = ""
    @State var relayRegistrationURL = ""
    @State var relayEnrollmentKey = ""
    @State var relayResetBusy = false
    @State var relayResetError: String?
    @State var relayEnrollmentBusy = false
    @State var relayEnrollmentError: String?
    @State var relayInvite: WarrenDesktopRelayInvite?
    /// The invite's QR code, made once when the invite arrives. Generated in
    /// the body, Core Image ran again on every render of the Relay page.
    @State var relayInviteQRCode: NSImage?
    @State var relayInviteBusy = false
    @State var relayInviteError: String?
    @State var lanPairingBusy = false
    @State var lanPairingError: String?
    @State var remoteShare: WarrenDesktopRemoteShare?
    /// The share link's QR code, made once when the link arrives.
    @State var remoteShareQRCode: NSImage?
    @State var remoteShareBusy = false
    @State var remoteShareError: String?
    @State var remoteRotateBusy = false
    @State var remoteRotateError: String?
    @State var remoteEnabledBusy = false
    /// The relay URL typed under "My own", before it is applied.
    @State var remoteCustomRelayURL = ""
    /// Whether "My own" is chosen while the Host still reports the official relay.
    @State var remoteRelayChoosingOwn = false
    /// The one blocking confirmation the page is showing, if any.
    @State var confirmation: SettingsConfirmation?
    /// Why the last Revoke of a Relay device failed, by device.
    @State var relayRevokeErrors: [String: String] = [:]
    @State var hostPickerPresented = false
    @State var usageRebuildBusy = false
    @State var usageRebuildError: String?
    @State var usageRebuildSummary: WarrenUsageRebuildSummary?
    @State var usageSelectedDay: String?
    @State var usageShowsDetail = false
    @ObservedObject var copyFeedback = WarrenCopyFeedback.shared
    @Environment(\.colorScheme) var colorScheme

    var initialSettingsSection: WarrenDesktopSettingsSection?
    var publicAccessPrefill: WarrenDesktopPublicAccessPrefill?
    var relayPrefill: WarrenDesktopRelayPrefill?

    enum OpenAITestStatus {
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

    typealias SettingsSection = WarrenDesktopSettingsSection

    /// The running bundle's marketing version. Read once: it cannot change
    /// while the process runs, and the page redraws on every settings event.
    static let appVersion: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "development" }
        return version
    }()

    @State var selectedSection: SettingsSection = .appearance
    @State var searchQuery = ""
    @FocusState var searchFocused: Bool
    @State var installedIDEs: [InstalledIDE] = []
    /// Read when the External IDEs page appears. A `@State` default runs on
    /// every initialisation of this view, which the root view repeats on each
    /// render, so decoding the store there cost a defaults read and a JSON
    /// decode per frame.
    @State var customIDEs: [WarrenDesktopCustomIDE] = []
    /// The editor the IDE button opens. The same key the root view uses, so
    /// the checkmark here and the button's action can never disagree.
    @AppStorage("warren.desktop.externalIDEID") var externalIDEID = ""
    @State var setupScriptValues: [ProjectID: String] = [:]
    @State var editingSetupScriptProjectID: ProjectID?
    @State var editingPresetID: String?
    /// The preset being dragged, so it can be lifted while the pointer carries
    /// it and the row it is over can take it.
    @State var draggedPresetID: String?
    /// The preset row that holds the keyboard, which is what makes ⌥↑ / ⌥↓
    /// unambiguous: they act on the row the user is standing on.
    @FocusState var focusedPresetID: String?

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
        remoteAccess: WarrenDesktopRemoteAccess = .init(),
        onLoadRemoteAccess: (() -> Void)? = nil,
        onSetRemoteEnabled: ((Bool) -> Void)? = nil,
        onSetRemoteRelay: ((String) -> Void)? = nil,
        onRemoteShare: ((@escaping (Result<WarrenDesktopRemoteShare, Error>) -> Void) -> Void)? = nil,
        onRotateRemote: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
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
        self.remoteAccess = remoteAccess
        self.onLoadRemoteAccess = onLoadRemoteAccess
        self.onSetRemoteEnabled = onSetRemoteEnabled
        self.onSetRemoteRelay = onSetRemoteRelay
        self.onRemoteShare = onRemoteShare
        self.onRotateRemote = onRotateRemote
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
        _selectedSection = State(initialValue: initialSettingsSection ?? .appearance)
    }

    var visibleSections: [SettingsSection] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchTerms.contains { $0.lowercased().contains(needle) }
        }
    }

    var thisMacSections: [SettingsSection] {
        visibleSections.filter { $0.scope == .thisMac }
    }

    var hostSections: [SettingsSection] {
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
        // The window's transparent titlebar already reserves the traffic
        // lights' row as the hosting view's top safe area, so the page must not
        // add a gutter of its own: doing both put the first card 53 points
        // down, which read as a wide empty band above the navigation.
        // The backdrop paints under the transparent titlebar; the content keeps
        // its inset, so the surface is seamless and the lights have room.
        .background { palette.windowBackdrop.ignoresSafeArea() }
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

    // MARK: - Detail

    func detailPanel(palette: WarrenSettingsPalette) -> some View {
        ScrollView {
            // Superset's settings pages leave 32 between the page header and
            // the first section, then 24 between sections; 24 everywhere made
            // the title look like one more section heading.
            VStack(alignment: .leading, spacing: 32) {
                pageHeader(for: selectedSection, palette: palette)
                pageContent(for: selectedSection, palette: palette)
            }
            // The column stops at the page's own width, then centres in what is
            // left. It used to be left-aligned, because a 640-point column
            // centred in a wide window pushed the title into the middle of the
            // screen with a dead gutter before it. At 1040 the column nearly
            // fills the panel, so centring only bites on a very wide window —
            // and there it is what keeps one gutter, not two.
            .frame(maxWidth: selectedSection.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
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

    func pageHeader(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        // Inset to the line the rows already use, so the title, the scope line,
        // every group label and every row title share one left edge. The header
        // used to sit on the column's own edge, 14 pt left of everything under
        // it, which is what made a tidy page look out of square.
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
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    func scopeRow(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 8) {
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
    func hostScopeChip(palette: WarrenSettingsPalette) -> some View {
        HStack(spacing: 6) {
            Text(currentHostLabel)
                .font(.system(size: 12))
                .foregroundStyle(palette.inkBody)
                .lineLimit(1)
            connectionDot(hostOptions.first { $0.id == selectedHostID }?.probeState, palette: palette)
        }
    }

    @ViewBuilder
    func headerAccessory(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
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

    func copyLinkButton(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
        let copied = copyFeedback.confirms(Self.deepLinkCopySource(section))
        return Button {
            copySettingsDeepLink(for: section)
        } label: {
            Image(systemName: copied ? "checkmark" : "link")
                .font(.system(size: 14))
                .foregroundStyle(palette.inkQuiet)
                // The 26 pt box is the hit area; the glyph sits on its trailing
                // edge so it ends on the same line as every control below it.
                .frame(width: 26, height: 26, alignment: .trailing)
                .background(RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous).fill(.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section == .publicAccess ? "Copy setup link" : "Copy link")
        .accessibilityLabel(section == .publicAccess ? "Copy Public Access setup link" : "Copy \(section.rawValue) settings link")
        .accessibilityIdentifier("settings.section.\(section.deepLinkValue).deeplink")
    }

    @ViewBuilder
    func pageContent(for section: SettingsSection, palette: WarrenSettingsPalette) -> some View {
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
        case .remoteAccess: accessSection(palette: palette)
        case .access: accessSection(palette: palette)
        }
    }

}

// MARK: - Navigation item

struct WarrenSettingsNavItem: View {
    let section: WarrenDesktopSettingsSection
    let status: WarrenStatusTone?
    let isSelected: Bool
    let palette: WarrenSettingsPalette
    let selectionNamespace: Namespace.ID
    /// Which scope the page belongs to. Drawn only while a search flattens the
    /// two navigation groups.
    var scopeLabel: String? = nil
    let onSelect: () -> Void

    @State var hovering = false

    var body: some View {
        let ring: Color = isSelected ? palette.selected : (hovering ? palette.hover : palette.card)
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // The glyph sits in the dim tier, never between the label's grey
                // and the section label's: a rail of four grey values reads as
                // texture, and the icons are not what a person scans for.
                Image(systemName: section.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? palette.ink : palette.inkFaint)
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
            .frame(maxWidth: .infinity, minHeight: 32)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                        .fill(palette.selected)
                        .matchedGeometryEffect(id: "settings-selection", in: selectionNamespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
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
enum SettingsConfirmation: Equatable {
    case rebuildUsage
    case resetRelay
    case revokeDevice(id: String, name: String)
    case rotateRemoteCode
}

// MARK: - App icon choice

/// One colorway of the app icon, drawn at Dock size. Five of these share a
/// row, so the choice is the icon itself rather than a framed preview card.
struct AppIconChoice: View {
    let colorway: WarrenAppIconColorway
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

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
                .padding(2)
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

struct TerminalFontPreview: View {
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

    func line(prompt: String, command: String) -> some View {
        HStack(spacing: 6) {
            Text(prompt).foregroundStyle(palette.info)
            Text(command).foregroundStyle(palette.inkBody)
        }
    }
}

// MARK: - Flowing chips

struct FlowingChips: View {
    let tokens: [(String, String)]
    let palette: WarrenSettingsPalette
    let onInsert: (String) -> Void

    let columns = [GridItem(.adaptive(minimum: 118), spacing: 6)]

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

struct InstalledIDE: Identifiable {
    let id: String
    let name: String
    let path: String
    let icon: NSImage
}
