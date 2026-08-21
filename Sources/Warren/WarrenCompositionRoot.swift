import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesktop
import WarrenDomain
import GhosttyAdapter
import WarrenStateStore
import WarrenDesignSystem

struct WarrenCompositionRoot: View {
    @State private var remoteModel: WarrenRemoteApplicationModel
    @State private var surfaceManager: TerminalSurfaceManager
    @State private var isProjectImporterPresented = false
    @State private var supersetImportPreview: SupersetImportPreview?
    @State private var isSupersetImporting = false
    @State private var workspaceCreatorProjectID: ProjectID?
    @State private var worktreeImportProjectID: ProjectID?
    @State private var worktreeImportCandidates: [WarrenDesktopWorktreeCandidate] = []
    @State private var worktreeImportLoading = false
    @State private var appMessage: WarrenAppMessage?
    @State private var terminalSearchPresented = false
    @State private var updateStatus: WarrenDesktopUpdateStatus = .none
    @StateObject private var presentation = WarrenPresentationCoordinator()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var terminalFontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var terminalFontSize = TerminalFontPreference.defaultSize
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
    @AppStorage("executionEndpoint")
    private var selectedEndpointID = "local"
    @State private var endpointCatalog: [WarrenRemoteEndpointConfiguration]

    @MainActor
    init() {
        let surfaceManager = TerminalSurfaceManager()
        _surfaceManager = State(initialValue: surfaceManager)
        _remoteModel = State(initialValue: WarrenRemoteApplicationModel(
            surfaceManager: surfaceManager
        ))
        // Endpoint configuration is user input, not frame state. Seed the
        // catalog once and refresh it from disk in the background so CLI
        // changes appear without restarting Warren.
        _endpointCatalog = State(initialValue: WarrenEndpointCatalog.load().endpoints)
    }

