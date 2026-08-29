import Foundation
import WarrenDomain

/// Device-local sidebar tree state (which tasks and projects are expanded and
/// whether each list is collapsed). It is intentionally not Host state:
/// ordering lives on the Host, while expansion is a per-endpoint UI preference.
public struct WarrenDesktopSidebarTreeState: Equatable, Sendable {
    public var expandedTaskIDs: Set<TaskID>
    public var expandedProjectIDs: Set<ProjectID>
    public var tasksCollapsed: Bool
    public var projectsCollapsed: Bool

    public init(
        expandedTaskIDs: Set<TaskID> = [],
        expandedProjectIDs: Set<ProjectID> = [],
        tasksCollapsed: Bool = false,
        projectsCollapsed: Bool = false
    ) {
        self.expandedTaskIDs = expandedTaskIDs
        self.expandedProjectIDs = expandedProjectIDs
        self.tasksCollapsed = tasksCollapsed
        self.projectsCollapsed = projectsCollapsed
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
            tasksCollapsed: defaults.bool(forKey: base + ".tasks.collapsed"),
            projectsCollapsed: defaults.bool(forKey: base + ".collapsed")
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
        defaults.set(state.tasksCollapsed, forKey: base + ".tasks.collapsed")
        defaults.set(state.projectsCollapsed, forKey: base + ".collapsed")
    }
}
