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
                onCommandPalette: onCommandPalette
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

}
