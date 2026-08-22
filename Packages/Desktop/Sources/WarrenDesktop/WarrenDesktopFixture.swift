import Foundation
import WarrenClientCore
import WarrenDomain

/// A project and its device-local workspace rows for the desktop shell.
///
/// This is a value projection. It carries no Host process, persistence, or
/// transport behavior, and can therefore be rebuilt from Host/Client state
/// whenever the composition root receives an update.
public struct WarrenDesktopProjectGroup: Identifiable, Hashable, Sendable {
    public let project: Project
    public let workspaces: [Workspace]

    public var id: Project.ID { project.id }

    public init(project: Project, workspaces: [Workspace] = []) {
        self.project = project
        self.workspaces = workspaces
    }
}

/// The workspace-level activity presentation keeps the highest-priority
/// state while also counting visible tabs whose agents are currently working.
/// A workspace row can therefore show both actionable state and concurrency
/// without rescanning the session graph during every SwiftUI render.
public struct WarrenDesktopWorkspaceActivitySummary: Hashable, Sendable {
    public let activity: AgentActivityState?
    public let activeTabCount: Int

    public init(
        activity: AgentActivityState? = nil,
        activeTabCount: Int = 0
    ) {
        self.activity = activity
        self.activeTabCount = max(activeTabCount, 0)
    }
}

/// An existing Git worktree shown by the project import picker. The candidate
/// remains visible after import so the UI can render it disabled and explain
/// that the operation is one-time.
public struct WarrenDesktopWorktreeCandidate: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let branch: String?
    public let locked: Bool
    public let imported: Bool
    public let workspaceID: WorkspaceID?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        branch: String? = nil,
        locked: Bool = false,
        imported: Bool = false,
        workspaceID: WorkspaceID? = nil
    ) {
        self.path = path
        self.name = name
        self.branch = branch
        self.locked = locked
        self.imported = imported
        self.workspaceID = workspaceID
    }
}

/// A Host-owned terminal group and its derived desktop session metrics.
public struct WarrenDesktopTerminalGroup: Identifiable, Hashable, Sendable {
    public let group: TerminalGroup
    public let sessions: [WarrenDesktopSession]

    public var id: TerminalGroupID { group.id }

    public var runningSessionCount: Int {
        sessions.filter { $0.state.isActive }.count
    }

    public var activity: AgentActivityState? {
        sessions.compactMap(\.activity).max { lhs, rhs in
            lhs.terminalPriority < rhs.terminalPriority
        }
    }

    public init(group: TerminalGroup, sessions: [WarrenDesktopSession] = []) {
        self.group = group
        self.sessions = sessions
    }
}

/// Desktop read model for a Host-owned Warren Terminal Session. `tabID` is
/// present only when the current Window Layout contains an entry for it.
public struct WarrenDesktopSession: Identifiable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID?
    public let terminalGroupID: TerminalGroupID?
    public let tabID: String?
    public let title: String
    public let customTitle: String?
    public let pinned: Bool
    public let kind: TerminalSessionKind
    public let state: WarrenDesktopSessionState
    public let agentStatus: AgentStatus?
    public let runtimeProcess: String
    public let workingDirectory: String

    public var activity: AgentActivityState? { agentStatus?.activity }

    /// Single display-name rule: a user-set custom title wins, otherwise the
    /// generated default title is shown.
    public var displayTitle: String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? title : custom
    }

    public init(
        id: TerminalSessionID,
        workspaceID: WorkspaceID? = nil,
        terminalGroupID: TerminalGroupID? = nil,
        tabID: String? = nil,
        title: String,
        customTitle: String? = nil,
        pinned: Bool = false,
        kind: TerminalSessionKind = .shell,
        state: WarrenDesktopSessionState = .attached,
        activity: AgentActivityState? = nil,
        agentStatus: AgentStatus? = nil,
        runtimeProcess: String = "",
        workingDirectory: String = ""
    ) {
        precondition(
            (workspaceID == nil) != (terminalGroupID == nil),
            "A terminal session must belong to exactly one context."
        )
        self.id = id
        self.workspaceID = workspaceID
        self.terminalGroupID = terminalGroupID
        self.tabID = tabID
        self.title = title
        self.customTitle = customTitle
        self.pinned = pinned
        self.kind = kind
        self.state = state
        self.agentStatus = agentStatus ?? activity.map { AgentStatus(activity: $0) }
        self.runtimeProcess = runtimeProcess
        self.workingDirectory = workingDirectory
    }

    public func withActivity(_ activity: AgentActivityState?) -> Self {
        withAgentStatus(activity.map { AgentStatus(activity: $0) })
    }

    public func withAgentStatus(_ agentStatus: AgentStatus?) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            terminalGroupID: terminalGroupID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            state: state,
            agentStatus: agentStatus,
            runtimeProcess: runtimeProcess,
            workingDirectory: workingDirectory
        )
    }

}

