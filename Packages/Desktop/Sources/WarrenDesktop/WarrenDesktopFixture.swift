import Foundation
import WarrenClientCore
import WarrenDesignSystem
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

public struct WarrenDesktopTaskGroup: Identifiable, Hashable, Sendable {
    public let task: WarrenTask
    public let workspaces: [Workspace]

    public var id: TaskID { task.id }

    public init(task: WarrenTask, workspaces: [Workspace] = []) {
        self.task = task
        self.workspaces = workspaces
    }
}

enum WarrenDesktopTaskWorkspaceOptions {
    static func availableGroups(
        from groups: [WarrenDesktopProjectGroup]
    ) -> [WarrenDesktopProjectGroup] {
        groups.compactMap { group in
            let workspaces = group.workspaces.filter { $0.taskID == nil }
            guard !workspaces.isEmpty else { return nil }
            return WarrenDesktopProjectGroup(
                project: group.project,
                workspaces: workspaces
            )
        }
    }
}

/// The workspace-level activity presentation keeps the highest-priority
/// state while also counting visible tabs whose agents are currently working.
/// A workspace row can therefore show both actionable state and concurrency
/// without rescanning the session graph during every SwiftUI render.
public struct WarrenDesktopWorkspaceActivitySummary: Hashable, Sendable {
    /// The most actionable mark among the Workspace's Sessions.
    ///
    /// This is a mark rather than a bare lifecycle value because the rollup is
    /// the only thing a collapsed Workspace row has to go on. Reducing to the
    /// lifecycle first threw away what the Host was asking for, so a Workspace
    /// holding an Agent that wanted an approval looked exactly like one holding
    /// an Agent that had merely stopped.
    public let mark: WarrenActivityMark?
    public let activeTabCount: Int

    public var activity: AgentActivityState? { mark?.activityState }

