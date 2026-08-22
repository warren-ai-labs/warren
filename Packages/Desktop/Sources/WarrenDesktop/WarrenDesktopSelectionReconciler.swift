import WarrenClientCore
import WarrenDomain

/// Device-local navigation owned by the application composition layer.
///
/// Host snapshots own durable projects, workspaces, sessions and tabs. This
/// value owns only which of those values the foreground window is presenting.
public struct WarrenDesktopNavigationMemory: Codable, Equatable, Hashable, Sendable {
    /// The last workspace selected from each project.
    public var workspaceByProjectID: [String: String]
    /// The last tab selected in each workspace.
    public var tabByWorkspaceID: [String: String]
    /// The last tab selected in each terminal group.
    public var tabByTerminalGroupID: [String: String]

    public var isEmpty: Bool {
        workspaceByProjectID.isEmpty
            && tabByWorkspaceID.isEmpty
            && tabByTerminalGroupID.isEmpty
    }

    public init(
        workspaceByProjectID: [String: String] = [:],
        tabByWorkspaceID: [String: String] = [:],
        tabByTerminalGroupID: [String: String] = [:]
    ) {
        self.workspaceByProjectID = workspaceByProjectID
        self.tabByWorkspaceID = tabByWorkspaceID
        self.tabByTerminalGroupID = tabByTerminalGroupID
    }
}

public struct WarrenDesktopNavigationState: Equatable, Hashable, Sendable {
    public var selection: WarrenDesktopSidebarSelection?
    public var selectedTabID: String?
    public var memory: WarrenDesktopNavigationMemory

    public init(
        selection: WarrenDesktopSidebarSelection? = nil,
        selectedTabID: String? = nil,
        memory: WarrenDesktopNavigationMemory = WarrenDesktopNavigationMemory()
    ) {
        self.selection = selection
        self.selectedTabID = selectedTabID
        self.memory = memory
    }
}

/// Pure navigation reducer. A click updates this state synchronously; Host and
/// tmux side effects may finish later without becoming another selection owner.
public enum WarrenDesktopNavigationReducer {
    public static func initial(
        for projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        guard let tab = projection.tabs.first,
              let workspace = workspace(for: tab.id, in: projection) else {
            return WarrenDesktopNavigationState(
                selection: firstSelection(in: projection),
                selectedTabID: nil
            )
        }
        return WarrenDesktopNavigationState(
            selection: .workspace(workspace.id),
            selectedTabID: tab.id
        )
    }

