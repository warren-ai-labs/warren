import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesktop
import WarrenDomain
import GhosttyAdapter
import WarrenStateStore
import WarrenDesignSystem
import WarrenTransport

private struct WarrenProjectFileDialogLabels: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .fileDialogMessage("Choose a local folder as the project.")
                .fileDialogConfirmationLabel("Add Project")
        } else {
            content
        }
    }
}

private struct WarrenWorkspaceCreatorContext: Equatable {
    let endpointID: String
    let projectID: ProjectID
    let taskID: TaskID?
}

private enum WarrenEndpointScopedModalError: LocalizedError {
    case endpointChanged

    var errorDescription: String? {
        "The endpoint changed while this dialog was open. Choose the resource again."
    }
}

struct WarrenCompositionRoot: View {
    @StateObject private var remoteModel: WarrenRemoteApplicationModel
    @StateObject private var multiHostSidebar: WarrenMultiHostSidebarModel
    @StateObject private var embeddedEditorModel: WarrenEmbeddedEditorModel
    /// The browser viewer's keyboard signal. Shared with the viewer cache,
    /// which registers each region's web view with it (RFC 0022 §8.4).
    @StateObject private var browserFocusModel = WarrenBrowserViewerFocusModel.shared
    @State private var surfaceManager: TerminalSurfaceManager
    @State private var isProjectImporterPresented = false
    @State private var supersetImportPreview: SupersetImportPreview?
    @State private var isSupersetImporting = false
    @State private var workspaceCreatorContext: WarrenWorkspaceCreatorContext?
    @State private var setupScriptProjectID: ProjectID?
    @State private var setupScriptEndpointID: String?
    @State private var setupScriptValue = ""
    @State private var worktreeImportProjectID: ProjectID?
    @State private var worktreeImportEndpointID: String?
    @State private var worktreeImportCandidates: [WarrenDesktopWorktreeCandidate] = []
    @State private var worktreeImportLoading = false
    @State private var terminalSearchPresented = false
    @State private var terminalSearchSessionID: TerminalSessionID?
    @State private var updateStatus: WarrenDesktopUpdateStatus = .none
    @StateObject private var presentation = WarrenPresentationCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(WarrenPreferenceKey.appearanceLiquidGlass)
    private var liquidGlassEnabled = false
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
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
    @State private var selectedEndpointID: String
    @State private var endpointCatalog: [WarrenRemoteEndpointConfiguration]
    @State private var displayConfiguration: WarrenDisplayConfiguration?
    @State private var endpointCatalogError: String?

    @State private var localEndpointWaitGeneration: UInt64 = 0
    @State private var pendingSidebarSelection: WarrenDesktopSidebarResourceSelection?
    @State private var pendingSidebarOpenWorkspace: WarrenDesktopHostResourceRef<WorkspaceID>?
    @State private var pendingSidebarOpenSession: WarrenDesktopHostResourceRef<TerminalSessionID>?

    @MainActor
    init() {
        let surfaceManager = TerminalSurfaceManager()
        _surfaceManager = State(initialValue: surfaceManager)
        let catalog = WarrenEndpointCatalog.load()
        let initialNavigationScope: String
        if let current = catalog.current?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty,
           current == "local" || catalog.endpoints.contains(where: { $0.id == current }) {
            initialNavigationScope = current
        } else {
            initialNavigationScope = "local"
        }
        let remoteModel = WarrenRemoteApplicationModel(
            surfaceManager: surfaceManager,
            initialNavigationScope: initialNavigationScope
        )
        let multiHostSidebar = WarrenMultiHostSidebarModel()
        let embeddedEditorModel = WarrenEmbeddedEditorModel()
        remoteModel.onResumeConnection = { [weak multiHostSidebar] in
            multiHostSidebar?.resumeConnections()
        }

        remoteModel.onOpenTerminalURL = { [weak remoteModel, weak embeddedEditorModel] sessionID, urlString, kind, workingDirectory in
            guard UserDefaults.standard.bool(forKey: WarrenPreferenceKey.embeddedEditorOpenLinks) else {
                return false
            }
            guard let remoteModel, let embeddedEditorModel else { return false }
            guard let workspaceID = remoteModel.projection.sessionWorkspaceIDs[sessionID],
                  let workspace = remoteModel.projection.groups.flatMap(\.workspaces).first(where: { $0.id == workspaceID }) else {
                return false
            }
            guard let target = WarrenTerminalLinkParser.parse(
                urlString,
                workingDirectory: workingDirectory,
                workspacePath: workspace.path
            ) else {
                return false
            }

            // The request carries the document so the Workspace's marker records
            // the file the link opened. That recorded path is what reopening the
            // editor for this Workspace lands on.
            NotificationCenter.default.post(
                name: WarrenDesktopCommand.openEmbeddedEditor,
                object: WarrenDesktopEmbeddedEditorRequest(
                    workspaceID: workspace.id,
                    document: WarrenTerminalLinkParser.relativePath(
                        of: target.path,
                        in: workspace.path
                    ).map { relativeFile in
                        WarrenDesktopEditorDocument(
                            relativeFile: relativeFile,
                            line: target.line,
                            column: target.column
                        )
                    }
                )
            )
            embeddedEditorModel.openFile(
                workspacePath: workspace.path,
                filePath: target.path,
                line: target.line,
                column: target.column
            )
            return true
        }

        _remoteModel = StateObject(wrappedValue: remoteModel)
        _multiHostSidebar = StateObject(wrappedValue: multiHostSidebar)
        _embeddedEditorModel = StateObject(wrappedValue: embeddedEditorModel)
        // Endpoint configuration is user input, not frame state. Seed the
        // catalog once and refresh it from disk in the background so CLI
        // changes appear without restarting Warren. The catalog's `current`
        // value is authoritative.
        _endpointCatalog = State(initialValue: catalog.endpoints)
        _displayConfiguration = State(initialValue: catalog.display)
        _selectedEndpointID = State(initialValue: catalog.current ?? "local")
        _endpointCatalogError = State(initialValue: nil)
    }