    var body: some View {
        WarrenDesktopRoot(
            projection: activeProjection,
            navigation: activeNavigation,
            chromeMode: .workspace,
            updateStatus: updateStatus,
            onUpdateAction: {
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.installRequested,
                    object: nil
                )
            },
            actions: WarrenDesktopActions(send: handle),
            webStatus: remoteModel.webStatus,
            creatingSessionWorkspaceIDs: remoteModel.creatingSessionWorkspaceIDs,
            creatingSessionTerminalGroupIDs: remoteModel.creatingSessionTerminalGroupIDs,
            deletingProjectIDs: remoteModel.deletingProjectIDs,
            deletingWorkspaceIDs: remoteModel.deletingWorkspaceIDs,
            endpointOptions: endpointOptions,
            selectedEndpointID: selectedEndpointID,
            onSelectEndpoint: selectEndpoint,
            onWebStart: { remoteModel.startWebFromUI() },
            onWebTest: { edgeURL, accountName, inviteKey, approvalKey in
                remoteModel.testPublicAccess(
                    edgeURL: edgeURL,
                    accountName: accountName,
                    inviteKey: inviteKey,
                    approvalKey: approvalKey
                )
            },
            onWebStop: { remoteModel.stopWeb() },
            onWebOpenURL: { remoteModel.openWebURL($0) },
            onWebCopyURL: { remoteModel.copyWebURL($0) },
            defaultRuntime: remoteModel.defaultRuntime,
            onSetRuntime: { remoteModel.setDefaultRuntime($0) },
            autoOpenShell: remoteModel.autoOpenShell,
            onSetAutoOpenShell: { remoteModel.setAutoOpenShell($0) },
            autoStartAI: remoteModel.autoStartAI,
            onSetAutoStartAI: { remoteModel.setAutoStartAI($0) }
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
                searchPresented: $terminalSearchPresented
            )
        }
        .preferredColorScheme(.dark)
        .disabled(isSupersetImporting)
        .overlay {
            if isSupersetImporting {
                let tokens = WarrenColorTokens.resolved(for: colorScheme)
                ZStack {
                    Color.black.opacity(0.5)
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
        .overlay {
            appPresentationLayer
        }
        .fileImporter(
            isPresented: $isProjectImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: importProject
        )
        .fileDialogMessage("Choose a local folder as the project.")
        .fileDialogConfirmationLabel("Add Project")
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copyLocalURL)) { _ in
            remoteModel.copyLocalWebURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenAppCommand.openTerminal)) { note in
            guard let request = note.object as? WarrenTerminalOpenRequest else { return }
            remoteModel.openTerminal(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenDesktopCommand.findInTerminal)) { _ in
            // Release the terminal's AppKit first responder before the search
            // field mounts so the field receives the next keystroke.
            NSApp.keyWindow?.makeFirstResponder(nil)
            terminalSearchPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: WarrenAppPresentation.message)) { note in
            guard let message = note.object as? WarrenAppMessage else { return }
            appMessage = message
        }
        .onChange(of: terminalFontFamily) { _, _ in updateTerminalFont() }
        .onChange(of: terminalFontSize) { _, _ in updateTerminalFont() }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.startCloudflare)) { _ in
            remoteModel.startCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.stopCloudflare)) { _ in
            remoteModel.stopCloudflareWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.startTailscale)) { _ in
            remoteModel.startTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.stopTailscale)) { _ in
            remoteModel.stopTailscaleWebAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: WebCommand.copySecureURL)) { _ in
            remoteModel.copySecureWebURL()
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
        .onReceive(NotificationCenter.default.publisher(for: WarrenUpdateNotification.failed)) { _ in
            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                updateStatus = .failed
            }
        }
        .task {
            presetOrder = WarrenDesktopSessionPreset.normalizedOrderRawValue(presetOrder)
            hiddenPresets = WarrenDesktopSessionPreset.normalizedHiddenRawValue(hiddenPresets)
            updateTerminalFont()
            restoreEndpointSelection()
            await monitorEndpointConfiguration()
        }
        .onChange(of: selectedEndpointID) { _, _ in connectSelectedEndpoint() }
    }

    @ViewBuilder
    private var appPresentationLayer: some View {
        if let appMessage {
            WarrenMessageDialog(
                title: appMessage.title,
                message: appMessage.message,
                actionLabel: appMessage.actionLabel,
                onDismiss: { self.appMessage = nil }
            )
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.modal) }
            .onDisappear { presentation.dismissTop() }
        } else if let preview = supersetImportPreview {
            WarrenSheetSurface {
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
        } else if let projectID = workspaceCreatorProjectID,
                  let project = activeProjection.projectGroup(id: projectID)?.project {
            WarrenModalSurface {
                WarrenWorkspaceCreatorView(
                    project: project,
                    onCancel: { workspaceCreatorProjectID = nil },
                    onCreate: { request in
                        remoteModel.createWorkspace(projectID: projectID, request: request)
                        workspaceCreatorProjectID = nil
                    }
                )
            }
            .zIndex(WarrenPresentationLayer.modal)
            .onAppear { presentation.present(.modal) }
            .onDisappear { presentation.dismissTop() }
        } else if let projectID = worktreeImportProjectID,
                  let project = activeProjection.projectGroup(id: projectID)?.project {
            WarrenSheetSurface {
                WarrenDesktopProjectWorktreeImportView(
                    projectName: project.name,
                    candidates: worktreeImportCandidates,
                    isLoading: worktreeImportLoading,
                    onCancel: dismissWorktreeImport,
                    onImport: { paths in
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

    private func updateTerminalFont() {
        remoteModel.updateTerminalFont(TerminalFontPreference(
            family: terminalFontFamily,
            size: terminalFontSize
        ))
    }

    private func handle(_ action: WarrenDesktopAction) {
        if action == .addProject {
            if isLocalEndpoint {
                isProjectImporterPresented = true
            } else {
                remoteModel.report(NSError(domain: "WarrenRemote", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Remote projects must use remote paths; add them from the remote CLI.",
                ]))
            }
        } else if action == .importSuperset {
            if isLocalEndpoint {
                beginSupersetImport()
            } else {
                remoteModel.report(NSError(domain: "WarrenRemote", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Superset import must run on the machine hosting the daemon.",
                ]))
            }
        } else if case .requestNewWorkspace(let projectID) = action {
            workspaceCreatorProjectID = projectID
        } else if case .requestProjectWorktreeImport(let projectID) = action {
            presentWorktreeImport(for: projectID)
        } else if case .setProjectAutoImportGitWorktrees(let projectID, let enabled) = action {
            remoteModel.setProjectAutoImportGitWorktrees(projectID, enabled: enabled)
        } else if case .requestNewSession(let workspaceID) = action {
            remoteModel.createSession(workspaceID: workspaceID, request: .shell)
        } else if case .requestNewTerminalGroupSession(let groupID) = action {
            remoteModel.createSession(terminalGroupID: groupID, request: .shell)
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
                            request: preset.resolvedRequest(commandOverride: command(for: preset.id))
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
                    request: preset.resolvedRequest(commandOverride: command(for: preset.id))
                )
            default:
                break
            }
        }
    }

    private func command(for presetID: String) -> String {
        switch presetID {
        case "claude": claudeCommand
        case "codex": codexCommand
        case "trae": traeCommand
        default: ""
        }
    }

    private var endpointOptions: [WarrenDesktopEndpointOption] {
        let local = WarrenDesktopEndpointOption(
            id: "local",
            label: "Local",
            isLocal: true,
            detail: Self.endpointDetail(WarrenRemoteEndpointConfiguration.localDaemon().url)
        )
        let configured = endpointCatalog
            .filter { $0.id != local.id }
            .map { endpoint in
                WarrenDesktopEndpointOption(
                    id: endpoint.id,
                    label: endpoint.name,
                    detail: Self.endpointDetail(endpoint.url)
                )
            }
        return [local] + configured
    }

    private static func endpointDetail(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return urlString
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var isLocalEndpoint: Bool { selectedEndpointID == "local" }
    private var activeProjection: WarrenDesktopProjection {
        remoteModel.projection
    }
    private var activeNavigation: WarrenDesktopNavigationState {
        remoteModel.navigation
    }

    private func selectEndpoint(_ id: String) {
        guard endpointOptions.contains(where: { $0.id == id }) else { return }
        selectedEndpointID = id
    }

    private func restoreEndpointSelection() {
        guard endpointOptions.contains(where: { $0.id == selectedEndpointID }) else {
            selectedEndpointID = "local"
            return
        }
        connectSelectedEndpoint()
    }

    private func monitorEndpointConfiguration() async {
        while !Task.isCancelled {
            let previous = endpointCatalog
            let loaded = WarrenEndpointCatalog.load().endpoints
            guard loaded != previous else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            endpointCatalog = loaded
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
        guard isLocalEndpoint else {
            guard let endpoint = endpointCatalog.first(where: { $0.id == selectedEndpointID }) else {
                remoteModel.disconnect()
                return
            }
            remoteModel.connect(endpoint)
            return
        }
        // Rebuild the endpoint on every pass instead of capturing it once
        // before the loop: on a clean first launch the daemon writes
        // ~/.warren/token only after this app starts, so a token captured
        // once is empty and the connection can never succeed (code 7).
        guard !remoteModel.isConnected(to: WarrenRemoteEndpointConfiguration.localDaemon()) else { return }
        remoteModel.disconnect()
        Task { @MainActor in
            for _ in 0..<30 {
                let endpoint = WarrenRemoteEndpointConfiguration.localDaemon()
                // The remote model already owns the WebSocket retry loop. Once
                // the daemon has published its token, connect immediately
                // instead of issuing a second authenticated /v1/state probe
                // that races the menu-bar supervisor.
                if !endpoint.token.isEmpty {
                    remoteModel.connect(endpoint)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            remoteModel.report(NSError(domain: "WarrenRemote", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "The local daemon is not running; check the Warren status in the menu bar.",
            ]))
        }
    }

    private func beginSupersetImport() {
        guard !isSupersetImporting else { return }
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
        worktreeImportProjectID = projectID
        worktreeImportCandidates = []
        worktreeImportLoading = true
        Task { @MainActor in
            do {
                worktreeImportCandidates = try await remoteModel.listProjectWorktrees(projectID)
            } catch {
                remoteModel.report(error)
                dismissWorktreeImport()
            }
            worktreeImportLoading = false
        }
    }

    private func dismissWorktreeImport() {
        worktreeImportProjectID = nil
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
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(tokens: tokens)

            divider(tokens: tokens)

            summary(tokens: tokens)

            projectList(tokens: tokens)

            divider(tokens: tokens)

            footer(tokens: tokens)
        }
        .frame(
            minWidth: 680,
            idealWidth: 720,
            maxWidth: WarrenLayoutMetrics.wideSheetWidth,
            minHeight: 520,
            idealHeight: 580
        )
    }

    private func divider(tokens: WarrenColorTokens) -> some View {
        Rectangle()
            .fill(tokens.border)
            .frame(height: WarrenSpacing.hairline)
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text("Import from Superset")
                .font(WarrenTypography.dialogTitle)
            Text("One-time copy. Warren does not modify or synchronize Superset.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.top, WarrenSpacing.large)
        .padding(.bottom, WarrenSpacing.standard)
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
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.medium)
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
        .frame(maxHeight: .infinity)
        .background(tokens.chromeSurface)
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.medium)
                .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.medium)
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
        HStack(spacing: WarrenSpacing.compact) {
            Text("\(selectedProjectIDs.count) of \(preview.readyProjectCount) projects selected")
                .font(WarrenTypography.dialogMeta)
                .foregroundStyle(tokens.mutedForeground)

            Spacer(minLength: 0)

            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                onCancel()
                onConfirm(selectedPreview)
            }
            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
            .keyboardShortcut(.defaultAction)
            .disabled(selectedProjectIDs.isEmpty)
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.standard)
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
    @Binding var searchPresented: Bool
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool

    private var activeSurface: GhosttySurface? {
        context.tab.sessionID.flatMap(surfaceManager.surface(for:))
    }

    var body: some View {
        ZStack {
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
                "terminalGroup": context.terminalGroup?.id.description ?? "nil",
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
                HStack(spacing: WarrenSpacing.small) {
                    WarrenBrailleSpinner(
                        size: 14,
                        accessibilityLabel: "Updating Warren"
                    )
                    Text("Updating Warren…")
                        .font(WarrenTypography.supporting)
                        .lineLimit(1)
                }
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.small)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(.top, WarrenSpacing.small)
                .help(maintenanceMessage)
            }
        }
        .onChange(of: searchPresented) { _, presented in
            if presented {
                searchQuery = activeSurface?.readSelection() ?? ""
                searchFieldFocused = true
            } else {
                searchQuery = ""
                searchFieldFocused = false
                activeSurface?.endSearch()
            }
        }
        .onChange(of: context.tab.sessionID) { _, _ in
            TerminalDiagnostics.log("terminal_tab_switch", [
                "tab": context.tab.sessionID.map(\.description) ?? "nil",
                "surfaces": String(surfaceManager.retainedSurfaceCount),
            ])
            surfaceManager.endAllSearches()
            searchQuery = ""
            searchPresented = false
        }
        .onChange(of: context.scopeID) { _, _ in
            TerminalDiagnostics.log("workspace_switch", [
                "workspace": context.workspace?.id.description ?? "nil",
                "terminalGroup": context.terminalGroup?.id.description ?? "nil",
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
            surfaceManager.requestFocusForActiveSurface()
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
                HStack(spacing: WarrenSpacing.compact) {
                    WarrenBrailleSpinner(size: 18, accessibilityLabel: label)
                    Text(label)
                        .font(WarrenTypography.supporting)
                }
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.compact)
                .warrenPresentationSurface(
                    role: .status,
                    cornerRadius: WarrenRadius.medium,
                    showsBorder: false
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                isVisible = true
            }
        }
    }
}