    public static func reduce(
        _ state: WarrenDesktopNavigationState,
        action: WarrenDesktopAction,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        switch action {
        case .selectProject(let projectID):
            guard let workspace = rememberedWorkspace(
                for: projectID,
                memory: state.memory,
                projection: projection
            ) ?? projection.firstWorkspace(in: projectID) else {
                return WarrenDesktopNavigationState(
                    selection: .project(projectID),
                    selectedTabID: nil,
                    memory: state.memory
                )
            }
            let next = WarrenDesktopNavigationState(
                selection: .workspace(workspace.id),
                selectedTabID: rememberedTab(
                    in: workspace.id,
                    memory: state.memory,
                    projection: projection
                ) ?? firstTabID(inWorkspace: workspace.id, projection: projection),
                memory: state.memory
            )
            return remembering(
                remembering(workspace: workspace.id, in: next, projection: projection),
                in: projection
            )
        case .selectWorkspace(let workspaceID):
            let next = WarrenDesktopNavigationState(
                selection: .workspace(workspaceID),
                selectedTabID: rememberedTab(
                    in: workspaceID,
                    memory: state.memory,
                    projection: projection
                ) ?? firstTabID(inWorkspace: workspaceID, projection: projection),
                memory: state.memory
            )
            return remembering(
                remembering(workspace: workspaceID, in: next, projection: projection),
                in: projection
            )
        case .openWorkspace(let workspaceID):
            return reduce(state, action: .selectWorkspace(workspaceID), in: projection)
        case .selectTerminalGroup(let groupID):
            let next = WarrenDesktopNavigationState(
                selection: .terminalGroup(groupID),
                selectedTabID: rememberedTab(
                    in: groupID,
                    memory: state.memory,
                    projection: projection
                ) ?? firstTabID(inTerminalGroup: groupID, projection: projection),
                memory: state.memory
            )
            return remembering(next, in: projection)
        case .selectTab(let tabID):
            guard projection.tabs.contains(where: { $0.id == tabID }) else { return state }
            let selection = selection(for: tabID, in: projection) ?? state.selection
            return remembering(
                WarrenDesktopNavigationState(
                    selection: selection,
                    selectedTabID: tabID,
                    memory: state.memory
                ),
                in: projection
            )
        case .openSession(let sessionID):
            guard let session = projection.sessions.first(where: { $0.id == sessionID }) else {
                return state
            }
            guard let selection = selection(for: session.id, in: projection) else { return state }
            return remembering(
                WarrenDesktopNavigationState(
                    selection: selection,
                    selectedTabID: session.tabID,
                    memory: state.memory
                ),
                in: projection
            )
        case .deleteSession(let sessionID):
            guard projection.sessions.contains(where: { $0.id == sessionID }) else { return state }
            let deletedTabID = projection.sessions.first { $0.id == sessionID }?.tabID
            var next = state
            if let deletedTabID {
                forget(tabID: deletedTabID, from: &next.memory)
            }
            if state.selectedTabID == deletedTabID {
                next.selectedTabID = nil
            }
            return next
        case .closeTab(let tabID):
            guard state.selectedTabID == tabID else { return state }
            let tabs = tabs(for: state.selection, projection: projection)
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return state }
            let remaining = tabs.enumerated().filter { $0.element.id != tabID }
            let replacement = remaining.first(where: { $0.offset >= index })?.element
                ?? remaining.last?.element
            guard let replacement else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil,
                    memory: forgetting(tabID: tabID, from: state.memory)
                )
            }
            return reduce(state, action: .selectTab(replacement.id), in: projection)
        case .closeOtherTabs(let tabID):
            return reduce(state, action: .selectTab(tabID), in: projection)
        case .closeAllTabs:
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: nil,
                memory: state.memory
            )
        case .restoreNavigation(let restoredState):
            return reconcile(restoredState, with: projection)
        case .addProject, .importSuperset, .requestNewWorkspace,
             .requestProjectWorktreeImport, .setProjectAutoImportGitWorktrees,
             .renameProject, .renameWorkspace, .deleteProject, .deleteWorkspace,
             .renameSession,
             .setProjectPinned, .setWorkspacePinned, .setSessionPinned,
             .dismissActivity,
             .moveTab, .moveSession, .moveProject, .moveWorkspace,
             .requestNewSession, .launchSession,
             .requestNewTerminalGroupSession, .launchTerminalGroupSession,
             .createTerminalGroup, .renameTerminalGroup, .setTerminalGroupHome,
             .deleteTerminalGroup, .moveTerminalGroup,
             .toggleSidebar:
            return state
        }
    }

    public static func reconcile(
        _ state: WarrenDesktopNavigationState,
        with projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        let hadValidSelection = state.selection.map { isValid($0, in: projection) } ?? false
        let selection = hadValidSelection ? state.selection : firstSelection(in: projection)

        if let tabID = state.selectedTabID,
           projection.tabs.contains(where: { $0.id == tabID }),
           tab(tabID, belongsTo: selection, in: projection) {
            return remembering(
                WarrenDesktopNavigationState(
                    selection: selection,
                    selectedTabID: tabID,
                    memory: state.memory
                ),
                in: projection
            )
        }

        // A valid explicit workspace with no selected tab is an intentional
        // empty workspace view. Background snapshot publications must not
        // steal focus by selecting an unrelated tab.
        if hadValidSelection, state.selectedTabID == nil {
            return WarrenDesktopNavigationState(
                selection: selection,
                selectedTabID: nil,
                memory: state.memory
            )
        }

        let next = WarrenDesktopNavigationState(
            selection: selection,
            selectedTabID: rememberedTab(
                for: selection,
                memory: state.memory,
                projection: projection
            ) ?? firstTabID(for: selection, projection: projection),
            memory: state.memory
        )
        return remembering(next, in: projection)
    }

    private static func rememberedWorkspace(
        for projectID: ProjectID,
        memory: WarrenDesktopNavigationMemory,
        projection: WarrenDesktopProjection
    ) -> Workspace? {
        guard let rawID = memory.workspaceByProjectID[projectID.description],
              let workspaceID = WorkspaceID(uuidString: rawID),
              let workspace = projection.workspace(id: workspaceID),
              workspace.projectID == projectID else {
            return nil
        }
        return workspace
    }

    private static func rememberedTab(
        in workspaceID: WorkspaceID,
        memory: WarrenDesktopNavigationMemory,
        projection: WarrenDesktopProjection
    ) -> String? {
        guard let tabID = memory.tabByWorkspaceID[workspaceID.description],
              projection.workspaceID(forTabID: tabID) == workspaceID else {
            return nil
        }
        return tabID
    }

    private static func rememberedTab(
        in groupID: TerminalGroupID,
        memory: WarrenDesktopNavigationMemory,
        projection: WarrenDesktopProjection
    ) -> String? {
        guard let tabID = memory.tabByTerminalGroupID[groupID.description],
              projection.terminalGroupID(forTabID: tabID) == groupID else {
            return nil
        }
        return tabID
    }

    private static func rememberedTab(
        for selection: WarrenDesktopSidebarSelection?,
        memory: WarrenDesktopNavigationMemory,
        projection: WarrenDesktopProjection
    ) -> String? {
        switch selection {
        case .workspace(let workspaceID):
            return rememberedTab(in: workspaceID, memory: memory, projection: projection)
        case .terminalGroup(let groupID):
            return rememberedTab(in: groupID, memory: memory, projection: projection)
        case .project, nil:
            return nil
        }
    }

    private static func remembering(
        _ state: WarrenDesktopNavigationState,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        guard let tabID = state.selectedTabID,
              let selection = selection(for: tabID, in: projection) else {
            return state
        }

        var next = state
        switch selection {
        case .workspace(let workspaceID):
            next.memory.tabByWorkspaceID[workspaceID.description] = tabID
            if let workspace = projection.workspace(id: workspaceID) {
                next.memory.workspaceByProjectID[workspace.projectID.description] = workspaceID.description
            }
        case .terminalGroup(let groupID):
            next.memory.tabByTerminalGroupID[groupID.description] = tabID
        case .project:
            break
        }
        return next
    }

    private static func remembering(
        workspace workspaceID: WorkspaceID,
        in state: WarrenDesktopNavigationState,
        projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        guard let workspace = projection.workspace(id: workspaceID) else { return state }
        var next = state
        next.memory.workspaceByProjectID[workspace.projectID.description] = workspaceID.description
        return next
    }

    private static func forget(tabID: String, from memory: inout WarrenDesktopNavigationMemory) {
        memory.tabByWorkspaceID = memory.tabByWorkspaceID.filter { $0.value != tabID }
        memory.tabByTerminalGroupID = memory.tabByTerminalGroupID.filter { $0.value != tabID }
    }

    private static func forgetting(
        tabID: String,
        from memory: WarrenDesktopNavigationMemory
    ) -> WarrenDesktopNavigationMemory {
        var next = memory
        forget(tabID: tabID, from: &next)
        return next
    }

    private static func tab(
        _ tabID: String,
        belongsTo selection: WarrenDesktopSidebarSelection?,
        in projection: WarrenDesktopProjection
    ) -> Bool {
        guard let selection else { return true }
        switch selection {
        case .workspace(let workspaceID):
            return projection.workspaceID(forTabID: tabID) == workspaceID
        case .project(let projectID):
            return workspace(for: tabID, in: projection)?.projectID == projectID
        case .terminalGroup(let groupID):
            return projection.terminalGroupID(forTabID: tabID) == groupID
        }
    }

    private static func firstTabID(
        for selection: WarrenDesktopSidebarSelection?,
        projection: WarrenDesktopProjection
    ) -> String? {
        guard let selection else { return projection.tabs.first?.id }
        switch selection {
        case .project(let projectID):
            return firstTabID(inProject: projectID, projection: projection)
        case .workspace(let workspaceID):
            return firstTabID(inWorkspace: workspaceID, projection: projection)
        case .terminalGroup(let groupID):
            return firstTabID(inTerminalGroup: groupID, projection: projection)
        }
    }

    private static func tabs(
        for selection: WarrenDesktopSidebarSelection?,
        projection: WarrenDesktopProjection
    ) -> [ClientTab] {
        guard let selection else { return projection.tabs }
        switch selection {
        case .project(let projectID):
            return projection.tabs.filter { tab in
                workspace(for: tab.id, in: projection)?.projectID == projectID
            }
        case .workspace(let workspaceID):
            return projection.tabs(in: workspaceID)
        case .terminalGroup(let groupID):
            return projection.tabs(in: groupID)
        }
    }

    private static func firstTabID(
        inProject projectID: ProjectID,
        projection: WarrenDesktopProjection
    ) -> String? {
        projection.tabs.first { tab in
            workspace(for: tab.id, in: projection)?.projectID == projectID
        }?.id
    }

    private static func firstTabID(
        inWorkspace workspaceID: WorkspaceID,
        projection: WarrenDesktopProjection
    ) -> String? {
        projection.tabs.first { tab in
            workspace(for: tab.id, in: projection)?.id == workspaceID
        }?.id
    }

    private static func firstTabID(
        inTerminalGroup groupID: TerminalGroupID,
        projection: WarrenDesktopProjection
    ) -> String? {
        projection.tabs(in: groupID).first?.id
    }

    private static func selection(
        for tabID: String,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopSidebarSelection? {
        if let workspace = workspace(for: tabID, in: projection) {
            return .workspace(workspace.id)
        }
        return projection.terminalGroupID(forTabID: tabID).map { .terminalGroup($0) }
    }

    private static func selection(
        for sessionID: TerminalSessionID,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopSidebarSelection? {
        if let workspace = projection.workspace(for: sessionID) {
            return .workspace(workspace.id)
        }
        return projection.terminalGroup(for: sessionID).map { .terminalGroup($0.id) }
    }

    private static func workspace(
        for tabID: String,
        in projection: WarrenDesktopProjection
    ) -> Workspace? {
        projection.workspaceID(forTabID: tabID).flatMap(projection.workspace(id:))
    }

    private static func isValid(
        _ selection: WarrenDesktopSidebarSelection,
        in projection: WarrenDesktopProjection
    ) -> Bool {
        switch selection {
        case .project(let projectID):
            projection.groups.contains { $0.project.id == projectID }
        case .workspace(let workspaceID):
            projection.workspace(id: workspaceID) != nil
        case .terminalGroup(let groupID):
            projection.terminalGroup(id: groupID) != nil
        }
    }

    private static func firstSelection(
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopSidebarSelection? {
        if let tabID = projection.tabs.first?.id,
           let selection = selection(for: tabID, in: projection) {
            return selection
        }
        for group in projection.groups {
            if let workspace = group.workspaces.first {
                return .workspace(workspace.id)
            }
        }
        if let group = projection.terminalGroups.first {
            return .terminalGroup(group.id)
        }
        return projection.groups.first.map { .project($0.project.id) }
    }
}

// Kept package-internal while probes and older tests migrate to the public API.
typealias WarrenDesktopReconciledState = WarrenDesktopNavigationState

enum WarrenDesktopSelectionReconciler {
    static func reconcile(
        selection: WarrenDesktopSidebarSelection?,
        selectedTabID: String?,
        with projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        WarrenDesktopNavigationReducer.reconcile(
            WarrenDesktopNavigationState(
                selection: selection,
                selectedTabID: selectedTabID
            ),
            with: projection
        )
    }
}