    /// The root view itself. It is a separate expression from the observer
    /// chain in `body` because the initializer takes well over fifty arguments,
    /// and holding both in one expression pushes the type checker over budget.
    private var rootChrome: some View {
        WarrenDesktopRoot(
            projection: activeProjection,
            navigation: activeNavigation,
            updateStatus: updateStatus,
            onUpdateAction: {
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.installRequested,
                    object: nil
                )
            },
            actions: WarrenDesktopActions(send: handle),
            onCreateTask: { creation in
                try await remoteModel.createTask(creation)
            },
            pendingDecisions: WarrenDesktopPendingDecisions(
                decisions: remoteModel.pendingDecisions,
                resolve: { sessionID, decisionID, optionID in
                    try await remoteModel.resolvePendingDecision(
                        decisionID,
                        optionID: optionID,
                        in: sessionID
                    )
                }
            ),
            webStatus: remoteModel.webStatus,
            isMigratingRuntimeSessions: remoteModel.isMigratingRuntimeSessions,
            creatingSessionWorkspaceIDs: remoteModel.creatingSessionWorkspaceIDs,
            createdSessionIDsByToken: remoteModel.createdSessionIDsByToken,
            deletingProjectIDs: remoteModel.deletingProjectIDs,
            deletingWorkspaceIDs: remoteModel.deletingWorkspaceIDs,
            notices: remoteModel.notices,
            onNoticeAdd: { title, message, detail, kind in
                remoteModel.addNotice(
                    title: title,
                    message: message,
                    detail: detail,
                    kind: kind
                )
            },
            onNoticeRead: { remoteModel.markNoticeRead($0) },
            onNoticeDismiss: { remoteModel.dismissNotice($0) },
            onActiveScreenSessionsWillChange: { sessions in
                surfaceManager.prepareForVisibilityChange(sessionIDs: sessions)
            },
            onActiveScreenSessionsChanged: { sessions in
                surfaceManager.activateMultiple(sessionIDs: sessions)
                remoteModel.ensureVisibleSessions(sessions)
                remoteModel.reportActiveScreenSessions(sessions)
            },
            onCommitPaneTree: { owner, tree, target in
                remoteModel.commitPaneTree(owner: owner, tree: tree, target: target)
            },
            onPaneDiagnostic: { event, fields in
                TerminalDiagnostics.log(event, fields)
            },
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            onSelectEndpoint: { id in selectEndpoint(id) },
            onSetEndpointSidebarVisibility: setEndpointSidebarVisibility,
            onSetEndpointDisplayName: setEndpointDisplayName,
            onDeleteEndpoint: deleteEndpoint,
            sidebarHostProjections: multiHostSidebar.projection.hosts,
            usesSidebarHostSections: displayConfiguration != nil,
            sidebarResourceSelection: activeSidebarResourceSelection,
            displayConfigurationError: multiHostSidebar.configurationError,
            onSelectSidebarResource: selectSidebarResource,
            onOpenSidebarWorkspace: openSidebarWorkspace,
            onOpenSidebarSession: openSidebarSession,
            onRetrySidebarHost: retrySidebarHost,
            onAddSSHHost: {},
            sshHostPage: sshHostPageModel,
            onRetryConnection: retrySelectedEndpointConnection,
            onStopConnection: stopSelectedEndpointConnection,
            onWebStart: { remoteModel.startWebFromUI() },
            onWebTest: { publicHostname, pathPrefix in
                remoteModel.testPublicAccess(
                    publicHostname: publicHostname,
                    pathPrefix: pathPrefix
                )
            },
            onWebStop: { remoteModel.stopWeb() },
            onWebReset: { remoteModel.resetPublicAccess() },
            onRelayEnroll: { relayURL, enrollmentKey, completion in
                remoteModel.enrollRelay(
                    relayURL: relayURL,
                    enrollmentKey: enrollmentKey,
                    completion: completion
                )
            },
            onRelayPairing: { completion in
                remoteModel.createRelayInvite(completion: completion)
            },
            lanPairing: remoteModel.lanPairing,
            onLANPairing: { enabled, completion in
                if enabled {
                    remoteModel.enableLANPairing(completion: completion)
                } else {
                    remoteModel.disableLANPairing(completion: completion)
                }
            },
            relaySettings: remoteModel.relaySettings,
            onSetRelayEnabled: { enabled in
                remoteModel.setRelayEnabled(enabled)
            },
            onResetRelay: { completion in
                remoteModel.resetRelay(completion: completion)
            },
            relayDevices: remoteModel.relayDevices,
            onLoadRelayDevices: {
                remoteModel.loadRelayDevices()
            },
            onRevokeRelayDevice: { deviceID, completion in
                remoteModel.revokeRelayDevice(deviceID, completion: completion)
            },
            onWebOpenURL: { remoteModel.openWebURL($0) },
            onWebCopyURL: { remoteModel.copyWebURL($0) },
            defaultRuntime: remoteModel.defaultRuntime,
            onSetRuntime: { remoteModel.setDefaultRuntime($0) },
            autoOpenShell: remoteModel.autoOpenShell,
            onSetAutoOpenShell: { remoteModel.setAutoOpenShell($0) },
            autoStartAI: remoteModel.autoStartAI,
            onSetAutoStartAI: { remoteModel.setAutoStartAI($0) },
            openAIBaseURL: remoteModel.openAIBaseURL,
            openAIModel: remoteModel.openAIModel,
            openAITitleEnabled: remoteModel.openAITitleEnabled,
            onSetOpenAISetting: { key, value in
                remoteModel.setOpenAISetting(key, value)
            },
            onTestOpenAI: { baseURL, model, apiKey in
                try await remoteModel.testOpenAITitle(
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                )
            },
            onSetProjectSetupScript: { projectID, script in
                remoteModel.setProjectSetupScript(projectID, script: script)
            },
            usageStats: remoteModel.usageStats,
            usageState: remoteModel.usageState,
            onLoadUsage: { days, day, force in
                remoteModel.loadUsageStats(days: days, selectedDay: day, force: force)
            },
            onRebuildUsage: { completion in
                remoteModel.rebuildUsageData(completion: completion)
            },
            embeddedEditorAvailable: selectedEndpointCapabilities.canUseEmbeddedEditor,
            editorHasKeyboardFocus: embeddedEditorModel.hasKeyboardFocus,
            browserHasKeyboardFocus: browserFocusModel.hasKeyboardFocus,
            editorSurface: { workspace in
                AnyView(WarrenEmbeddedEditorSurface(
                    workspace: workspace,
                    model: embeddedEditorModel
                ))
            },
            onOpenEditorDocument: { workspace, document in
                embeddedEditorModel.openFile(
                    workspacePath: workspace.path,
                    filePath: URL(fileURLWithPath: workspace.path)
                        .appendingPathComponent(document.relativeFile).path,
                    line: document.line,
                    column: document.column
                )
            },
            inspectorSurface: { workspace, tab, activity in
                AnyView(WarrenInspectorSurface(
                    inspector: remoteModel.inspector(for: workspace),
                    readsLocalFiles: remoteModel.inspectorReadsLocalFiles,
                    tab: tab,
                    activity: activity
                ))
            }
        ) { context in
            WarrenTerminalSurfaceView(
                context: context,
                surfaceManager: surfaceManager,
                maintenanceMessage: remoteModel.maintenanceMessage,
                connectionState: remoteModel.projection.connectionState,
                isAttaching: remoteModel.attachingSessionID == context.tab.sessionID,
                onFocused: { sessionID, size in
                    remoteModel.focus(sessionID: sessionID, size: size)
                },
                onBlurred: { sessionID in
                    remoteModel.blur(sessionID: sessionID)
                },
                browserSurface: { sessionID in
                    guard selectedEndpointCapabilities.canUseEmbeddedBrowser else { return nil }
                    return AnyView(WarrenBrowserSurface(sessionID: sessionID, model: remoteModel))
                },
                conversationSurface: { sessionID, wantsInputFocus in
                    guard remoteModel.isConversationSession(sessionID) else { return nil }
                    return AnyView(WarrenConversationSurface(
                        sessionID: sessionID,
                        model: remoteModel,
                        wantsInputFocus: wantsInputFocus
                    ))
                },
                searchPresented: Binding(
                    get: {
                        terminalSearchPresented
                            && terminalSearchSessionID == context.tab.sessionID
                    },
                    set: { presented in
                        if presented {
                            terminalSearchSessionID = context.tab.sessionID
                            terminalSearchPresented = true
                        } else if terminalSearchSessionID == context.tab.sessionID {
                            terminalSearchPresented = false
                            terminalSearchSessionID = nil
                        }
                    }
                )
            )
        }
        .disabled(isSupersetImporting)
        .background {
            // The window's single coat. Opaque Ember draws nothing here, so
            // turning glass off is exactly the appearance that shipped before.
            if windowMaterial == .glass {
                WarrenWindowCoat(cornerRadius: WarrenWindowGeometry.cornerRadius)
                    .transition(.opacity)
            }
        }
        .overlay {
            if isSupersetImporting {
                let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
                ZStack {
                    tokens.modalScrim
                        .ignoresSafeArea()
                    VStack(spacing: WarrenSpacing.compact) {
                        WarrenBrailleSpinner(
                            size: 22,
                            accessibilityLabel: "Reading Superset"
                        )
                        Text("Reading Superset…")
                            .font(WarrenTypography.navigationItem)
                            .foregroundStyle(tokens.foreground)
                        Text("Reading workspaces project by project, please wait")
                            .font(WarrenTypography.supporting)
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(WarrenSpacing.large)
                    .warrenPresentationSurface(role: .status, cornerRadius: WarrenRadius.large)
                }
                .transition(.opacity)
            }
        }
    }

