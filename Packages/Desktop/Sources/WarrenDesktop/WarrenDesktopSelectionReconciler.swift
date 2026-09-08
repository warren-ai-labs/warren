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
    /// The MRU stack of sidebar selections (most recent at the end).
    public var selectionHistory: [String]
    /// The MRU stack of tabs selected in each workspace (most recent at the end).
    public var tabHistoryByWorkspaceID: [String: [String]]
    /// The MRU stack of tabs selected in each terminal group (most recent at the end).
    public var tabHistoryByTerminalGroupID: [String: [String]]

    public var isEmpty: Bool {
        workspaceByProjectID.isEmpty
            && tabByWorkspaceID.isEmpty
            && tabByTerminalGroupID.isEmpty
            && selectionHistory.isEmpty
            && tabHistoryByWorkspaceID.isEmpty
            && tabHistoryByTerminalGroupID.isEmpty
    }

    public init(
        workspaceByProjectID: [String: String] = [:],
        tabByWorkspaceID: [String: String] = [:],
        tabByTerminalGroupID: [String: String] = [:],
        selectionHistory: [String] = [],
        tabHistoryByWorkspaceID: [String: [String]] = [:],
        tabHistoryByTerminalGroupID: [String: [String]] = [:]
    ) {
        self.workspaceByProjectID = workspaceByProjectID
        self.tabByWorkspaceID = tabByWorkspaceID
        self.tabByTerminalGroupID = tabByTerminalGroupID
        self.selectionHistory = selectionHistory
        self.tabHistoryByWorkspaceID = tabHistoryByWorkspaceID
        self.tabHistoryByTerminalGroupID = tabHistoryByTerminalGroupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceByProjectID = try container.decodeIfPresent([String: String].self, forKey: .workspaceByProjectID) ?? [:]
        tabByWorkspaceID = try container.decodeIfPresent([String: String].self, forKey: .tabByWorkspaceID) ?? [:]
        tabByTerminalGroupID = try container.decodeIfPresent([String: String].self, forKey: .tabByTerminalGroupID) ?? [:]
        selectionHistory = try container.decodeIfPresent([String].self, forKey: .selectionHistory) ?? []
        tabHistoryByWorkspaceID = try container.decodeIfPresent([String: [String]].self, forKey: .tabHistoryByWorkspaceID) ?? [:]
        tabHistoryByTerminalGroupID = try container.decodeIfPresent([String: [String]].self, forKey: .tabHistoryByTerminalGroupID) ?? [:]
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
/// Runtime side effects may finish later without becoming another selection owner.
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
                let next = WarrenDesktopNavigationState(
                    selection: .project(projectID),
                    selectedTabID: nil,
                    memory: state.memory
                )
                return remembering(next, in: projection)
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
            var nextMemory = state.memory
            if let deletedTabID {
                forget(tabID: deletedTabID, from: &nextMemory)
            }
            guard state.selectedTabID == deletedTabID, let deletedTabID else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: state.selectedTabID,
                    memory: nextMemory
                )
            }
            let tabs = tabs(for: state.selection, projection: projection)
            guard let index = tabs.firstIndex(where: { $0.id == deletedTabID }) else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil,
                    memory: nextMemory
                )
            }
            let remaining = tabs.enumerated().filter { $0.element.id != deletedTabID }
            let replacement = recentTab(for: state.selection, in: remaining.map(\.element), memory: nextMemory)
                ?? remaining.first(where: { $0.offset >= index })?.element
                ?? remaining.last?.element
            guard let replacement else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil,
                    memory: nextMemory
                )
            }
            return reduce(
                WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: state.selectedTabID,
                    memory: nextMemory
                ),
                action: .selectTab(replacement.id),
                in: projection
            )
        case .closeTab(let tabID):
            var nextMemory = state.memory
            forget(tabID: tabID, from: &nextMemory)
            guard state.selectedTabID == tabID else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: state.selectedTabID,
                    memory: nextMemory
                )
            }
            let tabs = tabs(for: state.selection, projection: projection)
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil,
                    memory: nextMemory
                )
            }
            let remaining = tabs.enumerated().filter { $0.element.id != tabID }
            let replacement = recentTab(for: state.selection, in: remaining.map(\.element), memory: nextMemory)
                ?? remaining.first(where: { $0.offset >= index })?.element
                ?? remaining.last?.element
            guard let replacement else {
                return WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: nil,
                    memory: nextMemory
                )
            }
            return reduce(
                WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: state.selectedTabID,
                    memory: nextMemory
                ),
                action: .selectTab(replacement.id),
                in: projection
            )
        case .closeOtherTabs(let tabID):
            var nextMemory = state.memory
            switch state.selection {
            case .workspace(let workspaceID):
                nextMemory.tabHistoryByWorkspaceID[workspaceID.description] = [tabID]
                nextMemory.tabByWorkspaceID[workspaceID.description] = tabID
            case .terminalGroup(let groupID):
                nextMemory.tabHistoryByTerminalGroupID[groupID.description] = [tabID]
                nextMemory.tabByTerminalGroupID[groupID.description] = tabID
            case .project, nil:
                break
            }
            return reduce(
                WarrenDesktopNavigationState(
                    selection: state.selection,
                    selectedTabID: state.selectedTabID,
                    memory: nextMemory
                ),
                action: .selectTab(tabID),
                in: projection
            )
        case .closeAllTabs:
            var nextMemory = state.memory
            switch state.selection {
            case .workspace(let workspaceID):
                nextMemory.tabHistoryByWorkspaceID.removeValue(forKey: workspaceID.description)
                nextMemory.tabByWorkspaceID.removeValue(forKey: workspaceID.description)
            case .terminalGroup(let groupID):
                nextMemory.tabHistoryByTerminalGroupID.removeValue(forKey: groupID.description)
                nextMemory.tabByTerminalGroupID.removeValue(forKey: groupID.description)
            case .project, nil:
                break
            }
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: nil,
                memory: nextMemory
            )
        case .restoreNavigation(let restoredState):
            return reconcile(restoredState, with: projection)
        case .deleteWorkspace(let workspaceID, _):
            var nextMemory = state.memory
            forget(workspaceID: workspaceID, from: &nextMemory)
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: state.selectedTabID,
                memory: nextMemory
            )
        case .deleteTerminalGroup(let groupID):
            var nextMemory = state.memory
            forget(terminalGroupID: groupID, from: &nextMemory)
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: state.selectedTabID,
                memory: nextMemory
            )
        case .deleteProject(let projectID):
            var nextMemory = state.memory
            forget(projectID: projectID, from: &nextMemory)
            return WarrenDesktopNavigationState(
                selection: state.selection,
                selectedTabID: state.selectedTabID,
                memory: nextMemory
            )
        case .addProject, .importSuperset, .requestNewWorkspace,
             .requestProjectWorktreeImport, .setProjectAutoImportGitWorktrees,
             .requestProjectSetupScript,
             .renameTask, .renameProject, .renameWorkspace,
             .attachWorkspaceToTask, .detachWorkspaceFromTask, .deleteTask,
             .renameSession,
             .setProjectPinned, .setWorkspacePinned, .setSessionPinned,
             .dismissActivity,
             .moveTab, .moveSession, .moveProject, .moveWorkspace,
             .requestNewSession, .launchSession,
             .requestNewTerminalGroupSession, .launchTerminalGroupSession,
             .createTerminalGroup, .renameTerminalGroup, .setTerminalGroupHome,
             .moveTerminalGroup,
             .toggleSidebar, .openNotifications:
            return state
        }
    }

    public static func reconcile(
        _ state: WarrenDesktopNavigationState,
        with projection: WarrenDesktopProjection
    ) -> WarrenDesktopNavigationState {
        let hadValidSelection = state.selection.map { isValid($0, in: projection) } ?? false
        let selection = hadValidSelection
            ? state.selection
            : recentSelection(from: state.memory, in: projection) ?? firstSelection(in: projection)

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

    private static func recordSelection(
        _ selection: WarrenDesktopSidebarSelection,
        in memory: inout WarrenDesktopNavigationMemory
    ) {
        let key = selection.serializedKey
        memory.selectionHistory.removeAll { $0 == key }
        memory.selectionHistory.append(key)
    }

    private static func recordTab(
        _ tabID: String,
        for selection: WarrenDesktopSidebarSelection,
        in memory: inout WarrenDesktopNavigationMemory
    ) {
        switch selection {
        case .workspace(let workspaceID):
            var stack = memory.tabHistoryByWorkspaceID[workspaceID.description] ?? []
            stack.removeAll { $0 == tabID }
            stack.append(tabID)
            memory.tabHistoryByWorkspaceID[workspaceID.description] = stack
        case .terminalGroup(let groupID):
            var stack = memory.tabHistoryByTerminalGroupID[groupID.description] ?? []
            stack.removeAll { $0 == tabID }
            stack.append(tabID)
            memory.tabHistoryByTerminalGroupID[groupID.description] = stack
        case .project:
            break
        }
    }

    private static func recentSelection(
        from memory: WarrenDesktopNavigationMemory,
        in projection: WarrenDesktopProjection
    ) -> WarrenDesktopSidebarSelection? {
        for key in memory.selectionHistory.reversed() {
            guard let selection = WarrenDesktopSidebarSelection(serializedKey: key),
                  isValid(selection, in: projection) else {
                continue
            }
            return selection
        }
        return nil
    }

    private static func recentTab(
        for selection: WarrenDesktopSidebarSelection?,
        in candidates: [ClientTab],
        memory: WarrenDesktopNavigationMemory
    ) -> ClientTab? {
        guard let selection else { return nil }
        let stack: [String]
        switch selection {
        case .workspace(let workspaceID):
            stack = memory.tabHistoryByWorkspaceID[workspaceID.description] ?? []
        case .terminalGroup(let groupID):
            stack = memory.tabHistoryByTerminalGroupID[groupID.description] ?? []
        case .project:
            stack = []
        }
        let candidateIDs = Set(candidates.map(\.id))
        for tabID in stack.reversed() {
            if candidateIDs.contains(tabID),
               let match = candidates.first(where: { $0.id == tabID }) {
                return match
            }
        }
        return nil
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
        if let tabID = memory.tabByWorkspaceID[workspaceID.description],
           projection.workspaceID(forTabID: tabID) == workspaceID {
            return tabID
        }
        if let stack = memory.tabHistoryByWorkspaceID[workspaceID.description] {
            for tabID in stack.reversed() {
                if projection.workspaceID(forTabID: tabID) == workspaceID {
                    return tabID
                }
            }
        }
        return nil
    }

    private static func rememberedTab(
        in groupID: TerminalGroupID,
        memory: WarrenDesktopNavigationMemory,
        projection: WarrenDesktopProjection
    ) -> String? {
        if let tabID = memory.tabByTerminalGroupID[groupID.description],
           projection.terminalGroupID(forTabID: tabID) == groupID {
            return tabID
        }
        if let stack = memory.tabHistoryByTerminalGroupID[groupID.description] {
            for tabID in stack.reversed() {
                if projection.terminalGroupID(forTabID: tabID) == groupID {
                    return tabID
                }
            }
        }
        return nil
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
        var next = state
        if let selection = state.selection {
            recordSelection(selection, in: &next.memory)
        }
        guard let tabID = state.selectedTabID,
              let selection = selection(for: tabID, in: projection) else {
            return next
        }

        switch selection {
        case .workspace(let workspaceID):
            next.memory.tabByWorkspaceID[workspaceID.description] = tabID
            recordTab(tabID, for: selection, in: &next.memory)
            if let workspace = projection.workspace(id: workspaceID) {
                next.memory.workspaceByProjectID[workspace.projectID.description] = workspaceID.description
            }
        case .terminalGroup(let groupID):
            next.memory.tabByTerminalGroupID[groupID.description] = tabID
            recordTab(tabID, for: selection, in: &next.memory)
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
        recordSelection(.workspace(workspaceID), in: &next.memory)
        return next
    }

    private static func forget(tabID: String, from memory: inout WarrenDesktopNavigationMemory) {
        memory.tabByWorkspaceID = memory.tabByWorkspaceID.filter { $0.value != tabID }
        memory.tabByTerminalGroupID = memory.tabByTerminalGroupID.filter { $0.value != tabID }
        for (key, stack) in memory.tabHistoryByWorkspaceID {
            memory.tabHistoryByWorkspaceID[key] = stack.filter { $0 != tabID }
        }
        for (key, stack) in memory.tabHistoryByTerminalGroupID {
            memory.tabHistoryByTerminalGroupID[key] = stack.filter { $0 != tabID }
        }
    }

    private static func forget(workspaceID: WorkspaceID, from memory: inout WarrenDesktopNavigationMemory) {
        let key = WarrenDesktopSidebarSelection.workspace(workspaceID).serializedKey
        memory.selectionHistory.removeAll { $0 == key }
        memory.workspaceByProjectID = memory.workspaceByProjectID.filter { $0.value != workspaceID.description }
        memory.tabByWorkspaceID.removeValue(forKey: workspaceID.description)
        memory.tabHistoryByWorkspaceID.removeValue(forKey: workspaceID.description)
    }

    private static func forget(terminalGroupID: TerminalGroupID, from memory: inout WarrenDesktopNavigationMemory) {
        let key = WarrenDesktopSidebarSelection.terminalGroup(terminalGroupID).serializedKey
        memory.selectionHistory.removeAll { $0 == key }
        memory.tabByTerminalGroupID.removeValue(forKey: terminalGroupID.description)
        memory.tabHistoryByTerminalGroupID.removeValue(forKey: terminalGroupID.description)
    }

    private static func forget(projectID: ProjectID, from memory: inout WarrenDesktopNavigationMemory) {
        let key = WarrenDesktopSidebarSelection.project(projectID).serializedKey
        memory.selectionHistory.removeAll { $0 == key }
        memory.workspaceByProjectID.removeValue(forKey: projectID.description)
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