/// Empty workspace state rendered above the stable native terminal host.
private struct WarrenEmptyWorkspacePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: WarrenSpacing.standard) {
            Text("Start a session")
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.mutedForeground)
            Text("Open a terminal with the + button or a preset")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .opacity(0.72)
                .multilineTextAlignment(.center)
                .lineSpacing(WarrenSpacing.small)
            VStack(spacing: WarrenSpacing.compact) {
                shortcutRow(tokens: tokens, key: "⌘T", label: "New terminal")
                shortcutRow(tokens: tokens, key: "⌘X", label: "Next tab")
                shortcutRow(tokens: tokens, key: "⇧⌘X", label: "Previous tab")
                shortcutRow(tokens: tokens, key: "⌘1…⌘9", label: "Switch to tab")
                shortcutRow(tokens: tokens, key: "⌘W", label: "Close terminal")
            }
            .frame(maxWidth: 420)
            .padding(.top, WarrenSpacing.compact)
        }
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No open sessions")
    }

    private func shortcutRow(
        tokens: WarrenColorTokens,
        key: String,
        label: String
    ) -> some View {
        HStack(spacing: WarrenSpacing.medium) {
            Text(key)
                .font(WarrenTypography.shortcut)
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 72, alignment: .leading)
            Spacer(minLength: WarrenSpacing.medium)
            Text(label)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(label)")
    }
}

private struct WarrenTerminalSearchBar: View {
    @Binding var presented: Bool
    @Binding var query: String
    @FocusState.Binding var fieldFocused: Bool
    let surface: GhosttySurface?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.mutedForeground)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(WarrenTypography.code)
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
            .help("Previous match (⇧⏎)")

            Button {
                surface?.navigateSearch(.next)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 20, height: 20)
            }
            .help("Next match (⏎)")

            Button {
                presented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .keyboardShortcut(.cancelAction)
            .help("Close search (esc)")
        }
        .buttonStyle(.plain)
        .font(WarrenTypography.navigationMeta)
        .foregroundStyle(tokens.mutedForeground)
        .padding(.horizontal, WarrenSpacing.small)
        .frame(height: 30)
        .warrenPresentationSurface(role: .popover, cornerRadius: WarrenRadius.medium)
        .onAppear {
            surface?.search(for: query)
            focusSearchField()
        }
        .onChange(of: query) { _, newValue in
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