    var body: some View {
        rootChrome
        .overlay {
            appPresentationLayer
        }
        .fileImporter(
            isPresented: $isProjectImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: importProject
        )
        .modifier(WarrenProjectFileDialogLabels())
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copyLocalURL)) { _ in
            guard selectedEndpointCapabilities.canCopyLocalWebURL else { return }
            remoteModel.copyLocalWebURL()
        }
        .onReceive(remoteModel.agentCompletionEvents) { event in
            handleAgentCompletion(event)
        }
        .modifier(WarrenAttentionAlertsModifier(model: remoteModel) { handle(.openSession($0)) })
        .onReceive(NotificationCenter.default.publisher(for: WarrenAppCommand.openTerminal)) { note in
            guard let request = note.object as? WarrenTerminalOpenRequest else { return }
            remoteModel.openTerminal(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.findInTerminal)) { _ in
            // Release the terminal's AppKit first responder before the search
            // field mounts so the field receives the next keystroke.
            NSApp.keyWindow?.makeFirstResponder(nil)
            terminalSearchSessionID = remoteModel.focusedTerminalSessionID
            terminalSearchPresented = terminalSearchSessionID != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenAppPresentation.message)) { note in
            guard let message = note.object as? WarrenAppMessage else { return }
            remoteModel.addNotice(
                title: message.title,
                message: message.message,
                kind: message.kind
            )
        }
        .onChange(of: terminalFontFamily) { _ in updateTerminalFont() }
        .onChange(of: terminalFontSize) { _ in updateTerminalFont() }
        .onChange(of: windowMaterial) { _ in updateTerminalMaterial() }
        .onChange(of: remoteModel.projection) { _ in
            refreshMultiHostSidebar()
        }
        .onChange(of: remoteModel.connectionError) { _ in
            refreshMultiHostSidebar()
        }
        .onChange(of: displayConfiguration) { _ in
            refreshMultiHostSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copySecureURL)) { _ in
            remoteModel.copySecureWebURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopEndpointOption.probeRequested)) { note in
            remoteModel.probeHosts(
                [.localDaemon()] + endpointCatalog.filter { $0.id != "local" },
                force: WarrenDesktopEndpointOption.isForcedProbe(note)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenUpdateNotification.available)) { note in
            guard let release = note.userInfo?[WarrenUpdateNotification.keyRelease] as? WarrenRelease else {
                return
            }
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                updateStatus = .available(version: release.displayVersion)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenUpdateNotification.installing)) { _ in
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                updateStatus = .updating
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenUpdateNotification.dismiss)) { _ in
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                updateStatus = .none
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenUpdateNotification.failed)) { note in
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                updateStatus = .failed
            }
            let error = note.userInfo?[WarrenUpdateNotification.keyError] as? String
            remoteModel.addNotice(
                title: "Update failed",
                message: error ?? "Warren could not prepare the update.",
                detail: error,
                kind: .error
            )
        }
        .task {
            TerminalDiagnostics.configure(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
            WarrenHangDiagnostics.start()
            // The chord monitor sees every key in the app but only owns the
            // terminal's. It cannot name the terminal view class from its own
            // package, so the answer is supplied here.
            EmacsSplitChordMonitor.shared.isTerminalFocused = { [surfaceManager] in
                surfaceManager.terminalOwnsKeyboardFocus
            }
            presetOrder = WarrenDesktopSessionPreset.normalizedOrderRawValue(presetOrder)
            hiddenPresets = WarrenDesktopSessionPreset.normalizedHiddenRawValue(hiddenPresets)
            updateTerminalFont()
            updateTerminalMaterial()
            restoreEndpointSelection()
            refreshMultiHostSidebar()
            publishEndpointCapabilities()
            await monitorEndpointConfiguration()
        }
        .task(id: selectedWorkspacePath) {
            // Warm the shared local editor server as soon as a workspace is
            // selected so opening the editor pane skips both the server and
            // workbench cold starts.
            guard let workspacePath = selectedWorkspacePath else { return }
            embeddedEditorModel.prewarm(workspacePath: workspacePath)
        }
        .task(id: colorScheme) {
            embeddedEditorModel.applyAppearance(WarrenEmbeddedEditorAppearance(colorScheme))
        }
        .onChange(of: embeddedEditorModel.hasKeyboardFocus) { hasFocus in
            // Only the departure needs reporting. The return is reported by the
            // surface manager when the click makes a terminal first responder
            // again, which also carries the size the Session needs.
            guard hasFocus else { return }
            // Mark the daemon's view of focus stale before reporting the
            // departure, so the click that brings the keyboard back is reported
            // rather than being read as already-current.
            surfaceManager.noteTerminalFocusSurrendered()
            remoteModel.relinquishTerminalFocus()
        }
        .onChange(of: browserFocusModel.hasKeyboardFocus) { hasFocus in
            // The browser viewer is a second region that can take the keyboard
            // away from the Terminal, so it reports the departure the same way
            // the editor does.
            guard hasFocus else { return }
            surfaceManager.noteTerminalFocusSurrendered()
            remoteModel.relinquishTerminalFocus()
        }
        .onChange(of: selectedEndpointID) { _ in
            embeddedEditorModel.stop()
            // Resource dialogs capture the current Endpoint. Their IDs are
            // Host-local, so discard them when the foreground Host changes
            // instead of allowing a later confirmation to target a different
            // Host with a colliding UUID.
            workspaceCreatorContext = nil
            dismissSetupScript()
            dismissWorktreeImport()
            if !selectedEndpointCapabilities.canAddProject {
                isProjectImporterPresented = false
            }
            if !selectedEndpointCapabilities.canImportSuperset {
                supersetImportPreview = nil
            }
            publishEndpointCapabilities()
            connectSelectedEndpoint()
            refreshMultiHostSidebar()
        }
        .onDisappear {
            localEndpointWaitGeneration &+= 1
            embeddedEditorModel.stop()
            multiHostSidebar.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // A bundled SSH helper is a child process of the Desktop. Stop it
            // before AppKit tears down the process so a tunnel cannot outlive
            // the app that owns the endpoint. The editor server is one too, and
            // the model's deinit never runs at process exit.
            localEndpointWaitGeneration &+= 1
            remoteModel.disconnect()
            multiHostSidebar.stop()
            embeddedEditorModel.stop()
        }
        .animation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion), value: windowMaterial)
        .environment(\.warrenWindowMaterial, windowMaterial)
    }

    /// Glass is the user's choice, but Reduce Transparency overrides it.
    private var windowMaterial: WarrenWindowMaterial {
        WarrenWindowMaterial.resolve(
            glassEnabled: liquidGlassEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    @ViewBuilder
    private var appPresentationLayer: some View {
        if let preview = supersetImportPreview {
            // The importer draws its own `WarrenDialog`, so it is not wrapped.
            Group {
                WarrenSupersetImportView(
                    preview: preview,
                    onCancel: { supersetImportPreview = nil },
                    onConfirm: { selectedPreview in
                        supersetImportPreview = nil
                        setSupersetImporting(true)
                        Task { @MainActor in
                            await remoteModel.commitSupersetImport(selectedPreview)
                            setSupersetImporting(false)
                        }
                    }
                )
            }
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.sheet) }
            .onDisappear { presentation.dismissTop() }
        } else if let context = workspaceCreatorContext,
                  context.endpointID == selectedEndpointID,
                  let project = activeProjection.projectGroup(id: context.projectID)?.project {
            // The creator draws its own `WarrenDialog`, so it is not wrapped.
            WarrenWorkspaceCreatorView(
                project: project,
                onCancel: { workspaceCreatorContext = nil },
                onCreate: { request in
                    guard context.endpointID == selectedEndpointID else {
                        throw WarrenEndpointScopedModalError.endpointChanged
                    }
                    try await remoteModel.createWorkspace(
                        projectID: context.projectID,
                        taskID: context.taskID,
                        request: request
                    )
                }
            )
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.modal) }
            .onDisappear { presentation.dismissTop() }
        } else if let projectID = setupScriptProjectID,
                  setupScriptEndpointID == selectedEndpointID,
                  let project = activeProjection.projectGroup(id: projectID)?.project {
            WarrenDesktopSetupScriptDialog(
                script: $setupScriptValue,
                onClear: {
                    setupScriptValue = ""
                    remoteModel.setProjectSetupScript(projectID, script: "")
                    dismissSetupScript()
                },
                onCancel: dismissSetupScript,
                onSave: {
                    guard setupScriptEndpointID == selectedEndpointID else {
                        dismissSetupScript()
                        return
                    }
                    remoteModel.setProjectSetupScript(projectID, script: setupScriptValue)
                    dismissSetupScript()
                }
            )
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.modal) }
            .onDisappear { presentation.dismissTop() }
        } else if let projectID = worktreeImportProjectID,
                  worktreeImportEndpointID == selectedEndpointID,
                  let project = activeProjection.projectGroup(id: projectID)?.project {
            // The importer draws its own `WarrenDialog`, so it is not wrapped.
            Group {
                WarrenDesktopProjectWorktreeImportView(
                    projectName: project.name,
                    candidates: worktreeImportCandidates,
                    isLoading: worktreeImportLoading,
                    onCancel: dismissWorktreeImport,
                    onImport: { paths in
                        guard worktreeImportEndpointID == selectedEndpointID else {
                            dismissWorktreeImport()
                            return
                        }
                        Task { @MainActor in
                            do {
                                try await remoteModel.importProjectWorktrees(projectID, paths: paths)
                                dismissWorktreeImport()
                            } catch {
                                remoteModel.report(error)
                            }
                        }
                    }
                )
            }
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.sheet) }
            .onDisappear { presentation.dismissTop() }
        }
    }

    /// On glass the terminal's default ground is the window's coat, which is
    /// the same color it reports, so the grid itself paints no background.
    private func updateTerminalMaterial() {
        remoteModel.updateTerminalBackgroundOpacity(windowMaterial == .glass ? 0 : 1)
    }

    private func updateTerminalFont() {
        remoteModel.updateTerminalFont(TerminalFontPreference(
            family: terminalFontFamily,
            size: terminalFontSize
        ))
    }

    private func handle(_ action: WarrenDesktopAction) {
        if action == .addProject {
            if selectedEndpointCapabilities.canAddProject {
                isProjectImporterPresented = true
            }
        } else if action == .importSuperset {
            if selectedEndpointCapabilities.canImportSuperset {
                beginSupersetImport()
            }
        } else if case .requestNewWorkspace(let projectID, let taskID) = action {
            workspaceCreatorContext = WarrenWorkspaceCreatorContext(
                endpointID: selectedEndpointID,
                projectID: projectID,
                taskID: taskID
            )
        } else if case .requestProjectSetupScript(let projectID) = action {
            guard let project = activeProjection.projectGroup(id: projectID)?.project else { return }
            setupScriptValue = project.setupScript ?? ""
            setupScriptEndpointID = selectedEndpointID
            setupScriptProjectID = projectID
        } else if case .requestProjectWorktreeImport(let projectID) = action {
            presentWorktreeImport(for: projectID)
        } else if case .setProjectAutoImportGitWorktrees(let projectID, let enabled) = action {
            remoteModel.setProjectAutoImportGitWorktrees(projectID, enabled: enabled)
        } else if case .requestNewSession(let workspaceID, let token) = action {
            remoteModel.createSession(workspaceID: workspaceID, request: .shell, token: token)
        } else {
            let workspaceID = WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: action,
                in: remoteModel.projection,
                creatingWorkspaceIDs: remoteModel.creatingSessionWorkspaceIDs,
                autoOpenShell: remoteModel.autoOpenShell,
                autoStartAI: remoteModel.autoStartAI
            )
            remoteModel.perform(action)
            guard let workspaceID else { return }
            switch action {
            case .openWorkspace:
                // A preceding select action may already have reserved this
                // workspace for the first AI. The remote model's reservation
                // guard prevents the double-click path from creating a second
                // process. If this is the first event, the AI preference wins
                // over the Shell preference for the same empty workspace.
                if remoteModel.autoStartAI {
                    if let preset = WarrenDesktopSessionPreset.firstAI(
                        orderedBy: presetOrder,
                        hidden: hiddenPresets
                    ) {
                        remoteModel.createSession(
                            workspaceID: workspaceID,
                            request: preset.resolvedRequest(
                                commandOverride: command(for: preset.id),
                                conversation: autoStartsConversation
                            )
                        )
                    } else if remoteModel.autoOpenShell {
                        remoteModel.createSession(workspaceID: workspaceID, request: .shell)
                    }
                } else {
                    remoteModel.createSession(workspaceID: workspaceID, request: .shell)
                }
            case .selectWorkspace, .selectProject:
                guard let preset = WarrenDesktopSessionPreset.firstAI(
                    orderedBy: presetOrder,
                    hidden: hiddenPresets
                ) else { return }
                remoteModel.createSession(
                    workspaceID: workspaceID,
                    request: preset.resolvedRequest(
                        commandOverride: command(for: preset.id),
                        conversation: autoStartsConversation
                    )
                )
            default:
                break
            }
        }
    }

    /// An automatic launch has no click to answer "Ask each time", so only an
    /// explicit Chat preference starts a Conversation; otherwise it is the CLI.
    private var autoStartsConversation: Bool {
        WarrenAgentInterface(storedValue: agentInterfaceRawValue) == .acp
    }

    private func command(for presetID: String) -> String {
        switch presetID {
        case "claude": claudeCommand
        case "codex": codexCommand
        case "opencode": opencodeCommand
        case "pi": piCommand
        case "qoder": qoderCommand
        case "antigravity": antigravityCommand
        case "trae": traeCommand
        default: ""
        }
    }

    private var endpointOptions: [WarrenDesktopEndpointOption] {
        let localEndpoint = WarrenRemoteEndpointConfiguration.localDaemon()
        let localProbe = remoteModel.hostProbes[localEndpoint]
        let localLabel = displayConfiguration?.displayName(
            for: "local",
            fallback: "Local"
        ) ?? "Local"
        let local = WarrenDesktopEndpointOption(
            id: "local",
            label: localLabel,
            isLocal: true,
            detail: Self.endpointDetail(localEndpoint.url),
            probeStatus: localProbe?.message ?? "Checking Host…",
            probeFailed: localProbe?.isFailure ?? false,
            probeState: Self.probeState(localProbe, isInFlight: remoteModel.hostProbesInFlight.contains(localEndpoint)),
            connectionError: selectedEndpointID == "local" ? remoteModel.connectionError : nil,
            isDisplayedInSidebar: displayConfiguration?.endpoints.contains("local") == true
        )
        let configured = endpointCatalog
            .filter { $0.id != local.id }
            .map { endpoint in
                let label = displayConfiguration?.displayName(
                    for: endpoint.id,
                    fallback: endpoint.name
                ) ?? endpoint.name
                return WarrenDesktopEndpointOption(
                    id: endpoint.id,
                    label: label,
                    detail: endpoint.ssh.map { "SSH · \($0)" } ?? Self.endpointDetail(endpoint.url),
                    probeStatus: remoteModel.hostProbes[endpoint]?.message ?? "Checking Host…",
                    probeFailed: remoteModel.hostProbes[endpoint]?.isFailure ?? false,
                    probeState: Self.probeState(
                        remoteModel.hostProbes[endpoint],
                        isInFlight: remoteModel.hostProbesInFlight.contains(endpoint)
                    ),
                    connectionError: selectedEndpointID == endpoint.id ? remoteModel.connectionError : nil,
                    isDisplayedInSidebar: displayConfiguration?.endpoints.contains(endpoint.id) == true
                )
            }
        return [local] + configured
    }

    /// What a Host's dot shows: a probe still running is checking, even when
    /// an older result is on hand.
    private static func probeState(
        _ probe: WarrenHostProbe?,
        isInFlight: Bool
    ) -> WarrenDesktopEndpointOption.ProbeState {
        if isInFlight { return .checking }
        guard let probe else { return .unknown }
        if probe.isFailure { return .failed }
        return probe.isInconclusive ? .unknown : .reachable
    }

    private static func endpointDetail(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return urlString
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var isLocalEndpoint: Bool { selectedEndpointID == "local" }

    private var selectedEndpointCapabilities: WarrenDesktopEndpointCapabilities {
        endpointOptions.first(where: { $0.id == selectedEndpointID })?.capabilities
            ?? (isLocalEndpoint ? .local : .remote)
    }

    private func publishEndpointCapabilities() {
        NotificationCenter.default.post(
            name: WarrenDesktopEndpointCapabilitiesNotification.didChange,
            object: selectedEndpointCapabilities
        )
    }

    /// Path of the workspace the sidebar currently points at, used to warm
    /// the embedded editor before its pane is ever opened.
    private var selectedWorkspacePath: String? {
        guard isLocalEndpoint,
              case .workspace(let workspaceID) = activeNavigation.selection
        else { return nil }
        return activeProjection.workspace(id: workspaceID)?.path
    }

    private var activeProjection: WarrenDesktopProjection {
        remoteModel.projection
    }
    private var activeNavigation: WarrenDesktopNavigationState {
        remoteModel.navigation
    }

    /// Navigation IDs are Host-local. Use the scope held by the interactive
    /// controller rather than the requested endpoint so a transient switch
    /// cannot expand a same-ID Project in a different Host section.
    private var activeSidebarResourceSelection: WarrenDesktopSidebarResourceSelection? {
        let endpointID = remoteModel.navigationEndpointID
        switch activeNavigation.selection {
        case .project(let projectID):
            return .project(
                WarrenDesktopHostResourceRef(endpointID: endpointID, id: projectID)
            )
        case .workspace(let workspaceID):
            return .workspace(
                WarrenDesktopHostResourceRef(endpointID: endpointID, id: workspaceID)
            )
        case .none:
            return nil
        }
    }

    private func handleAgentCompletion(_ event: WarrenAgentCompletionEvent) {
        let selectedSessionID = activeNavigation.selectedTabID.flatMap { tabID in
            activeProjection.tabs.first(where: { $0.id == tabID })?.sessionID
        }
        guard !NSApp.isActive || selectedSessionID != event.sessionID else { return }
        WarrenDesktopNotificationSound.playAgentCompletionSoundIfEnabled()
    }

    private func selectEndpoint(
        _ id: String,
        preservingPendingSidebarSelection: Bool = false
    ) {
        guard endpointOptions.contains(where: { $0.id == id }) else { return }
        if !preservingPendingSidebarSelection {
            pendingSidebarSelection = nil
            pendingSidebarOpenWorkspace = nil
            pendingSidebarOpenSession = nil
        }
        WarrenHangDiagnostics.logEndpointSwitch(from: selectedEndpointID, to: id)
        selectedEndpointID = id
        do {
            try WarrenEndpointCatalog.setCurrent(id)
        } catch {
            remoteModel.report(error)
        }
    }

    private func setEndpointSidebarVisibility(
        _ endpointID: String,
        isDisplayed: Bool
    ) {
        guard endpointOptions.contains(where: { $0.id == endpointID }) else { return }
        do {
            let configURL = WarrenEndpointCatalog.configurationURL()
            try WarrenEndpointCatalog.setDisplayMembership(
                endpointID,
                isDisplayed: isDisplayed,
                to: configURL
            )
            let catalog = try WarrenEndpointCatalog.loadThrowing(from: configURL)
            endpointCatalog = catalog.endpoints
            displayConfiguration = catalog.display
        } catch {
            remoteModel.report(error)
        }
    }

    private func setEndpointDisplayName(
        _ endpointID: String,
        name: String?
    ) {
        guard endpointOptions.contains(where: { $0.id == endpointID }) else { return }
        do {
            let configURL = WarrenEndpointCatalog.configurationURL()
            try WarrenEndpointCatalog.setDisplayName(
                endpointID,
                name: name,
                to: configURL
            )
            let catalog = try WarrenEndpointCatalog.loadThrowing(from: configURL)
            endpointCatalog = catalog.endpoints
            displayConfiguration = catalog.display
        } catch {
            remoteModel.report(error)
        }
    }

    /// Forgets a Host. The window's own Host hands over to this Mac first,
    /// so the connection is never left pointing at an endpoint that is gone.
    private func deleteEndpoint(_ endpointID: String) {
        guard endpointID != "local",
              endpointOptions.contains(where: { $0.id == endpointID }) else { return }
        if selectedEndpointID == endpointID {
            selectEndpoint("local")
        }
        do {
            let configURL = WarrenEndpointCatalog.configurationURL()
            try WarrenEndpointCatalog.remove(endpointID, from: configURL)
            let catalog = try WarrenEndpointCatalog.loadThrowing(from: configURL)
            endpointCatalog = catalog.endpoints
            displayConfiguration = catalog.display
        } catch {
            remoteModel.report(error)
        }
    }

    private func selectSidebarResource(
        _ selection: WarrenDesktopSidebarResourceSelection
    ) {
        guard endpointOptions.contains(where: { $0.id == selection.endpointID }) else {
            return
        }
        // A later single-click supersedes an earlier double-click request.
        // Otherwise an old pending open could fire after the user promotes a
        // different Host.
        pendingSidebarOpenWorkspace = nil
        pendingSidebarOpenSession = nil
        if selection.endpointID != selectedEndpointID {
            pendingSidebarSelection = selection
            selectEndpoint(
                selection.endpointID,
                preservingPendingSidebarSelection: true
            )
            return
        }
        applySidebarResource(selection)
    }

    private func applySidebarResource(
        _ selection: WarrenDesktopSidebarResourceSelection
    ) {
        guard selection.endpointID == selectedEndpointID,
              remoteModel.isReady(for: selection.endpointID) else {
            return
        }
        switch selection {
        case .project(let reference):
            guard activeProjection.projectGroup(id: reference.id) != nil else {
                return
            }
            pendingSidebarSelection = nil
            handle(.selectProject(reference.id))
        case .workspace(let reference):
            guard activeProjection.workspace(id: reference.id) != nil else {
                return
            }
            pendingSidebarSelection = nil
            handle(.selectWorkspace(reference.id))
        }
    }

    private func openSidebarWorkspace(
        _ reference: WarrenDesktopHostResourceRef<WorkspaceID>
    ) {
        guard endpointOptions.contains(where: { $0.id == reference.endpointID }) else {
            return
        }
        pendingSidebarOpenSession = nil
        if reference.endpointID != selectedEndpointID {
            pendingSidebarSelection = .workspace(reference)
            pendingSidebarOpenWorkspace = reference
            selectEndpoint(reference.endpointID, preservingPendingSidebarSelection: true)
            return
        }
        applySidebarWorkspaceOpen(reference)
    }

    private func applySidebarWorkspaceOpen(
        _ reference: WarrenDesktopHostResourceRef<WorkspaceID>
    ) {
        guard reference.endpointID == selectedEndpointID,
              remoteModel.isReady(for: reference.endpointID),
              activeProjection.workspace(id: reference.id) != nil,
              activeProjection.isConnected else {
            return
        }
        pendingSidebarSelection = nil
        pendingSidebarOpenWorkspace = nil
        handle(.openWorkspace(reference.id))
    }

    private func openSidebarSession(
        _ reference: WarrenDesktopHostResourceRef<TerminalSessionID>
    ) {
        guard endpointOptions.contains(where: { $0.id == reference.endpointID }) else {
            return
        }
        // A session row is a stronger open request than a workspace row. Clear
        // any older pending resource so a slow Host switch cannot activate the
        // wrong UUID after the user has chosen a different Agent.
        pendingSidebarSelection = nil
        pendingSidebarOpenWorkspace = nil
        if reference.endpointID != selectedEndpointID {
            pendingSidebarOpenSession = reference
            selectEndpoint(reference.endpointID, preservingPendingSidebarSelection: true)
            return
        }
        pendingSidebarOpenSession = reference
        applySidebarSessionOpen(reference)
    }

    private func applySidebarSessionOpen(
        _ reference: WarrenDesktopHostResourceRef<TerminalSessionID>
    ) {
        guard reference.endpointID == selectedEndpointID else { return }
        guard remoteModel.isReady(for: reference.endpointID) else { return }
        guard let session = activeProjection.sessions.first(where: { $0.id == reference.id }),
              session.state.isActive else {
            // Once the Host is ready, a missing or no-longer-live row is
            // authoritative. Drop it instead of retrying the stale UUID on
            // every roster update. Every live Session the tree lists is
            // openable: the rich tree's leaves include plain shells, and
            // requiring an Agent binding left those rows inert.
            if pendingSidebarOpenSession == reference {
                pendingSidebarOpenSession = nil
            }
            return
        }
        pendingSidebarOpenSession = nil
        handle(.openSession(reference.id))
    }

    private func applyPendingSidebarSelectionIfReady() {
        guard remoteModel.isReady(for: selectedEndpointID) else { return }
        if let pendingSession = pendingSidebarOpenSession,
           pendingSession.endpointID == selectedEndpointID {
            applySidebarSessionOpen(pendingSession)
            if pendingSidebarOpenSession != nil {
                return
            }
        }
        if let pendingOpen = pendingSidebarOpenWorkspace,
           pendingOpen.endpointID == selectedEndpointID {
            applySidebarWorkspaceOpen(pendingOpen)
            if pendingSidebarOpenWorkspace != nil {
                return
            }
        }
        guard let pending = pendingSidebarSelection,
              pending.endpointID == selectedEndpointID else {
            return
        }
        applySidebarResource(pending)
    }

    private func retrySidebarHost(_ endpointID: String) {
        if endpointID == selectedEndpointID {
            retrySelectedEndpointConnection()
        } else {
            multiHostSidebar.retry(endpointID: endpointID)
        }
    }

    private func refreshMultiHostSidebar() {
        multiHostSidebar.configure(
            display: displayConfiguration,
            endpoints: endpointCatalog,
            activeEndpointID: selectedEndpointID,
            activeProjection: remoteModel.projection,
            // An attached projection that is not ready for the selected
            // endpoint is the previous Host's, still published mid-switch.
            activeProjectionIsCurrent: !remoteModel.projection.isConnected
                || remoteModel.isReady(for: selectedEndpointID),
            activeConnectionError: remoteModel.connectionError
        )
        applyPendingSidebarSelectionIfReady()
    }

    /// The Add SSH Host page the Host panel drills into. The Desktop draws
    /// it; the app owns the catalog and how an alias becomes an endpoint.
    private var sshHostPageModel: WarrenDesktopSSHHostPageModel {
        WarrenDesktopSSHHostPageModel(
            load: {
                let result = await Task.detached(priority: .utility) {
                    WarrenSSHHostCatalog.loadResult(
                        from: FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".ssh/config")
                    )
                }.value
                return WarrenDesktopSSHHostLoadResult(
                    hosts: result.hosts.map(Self.sshHostOption),
                    error: result.error
                )
            },
            onAdd: { option in
                configureSSHHost(named: option.name)
            },
            onCopyFallback: { option in
                copySSHHostFallback(named: option.name)
            },
            onOpenConfig: openSSHConfig
        )
    }

    private static func sshHostOption(_ host: WarrenSSHHost) -> WarrenDesktopSSHHostOption {
        WarrenDesktopSSHHostOption(
            id: host.name,
            name: host.name,
            route: "\(host.user)@\(host.host):\(host.port)",
            isSupported: host.supported,
            reason: host.message
        )
    }

    private func configureSSHHost(named name: String) {
        let endpointName = Self.endpointName(for: name, endpoints: endpointCatalog)
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: endpointName,
            url: "http://127.0.0.1:0",
            token: "",
            ssh: name
        )
        do {
            try WarrenEndpointCatalog.upsert(endpoint, current: endpointName)
            endpointCatalog = WarrenEndpointCatalog.load().endpoints
            selectedEndpointID = endpointName
        } catch {
            remoteModel.report(error)
        }
    }

    private func copySSHHostFallback(named name: String) {
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "ssh -L 8789:127.0.0.1:8789 \(quoted)"
            + "  # then: warren endpoint add \(quoted)"
            + " --url http://127.0.0.1:8789 --token '<TOKEN>' --use"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    private func openSSHConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(".ssh/config")
        if FileManager.default.fileExists(atPath: config.path) {
            NSWorkspace.shared.open(config)
        } else {
            let sshDirectory = home.appendingPathComponent(".ssh")
            try? FileManager.default.createDirectory(
                at: sshDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            NSWorkspace.shared.open(sshDirectory)
        }
    }

    nonisolated static func endpointName(
        for hostName: String,
        endpoints: [WarrenRemoteEndpointConfiguration]
    ) -> String {
        // `local` is a synthetic endpoint owned by the Desktop and is not
        // stored in the shared catalog. Reserve that identifier so an SSH
        // alias named "local" cannot be persisted into an unreachable,
        // indistinguishable row.
        let occupied = Set(["local"]).union(endpoints.map(\.name))
        if !occupied.contains(hostName) {
            return hostName
        }
        var candidate = "ssh-\(hostName)"
        var suffix = 2
        while occupied.contains(candidate) {
            candidate = "ssh-\(hostName)-\(suffix)"
            suffix += 1
        }
        // Re-selecting an existing SSH endpoint should update it in place.
        if endpoints.contains(where: { $0.name == hostName && $0.ssh == hostName }) {
            return hostName
        }
        return candidate
    }

    private func restoreEndpointSelection() {
        let catalog = WarrenEndpointCatalog.load()
        if let current = catalog.current,
           endpointOptions.contains(where: { $0.id == current }) {
            selectedEndpointID = current
        } else if !endpointOptions.contains(where: { $0.id == selectedEndpointID }) {
            selectedEndpointID = "local"
        }
        connectSelectedEndpoint()
    }

    private func monitorEndpointConfiguration() async {
        while !Task.isCancelled {
            let previous = endpointCatalog
            let loadedCatalog: (
                current: String?,
                endpoints: [WarrenRemoteEndpointConfiguration],
                display: WarrenDisplayConfiguration?
            )
            do {
                loadedCatalog = try await Task.detached(priority: .utility) {
                    try WarrenEndpointCatalog.loadThrowing(from: WarrenEndpointCatalog.configurationURL())
                }.value
            } catch {
                let message = error.localizedDescription
                if endpointCatalogError != message {
                    endpointCatalogError = message
                    remoteModel.addNotice(
                        title: "Host list unavailable",
                        message: "Warren could not read ~/.warren/config.json.",
                        detail: message,
                        kind: .error
                    )
                }
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            endpointCatalogError = nil
            let loaded = loadedCatalog.endpoints
            let displayChanged = loadedCatalog.display != displayConfiguration
            // A missing `current` is the normal fresh-checkout state.
            let currentChanged: Bool
            if let current = loadedCatalog.current {
                currentChanged = current != selectedEndpointID
            } else {
                currentChanged = selectedEndpointID != "local"
                    && !loaded.contains(where: { $0.id == selectedEndpointID })
            }
            guard loaded != previous || currentChanged || displayChanged else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            endpointCatalog = loaded
            displayConfiguration = loadedCatalog.display
            if let current = loadedCatalog.current,
               current == "local" || loaded.contains(where: { $0.id == current }) {
               selectedEndpointID = current
            }
            refreshMultiHostSidebar()
            guard selectedEndpointID != "local" else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if let endpoint = loaded.first(where: { $0.id == selectedEndpointID }) {
                if previous.first(where: { $0.id == selectedEndpointID }) != endpoint {
                    connectSelectedEndpoint()
                }
            } else {
                selectedEndpointID = "local"
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func connectSelectedEndpoint() {
        localEndpointWaitGeneration &+= 1
        let waitGeneration = localEndpointWaitGeneration
        let start = Date()
        TerminalDiagnostics.log("connect_selected_begin", ["endpoint": selectedEndpointID, "isLocal": isLocalEndpoint ? "true" : "false"])
        defer {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            TerminalDiagnostics.log("connect_selected_end", ["endpoint": selectedEndpointID, "duration_ms": String(ms)])
        }
        guard isLocalEndpoint else {
            guard let endpoint = endpointCatalog.first(where: { $0.id == selectedEndpointID }) else {
                remoteModel.disconnect()
                return
            }
            remoteModel.connect(endpoint, isLocal: false)
            return
        }
        // Rebuild the endpoint on every pass instead of capturing it once
        // before the loop: on a clean first launch the daemon writes
        // ~/.warren/token only after this app starts, so a token captured
        // once is empty and the connection can never succeed (code 7).
        guard !remoteModel.isConnected(to: WarrenRemoteEndpointConfiguration.localDaemon()) else { return }
        remoteModel.disconnect()
        remoteModel.markConnectionConnecting()
        Task { @MainActor in
            for _ in 0..<30 {
                guard self.localEndpointWaitGeneration == waitGeneration,
                      self.selectedEndpointID == "local" else { return }
                remoteModel.refreshLocalRuntimeMigrationStatus()
                let endpoint = WarrenRemoteEndpointConfiguration.localDaemon()
                // The remote model already owns the WebSocket retry loop. Once
                // the daemon has published its token, connect immediately
                // instead of issuing a second authenticated probe that races
                // the menu-bar supervisor.
                if !endpoint.token.isEmpty {
                    remoteModel.connect(endpoint, isLocal: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard self.localEndpointWaitGeneration == waitGeneration,
                  self.selectedEndpointID == "local" else { return }
            remoteModel.markConnectionFailed(NSError(domain: "WarrenRemote", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "The local daemon is not running; check the Warren status in the menu bar.",
            ]))
        }
    }

    private func stopSelectedEndpointConnection() {
        localEndpointWaitGeneration &+= 1
        remoteModel.stopConnection()
    }

    private func retrySelectedEndpointConnection() {
        // Re-resolve the selected catalog entry instead of relying on the
        // model's retained transport state. Stop clears that state by design;
        // the same action must still restart a direct or SSH endpoint.
        connectSelectedEndpoint()
    }

    private func beginSupersetImport() {
        guard selectedEndpointCapabilities.canImportSuperset,
              !isSupersetImporting else { return }
        setSupersetImporting(true)
        Task { @MainActor in
            do {
                supersetImportPreview = try await remoteModel.previewSupersetImport()
            } catch {
                remoteModel.report(error)
            }
            setSupersetImporting(false)
        }
    }

    private func setSupersetImporting(_ importing: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isSupersetImporting = importing
        }
    }

    private func presentWorktreeImport(for projectID: ProjectID) {
        let endpointID = selectedEndpointID
        worktreeImportEndpointID = endpointID
        worktreeImportProjectID = projectID
        worktreeImportCandidates = []
        worktreeImportLoading = true
        Task { @MainActor in
            do {
                let candidates = try await remoteModel.listProjectWorktrees(projectID)
                guard selectedEndpointID == endpointID,
                      worktreeImportEndpointID == endpointID,
                      worktreeImportProjectID == projectID else {
                    return
                }
                worktreeImportCandidates = candidates
            } catch {
                guard selectedEndpointID == endpointID,
                      worktreeImportEndpointID == endpointID,
                      worktreeImportProjectID == projectID else {
                    return
                }
                remoteModel.report(error)
                dismissWorktreeImport()
            }
            if selectedEndpointID == endpointID,
               worktreeImportEndpointID == endpointID,
               worktreeImportProjectID == projectID {
                worktreeImportLoading = false
            }
        }
    }

    private func dismissSetupScript() {
        setupScriptProjectID = nil
        setupScriptEndpointID = nil
    }

    private func dismissWorktreeImport() {
        worktreeImportProjectID = nil
        worktreeImportEndpointID = nil
        worktreeImportCandidates = []
        worktreeImportLoading = false
    }

    private func importProject(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            Task {
                let hasScopedAccess = folder.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
                }
                await remoteModel.addProject(folder)
            }
        case .failure(let error):
            remoteModel.report(error)
        }
    }
}

private struct WarrenSupersetImportView: View {
    let preview: SupersetImportPreview
    let onCancel: () -> Void
    let onConfirm: (SupersetImportPreview) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var selectedProjectIDs: Set<String>

    init(
        preview: SupersetImportPreview,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (SupersetImportPreview) -> Void
    ) {
        self.preview = preview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedProjectIDs = State(initialValue: preview.readyProjectIDs)
    }

    private var allWorkspaces: [SupersetImportWorkspaceCandidate] {
        preview.projects.flatMap(\.workspaces)
    }

    private var selectedPreview: SupersetImportPreview {
        preview.selectingProjects(selectedProjectIDs)
    }

    private var missingPathCount: Int {
        allWorkspaces.filter { $0.status == .missing }.count
    }

    private var invalidPathCount: Int {
        allWorkspaces.filter { $0.status == .invalid }.count
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Import from Superset",
            message: "One-time copy. Warren does not modify or synchronize Superset.",
            width: .l
        ) {
            VStack(alignment: .leading, spacing: 14) {
                summary(tokens: tokens)
                projectList(tokens: tokens)
            }
        } footer: {
            footer(tokens: tokens)
        }
    }

    private func summary(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            summaryMetric(preview.readyProjectCount, label: "ready projects", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(preview.readyWorkspaceCount, label: "ready workspaces", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(missingPathCount, label: "missing paths", tokens: tokens)
            separator(tokens: tokens)
            summaryMetric(invalidPathCount, label: "invalid paths", tokens: tokens)
            Spacer(minLength: 0)
        }
    }

    private func summaryMetric(
        _ value: Int,
        label: String,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            Text("\(value)")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.foreground)
            Text(label)
                .font(WarrenTypography.dialogMeta)
                .foregroundStyle(tokens.mutedForeground)
        }
    }

    private func separator(tokens: WarrenColorTokens) -> some View {
        Text("·")
            .font(WarrenTypography.dialogMeta)
            .foregroundStyle(tokens.mutedForeground)
            .accessibilityHidden(true)
    }

    private func projectList(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            if preview.projects.isEmpty {
                Text("No projects found in Superset.")
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, WarrenSpacing.large)
            } else {
                LazyVStack(spacing: WarrenSpacing.xs) {
                    ForEach(preview.projects) { project in
                        projectRow(project, tokens: tokens)
                    }
                }
                .padding(WarrenSpacing.small)
            }
        }
        .frame(minHeight: 280, maxHeight: 420)
        .background(tokens.inputSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
    }

    private func projectRow(
        _ project: SupersetImportProjectCandidate,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelectable = project.status == .ready
        let isSelected = selectedProjectIDs.contains(project.id)
        return HStack(spacing: WarrenSpacing.medium) {
            Toggle("", isOn: selectionBinding(for: project))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(tokens.highlight)
                .disabled(!isSelectable)
                .accessibilityLabel(project.name)

            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(project.name)
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    Text(project.status.rawValue.capitalized)
                        .font(WarrenTypography.dialogMeta)
                        .foregroundStyle(statusColor(project.status, tokens: tokens))
                }
                Text(project.repositoryPath)
                    .font(WarrenTypography.code)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: WarrenSpacing.medium)

            VStack(alignment: .trailing, spacing: WarrenSpacing.xxs) {
                Text(workspaceSummary(project))
                    .font(WarrenTypography.dialogMeta)
                    .foregroundStyle(tokens.mutedForeground)
                if let diagnostic = project.diagnostic {
                    Text(diagnostic)
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(statusColor(project.status, tokens: tokens))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
        .background(isSelected ? tokens.fillSelected : Color.clear)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .accessibilityElement(children: .contain)
    }

    private func selectionBinding(for project: SupersetImportProjectCandidate) -> Binding<Bool> {
        Binding(
            get: { selectedProjectIDs.contains(project.id) },
            set: { isOn in
                if isOn {
                    selectedProjectIDs.insert(project.id)
                } else {
                    selectedProjectIDs.remove(project.id)
                }
            }
        )
    }

    private func workspaceSummary(_ project: SupersetImportProjectCandidate) -> String {
        let ready = project.workspaces.filter { $0.status == .ready }.count
        return "\(ready)/\(project.workspaces.count) workspaces"
    }

    private func statusColor(
        _ status: SupersetImportCandidateStatus,
        tokens: WarrenColorTokens
    ) -> Color {
        switch status {
        case .ready:
            tokens.success
        case .missing:
            tokens.warning
        case .invalid:
            tokens.destructive
        }
    }

    private func footer(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 8) {
            Text("\(selectedProjectIDs.count) of \(preview.readyProjectCount) projects selected")
                .font(WarrenTypography.dialogMeta)
                .foregroundStyle(tokens.mutedForeground)

            Spacer(minLength: 0)

            Button(action: onCancel) {
                HStack(spacing: 6) {
                    Text("Cancel")
                    WarrenDialogKeycap("esc")
                }
            }
            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
            .keyboardShortcut(.cancelAction)

            Button {
                onCancel()
                onConfirm(selectedPreview)
            } label: {
                HStack(spacing: 6) {
                    Text("Import")
                    WarrenDialogKeycap("\u{23CE}", isOnPrimary: true)
                }
            }
            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
            .keyboardShortcut(.defaultAction)
            .disabled(selectedProjectIDs.isEmpty)
        }
    }
}