    public init(
        mark: WarrenActivityMark? = nil,
        activeTabCount: Int = 0
    ) {
        self.mark = mark
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

/// Desktop read model for a Host-owned Warren Terminal Session. `tabID` is
/// present only when the current Window Layout contains an entry for it.
public struct WarrenDesktopSession: Identifiable, Hashable, Sendable {
    public let id: TerminalSessionID
    public let workspaceID: WorkspaceID?
    public let tabID: String?
    public let title: String
    public let customTitle: String?
    public let pinned: Bool
    public let kind: TerminalSessionKind
    /// The Agent provider family the Host has bound to this Session, when it
    /// differs from the durable `kind`.
    ///
    /// A shell can become Agent-backed after launch: the user starts `claude`
    /// inside it and the Host records the binding. The Session's Warren kind
    /// stays `.shell` — that is what was launched, and Warren does not rewrite
    /// history — so presentation must read the binding to name the provider.
    public let agentProvider: TerminalSessionKind?
    public let state: WarrenDesktopSessionState
    public let agentStatus: AgentStatus?
    /// The last client-observed activity transition. This is intentionally
    /// separate from `AgentStatus`, whose wire representation has no
    /// activity timestamp.
    public let activityUpdatedAt: Date?
    /// When the Host created the Session, for the "nothing run yet" duration.
    public let createdAt: Date?
    public let runtimeProcess: String
    /// The foreground command line including arguments, e.g. `npm run dev`.
    /// Empty when the Host has no foreground probe data.
    public let runtimeCommandLine: String
    public let workingDirectory: String
    /// The shell's live OSC 133 prompt state. Nil when the shell reported no
    /// marker, which is not the same as sitting at an empty prompt.
    public let shellState: WarrenDesktopShellState?
    /// The lifecycle this person has already seen for this Session, on this
    /// device.
    ///
    /// Device-local presentation state, in the same tier as Tab order: it says
    /// what was read here, which another client cannot know and the Host has no
    /// business storing. It retires a completion notice and nothing else — see
    /// `WarrenActivityMark.isAcknowledgeable`.
    public let acknowledgedActivity: AgentActivityState?
    /// A working Agent's current step, and the last primary fact the row
    /// showed for it. The second line keeps `primaryLine` when a turn has
    /// neither a tool step nor a plan entry, so the row holds its previous
    /// text instead of falling to a foreground command or a past turn.
    public let currentStep: String?
    /// The last non-empty primary fact a working row showed. Carried forward
    /// while the Session works; see `currentStep`.
    public let primaryLine: String?
    /// What the Session last did, as one line in the past tense ("Ran swift
    /// test", "Worked 1m 12s"), folded on this client from the same event stream
    /// and frozen when the turn ends.
    ///
    /// `currentStep` answers "what is it doing" and is cleared at every turn
    /// boundary; this answers "what did it last do", which is what a resting
    /// row has left to say. Nil until the Session has done anything this client
    /// has seen.
    public let lastActivity: String?
    /// The Host's sentence for the last completed turn ("Fixed the resize
    /// race, added 3 tests"). A resting Agent row prefers it to its counts;
    /// nil whenever the Host could not ask a model, which is why the counts
    /// stay as the fallback rather than as a footnote.
    public let resultSentence: String?
    /// Whether the Host can name this Session from its conversation on
    /// request right now. The Host knows both halves — the Agent has
    /// recorded a user and an assistant text, and a title endpoint is
    /// configured — so the row asks it rather than guessing.
    public let titleRegeneratable: Bool
    /// The Session's plan and context, and this turn's action counts, folded
    /// on this client from the same event stream as `currentStep`. They are the
    /// sidebar's second line's numbers; see `secondLine`.
    public let plan: WarrenDesktopPlanProgress?
    public let context: WarrenDesktopContextUsage?
    /// This turn's action counts, heaviest first by the sidebar's own priority
    /// (Edited > Ran > Fetched > Searched > Read). Empty until the turn has
    /// settled a countable action.
    public let turnCounts: [String]
    /// When the current turn started, so a running row can show how long it has
    /// run. Nil when the client's history starts mid-turn, because a duration
    /// measured from a guessed start is worse than none.
    public let turnStartedAt: Date?
    /// The subagents this Session spawned, in first-seen order. They are the
    /// Session's children, not Sessions of their own; see `WarrenDesktopSubagent`.
    public let subagents: [WarrenDesktopSubagent]

    public var activity: AgentActivityState? { agentStatus?.activity }

    /// The kind every presentation surface should name and draw an icon for.
    ///
    /// This resolves the Agent binding over the durable kind, so a `claude`
    /// running inside a shell Session reads as Claude Code instead of as a
    /// plain terminal. Behavior that depends on what Warren launched must keep
    /// using `kind`.
    public var presentedKind: TerminalSessionKind {
        SessionTitle.presentedKind(kind, agentProvider: agentProvider)
    }

    /// Warren's structured Agent view is available for integrated providers
    /// and for a shell that the Host has promoted through an Agent binding.
    public var isAgentSession: Bool {
        switch presentedKind {
        case .claude, .codex, .opencode, .pi, .qoder, .antigravity:
            true
        case .shell, .custom:
            agentStatus != nil
        case .trae, .browser:
            false
        }
    }

    /// Single display-name rule: a user-set custom title wins, otherwise the
    /// generated default title is shown.
    public var displayTitle: String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? title : custom
    }

    public init(
        id: TerminalSessionID,
        workspaceID: WorkspaceID? = nil,
        tabID: String? = nil,
        title: String,
        customTitle: String? = nil,
        pinned: Bool = false,
        kind: TerminalSessionKind = .shell,
        agentProvider: TerminalSessionKind? = nil,
        state: WarrenDesktopSessionState = .attached,
        activity: AgentActivityState? = nil,
        agentStatus: AgentStatus? = nil,
        activityUpdatedAt: Date? = nil,
        createdAt: Date? = nil,
        runtimeProcess: String = "",
        runtimeCommandLine: String = "",
        workingDirectory: String = "",
        shellState: WarrenDesktopShellState? = nil,
        acknowledgedActivity: AgentActivityState? = nil,
        currentStep: String? = nil,
        resultSentence: String? = nil,
        titleRegeneratable: Bool = false,
        primaryLine: String? = nil,
        lastActivity: String? = nil,
        plan: WarrenDesktopPlanProgress? = nil,
        context: WarrenDesktopContextUsage? = nil,
        turnCounts: [String] = [],
        turnStartedAt: Date? = nil,
        subagents: [WarrenDesktopSubagent] = []
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.title = title
        self.customTitle = customTitle
        self.pinned = pinned
        self.kind = kind
        self.agentProvider = agentProvider
        self.state = state
        self.agentStatus = agentStatus ?? activity.map { AgentStatus(activity: $0) }
        self.activityUpdatedAt = activityUpdatedAt
        self.createdAt = createdAt
        self.runtimeProcess = runtimeProcess
        self.runtimeCommandLine = runtimeCommandLine
        self.workingDirectory = workingDirectory
        self.shellState = shellState
        self.acknowledgedActivity = acknowledgedActivity
        self.currentStep = currentStep
        self.primaryLine = primaryLine
        self.lastActivity = lastActivity
        self.resultSentence = resultSentence
        self.titleRegeneratable = titleRegeneratable
        self.plan = plan
        self.context = context
        self.turnCounts = turnCounts
        self.turnStartedAt = turnStartedAt
        self.subagents = subagents
    }

    public func withActivity(_ activity: AgentActivityState?) -> Self {
        withAgentStatus(activity.map { AgentStatus(activity: $0) })
    }

    public func withAgentStatus(
        _ agentStatus: AgentStatus?,
        activityUpdatedAt: Date? = nil
    ) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            agentProvider: agentProvider,
            state: state,
            agentStatus: agentStatus,
            activityUpdatedAt: activityUpdatedAt ?? self.activityUpdatedAt,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: workingDirectory,
            shellState: shellState,
            acknowledgedActivity: acknowledgedActivity,
            currentStep: currentStep,
            resultSentence: resultSentence,
            titleRegeneratable: titleRegeneratable,
            primaryLine: primaryLine,
            lastActivity: lastActivity,
            plan: plan,
            context: context,
            turnCounts: turnCounts,
            turnStartedAt: turnStartedAt,
            subagents: subagents
        )
    }

    public func acknowledgingActivity(_ activity: AgentActivityState?) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            agentProvider: agentProvider,
            state: state,
            agentStatus: agentStatus,
            activityUpdatedAt: activityUpdatedAt,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: workingDirectory,
            shellState: shellState,
            acknowledgedActivity: activity,
            currentStep: currentStep,
            resultSentence: resultSentence,
            titleRegeneratable: titleRegeneratable,
            primaryLine: primaryLine,
            lastActivity: lastActivity,
            plan: plan,
            context: context,
            turnCounts: turnCounts,
            turnStartedAt: turnStartedAt,
            subagents: subagents
        )
    }

    public func withCurrentStep(_ step: String?) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            agentProvider: agentProvider,
            state: state,
            agentStatus: agentStatus,
            activityUpdatedAt: activityUpdatedAt,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: workingDirectory,
            shellState: shellState,
            acknowledgedActivity: acknowledgedActivity,
            currentStep: step,
            resultSentence: resultSentence,
            titleRegeneratable: titleRegeneratable,
            primaryLine: primaryLine,
            lastActivity: lastActivity,
            plan: plan,
            context: context,
            turnCounts: turnCounts,
            turnStartedAt: turnStartedAt,
            subagents: subagents
        )
    }

    public func withPrimaryLine(_ line: String?) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            agentProvider: agentProvider,
            state: state,
            agentStatus: agentStatus,
            activityUpdatedAt: activityUpdatedAt,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: workingDirectory,
            shellState: shellState,
            acknowledgedActivity: acknowledgedActivity,
            currentStep: currentStep,
            resultSentence: resultSentence,
            titleRegeneratable: titleRegeneratable,
            primaryLine: line,
            lastActivity: lastActivity,
            plan: plan,
            context: context,
            turnCounts: turnCounts,
            turnStartedAt: turnStartedAt,
            subagents: subagents
        )
    }

    public func withLastActivity(_ activity: String?) -> Self {
        Self(
            id: id,
            workspaceID: workspaceID,
            tabID: tabID,
            title: title,
            customTitle: customTitle,
            pinned: pinned,
            kind: kind,
            agentProvider: agentProvider,
            state: state,
            agentStatus: agentStatus,
            activityUpdatedAt: activityUpdatedAt,
            createdAt: createdAt,
            runtimeProcess: runtimeProcess,
            runtimeCommandLine: runtimeCommandLine,
            workingDirectory: workingDirectory,
            shellState: shellState,
            acknowledgedActivity: acknowledgedActivity,
            currentStep: currentStep,
            primaryLine: primaryLine,
            lastActivity: activity,
            plan: plan,
            context: context,
            turnCounts: turnCounts,
            turnStartedAt: turnStartedAt,
            subagents: subagents
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
        public let tabIDs: [String]
        public let sessionIDs: [TerminalSessionID]
        fileprivate init(
            groups: [WarrenDesktopProjectGroup],
            sessions: [WarrenDesktopSession],
            tabs: [ClientTab]
        ) {
            self.projectIDs = groups.map(\.project.id)
            self.workspaceIDs = groups.flatMap { $0.workspaces.map(\.id) }
            self.tabIDs = tabs.map(\.id)
            self.sessionIDs = sessions.map(\.id)
        }
    }

    public let host: WarrenDomain.Host
    public let taskGroups: [WarrenDesktopTaskGroup]
    public let groups: [WarrenDesktopProjectGroup]
    public let sessions: [WarrenDesktopSession]
    public let tabs: [ClientTab]
    public let sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID]
    /// The Host's durable split arrangements. They belong to the Host, so every
    /// client reads the same shape and a WebSocket peer never has to report one.
    public let paneGroups: [PaneGroup]
    public let tabWorkspaceIDs: [String: WorkspaceID]
    public let reconciliationKey: ReconciliationKey
    /// Lookup tables are built once at the projection boundary. SwiftUI can
    /// ask for the same relationship many times while reconciling a frame;
    /// those reads must not rescan the whole sidebar/session tree.
    private let workspacesByID: [WorkspaceID: Workspace]
    private let sessionsByID: [TerminalSessionID: WarrenDesktopSession]
    private let tabsByWorkspaceID: [WorkspaceID: [ClientTab]]
    private let firstWorkspaceID: WorkspaceID?
    private let firstWorkspaceIDByProjectID: [ProjectID: WorkspaceID]
    private let markByWorkspaceID: [WorkspaceID: WarrenActivityMark]
    private let workspaceActivitySummariesByID: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    private let activeSessionsByWorkspaceIDStorage: [WorkspaceID: [WarrenDesktopSession]]
    public let connectionState: WarrenDesktopConnectionState

    public var isConnected: Bool {
        connectionState.isConnected
    }

    /// Activity is already reduced by workspace during projection creation.
    /// Exposing the value map keeps the sidebar from rebuilding one on every
    /// body evaluation.
    public var workspaceActivities: [WorkspaceID: AgentActivityState] {
        markByWorkspaceID.mapValues(\.activityState)
    }

    /// The workspace activity summary includes the existing primary state and
    /// the number of visible tabs whose agent is actively working.
    public var workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary] {
        workspaceActivitySummariesByID
    }

    /// Live Sessions grouped by Workspace for the rich sidebar rows.
    ///
    /// Every live Session is included, Agent or plain shell, because the rich
    /// presentation makes the Session the leaf of the navigation tree: a tree
    /// that hides half of a Workspace's Sessions misreports what the Host is
    /// running. Ended Sessions are omitted; they own no runtime to navigate to.
    /// The arrangements of one Workspace, in draw order.
    public func paneGroups(in workspaceID: WorkspaceID) -> [PaneGroup] {
        paneGroups.filter { $0.workspaceID == workspaceID }
    }

    public func paneGroup(id: PaneGroupID) -> PaneGroup? {
        paneGroups.first { $0.id == id }
    }

    /// The arrangement that shows one Session. A Session is in at most one pane
    /// on one Host, so the answer is unambiguous.
    public func paneGroup(containingSession sessionID: TerminalSessionID) -> PaneGroup? {
        paneGroups.first { $0.tree.paneIndex(forSession: sessionID) != nil }
    }

    public func activeSessions(in workspaceID: WorkspaceID) -> [WarrenDesktopSession] {
        activeSessionsByWorkspaceIDStorage[workspaceID] ?? []
    }

    public var activeSessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]] {
        activeSessionsByWorkspaceIDStorage
    }

    /// Workspace IDs that have at least one active or attached terminal session.
    public var activeWorkspaceIDs: Set<WorkspaceID> {
        var result = Set<WorkspaceID>()
        for session in sessions where session.state.isActive {
            if let workspaceID = sessionWorkspaceIDs[session.id] ?? session.workspaceID {
                result.insert(workspaceID)
            }
        }
        return result
    }

    /// Count of unread notices from the notification center.
    public let unreadNoticeCount: Int

    public var firstWorkspace: Workspace? {
        firstWorkspaceID.flatMap { workspacesByID[$0] }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host
            && lhs.taskGroups == rhs.taskGroups
            && lhs.groups == rhs.groups
            && lhs.sessions == rhs.sessions
            && lhs.tabs == rhs.tabs
            && lhs.sessionWorkspaceIDs == rhs.sessionWorkspaceIDs
            && lhs.tabWorkspaceIDs == rhs.tabWorkspaceIDs
            && lhs.paneGroups == rhs.paneGroups
            && lhs.connectionState == rhs.connectionState
            && lhs.unreadNoticeCount == rhs.unreadNoticeCount
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(taskGroups)
        hasher.combine(groups)
        hasher.combine(sessions)
        hasher.combine(tabs)
        hasher.combine(sessionWorkspaceIDs)
        hasher.combine(tabWorkspaceIDs)
        hasher.combine(paneGroups)
        hasher.combine(connectionState)
        hasher.combine(unreadNoticeCount)
    }

    public init(
        host: WarrenDomain.Host,
        groups: [WarrenDesktopProjectGroup],
        tasks: [WarrenTask] = [],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        connectionState: WarrenDesktopConnectionState = .attached,
        paneGroups: [PaneGroup] = [],
        unreadNoticeCount: Int = 0
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
        var workspacesByTaskID: [TaskID: [Workspace]] = [:]
        for workspace in self.groups.flatMap(\.workspaces) {
            if let taskID = workspace.taskID {
                workspacesByTaskID[taskID, default: []].append(workspace)
            }
        }
        self.taskGroups = Self.pinnedFirst(tasks) { $0.pinned }.map { task in
            WarrenDesktopTaskGroup(
                task: task,
                workspaces: Self.pinnedFirst(workspacesByTaskID[task.id] ?? []) { $0.pinned }
            )
        }
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
        self.sessionWorkspaceIDs = resolvedSessionWorkspaceIDs
        // Draw order is the Host's order, then creation, then ID, so two clients
        // that never reorder agree on which group sits where.
        self.paneGroups = paneGroups.sorted { first, second in
            if first.order != second.order { return first.order < second.order }
            if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
            return first.id.description < second.id.description
        }
        let resolvedTabWorkspaceIDs = tabWorkspaceIDs.merging(
            Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
                tab.sessionID.flatMap { resolvedSessionWorkspaceIDs[$0] }.map { (tab.id, $0) }
            }),
            uniquingKeysWith: { explicit, _ in explicit }
        )
        self.tabWorkspaceIDs = resolvedTabWorkspaceIDs

        // Assign the notice count from the projection boundary
        self.unreadNoticeCount = unreadNoticeCount

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

        // The rollup is `max()` over the shared mark, whose case order *is* the
        // priority order. It used to run over a Desktop-local copy of that
        // ladder that had no rung for attention, so a Workspace could only ever
        // report the lifecycle half of what the Host had said.
        var markByWorkspaceID: [WorkspaceID: WarrenActivityMark] = [:]
        var activeSessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]] = [:]
        for session in sessions {
            if session.state.isActive,
               let workspaceID = resolvedSessionWorkspaceIDs[session.id] ?? session.workspaceID {
                activeSessionsByWorkspaceID[workspaceID, default: []].append(session)
            }
            guard let workspaceID = session.workspaceID,
                  let mark = session.activityMark else { continue }
            markByWorkspaceID[workspaceID] = max(markByWorkspaceID[workspaceID] ?? mark, mark)
        }
        self.markByWorkspaceID = markByWorkspaceID

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
        let activityWorkspaceIDs = Set(markByWorkspaceID.keys)
            .union(activeTabCountByWorkspaceID.keys)
        for workspaceID in activityWorkspaceIDs {
            workspaceActivitySummariesByID[workspaceID] = WarrenDesktopWorkspaceActivitySummary(
                mark: markByWorkspaceID[workspaceID],
                activeTabCount: activeTabCountByWorkspaceID[workspaceID, default: 0]
            )
        }
        self.workspaceActivitySummariesByID = workspaceActivitySummariesByID
        self.activeSessionsByWorkspaceIDStorage = activeSessionsByWorkspaceID

        self.connectionState = connectionState
        self.reconciliationKey = ReconciliationKey(
            groups: groups,
            sessions: sessions,
            tabs: tabs
        )
    }

    /// Convenience initializer for callers that already have domain arrays.
    /// Grouping happens once at projection construction, not while rendering rows.
    public init(
        host: WarrenDomain.Host,
        tasks: [WarrenTask] = [],
        projects: [Project],
        workspaces: [Workspace],
        sessions: [WarrenDesktopSession] = [],
        tabs: [ClientTab] = [],
        sessionWorkspaceIDs: [TerminalSessionID: WorkspaceID] = [:],
        tabWorkspaceIDs: [String: WorkspaceID] = [:],
        connectionState: WarrenDesktopConnectionState = .attached,
        paneGroups: [PaneGroup] = [],
        unreadNoticeCount: Int = 0
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
            tasks: tasks,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            paneGroups: paneGroups,
            unreadNoticeCount: unreadNoticeCount
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

    public func session(id: TerminalSessionID) -> WarrenDesktopSession? {
        sessionsByID[id]
    }

    public func workspaceID(forTabID tabID: String) -> WorkspaceID? {
        tabWorkspaceIDs[tabID]
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

    /// Returns the most actionable state for a Workspace. A failure or input
    /// request must remain visible even when another Session is still working.
    public func activity(in workspaceID: WorkspaceID) -> AgentActivityState? {
        mark(in: workspaceID)?.activityState
    }

    public func activity(in workspaceID: WorkspaceID?) -> AgentActivityState? {
        workspaceID.flatMap(activity(in:))
    }

    /// The mark itself, for a caller that draws the rollup rather than compares
    /// it. The lifecycle accessors above drop what is being asked; a row does
    /// not get to.
    public func mark(in workspaceID: WorkspaceID) -> WarrenActivityMark? {
        markByWorkspaceID[workspaceID]
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

    /// Replaces one Session's two activity lines: what it is doing now, and what
    /// it last did. They move together because one event batch usually decides
    /// both, and a projection carries the whole tree to rebuild. `primaryLine`
    /// is the sticky copy the second line holds when both are absent.
    public func withSessionActivityLines(
        currentStep: String?,
        primaryLine: String?,
        lastActivity: String?,
        for id: TerminalSessionID
    ) -> Self {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].currentStep != currentStep
                || sessions[index].primaryLine != primaryLine
                || sessions[index].lastActivity != lastActivity else {
            return self
        }
        return copyingSessions { sessions in
            sessions[index] = sessions[index]
                .withCurrentStep(currentStep)
                .withPrimaryLine(primaryLine)
                .withLastActivity(lastActivity)
        }
    }

    /// Replaces one Session's plan, context, turn counts, and subagents. They
    /// move together because the same Agent event batch usually decides all of
    /// them, and a projection carries the whole tree to rebuild.
    public func withSessionSummary(
        plan: WarrenDesktopPlanProgress?,
        context: WarrenDesktopContextUsage?,
        turnCounts: [String],
        turnStartedAt: Date?,
        subagents: [WarrenDesktopSubagent],
        for id: TerminalSessionID
    ) -> Self {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].plan != plan
                || sessions[index].context != context
                || sessions[index].turnCounts != turnCounts
                || sessions[index].turnStartedAt != turnStartedAt
                || sessions[index].subagents != subagents else {
            return self
        }
        return copyingSessions { sessions in
            let existing = sessions[index]
            sessions[index] = WarrenDesktopSession(
                id: existing.id,
                workspaceID: existing.workspaceID,
                tabID: existing.tabID,
                title: existing.title,
                customTitle: existing.customTitle,
                pinned: existing.pinned,
                kind: existing.kind,
                agentProvider: existing.agentProvider,
                state: existing.state,
                agentStatus: existing.agentStatus,
                activityUpdatedAt: existing.activityUpdatedAt,
                createdAt: existing.createdAt,
                runtimeProcess: existing.runtimeProcess,
                runtimeCommandLine: existing.runtimeCommandLine,
                workingDirectory: existing.workingDirectory,
                shellState: existing.shellState,
                acknowledgedActivity: existing.acknowledgedActivity,
                currentStep: existing.currentStep,
                resultSentence: existing.resultSentence,
                titleRegeneratable: existing.titleRegeneratable,
                primaryLine: existing.primaryLine,
                lastActivity: existing.lastActivity,
                plan: plan,
                context: context,
                turnCounts: turnCounts,
                turnStartedAt: turnStartedAt,
                subagents: subagents
            )
        }
    }

    /// A projection whose only change is its Session list.
    ///
    /// Every field a Session mutator does not touch has to be carried over
    /// explicitly, and one that is forgotten is silently reset: a passed-through
    /// copy that dropped `paneGroups` would erase the Host's arrangements from
    /// the client on every Agent step. Building the copy in one place keeps that
    /// from depending on which mutator was called.
    private func copyingSessions(
        _ transform: (inout [WarrenDesktopSession]) -> Void
    ) -> Self {
        var nextSessions = sessions
        transform(&nextSessions)
        return Self(
            host: host,
            groups: groups,
            tasks: taskGroups.map(\.task),
            sessions: nextSessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            paneGroups: paneGroups,
            unreadNoticeCount: unreadNoticeCount
        )
    }

    /// Replaces one Session's acknowledgment without touching anything else.
    public func withSessionAcknowledgedActivity(
        _ activity: AgentActivityState?,
        for id: TerminalSessionID
    ) -> Self {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].acknowledgedActivity != activity else {
            return self
        }
        return copyingSessions { sessions in
            sessions[index] = sessions[index].acknowledgingActivity(activity)
        }
    }

    public func withSessionAgentStatus(
        _ agentStatus: AgentStatus?,
        activityUpdatedAt: Date? = nil,
        acknowledgedActivity: AgentActivityState? = nil,
        for sessionID: TerminalSessionID
    ) -> Self {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return self
        }
        let nextActivityUpdatedAt = activityUpdatedAt ?? sessions[index].activityUpdatedAt
        guard sessions[index].agentStatus != agentStatus
            || sessions[index].activityUpdatedAt != nextActivityUpdatedAt
            || sessions[index].acknowledgedActivity != acknowledgedActivity else {
            return self
        }
        return copyingSessions { sessions in
            sessions[index] = sessions[index]
                .withAgentStatus(agentStatus, activityUpdatedAt: nextActivityUpdatedAt)
                .acknowledgingActivity(acknowledgedActivity)
        }
    }
}

