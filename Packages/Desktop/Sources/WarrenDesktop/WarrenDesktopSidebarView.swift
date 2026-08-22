import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopSidebar: View {
    let projection: WarrenDesktopProjection
    @Binding var sidebarState: WarrenDesktopSidebarState
    @Binding var sidebarTree: WarrenDesktopSidebarTreeState
    let selection: WarrenDesktopSidebarSelection?
    let chromeMode: WarrenDesktopChromeMode
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let deletingProjectIDs: Set<ProjectID>
    let deletingWorkspaceIDs: Set<WorkspaceID>
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
                        groups: projection.groups,
                        terminalGroups: projection.terminalGroups.map {
                            WarrenDesktopTerminalGroup(
                                group: $0,
                                sessions: projection.sessions(in: $0.id)
                            )
                        },
                        workspaceActivitySummaries: projection.workspaceActivitySummaries,
                        tree: $sidebarTree,
                        isCollapsed: sidebarState.isCollapsed,
                        selection: selection,
                        deletingProjectIDs: deletingProjectIDs,
                        deletingWorkspaceIDs: deletingWorkspaceIDs,
                        isInteractionDisabled: !projection.isConnected,
                        onAddProject: { onAction(.addProject) },
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

    private func toggleSidebar() {
        sidebarState.toggleCollapsed()
        onAction(.toggleSidebar)
    }

}