private struct WarrenTerminalSurfaceView: View {
    let context: WarrenDesktopTerminalContext
    let surfaceManager: TerminalSurfaceManager
    let maintenanceMessage: String?
    let connectionState: WarrenDesktopConnectionState
    let isAttaching: Bool
    let onFocused: (TerminalSessionID, TerminalSize?) -> Void
    let onBlurred: (TerminalSessionID) -> Void
    /// Builds the Host's viewer page for a browser Session, or `nil` when the
    /// selected Host cannot run one.
    let browserSurface: @MainActor (String) -> AnyView?
    /// Builds the Conversation surface for an ACP Session, or `nil` for a
    /// Session that has a terminal (RFC 0023). The flag is the pane's
    /// keyboard intent; an inactive or overlaid pane must not take focus.
    let conversationSurface: @MainActor (TerminalSessionID, Bool) -> AnyView?
    @Binding var searchPresented: Bool
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private var activeSurface: GhosttySurface? {
        context.tab.sessionID.flatMap(surfaceManager.surface(for:))
    }

    /// A browser pane renders the Host's viewer page instead of a PTY.
    ///
    /// The browser is a Session like any other, so it is a pane like any other:
    /// its Tab names it, the arrangement sizes it, and the viewer reports the
    /// size the page should be. Nothing here is terminal-shaped, which is why
    /// the pane is the whole of the integration (RFC 0022 §8.1).
    var body: some View {
        if context.tab.kind == .browser,
           let sessionID = context.tab.sessionID,
           let viewer = browserSurface(sessionID.description) {
            viewer
        } else if let sessionID = context.tab.sessionID,
                  let conversation = conversationSurface(
                      sessionID,
                      context.wantsTerminalFocus
                  ) {
            // An ACP Session has no terminal: the conversation is the pane.
            conversation
        } else {
            terminalBody
        }
    }