public enum WarrenDesktopSessionState: String, Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case exited
    case failed

    public var isActive: Bool {
        switch self {
        case .attached, .connecting, .reconnecting:
            true
        case .disconnected, .exited, .failed:
            false
        }
    }
}

/// Connection state rendered by the desktop chrome.
public enum WarrenDesktopConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case attached
    case reconnecting
    case failed

    public var isConnected: Bool {
        self == .attached
    }
}

/// Immutable data projection consumed by the production desktop shell.
///
/// The executable owns the mutable Host/Client models and creates this value
/// at its composition boundary. The views never mutate this projection and do
/// not know whether it came from the daemon, a test double, or a future
/// transport adapter.
public struct WarrenDesktopProjection: Sendable, Hashable {
    /// The small identity-only value used by SwiftUI when it only needs to
    /// validate selection.  Comparing the full projection here would walk
    /// every project, workspace, tab, and session mapping on every snapshot.
    public struct ReconciliationKey: Sendable, Hashable {
        public let projectIDs: [ProjectID]
        public let workspaceIDs: [WorkspaceID]
        public let terminalGroupIDs: [TerminalGroupID]
        public let tabIDs: [String]
        public let sessionIDs: [TerminalSessionID]
        fileprivate init(
            groups: [WarrenDesktopProjectGroup],
            terminalGroups: [TerminalGroup],
            sessions: [WarrenDesktopSession],
            tabs: [ClientTab]
        ) {
            self.projectIDs = groups.map(\.project.id)
            self.workspaceIDs = groups.flatMap { $0.workspaces.map(\.id) }
            self.terminalGroupIDs = terminalGroups.map(\.id)
            self.tabIDs = tabs.map(\.id)
            self.sessionIDs = sessions.map(\.id)
        }
    }

