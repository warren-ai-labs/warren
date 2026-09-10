import Foundation
import WarrenDomain

/// Device-local sidebar tree state (which tasks and projects are expanded and
/// whether each sidebar section is collapsed). It is intentionally not Host
/// state: ordering lives on the Host, while expansion is a per-endpoint UI
/// preference.
public struct WarrenDesktopSidebarTreeState: Equatable, Sendable {
    public var expandedTaskIDs: Set<TaskID>
    public var expandedProjectIDs: Set<ProjectID>
    public var terminalGroupsCollapsed: Bool
    public var tasksCollapsed: Bool
    public var projectsCollapsed: Bool
    public var activeSessionsCollapsed: Bool
    public var showsActiveOnly: Bool

    public init(
        expandedTaskIDs: Set<TaskID> = [],
        expandedProjectIDs: Set<ProjectID> = [],
        terminalGroupsCollapsed: Bool = false,
        tasksCollapsed: Bool = false,
        projectsCollapsed: Bool = false,
        activeSessionsCollapsed: Bool = false,
        showsActiveOnly: Bool = false
    ) {
        self.expandedTaskIDs = expandedTaskIDs
        self.expandedProjectIDs = expandedProjectIDs
        self.terminalGroupsCollapsed = terminalGroupsCollapsed
        self.tasksCollapsed = tasksCollapsed
        self.projectsCollapsed = projectsCollapsed
        self.activeSessionsCollapsed = activeSessionsCollapsed
        self.showsActiveOnly = showsActiveOnly
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
        let expandedTasks = (defaults.stringArray(forKey: base + ".tasks.expanded") ?? [])
            .compactMap(TaskID.init(uuidString:))
        let expanded = (defaults.stringArray(forKey: base + ".expanded") ?? [])
            .compactMap(ProjectID.init(uuidString:))
        return WarrenDesktopSidebarTreeState(
            expandedTaskIDs: Set(expandedTasks),
            expandedProjectIDs: Set(expanded),
            terminalGroupsCollapsed: defaults.bool(forKey: base + ".terminal-groups.collapsed"),
            tasksCollapsed: defaults.bool(forKey: base + ".tasks.collapsed"),
            projectsCollapsed: defaults.bool(forKey: base + ".collapsed"),
            activeSessionsCollapsed: defaults.bool(forKey: base + ".active-sessions.collapsed"),
            showsActiveOnly: defaults.bool(forKey: base + ".active-only")
        )
    }

    public static func save(
        _ state: WarrenDesktopSidebarTreeState,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let base = "warren.desktop.sidebar.tree.\(scope)"
        defaults.set(
            state.expandedTaskIDs.map(\.description).sorted(),
            forKey: base + ".tasks.expanded"
        )
        defaults.set(
            state.expandedProjectIDs
                .map(\.description)
                .sorted(),
            forKey: base + ".expanded"
        )
        defaults.set(
            state.terminalGroupsCollapsed,
            forKey: base + ".terminal-groups.collapsed"
        )
        defaults.set(state.tasksCollapsed, forKey: base + ".tasks.collapsed")
        defaults.set(
            state.activeSessionsCollapsed,
            forKey: base + ".active-sessions.collapsed"
        )
        defaults.set(state.showsActiveOnly, forKey: base + ".active-only")
        defaults.set(state.projectsCollapsed, forKey: base + ".collapsed")
    }

}