    private var terminalBody: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return ZStack {
            TerminalHostRepresentable(
                manager: surfaceManager,
                activeSessionID: context.tab.sessionID,
                wantsTerminalFocus: context.wantsTerminalFocus && !searchPresented,
                onFocused: onFocused,
                onBlurred: onBlurred
            )
            if context.tab.sessionID == nil {
                WarrenEmptyWorkspacePanel()
            }
            if let loadingLabel {
                WarrenTerminalLoadingOverlay(label: loadingLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            TerminalDiagnostics.log("terminal_view_appear", [
                "workspace": context.workspace?.id.description ?? "nil",
                "tab": context.tab.sessionID.map(\.description) ?? "nil",
                "mounted": String(surfaceManager.retainedSurfaceCount),
                "active": activeSurface != nil ? "true" : "false",
            ])
        }
        .overlay(alignment: .topTrailing) {
            if searchPresented, activeSurface != nil {
                WarrenTerminalSearchBar(
                    presented: $searchPresented,
                    query: $searchQuery,
                    fieldFocused: $searchFieldFocused,
                    surface: activeSurface
                )
                .padding(WarrenSpacing.compact)
            }
        }
        .overlay(alignment: .top) {
            if let maintenanceMessage {
                WarrenTerminalStatusPill(
                    title: "Updating Warren…",
                    detail: maintenanceMessage == "Warren is updating" ? nil : maintenanceMessage,
                    lingeringDetail: "Your Sessions pick up where they were once it is back."
                )
                .padding(.top, WarrenSpacing.small)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .onChange(of: searchPresented) { presented in
            if presented {
                searchQuery = activeSurface?.readSelection() ?? ""
                searchFieldFocused = true
            } else {
                searchQuery = ""
                searchFieldFocused = false
                activeSurface?.endSearch()
            }
        }
        .onChange(of: context.tab.sessionID) { _ in
            TerminalDiagnostics.log("terminal_tab_switch", [
                "tab": context.tab.sessionID.map(\.description) ?? "nil",
                "surfaces": String(surfaceManager.retainedSurfaceCount),
            ])
            surfaceManager.endAllSearches()
            searchQuery = ""
            searchPresented = false
        }
        .onChange(of: context.scopeID) { _ in
            TerminalDiagnostics.log("workspace_switch", [
                "workspace": context.workspace?.id.description ?? "nil",
                "tab": context.tab.sessionID.map(\.description) ?? "nil",
                "mounted": String(surfaceManager.retainedSurfaceCount),
                "active": activeSurface != nil ? "true" : "false",
            ])
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: WarrenDesktopCommand.settingsDismissed
            )
        ) { _ in
            // Returning the keyboard to the Session is the activation path's
            // job: closing Settings restores the navigation it covered, which
            // reaches `presentSelectedSession(activatingInput: true)`. Only the
            // presentation can still be deferred here.
            if let sessionID = context.tab.sessionID {
                surfaceManager.requestPresent(sessionID)
            }
        }
    }

    private var loadingLabel: String? {
        guard maintenanceMessage == nil else { return nil }
        if connectionState == .reconnecting {
            return "Reconnecting terminal…"
        }
        if isAttaching {
            return "Connecting terminal…"
        }
        return nil
    }
}

private struct WarrenTerminalLoadingOverlay: View {
    let label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                WarrenTerminalStatusPill(
                    title: label,
                    lingeringDetail: "The Host is taking a moment; the Session keeps running there."
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .task {
            // A fast attach never shows the pill at all.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                isVisible = true
            }
        }
    }
}

/// The small floating status that sits over a terminal while it connects,
/// reconnects or waits out a Warren update.
///
/// Both used to be bare capsules of their own making: one on the status
/// surface without a border, one on the popover surface with a rule and a
/// different spinner size. This is one card on the menu surface, the
/// spinner in a 16pt slot the way a loading menu row draws it, a title and,
/// once the wait runs long, a second line saying nothing is lost, so a
/// slow reconnect reads as expected rather than stuck.
private struct WarrenTerminalStatusPill: View {
    let title: String
    var detail: String? = nil
    /// Shown in place of `detail` once the wait passes `lingerDelay`.
    var lingeringDetail: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLingering = false

