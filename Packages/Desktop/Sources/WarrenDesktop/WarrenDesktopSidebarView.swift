import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopSidebar: View {
    let projection: WarrenDesktopProjection
    @Binding var sidebarState: WarrenDesktopSidebarState
    @Binding var sidebarTree: WarrenDesktopSidebarTreeState
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
    let chromeMode: WarrenDesktopChromeMode
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let showsTasks: Bool
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
    let onRequestTaskCreate: () -> Void
    let endpointCapabilities: WarrenDesktopEndpointCapabilities
    let onAction: (WarrenDesktopAction) -> Void
    let onCommandPalette: () -> Void
    let onSettings: () -> Void
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    let onRequestTerminalGroupCreate: () -> Void
    let onRequestTerminalGroupEdit: (TerminalGroup) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            WarrenDesktopSidebarHeader(
                isCollapsed: sidebarState.isCollapsed,
                chromeMode: chromeMode,
                updateStatus: updateStatus,
                onUpdateAction: onUpdateAction,
                onToggle: toggleSidebar,
                onCommandPalette: onCommandPalette,
                showsActiveOnly: sidebarTree.showsActiveOnly,
                onToggleActiveOnly: toggleActiveOnly
            )
            ScrollViewReader { proxy in
                WarrenOverflowFadeScrollView(
                    .vertical,
                    fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                    surface: tokens.sidebarSurface
                ) {
                    WarrenDesktopSidebarRows(
                        taskGroups: projection.taskGroups,
                        groups: projection.groups,
                        terminalGroups: projection.terminalGroups.map {
                            WarrenDesktopTerminalGroup(
                                group: $0,
                                sessions: projection.sessions(in: $0.id)
                            )
                        },
                        workspaceActivitySummaries: projection.workspaceActivitySummaries,
                        activeWorkspaceIDs: projection.activeWorkspaceIDs,
                        // Active Sessions lives in the dedicated shortcut
                        // switcher; the sidebar stays focused on navigation.
                        showsActiveSessions: false,
                        showsTasks: showsTasks,
                        tree: $sidebarTree,
                        isCollapsed: sidebarState.isCollapsed,
                        selection: selection,
                        selectedTabID: selectedTabID,
                        deletingProjectIDs: deletingProjectIDs,
                        deletingWorkspaceIDs: deletingWorkspaceIDs,
                        endpointCapabilities: endpointCapabilities,
                        isInteractionDisabled: !projection.isConnected,
                        onAddProject: { onAction(.addProject) },
                        onRequestTaskCreate: onRequestTaskCreate,
                        onFocusTask: { taskID in
                            Self.revealTask(taskID, in: &sidebarTree)
                            DispatchQueue.main.async {
                                withAnimation(WarrenMotion.animation(
                                    .stateChange,
                                    reduceMotion: reduceMotion
                                )) {
                                    proxy.scrollTo(
                                        "task.\(taskID.description)",
                                        anchor: .center
                                    )
                                }
                            }
                        },
                        onRequestTerminalGroupCreate: onRequestTerminalGroupCreate,
                        onRequestTerminalGroupEdit: onRequestTerminalGroupEdit,
                        onAction: onAction,
                        onRequestRename: onRequestRename,
                        onRequestDeletion: onRequestDeletion
                    )
                    .padding(.vertical, WarrenSpacing.compact)
                }
                .onChange(of: selection) { newSelection in
                    guard case let .workspace(workspaceID)? = newSelection else { return }
                    withAnimation(WarrenMotion.animation(
                        .stateChange,
                        reduceMotion: reduceMotion
                    )) {
                        proxy.scrollTo(workspaceID, anchor: .center)
                    }
                }
            }
            sidebarFooter(tokens: tokens)
        }
        .frame(maxHeight: .infinity)
        .background(tokens.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(tokens.chromeDivider)
                .frame(width: WarrenSpacing.hairline)
                .zIndex(2)
        }
    }

    static func revealTask(
        _ taskID: TaskID,
        in tree: inout WarrenDesktopSidebarTreeState
    ) {
        tree.tasksCollapsed = false
        tree.expandedTaskIDs.insert(taskID)
    }

    private func toggleSidebar() {
        sidebarState.toggleCollapsed()
        onAction(.toggleSidebar)
    }

    private func toggleActiveOnly() {
        withAnimation(WarrenMotion.animation(
            .stateChange,
            reduceMotion: reduceMotion
        )) {
            sidebarTree.showsActiveOnly.toggle()
            if sidebarTree.showsActiveOnly {
                sidebarTree.expandedProjectIDs.formUnion(projection.groups.map(\.project.id))
            }
        }
    }

    private func sidebarFooter(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            if sidebarState.isCollapsed {
                VStack(spacing: WarrenSpacing.xs) {
                    if endpointCapabilities.canAddProject {
                        addProjectButton(tokens: tokens, showsLabel: false)
                    }
                    if updateStatus != .none {
                        updateButton(tokens: tokens)
                    }
                    settingsButton(tokens: tokens)
                }
                .padding(.vertical, WarrenSpacing.xs)
            } else {
                HStack(spacing: WarrenSpacing.xs) {
                    if endpointCapabilities.canAddProject {
                        addProjectButton(tokens: tokens, showsLabel: true)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if updateStatus != .none {
                        WarrenDesktopBuildBadge(
                            updateStatus: updateStatus,
                            showsBuildMarker: false,
                            onUpdateAction: onUpdateAction
                        )
                    }
                    settingsButton(tokens: tokens)
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.vertical, WarrenSpacing.xs)
            }
        }
    }

    private func addProjectButton(tokens: WarrenColorTokens, showsLabel: Bool) -> some View {
        Button { onAction(.addProject) } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                if showsLabel {
                        Text("Add project")
                            .font(WarrenTypography.navigationItemLight)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(tokens.mutedForeground)
            .frame(maxWidth: showsLabel ? .infinity : nil, minHeight: 32, alignment: .leading)
            .frame(width: showsLabel ? nil : 32)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .disabled(!endpointCapabilities.canAddProject || !projection.isConnected)
        .help("Add project")
        .accessibilityLabel("Add project")
        .accessibilityIdentifier("sidebar.add-project")
    }

    private func settingsButton(tokens: WarrenColorTokens) -> some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(tokens.mutedForeground)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .help("Open Warren settings")
        .accessibilityLabel("Open Warren settings")
        .accessibilityIdentifier("sidebar.settings")
    }

    private func updateButton(tokens: WarrenColorTokens) -> some View {
        Button(action: onUpdateAction) {
            Group {
                switch updateStatus {
                case .updating:
                    WarrenBrailleSpinner(size: 10, accessibilityLabel: "Updating Warren")
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                case .available:
                    Image(systemName: "arrow.down.circle")
                case .none:
                    EmptyView()
                }
            }
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(updateStatus == .failed ? tokens.destructive : tokens.info)
            .frame(width: 32, height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle())
        .disabled(!updateStatus.isActionable)
        .help(updateStatus.helpText ?? "Warren is up to date")
        .accessibilityLabel(updateStatus.accessibilityLabel ?? "Warren update")
    }

}