    public let host: WarrenDomain.Host
    public let groups: [WarrenDesktopProjectGroup]
    public let terminalGroups: [TerminalGroup]
    public let sessions: [WarrenDesktopSession]
    public let tabs: [ClientTab]
    public let sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID]
    public let sessionTerminalGroupIDs: [TerminalSessionID: TerminalGroupID]
    public let tabWorkspaceIDs: [String: WorkspaceID]
    public let tabTerminalGroupIDs: [String: TerminalGroupID]
    public let reconciliationKey: ReconciliationKey
    /// Lookup tables are built once at the projection boundary. SwiftUI can
    /// ask for the same relationship many times while reconciling a frame;
    /// those reads must not rescan the whole sidebar/session tree.
    private let workspacesByID: [WorkspaceID: Workspace]
    private let sessionsByID: [TerminalSessionID: WarrenDesktopSession]
    private let tabsByWorkspaceID: [WorkspaceID: [ClientTab]]
    private let sessionsByTerminalGroupID: [TerminalGroupID: [WarrenDesktopSession]]
    private let tabsByTerminalGroupID: [TerminalGroupID: [ClientTab]]
    private let firstWorkspaceID: WorkspaceID?
    private let firstWorkspaceIDByProjectID: [ProjectID: WorkspaceID]
    private let activityByWorkspaceID: [WorkspaceID: AgentActivityState]
    private let workspaceActivitySummariesByID: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    private let activityByTerminalGroupID: [TerminalGroupID: AgentActivityState]
    private let terminalGroupsByID: [TerminalGroupID: TerminalGroup]
    public let connectionState: WarrenDesktopConnectionState

    public var isConnected: Bool {
        connectionState.isConnected
    }

    /// Activity is already reduced by workspace during projection creation.
    /// Exposing the value map keeps the sidebar from rebuilding one on every
    /// body evaluation.
    public var workspaceActivities: [WorkspaceID: AgentActivityState] {
        activityByWorkspaceID
    }

    /// The workspace activity summary includes the existing primary state and
    /// the number of visible tabs whose agent is actively working.
    public var workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary] {
        workspaceActivitySummariesByID
    }

    public var firstWorkspace: Workspace? {
        firstWorkspaceID.flatMap { workspacesByID[$0] }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host
            && lhs.groups == rhs.groups
            && lhs.terminalGroups == rhs.terminalGroups
            && lhs.sessions == rhs.sessions
            && lhs.tabs == rhs.tabs
            && lhs.sessionWorkspaceIDs == rhs.sessionWorkspaceIDs
            && lhs.sessionTerminalGroupIDs == rhs.sessionTerminalGroupIDs
            && lhs.tabWorkspaceIDs == rhs.tabWorkspaceIDs
            && lhs.tabTerminalGroupIDs == rhs.tabTerminalGroupIDs
            && lhs.connectionState == rhs.connectionState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(groups)
        hasher.combine(terminalGroups)
        hasher.combine(sessions)
        hasher.combine(tabs)
        hasher.combine(sessionWorkspaceIDs)
        hasher.combine(sessionTerminalGroupIDs)
        hasher.combine(tabWorkspaceIDs)
        hasher.combine(tabTerminalGroupIDs)
        hasher.combine(connectionState)
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        connectionState: WarrenDesktopConnectionState = .attached,
        terminalGroups: [TerminalGroup] = [],
        sessionTerminalGroupIDs: [TerminalSessionID: TerminalGroupID] = [:],
        tabTerminalGroupIDs: [String: TerminalGroupID] = [:]
    ) {
        let pinnedBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.pinned) }
        )
        self.host = host
        self.groups = Self.pinnedFirst(groups) { $0.project.pinned }.map { group in
            WarrenDesktopProjectGroup(
                project: group.project,
                workspaces: Self.pinnedFirst(group.workspaces) { $0.pinned }
            )
        }
        self.terminalGroups = terminalGroups
        self.sessions = Self.pinnedFirst(sessions) { $0.pinned }
        self.tabs = Self.pinnedFirst(tabs) { tab in
            tab.sessionID.flatMap { pinnedBySessionID[$0] } ?? false
        }
        let resolvedSessionWorkspaceIDs = sessionWorkspaceIDs.merging(
            Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                session.workspaceID.map { (session.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        let resolvedSessionTerminalGroupIDs = sessionTerminalGroupIDs.merging(
            Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                session.terminalGroupID.map { (session.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        self.sessionWorkspaceIDs = resolvedSessionWorkspaceIDs
        self.sessionTerminalGroupIDs = resolvedSessionTerminalGroupIDs
        let resolvedTabWorkspaceIDs = tabWorkspaceIDs.merging(
            Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
                tab.sessionID.flatMap { resolvedSessionWorkspaceIDs[$0] }.map { (tab.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        let resolvedTabTerminalGroupIDs = tabTerminalGroupIDs.merging(
            Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
                tab.sessionID.flatMap { resolvedSessionTerminalGroupIDs[$0] }.map { (tab.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        self.tabWorkspaceIDs = resolvedTabWorkspaceIDs
        self.tabTerminalGroupIDs = resolvedTabTerminalGroupIDs

        var workspacesByID: [WorkspaceID: Workspace] = [:]
        var firstWorkspaceID: WorkspaceID?
        var firstWorkspaceIDByProjectID: [ProjectID: WorkspaceID] = [:]
        for group in groups {
            for workspace in group.workspaces {
                workspacesByID[workspace.id] = workspace
                if firstWorkspaceID == nil {
                    firstWorkspaceID = workspace.id
                }
                if firstWorkspaceIDByProjectID[group.project.id] == nil {
                    firstWorkspaceIDByProjectID[group.project.id] = workspace.id
                }
            }
        }
        self.workspacesByID = workspacesByID
        self.firstWorkspaceID = firstWorkspaceID
        self.firstWorkspaceIDByProjectID = firstWorkspaceIDByProjectID

        self.sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        var tabsByWorkspaceID: [WorkspaceID: [ClientTab]] = [:]
        for tab in tabs {
            guard let workspaceID = resolvedTabWorkspaceIDs[tab.id] else { continue }
            tabsByWorkspaceID[workspaceID, default: []].append(tab)
        }
        self.tabsByWorkspaceID = tabsByWorkspaceID

        var sessionsByTerminalGroupID: [TerminalGroupID: [WarrenDesktopSession]] = [:]
        for session in self.sessions {
            guard let groupID = resolvedSessionTerminalGroupIDs[session.id] else { continue }
            sessionsByTerminalGroupID[groupID, default: []].append(session)
        }
        self.sessionsByTerminalGroupID = sessionsByTerminalGroupID

        var tabsByTerminalGroupID: [TerminalGroupID: [ClientTab]] = [:]
        for tab in tabs {
            guard let groupID = resolvedTabTerminalGroupIDs[tab.id] else { continue }
            tabsByTerminalGroupID[groupID, default: []].append(tab)
        }
        self.tabsByTerminalGroupID = tabsByTerminalGroupID

        var activityByWorkspaceID: [WorkspaceID: AgentActivityState] = [:]
        for session in sessions {
            guard let workspaceID = session.workspaceID,
                  let activity = session.activity else { continue }
            guard let current = activityByWorkspaceID[workspaceID],
                  current.workspacePriority >= activity.workspacePriority else {
                activityByWorkspaceID[workspaceID] = activity
                continue
            }
        }
        self.activityByWorkspaceID = activityByWorkspaceID

        var activeTabCountByWorkspaceID: [WorkspaceID: Int] = [:]
        for (workspaceID, workspaceTabs) in tabsByWorkspaceID {
            for tab in workspaceTabs {
                guard let sessionID = tab.sessionID,
                      sessionsByID[sessionID]?.activity == .working else {
                    continue
                }
                activeTabCountByWorkspaceID[workspaceID, default: 0] += 1
            }
        }
        var workspaceActivitySummariesByID: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary] = [:]
        let activityWorkspaceIDs = Set(activityByWorkspaceID.keys)
            .union(activeTabCountByWorkspaceID.keys)
        for workspaceID in activityWorkspaceIDs {
            workspaceActivitySummariesByID[workspaceID] = WarrenDesktopWorkspaceActivitySummary(
                activity: activityByWorkspaceID[workspaceID],
                activeTabCount: activeTabCountByWorkspaceID[workspaceID, default: 0]
            )
        }
        self.workspaceActivitySummariesByID = workspaceActivitySummariesByID

        var activityByTerminalGroupID: [TerminalGroupID: AgentActivityState] = [:]
        for session in sessions {
            guard let groupID = session.terminalGroupID,
                  let activity = session.activity else { continue }
            guard let current = activityByTerminalGroupID[groupID],
                  current.terminalPriority >= activity.terminalPriority else {
                activityByTerminalGroupID[groupID] = activity
                continue
            }
        }
        self.activityByTerminalGroupID = activityByTerminalGroupID
        self.terminalGroupsByID = Dictionary(uniqueKeysWithValues: terminalGroups.map { ($0.id, $0) })
        self.connectionState = connectionState
        self.reconciliationKey = ReconciliationKey(
            groups: groups,
            terminalGroups: terminalGroups,
            sessions: sessions,
            tabs: tabs
        )
    }

    /// Convenience initializer for callers that already have domain arrays.
    /// Grouping happens once at projection construction, not while rendering rows.
    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        connectionState: WarrenDesktopConnectionState = .attached,
        terminalGroups: [TerminalGroup] = [],
        sessionTerminalGroupIDs: [TerminalSessionID: TerminalGroupID] = [:],
        tabTerminalGroupIDs: [String: TerminalGroupID] = [:]
    ) {
        var workspacesByProjectID: [ProjectID: [Workspace]] = [:]
        for workspace in Self.pinnedFirst(workspaces, isPinned: \.pinned) {
            workspacesByProjectID[workspace.projectID, default: []].append(workspace)
        }
        let groups = Self.pinnedFirst(projects, isPinned: \.pinned).map { project in
            WarrenDesktopProjectGroup(
                project: project,
                workspaces: workspacesByProjectID[project.id] ?? []
            )
        }
        self.init(
            host: host,
            groups: groups,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs
        )
    }

    private static func pinnedFirst<Value>(
        _ values: [Value],
        isPinned: (Value) -> Bool
    ) -> [Value] {
        values.filter { isPinned($0) } + values.filter { !isPinned($0) }
    }

    public static func empty(host: WarrenDomain.Host) -> Self {
        Self(host: host, groups: [])
    }

    public func projectGroup(id: ProjectID) -> WarrenDesktopProjectGroup? {
        groups.first { $0.project.id == id }
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        workspacesByID[id]
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        firstWorkspaceIDByProjectID[projectID].flatMap { workspacesByID[$0] }
    }

    public func workspace(for sessionID: TerminalSessionID) -> Workspace? {
        guard let workspaceID = sessionWorkspaceIDs[sessionID] else { return nil }
        return workspacesByID[workspaceID]
    }

    public func terminalGroup(id: TerminalGroupID) -> TerminalGroup? {
        terminalGroupsByID[id]
    }

    public func terminalGroup(for sessionID: TerminalSessionID) -> TerminalGroup? {
        guard let groupID = sessionTerminalGroupIDs[sessionID] else { return nil }
        return terminalGroupsByID[groupID]
    }

    public func session(id: TerminalSessionID) -> WarrenDesktopSession? {
        sessionsByID[id]
    }

    public func workspaceID(forTabID tabID: String) -> WorkspaceID? {
        tabWorkspaceIDs[tabID]
    }

    public func terminalGroupID(forTabID tabID: String) -> TerminalGroupID? {
        tabTerminalGroupIDs[tabID]
    }

    /// Tabs are workspace-local UI. The Host may keep tabs from several
    /// workspaces open, but a workspace chrome must never render siblings
    /// owned by another project/branch.
    public func tabs(in workspaceID: WorkspaceID) -> [ClientTab] {
        tabsByWorkspaceID[workspaceID] ?? []
    }

    public func tabs(in workspaceID: WorkspaceID?) -> [ClientTab] {
        guard let workspaceID else { return [] }
        return tabs(in: workspaceID)
    }

    public func tabs(in terminalGroupID: TerminalGroupID) -> [ClientTab] {
        tabsByTerminalGroupID[terminalGroupID] ?? []
    }

    public func sessions(in terminalGroupID: TerminalGroupID) -> [WarrenDesktopSession] {
        sessionsByTerminalGroupID[terminalGroupID] ?? []
    }

    /// Returns the most actionable state for a Workspace. A failure or input
    /// request must remain visible even when another Session is still working.
    public func activity(in workspaceID: WorkspaceID) -> AgentActivityState? {
        activityByWorkspaceID[workspaceID]
    }

    public func activity(in workspaceID: WorkspaceID?) -> AgentActivityState? {
        workspaceID.flatMap(activity(in:))
    }

    public func activity(in terminalGroupID: TerminalGroupID) -> AgentActivityState? {
        activityByTerminalGroupID[terminalGroupID]
    }

    public func runningSessionCount(in terminalGroupID: TerminalGroupID) -> Int {
        sessions(in: terminalGroupID).filter { $0.state.isActive }.count
    }

    /// Returns a projection with one session's client-local activity
    /// presentation changed. The source projection remains immutable and all
    /// relationship lookups are rebuilt at this boundary.
    public func withSessionActivity(
        _ activity: AgentActivityState?,
        for sessionID: TerminalSessionID
    ) -> Self {
        withSessionAgentStatus(activity.map { AgentStatus(activity: $0) }, for: sessionID)
    }

    public func withSessionAgentStatus(
        _ agentStatus: AgentStatus?,
        for sessionID: TerminalSessionID
    ) -> Self {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return self
        }
        guard sessions[index].agentStatus != agentStatus else { return self }
        var nextSessions = sessions
        nextSessions[index] = nextSessions[index].withAgentStatus(agentStatus)
        return Self(
            host: host,
            groups: groups,
            sessions: nextSessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs
        )
    }
}

private extension AgentActivityState {
    var workspacePriority: Int {
        switch self {
        case .failed: 6
        case .blocked: 5
        case .stalled: 4
        case .working: 3
        case .ready: 1
        case .exited: 0
        }
    }

    var terminalPriority: Int { workspacePriority }
}

/// A deterministic preview/test-only fixture. Production composition should
/// construct `WarrenDesktopProjection` from live Host and Client state instead.
public struct WarrenDesktopFixture: Sendable {
    public let projection: WarrenDesktopProjection

    public var host: WarrenDomain.Host { projection.host }
    public var groups: [WarrenDesktopProjectGroup] { projection.groups }
    public var terminalGroups: [TerminalGroup] { projection.terminalGroups }
    public var sessions: [WarrenDesktopSession] { projection.sessions }
    public var tabs: [ClientTab] { projection.tabs }
    public var isConnected: Bool { projection.isConnected }

    public init(projection: WarrenDesktopProjection) {
        self.projection = projection
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        tabs: [ClientTab] = [],
        isConnected: Bool = true,
        terminalGroups: [TerminalGroup] = [],
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                groups: groups,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected,
                terminalGroups: terminalGroups
            )
        )
    }

    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        tabs: [ClientTab] = [],
        isConnected: Bool = true,
        terminalGroups: [TerminalGroup] = [],
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                projects: projects,
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected,
                terminalGroups: terminalGroups
            )
        )
    }

    public func projectGroup(id: ProjectID) -> WarrenDesktopProjectGroup? {
        projection.projectGroup(id: id)
    }

    public func workspace(id: WorkspaceID) -> Workspace? {
        projection.workspace(id: id)
    }

    public func firstWorkspace(in projectID: ProjectID) -> Workspace? {
        projection.firstWorkspace(in: projectID)
    }

    /// Stable IDs keep preview diffing and UI tests deterministic.
    public static var preview: Self {
        let hostID = HostID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000001"))
        let projectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000002"))
        let secondProjectID = ProjectID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000003"))
        let firstWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000004"))
        let secondWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000005"))
        let thirdWorkspaceID = WorkspaceID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000006"))
        let firstSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000007"))
        let secondSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000008"))

        let host = WarrenDomain.Host(id: hostID, name: "Local Mac")
        let project = Project(
            id: projectID,
            hostID: hostID,
            name: "Warren",
            rootPath: "/Users/demo/Code/warren"
        )
        let secondProject = Project(
            id: secondProjectID,
            hostID: hostID,
            name: "Superset",
            rootPath: "/Users/demo/Code/superset"
        )
        let workspaces = [
            Workspace(
                id: firstWorkspaceID,
                projectID: projectID,
                name: "main",
                path: "/Users/demo/Code/warren",
                branch: "main"
            ),
            Workspace(
                id: secondWorkspaceID,
                projectID: projectID,
                name: "feature/mobile-shell",
                path: "/Users/demo/Code/warren-feature",
                branch: "feature/mobile-shell"
            ),
            Workspace(
                id: thirdWorkspaceID,
                projectID: secondProjectID,
                name: "review",
                path: "/Users/demo/Code/superset-review",
                branch: "review/warren"
            ),
        ]
        let tabs = [
            ClientTab(
                id: "tab-main",
                title: "main",
                sessionID: firstSessionID,
                kind: .shell
            ),
            ClientTab(
                id: "tab-review",
                title: "review",
                sessionID: secondSessionID,
                kind: .claude
            ),
        ]
        let sessions = [
            WarrenDesktopSession(
                id: firstSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-main",
                title: "main",
                kind: .shell
            ),
            WarrenDesktopSession(
                id: secondSessionID,
                workspaceID: thirdWorkspaceID,
                tabID: "tab-review",
                title: "review",
                kind: .claude
            ),
        ]

        return Self(
            projection: WarrenDesktopProjection(
                host: host,
                projects: [project, secondProject],
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                sessionWorkspaceIDs: [
                    firstSessionID: firstWorkspaceID,
                    secondSessionID: thirdWorkspaceID,
                ]
            )
        )
    }

    private static func uuid(_ string: String) -> UUID {
        // Fixture literals are compile-time-known and deliberately fail fast
        // if somebody edits one into a non-UUID value.
        UUID(uuidString: string)!
    }
}

public enum WarrenDesktopSidebarSelection: Hashable, Sendable {
    case project(ProjectID)
    case workspace(WorkspaceID)
    case terminalGroup(TerminalGroupID)
}

/// The Host context a Session can be moved into. Workspace and Terminal Group
/// remain mutually exclusive destinations, matching the daemon protocol.
public enum WarrenDesktopSessionMoveDestination: Hashable, Sendable {
    case workspace(WorkspaceID)
    case terminalGroup(TerminalGroupID)
}

/// A selectable destination shown in the tab context menu. `id` is stable for
/// SwiftUI identity and is derived from the destination ID, never from the
/// display title.
public struct WarrenDesktopSessionMoveTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let destination: WarrenDesktopSessionMoveDestination

    public init(
        id: String,
        title: String,
        destination: WarrenDesktopSessionMoveDestination
    ) {
        self.id = id
        self.title = title
        self.destination = destination
    }
}

/// User intent emitted by the desktop shell. The composition root translates
/// these intents into Host, ClientLayoutStore, or renderer operations.
public enum WarrenDesktopAction: Hashable, Sendable {
    case addProject
    case importSuperset
    case requestNewWorkspace(ProjectID)
    case requestProjectWorktreeImport(ProjectID)
    case setProjectAutoImportGitWorktrees(ProjectID, Bool)
    case renameProject(ProjectID, String)
    case renameWorkspace(WorkspaceID, String)
    case deleteProject(ProjectID)
    case deleteWorkspace(WorkspaceID, removeLocalWorktree: Bool)
    case renameSession(TerminalSessionID, String)
    case setProjectPinned(ProjectID, Bool)
    case setWorkspacePinned(WorkspaceID, Bool)
    case setSessionPinned(TerminalSessionID, Bool)
    case dismissActivity(TerminalSessionID, AgentActivityState)
    case selectProject(ProjectID)
    case selectWorkspace(WorkspaceID)
    /// Opens a workspace from a double-click/explicit open gesture. Any
    /// default Shell creation is decided by the host setting at the root.
    case openWorkspace(WorkspaceID)
    case selectTerminalGroup(TerminalGroupID)
    case moveProject(ProjectID, before: ProjectID?)
    case moveWorkspace(WorkspaceID, before: WorkspaceID?)
    case openSession(TerminalSessionID)
    case deleteSession(TerminalSessionID)
    case selectTab(String)
    case moveTab(String, before: String?)
    case moveSession(TerminalSessionID, to: WarrenDesktopSessionMoveDestination)
    case requestNewSession(WorkspaceID)
    case launchSession(WorkspaceID, TerminalSessionLaunchRequest)
    case requestNewTerminalGroupSession(TerminalGroupID)
    case launchTerminalGroupSession(TerminalGroupID, TerminalSessionLaunchRequest)
    case createTerminalGroup(String, home: String?)
    case renameTerminalGroup(TerminalGroupID, String)
    case setTerminalGroupHome(TerminalGroupID, String?)
    case deleteTerminalGroup(TerminalGroupID)
    case moveTerminalGroup(TerminalGroupID, before: TerminalGroupID?)
    case closeTab(String)
    case closeOtherTabs(String)
    case closeAllTabs
    case restoreNavigation(WarrenDesktopNavigationState)
    case toggleSidebar
}

/// UI-only event surface. The package itself performs no side effects.
///
/// Keeping one typed event channel avoids hiding important composition work in
/// row views. It also makes the full action contract easy to test without
/// constructing a Host or starting a process.
public struct WarrenDesktopActions {
    public let send: @MainActor (WarrenDesktopAction) -> Void

    public init(
        send: @escaping @MainActor (WarrenDesktopAction) -> Void = { _ in }
    ) {
        self.send = send
    }

    @MainActor
    public func callAsFunction(_ action: WarrenDesktopAction) {
        send(action)
    }
}

/// Context passed to the injected terminal surface slot. A surface renders
/// bytes and forwards input through its own injected adapter; this value never
/// contains a process, transport, or persistence dependency.
public struct WarrenDesktopTerminalContext: Hashable, Sendable {
    public let workspace: Workspace?
    public let terminalGroup: TerminalGroup?
    public let tab: ClientTab
    public let font: TerminalFontPreference
    /// Whether the injected terminal surface should own AppKit keyboard focus.
    /// Overlays such as search and the command palette temporarily suppress
    /// this intent while keeping the surface mounted.
    public let wantsTerminalFocus: Bool

    public var scopeID: String {
        workspace?.id.description ?? terminalGroup?.id.description ?? "none"
    }

    public init(
        workspace: Workspace,
        tab: ClientTab,
        font: TerminalFontPreference = .init(),
        wantsTerminalFocus: Bool = true
    ) {
        self.workspace = workspace
        self.terminalGroup = nil
        self.tab = tab
        self.font = font
        self.wantsTerminalFocus = wantsTerminalFocus
    }

    public init(
        terminalGroup: TerminalGroup,
        tab: ClientTab,
        font: TerminalFontPreference = .init(),
        wantsTerminalFocus: Bool = true
    ) {
        self.workspace = nil
        self.terminalGroup = terminalGroup
        self.tab = tab
        self.font = font
        self.wantsTerminalFocus = wantsTerminalFocus
    }
}
