import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopSidebar: View {
    let projection: WarrenDesktopProjection
    /// Whether this card is the docked column or the floating peek copy.
    var presentation: WarrenDesktopSidebarPresentation = .docked
    @Binding var sidebarState: WarrenDesktopSidebarState
    @Binding var sidebarTree: WarrenDesktopSidebarTreeState
    let selection: WarrenDesktopSidebarSelection?
    let selectedTabID: String?
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
    /// Which failed shell commands have been looked at; see
    /// `WarrenDesktopShellAttention`.
    @StateObject private var shellAttention = WarrenDesktopShellAttention()
    /// Whether the pointer is over the rail, so an idle row does not collapse
    /// under it.
    @State private var pointerInsideSidebar = false
    /// What the tab bar's fold action does: the tree on screen reports
    /// whether all its projects are open, and a bump asks it to toggle them.
    @State private var allProjectsExpanded: Bool?
    @State private var toggleAllProjectsRequest = 0
    /// Rich is the default because the tree is the only session switcher: the
    /// tab strip controls the panes on screen and no longer lists a workspace's
    /// other Sessions. Compact remains available for navigating projects
    /// without their Sessions, at the cost of having to open a workspace to
    /// reach one.
    let onRequestRename: (WarrenDesktopRenameRequest) -> Void
    let onRequestDeletion: (WarrenDesktopDeletionRequest) -> Void
    let activeEndpointID: String
    let displayConfigurationError: String?
    /// Optional ordered Host sections. When present, the Projects/Workspaces
    /// portion uses the endpoint-scoped read model while the footer and
    /// current-host controls remain unchanged.
    let sidebarHostProjections: [WarrenDesktopSidebarHostProjection]?
    /// An explicit display configuration uses the Host-scoped tree even for
    /// one Host. A missing configuration retains the legacy current-Host
    /// sidebar instead.
    let usesSidebarHostSections: Bool
    /// Selection with the endpoint scope owned by the navigation controller.
    /// It is supplied separately from `activeEndpointID` because a Host switch
    /// can briefly render the old navigation state under a new requested Host.
    let sidebarResourceSelection: WarrenDesktopSidebarResourceSelection?
    let onSelectSidebarResource: (WarrenDesktopSidebarResourceSelection) -> Void
    let onOpenSidebarWorkspace: (WarrenDesktopHostResourceRef<WorkspaceID>) -> Void
    let onOpenSidebarSession: (WarrenDesktopHostResourceRef<TerminalSessionID>) -> Void
    let onRetrySidebarHost: (String) -> Void
    /// The Desktop-local editor markers, folded into each Host's active set so
    /// an editor-only Workspace survives the `Active only` filter (RFC 0021 §7).
    let editorActivity: WarrenDesktopEditorActivityOverlay
    /// Reveals a marked Workspace's editor from its sidebar row.
    var onOpenEditor: (WorkspaceID) -> Void = { _ in }
    /// Drops a Session from the tree onto a pane.
    var onSplitDropSession: ((String, String, SplitDropTarget) -> Void)? = nil
    /// The Host this window works on, for the row at the top of the card.
    var hostSummary: WarrenDesktopSidebarHostIdentity? = nil
    /// Whether Public Access is serving this Host. A quiet globe with a green
    /// dot follows the Host name while it is, so it stays visible with the
    /// right sidebar closed.
    var isPublicAccessOn: Bool = false
    /// Whether the Host picker is open, and what clicking the Host row does.
    /// The window root owns the picker, like every other chrome surface.
    var isHostPickerPresented: Bool = false
    var onToggleHostPicker: (() -> Void)? = nil
    /// The Hosts listed at the foot of the card, and what picking one does.
    var otherHosts: [WarrenDesktopSidebarOtherHost] = []
    var onSelectHost: (String) -> Void = { _ in }
    /// The window's own Host, selected first in the foot's panel.
    var currentHost: WarrenDesktopSidebarOtherHost? = nil
    /// Opens the flow that adds a Host; offered at the foot of the Hosts'
    /// panel, and as the foot itself while there is no other Host.
    var onAddHost: (() -> Void)? = nil
    var onSetHostSidebarVisibility: ((String, Bool) -> Void)? = nil
    var onRenameHost: ((String) -> Void)? = nil
    var onDeleteHost: ((String) -> Void)? = nil
    var isCheckingHosts: Bool = false
    /// The notice center's bell, at the card's bottom-left corner.
    var noticeBell: AnyView? = nil

    /// The current Host's marked Workspaces, for the current-Host tree.
    private var editorMarkedWorkspaceIDs: Set<WorkspaceID> {
        editorActivity.activeWorkspaceIDs([], hostId: activeEndpointID)
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The list on screen. With Tasks turned off only Projects exists.
    private var tab: WarrenDesktopSidebarTab {
        showsTasks ? sidebarTree.selectedTab : .projects
    }

    private var projectCount: Int {
        if let sidebarHostProjections, usesSidebarHostSections {
            return sidebarHostProjections.reduce(0) { $0 + $1.projectGroups.count }
        }
        return projection.groups.count
    }

    private var taskWorkspaceIDs: Set<WorkspaceID> {
        Set(projection.taskGroups.flatMap { $0.workspaces.map(\.id) })
    }

    private var projectsNeedYou: Bool {
        if let sidebarHostProjections, usesSidebarHostSections {
            return sidebarHostProjections.contains { host in
                WarrenDesktopSidebarAttention.needsYou(host.activeSessionsByWorkspaceID.values.joined())
            }
        }
        return WarrenDesktopSidebarAttention.needsYou(projection.activeSessionsByWorkspaceID.values.joined())
    }

    private var tasksNeedYou: Bool {
        let ids = taskWorkspaceIDs
        return WarrenDesktopSidebarAttention.needsYou(
            projection.activeSessionsByWorkspaceID
                .filter { ids.contains($0.key) }
                .values
                .joined()
        )
    }

    private var tabBar: some View {
        let addAction: WarrenDesktopSidebarSectionAction = tab == .tasks
            ? WarrenDesktopSidebarSectionAction(
                id: "new-task",
                image: "plus",
                label: "New Task…",
                isEnabled: projection.isConnected,
                action: onRequestTaskCreate
            )
            : WarrenDesktopSidebarSectionAction(
                id: "add-project",
                image: "plus",
                label: "Add Project…",
                isEnabled: projection.isConnected && endpointCapabilities.canAddProject,
                action: { onAction(.addProject) }
            )
        var additional: [WarrenDesktopSidebarSectionAction] = []
        if tab == .projects, let expanded = allProjectsExpanded {
            additional.append(WarrenDesktopSidebarSectionAction(
                id: "toggle-all-projects",
                image: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                label: expanded ? "Collapse all projects" : "Expand all projects",
                isEnabled: true,
                action: { toggleAllProjectsRequest += 1 }
            ))
        }
        return WarrenDesktopSidebarTabBar(
            selected: tab,
            showsTasks: showsTasks,
            projectCount: projectCount,
            taskCount: projection.taskGroups.count,
            projectsNeedYou: projectsNeedYou,
            tasksNeedYou: tasksNeedYou,
            addAction: addAction,
            additionalActions: additional,
            onSelect: { next in
                withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                    sidebarTree.selectedTab = next
                }
            }
        )
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        // The rail owns the column's width. A child that cannot compress widens
        // the column instead of truncating, and SwiftUI then centres that
        // over-wide column inside the rail's frame — every row would lose its
        // leading edge off the window. Pinning the column to the rail and
        // clipping keeps overflow on the trailing edge, where it is harmless.
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopSidebarHeader(
                updateStatus: updateStatus,
                onUpdateAction: onUpdateAction,
                onToggle: toggleSidebar,
                onCommandPalette: onCommandPalette,
                host: hostSummary,
                isHostPickerPresented: isHostPickerPresented,
                isPublicAccessOn: isPublicAccessOn,
                onToggleHostPicker: onToggleHostPicker
            )
            if let displayConfigurationError {
                displayConfigurationNotice(displayConfigurationError, tokens: tokens)
            }
            tabBar
            ScrollViewReader { proxy in
                WarrenOverflowFadeScrollView(
                    .vertical,
                    fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                    surface: tokens.workbenchCardFill,
                    // Every row carries hover, help, and menu responders; a
                    // still pointer over moving rows walked them all twice a
                    // frame. Hover pauses for the scroll and resumes after it.
                    suspendsHitTestingWhileScrolling: true
                ) {
                    Group {
                        if let sidebarHostProjections, usesSidebarHostSections {
                            if tab == .tasks {
                                // Tasks remain a current-host feature in the
                                // first multi-host release. Reuse the existing
                                // rows for that list while the scoped Host
                                // view owns only Projects/Workspaces.
                                WarrenDesktopSidebarRows(
                                    taskGroups: projection.taskGroups,
                                    groups: projection.groups,
                                    workspaceActivitySummaries: projection.workspaceActivitySummaries,
                                    activeWorkspaceIDs: editorActivity.activeWorkspaceIDs(
                                        projection.activeWorkspaceIDs,
                                        hostId: activeEndpointID
                                    ),
                                    editorMarkedWorkspaceIDs: editorMarkedWorkspaceIDs,
                                    activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                                    workspaceDisplayMode: workspaceDisplayMode,
                                    showsTasks: showsTasks,
                                    showsProjects: false,
                                    tree: $sidebarTree,
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
                                                proxy.scrollTo("task.\(taskID.description)")
                                            }
                                        }
                                    },
                                    onAction: onAction,
                                    onRequestRename: onRequestRename,
                                    onRequestDeletion: onRequestDeletion,
                                    onOpenEditor: onOpenEditor,
                                    onSplitDropSession: onSplitDropSession
                                )
                            } else {
                                WarrenDesktopSidebarHostRows(
                                    hosts: sidebarHostProjections.map {
                                        $0.widenedActivity(with: editorActivity)
                                    },
                                    showsActiveOnly: sidebarTree.showsActiveOnly,
                                    workspaceDisplayMode: workspaceDisplayMode,
                                    selection: sidebarResourceSelection,
                                    activeEndpointID: activeEndpointID,
                                    selectedTabID: selectedTabID,
                                    deletingProjectIDs: deletingProjectIDs,
                                    deletingWorkspaceIDs: deletingWorkspaceIDs,
                                    editorActivity: editorActivity,
                                    onAction: onAction,
                                    onRequestRename: onRequestRename,
                                    onRequestDeletion: onRequestDeletion,
                                    onSelect: onSelectSidebarResource,
                                    onOpenWorkspace: onOpenSidebarWorkspace,
                                    onOpenSession: onOpenSidebarSession,
                                    onFocusTask: { taskID in
                                        Self.revealTask(taskID, in: &sidebarTree)
                                        DispatchQueue.main.async {
                                            withAnimation(WarrenMotion.animation(
                                                .stateChange,
                                                reduceMotion: reduceMotion
                                            )) {
                                                proxy.scrollTo("task.\(taskID.description)")
                                            }
                                        }
                                    },
                                    onToggleActiveOnly: toggleActiveOnly,
                                    onRetry: onRetrySidebarHost,
                                    onSplitDropSession: onSplitDropSession,
                                    onOpenEditor: onOpenEditor,
                                    toggleAllProjectsRequest: toggleAllProjectsRequest
                                )
                            }
                        } else {
                            WarrenDesktopSidebarRows(
                            taskGroups: projection.taskGroups,
                            groups: projection.groups,
                            workspaceActivitySummaries: projection.workspaceActivitySummaries,
                            activeWorkspaceIDs: editorActivity.activeWorkspaceIDs(
                                projection.activeWorkspaceIDs,
                                hostId: activeEndpointID
                            ),
                            editorMarkedWorkspaceIDs: editorMarkedWorkspaceIDs,
                            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                            workspaceDisplayMode: workspaceDisplayMode,
                            showsTasks: showsTasks,
                            tree: $sidebarTree,
                            selection: selection,
                            selectedTabID: selectedTabID,
                            deletingProjectIDs: deletingProjectIDs,
                            deletingWorkspaceIDs: deletingWorkspaceIDs,
                            endpointCapabilities: endpointCapabilities,
                            isInteractionDisabled: !projection.isConnected,
                            connectionState: projection.connectionState,
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
                                            "task.\(taskID.description)"
                                        )
                                    }
                                }
                            },
                            onAction: onAction,
                            onRequestRename: onRequestRename,
                            onRequestDeletion: onRequestDeletion,
                            onOpenEditor: onOpenEditor,
                            onSplitDropSession: onSplitDropSession,
                            toggleAllProjectsRequest: toggleAllProjectsRequest
                            )
                        }
                    }
                    .onPreferenceChange(WarrenDesktopAllProjectsExpandedKey.self) { allProjectsExpanded = $0 }
                    .padding(.vertical, WarrenDesktopSidebarMetrics.contentVerticalInset)
                    .padding(.horizontal, WarrenDesktopSidebarMetrics.contentHorizontalInset)
                    .animation(
                        WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion),
                        value: rowStructure
                    )
                }
                .onChange(of: sidebarResourceSelection) { newSelection in
                    guard usesSidebarHostSections,
                          case let .workspace(reference)? = newSelection else {
                        return
                    }
                    // On the Tasks tab a task-linked workspace is found under
                    // its Task; anything else is found on the Projects tab.
                    let owningTaskID = tab == .tasks ? currentHostTaskID(for: reference) : nil
                    if tab == .tasks, owningTaskID == nil {
                        sidebarTree.selectedTab = .projects
                    }
                    if let owningTaskID {
                        // Task rows exist only while the Task is expanded, so
                        // reveal it before asking for the scroll.
                        Self.revealTask(owningTaskID, in: &sidebarTree)
                    }
                    let targetID = Self.hostWorkspaceScrollTarget(
                        endpointID: reference.endpointID,
                        workspaceID: reference.id,
                        owningTaskID: owningTaskID
                    )
                    // A nil anchor asks ScrollViewReader to make an off-screen
                    // row visible with the smallest required movement. It
                    // leaves an already visible row where it is instead of
                    // recentering the sidebar for every selection change.
                    DispatchQueue.main.async {
                        withAnimation(WarrenMotion.animation(
                            .stateChange,
                            reduceMotion: reduceMotion
                        )) {
                            proxy.scrollTo(targetID)
                        }
                    }
                }
                .onChange(of: selection) { newSelection in
                    guard !usesSidebarHostSections,
                          case let .workspace(workspaceID)? = newSelection else {
                        return
                    }
                    let workspace = projection.groups
                        .flatMap(\.workspaces)
                        .first(where: { $0.id == workspaceID })
                    // On the Tasks tab a task-linked workspace is found under
                    // its Task, which is only mounted while the Task is open;
                    // a workspace no Task lists is found on the Projects tab.
                    if tab == .tasks {
                        if let owningTaskID = workspace?.taskID,
                           taskWorkspaceIDs.contains(workspaceID) {
                            Self.revealTask(owningTaskID, in: &sidebarTree)
                        } else {
                            sidebarTree.selectedTab = .projects
                        }
                    }
                    let targetID = workspace.map { Self.workspaceScrollTarget(for: $0, tab: tab) }
                        ?? "workspace.project-list.\(workspaceID.description)"
                    // A nil anchor asks ScrollViewReader to make an off-screen
                    // row visible with the smallest required movement. It
                    // leaves an already visible row where it is instead of
                    // recentering the sidebar for every selection change.
                    DispatchQueue.main.async {
                        withAnimation(WarrenMotion.animation(
                            .stateChange,
                            reduceMotion: reduceMotion
                        )) {
                            proxy.scrollTo(targetID)
                        }
                    }
                }
            }
            sidebarFooter(tokens: tokens)
            if presentation == .peek {
                peekPinRow(tokens: tokens)
            }
        }
        .frame(width: renderedWidth, alignment: .leading)
        .clipped()
        .frame(maxHeight: .infinity)
        .modifier(WarrenDesktopSidebarPresentationStyle(
            presentation: presentation,
            tokens: tokens
        ))
        .onHover { pointerInsideSidebar = $0 }
        .environment(\.warrenPointerInsideSidebar, pointerInsideSidebar)
        .environment(\.warrenShellAttention, shellAttention)
    }

    /// The rail's rows by identity: the Tasks, Projects, Workspaces and
    /// Sessions it lists and which Workspaces count as active. A Session that
    /// opens or closes, or a Workspace that folds into its project's idle row,
    /// changes it, so the rows around them move instead of snapping. What a row
    /// says is left out: a working line changes too often to animate.
    private var rowStructure: [String] {
        var ids: [String] = []
        func append(
            groups: [WarrenDesktopProjectGroup],
            sessions: [WorkspaceID: [WarrenDesktopSession]],
            active: Set<WorkspaceID>
        ) {
            for group in groups {
                ids.append("p:\(group.id.description)")
                for workspace in group.workspaces {
                    let mark = active.contains(workspace.id) ? "a" : "i"
                    ids.append("w\(mark):\(workspace.id.description)")
                    for session in sessions[workspace.id] ?? [] {
                        ids.append("s:\(session.id.description)")
                    }
                }
            }
        }
        for group in projection.taskGroups {
            ids.append("t:\(group.id.description)")
            ids.append(contentsOf: group.workspaces.map { "tw:\($0.id.description)" })
        }
        if let sidebarHostProjections, usesSidebarHostSections {
            for host in sidebarHostProjections {
                ids.append("h:\(host.endpointID)")
                append(
                    groups: host.projectGroups,
                    sessions: host.activeSessionsByWorkspaceID,
                    active: host.activeWorkspaceIDs
                )
            }
        } else {
            append(
                groups: projection.groups,
                sessions: projection.activeSessionsByWorkspaceID,
                active: editorActivity.activeWorkspaceIDs(
                    projection.activeWorkspaceIDs,
                    hostId: activeEndpointID
                )
            )
        }
        return ids
    }

    /// The docked column takes the dragged width; the peek copy ignores the
    /// collapse entirely and reuses the width the user chose.
    private var renderedWidth: CGFloat {
        presentation == .peek ? sidebarState.width : sidebarState.renderedWidth
    }

    /// The peek's foot: the hint that it will move away, and the pin chord.
    private func peekPinRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Text("Click a session to jump. Moves away to hide.")
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.treeQuietText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: WarrenSpacing.xxs) {
                // The menus' own keycaps, one per key, rather than a
                // hand-drawn cap that matched nothing else in the app.
                WarrenDesktopMenuKeycaps(keys: "\u{2318}B")
                Text("pin")
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.treeQuietText)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: WarrenDesktopSidebarMetrics.footerHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.cardBorder)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pin sidebar with Command-B")
    }

    @ViewBuilder
    private func displayConfigurationNotice(
        _ message: String,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(alignment: .top, spacing: WarrenSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(WarrenTypography.navigationMeta)
                .foregroundStyle(tokens.warning)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .padding(.vertical, WarrenSpacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Display configuration warning")
        .accessibilityValue(message)
    }

    static func revealTask(
        _ taskID: TaskID,
        in tree: inout WarrenDesktopSidebarTreeState
    ) {
        tree.tasksCollapsed = false
        tree.collapsedTaskIDs.remove(taskID)
        tree.selectedTab = .tasks
    }

    /// Where a selected workspace's row is: under its Task on the Tasks tab,
    /// under its project otherwise.
    static func workspaceScrollTarget(for workspace: Workspace, tab: WarrenDesktopSidebarTab) -> String {
        let scope = tab == .tasks && workspace.taskID != nil ? "task-list" : "project-list"
        return "workspace.\(scope).\(workspace.id.description)"
    }

    /// The scroll target for a workspace selected in the Host-scoped tree.
    ///
    /// On the Tasks tab a task-linked workspace resolves to its Task row;
    /// everything else resolves to its Host row.
    static func hostWorkspaceScrollTarget(
        endpointID: String,
        workspaceID: WorkspaceID,
        owningTaskID: TaskID?
    ) -> String {
        owningTaskID == nil
            ? "host.\(endpointID).workspace.\(workspaceID.description)"
            : "workspace.task-list.\(workspaceID.description)"
    }

    /// The Task that owns a selected workspace, when the Task row is the
    /// navigation target rather than the Host's Projects subtree.
    ///
    /// Tasks are current-Host-only in this release, so a workspace on a
    /// background Host keeps its Host row as the only activation path — which
    /// is also why that row stays selectable there.
    private func currentHostTaskID(
        for reference: WarrenDesktopHostResourceRef<WorkspaceID>
    ) -> TaskID? {
        guard showsTasks, reference.endpointID == activeEndpointID else { return nil }
        return projection.groups
            .flatMap(\.workspaces)
            .first(where: { $0.id == reference.id })?
            .taskID
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
                sidebarTree.collapsedProjectIDs.subtract(projection.groups.map(\.project.id))
            }
        }
    }

    /// The sidebar always lists Sessions under their Workspace; the compact
    /// tree is no longer offered.
    private var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode { .rich }

    /// The foot of the card, one row: the Hosts (see
    /// `WarrenDesktopSidebarHostStack`), then the update glyph and the notice
    /// bell at the row's end. The update glyph is there only while an update
    /// is ready, installing or failed.
    private func sidebarFooter(tokens: WarrenColorTokens) -> some View {
        WarrenDesktopSidebarHostStack(
            hosts: otherHosts,
            currentHost: currentHost,
            onSelectHost: onSelectHost,
            onAddHost: onAddHost,
            onSetSidebarVisibility: onSetHostSidebarVisibility,
            onRenameHost: onRenameHost,
            onDeleteHost: onDeleteHost,
            isCheckingHosts: isCheckingHosts,
            trailingAccessory: footerAccessory
        )
        .frame(maxWidth: .infinity)
    }

    private var footerAccessory: AnyView? {
        let showsUpdate = updateStatus != .none
        guard showsUpdate || noticeBell != nil else { return nil }
        return AnyView(HStack(spacing: 2) {
            if showsUpdate {
                WarrenDesktopUpdateIcon(status: updateStatus, onAction: onUpdateAction)
                    .transition(.opacity)
            }
            if let noticeBell {
                noticeBell
            }
        })
    }
}

/// The two fills one sidebar view can wear.
///
/// The docked card's fill and corners are drawn by the root view's card
/// modifier. The peek copy draws its own, because it floats over the content
/// card rather than sitting on the window backdrop: it is one step brighter,
/// carries a hairline, and is lifted by a long, offset shadow.
private struct WarrenDesktopSidebarPresentationStyle: ViewModifier {
    let presentation: WarrenDesktopSidebarPresentation
    let tokens: WarrenColorTokens

    func body(content: Content) -> some View {
        switch presentation {
        case .docked:
            content.background(tokens.workbenchCardFill)
        case .peek:
            content
                .background(tokens.peekSurface)
                .clipShape(RoundedRectangle(
                    cornerRadius: WarrenLayoutMetrics.cardRadius,
                    style: .continuous
                ))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: WarrenLayoutMetrics.cardRadius,
                        style: .continuous
                    )
                    .strokeBorder(tokens.cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 40, x: 12, y: 0)
        }
    }
}