    private static let lingerDelay: Duration = .seconds(4)

    private var shownDetail: String? {
        isLingering ? (lingeringDetail ?? detail) : detail
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: shownDetail == nil ? .center : .top, spacing: 9) {
            WarrenBrailleSpinner(size: 13, accessibilityLabel: title)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground.opacity(0.92))
                if let shownDetail {
                    Text(shownDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .lineLimit(2)
            // Hugs the title alone; with a second line the card takes a
            // reading width so the text wraps instead of stretching, and a
            // narrow pane gets less of it rather than a card wider than itself.
            .frame(maxWidth: shownDetail == nil ? nil : 268, alignment: .leading)
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .padding(.vertical, shownDetail == nil ? 8 : 9)
        .background(shape.fill(tokens.popoverSurface))
        .overlay(shape.strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
        .shadow(color: tokens.elevationShadow, radius: 14, y: 6)
        .padding(.horizontal, WarrenSpacing.small)
        .animation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion), value: isLingering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .task {
            guard lingeringDetail != nil else { return }
            try? await Task.sleep(for: Self.lingerDelay)
            guard !Task.isCancelled else { return }
            isLingering = true
        }
    }
}

/// Empty workspace state rendered above the stable native terminal host.
private struct WarrenEmptyWorkspacePanel: View {
    var body: some View {
        WarrenDesktopEmptyStage(
            mark: .symbol("terminal"),
            title: "Start a session",
            message: "Open a Shell or an Agent from + in the top bar.",
            // Only what starts a Session: tab and pane shortcuts have
            // nothing to act on until one is open.
            hints: [.init(keys: "⌘T", label: "New shell")]
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No open sessions")
    }
}

private struct WarrenTerminalSearchBar: View {
    @Binding var presented: Bool
    @Binding var query: String
    @FocusState.Binding var fieldFocused: Bool
    let surface: GhosttySurface?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: WarrenSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.mutedForeground)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(WarrenTypography.terminalSearchField)
                .focused($fieldFocused)
                .frame(width: 170)
                .onSubmit {
                    surface?.navigateSearch(.next)
                }

            Button {
                surface?.navigateSearch(.previous)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 20, height: 20)
            }
            .warrenTooltip("Previous match", shortcut: "⇧⏎")

            Button {
                surface?.navigateSearch(.next)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 20, height: 20)
            }
            .warrenTooltip("Next match", shortcut: "⏎")

            Button {
                presented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .keyboardShortcut(.cancelAction)
            .warrenTooltip("Close search", shortcut: "esc")
        }
        .buttonStyle(.plain)
        .font(WarrenTypography.navigationMeta)
        .foregroundStyle(tokens.mutedForeground)
        .padding(.horizontal, WarrenSpacing.small)
        .frame(height: 30)
        .warrenMenuSurface(width: nil, shadowY: 6)
        .onAppear {
            surface?.search(for: query)
            focusSearchField()
        }
        .onChange(of: query) { newValue in
            surface?.search(for: newValue)
        }
    }

    private func focusSearchField() {
        fieldFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled, presented else { return }
            fieldFocused = true
        }
    }
}