/// A deterministic preview/test-only fixture. Production composition should
/// construct `WarrenDesktopProjection` from live Host and Client state instead.
public struct WarrenDesktopFixture: Sendable {
    public let projection: WarrenDesktopProjection

    public var host: WarrenDomain.Host { projection.host }
    public var groups: [WarrenDesktopProjectGroup] { projection.groups }
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
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                groups: groups,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected
            )
        )
    }

    public init(
        host: WarrenDomain.Host,
        projects: [Project],
        workspaces: [Workspace],
        tabs: [ClientTab] = [],
        isConnected: Bool = true,
        sessions: [WarrenDesktopSession] = []
    ) {
        self.init(
            projection: WarrenDesktopProjection(
                host: host,
                projects: projects,
                workspaces: workspaces,
                sessions: sessions,
                tabs: tabs,
                connectionState: isConnected ? .attached : .disconnected
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
        let thirdSessionID = TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-000000000009"))

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
                kind: .claude,
                // An unread completion, so the preview exercises the
                // acknowledgment path a real Host produces rather than only the
                // plain-shell case.
                activity: .ready,
                // ...and a last activity, so the preview shows the resting second
                // line a finished Session keeps.
                lastActivity: "Ran swift test"
            ),
            // A second Agent Session on the Workspace the probe expands, so the
            // real artifact shows an unread completion beside a running one
            // rather than only the plain-shell case.
            WarrenDesktopSession(
                id: thirdSessionID,
                workspaceID: firstWorkspaceID,
                tabID: "tab-agent",
                title: "migrate schema",
                kind: .codex,
                activity: .ready,
                lastActivity: "Edited Patch.swift"
            ),
            WarrenDesktopSession(
                id: TerminalSessionID(rawValue: Self.uuid("A0000000-0000-4000-8000-00000000000A")),
                workspaceID: firstWorkspaceID,
                tabID: "tab-agent-working",
                title: "build docs",
                kind: .codex,
                activity: .working,
                currentStep: "Running swift build",
                lastActivity: "Ran swift build"
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
                    thirdSessionID: firstWorkspaceID,
                    TerminalSessionID(
                        rawValue: Self.uuid("A0000000-0000-4000-8000-00000000000A")
                    ): firstWorkspaceID,
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

    public var serializedKey: String {
        switch self {
        case .workspace(let id):
            return "workspace:\(id.description)"
        case .project(let id):
            return "project:\(id.description)"
        }
    }

    public init?(serializedKey: String) {
        let parts = serializedKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "workspace":
            guard let id = WorkspaceID(uuidString: parts[1]) else { return nil }
            self = .workspace(id)
        case "project":
            guard let id = ProjectID(uuidString: parts[1]) else { return nil }
            self = .project(id)
        default:
            return nil
        }
    }
}

/// The Host context a Session can be moved into: always a Workspace,
/// matching the daemon protocol.
public enum WarrenDesktopSessionMoveDestination: Hashable, Sendable {
    case workspace(WorkspaceID)
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
    case requestNewWorkspace(ProjectID, taskID: TaskID? = nil)
    case requestProjectWorktreeImport(ProjectID)
    case requestProjectSetupScript(ProjectID)
    case setProjectAutoImportGitWorktrees(ProjectID, Bool)
    case renameTask(TaskID, String)
    case renameProject(ProjectID, String)
    case renameWorkspace(WorkspaceID, String)
    case attachWorkspaceToTask(TaskID, WorkspaceID)
    case detachWorkspaceFromTask(TaskID, WorkspaceID)
    case deleteTask(TaskID)
    case deleteProject(ProjectID)
    case deleteWorkspace(WorkspaceID, removeLocalWorktree: Bool)
    case renameSession(TerminalSessionID, String)
    /// Names a Session again from its recent conversation, on the Host.
    case regenerateSessionTitle(TerminalSessionID)
    case setTaskPinned(TaskID, Bool)
    case setProjectPinned(ProjectID, Bool)
    case setWorkspacePinned(WorkspaceID, Bool)
    case setSessionPinned(TerminalSessionID, Bool)
    case dismissActivity(TerminalSessionID, AgentActivityState)
    case selectProject(ProjectID)
    case selectWorkspace(WorkspaceID)
    /// Opens a workspace from a double-click/explicit open gesture. Any
    /// default Shell creation is decided by the host setting at the root.
    case openWorkspace(WorkspaceID)
    case moveProject(ProjectID, before: ProjectID?)
    case moveWorkspace(WorkspaceID, before: WorkspaceID?)
    case openSession(TerminalSessionID)
    case deleteSession(TerminalSessionID)
    case selectTab(String)
    /// Leaves the current scope with nothing on screen. The Sessions it owns
    /// keep running; only the view is emptied.
    case clearSelectedTab
    case moveTab(String, before: String?)
    case moveSession(TerminalSessionID, to: WarrenDesktopSessionMoveDestination)
    /// Creates a Shell Session. The token names this request so a caller can
    /// tell the Session it produced from any other Session that appears in
    /// the meantime; the model reports the created Session under it.
    case requestNewSession(WorkspaceID, token: UUID)
    case launchSession(WorkspaceID, TerminalSessionLaunchRequest)
    case restoreNavigation(WarrenDesktopNavigationState)
    case toggleSidebar
    case openNotifications
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
    public let tab: ClientTab
    public let font: TerminalFontPreference
    /// Whether the injected terminal surface should own AppKit keyboard focus.
    /// Overlays such as search and the command palette temporarily suppress
    /// this intent while keeping the surface mounted.
    public let wantsTerminalFocus: Bool

    public var scopeID: String {
        workspace?.id.description ?? "none"
    }

    public init(
        workspace: Workspace?,
        tab: ClientTab,
        font: TerminalFontPreference = .init(),
        wantsTerminalFocus: Bool = true
    ) {
        self.workspace = workspace
        self.tab = tab
        self.font = font
        self.wantsTerminalFocus = wantsTerminalFocus
    }
}
