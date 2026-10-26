import Foundation
import WarrenDomain

/// Device-local sidebar tree state (which tasks, projects, and workspaces
/// the user folded away, and whether each
/// sidebar section is collapsed). Everything starts open: only a fold is
/// recorded, so a new row is never hidden by a choice nobody made. It is intentionally not Host
/// state: ordering lives on the Host, while expansion is a per-endpoint UI
/// preference.
/// Which list the sidebar shows. One at a time: Projects is the tree of every
/// project's branches and Sessions, Tasks the tree of Tasks and the worktrees
/// they span.
public enum WarrenDesktopSidebarTab: String, Equatable, Sendable, CaseIterable {
    case projects
    case tasks
}

public struct WarrenDesktopSidebarTreeState: Equatable, Sendable {
    /// The list on screen, remembered per Host.
    public var selectedTab: WarrenDesktopSidebarTab
    /// Tasks the user folded away.
    public var collapsedTaskIDs: Set<TaskID>
    /// Projects the user folded away.
    public var collapsedProjectIDs: Set<ProjectID>
    /// Workspaces whose Session leaves the user folded away. Stored as the
    /// collapsed set so a new workspace lists its Sessions by default.
    public var collapsedWorkspaceIDs: Set<WorkspaceID>
    /// Sessions whose subagent rows the user opened. Stored as the opened set so
    /// a new Session keeps its subagents in the title's count chip.
    public var expandedSubagentSessionIDs: Set<TerminalSessionID>
    /// Sessions whose completed subagents the user opened past the `N done`
    /// row. Stored separately because it is a second fold inside the first.
    public var expandedSubagentDoneSessionIDs: Set<TerminalSessionID>
    public var tasksCollapsed: Bool
    public var projectsCollapsed: Bool
    public var showsActiveOnly: Bool
    /// Projects whose idle-worktrees row the user opened. That row starts
    /// folded, so the opened set is what is recorded.
    public var expandedIdleWorkspaceProjectIDs: Set<ProjectID>
    /// Whether the user opened the inactive-projects row, which starts folded.
    public var inactiveProjectsExpanded: Bool

    public init(
        selectedTab: WarrenDesktopSidebarTab = .projects,
        collapsedTaskIDs: Set<TaskID> = [],
        collapsedProjectIDs: Set<ProjectID> = [],
        collapsedWorkspaceIDs: Set<WorkspaceID> = [],
        expandedSubagentSessionIDs: Set<TerminalSessionID> = [],
        expandedSubagentDoneSessionIDs: Set<TerminalSessionID> = [],
        tasksCollapsed: Bool = false,
        projectsCollapsed: Bool = false,
        showsActiveOnly: Bool = false,
        expandedIdleWorkspaceProjectIDs: Set<ProjectID> = [],
        inactiveProjectsExpanded: Bool = false
    ) {
        self.selectedTab = selectedTab
        self.collapsedTaskIDs = collapsedTaskIDs
        self.collapsedProjectIDs = collapsedProjectIDs
        self.collapsedWorkspaceIDs = collapsedWorkspaceIDs
        self.expandedSubagentSessionIDs = expandedSubagentSessionIDs
        self.expandedSubagentDoneSessionIDs = expandedSubagentDoneSessionIDs
        self.tasksCollapsed = tasksCollapsed
        self.projectsCollapsed = projectsCollapsed
        self.showsActiveOnly = showsActiveOnly
        self.expandedIdleWorkspaceProjectIDs = expandedIdleWorkspaceProjectIDs
        self.inactiveProjectsExpanded = inactiveProjectsExpanded
    }
}

/// Device-local persistence for sidebar expansion. The scope key is the
/// selected endpoint ID so Local and Server keep independent trees.
public enum WarrenDesktopSidebarTreePersistence {
    public static func restore(
        scope: String,
        defaults: UserDefaults = .standard
    ) -> WarrenDesktopSidebarTreeState {
        let base = "warren.desktop.sidebar.tree.\(scope)"
        // The folded sets have keys of their own. The expanded sets an earlier
        // build stored are left unread, so every row opens once and then
        // remembers its own fold.
        let collapsedTasks = (defaults.stringArray(forKey: base + ".tasks.folded") ?? [])
            .compactMap(TaskID.init(uuidString:))
        let collapsedProjects = (defaults.stringArray(forKey: base + ".projects.folded") ?? [])
            .compactMap(ProjectID.init(uuidString:))
        let collapsedWorkspaces = (defaults.stringArray(forKey: base + ".workspaces.collapsed") ?? [])
            .compactMap(WorkspaceID.init(uuidString:))
        let expandedSubagents = (defaults.stringArray(forKey: base + ".sessions.subagents.expanded") ?? [])
            .compactMap(TerminalSessionID.init(uuidString:))
        let expandedSubagentDone = (defaults.stringArray(forKey: base + ".sessions.subagents.done.expanded") ?? [])
            .compactMap(TerminalSessionID.init(uuidString:))
        let expandedIdleWorkspaces = (defaults.stringArray(forKey: base + ".projects.idle-worktrees.expanded") ?? [])
            .compactMap(ProjectID.init(uuidString:))
        return WarrenDesktopSidebarTreeState(
            selectedTab: defaults.string(forKey: base + ".tab")
                .flatMap(WarrenDesktopSidebarTab.init(rawValue:)) ?? .projects,
            collapsedTaskIDs: Set(collapsedTasks),
            collapsedProjectIDs: Set(collapsedProjects),
            collapsedWorkspaceIDs: Set(collapsedWorkspaces),
            expandedSubagentSessionIDs: Set(expandedSubagents),
            expandedSubagentDoneSessionIDs: Set(expandedSubagentDone),
            tasksCollapsed: defaults.bool(forKey: base + ".tasks.collapsed"),
            projectsCollapsed: defaults.bool(forKey: base + ".collapsed"),
            showsActiveOnly: defaults.bool(forKey: base + ".active-only"),
            expandedIdleWorkspaceProjectIDs: Set(expandedIdleWorkspaces),
            inactiveProjectsExpanded: defaults.bool(forKey: base + ".projects.inactive.expanded")
        )
    }

    public static func save(
        _ state: WarrenDesktopSidebarTreeState,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let base = "warren.desktop.sidebar.tree.\(scope)"
        defaults.set(state.selectedTab.rawValue, forKey: base + ".tab")
        defaults.set(
            state.collapsedTaskIDs.map(\.description).sorted(),
            forKey: base + ".tasks.folded"
        )
        defaults.set(
            state.collapsedProjectIDs.map(\.description).sorted(),
            forKey: base + ".projects.folded"
        )
        defaults.set(
            state.collapsedWorkspaceIDs.map(\.description).sorted(),
            forKey: base + ".workspaces.collapsed"
        )
        defaults.set(
            state.expandedSubagentSessionIDs.map(\.description).sorted(),
            forKey: base + ".sessions.subagents.expanded"
        )
        defaults.set(
            state.expandedSubagentDoneSessionIDs.map(\.description).sorted(),
            forKey: base + ".sessions.subagents.done.expanded"
        )
        defaults.set(state.tasksCollapsed, forKey: base + ".tasks.collapsed")
        defaults.set(state.showsActiveOnly, forKey: base + ".active-only")
        defaults.set(state.projectsCollapsed, forKey: base + ".collapsed")
        defaults.set(
            state.expandedIdleWorkspaceProjectIDs.map(\.description).sorted(),
            forKey: base + ".projects.idle-worktrees.expanded"
        )
        defaults.set(state.inactiveProjectsExpanded, forKey: base + ".projects.inactive.expanded")
    }

}
