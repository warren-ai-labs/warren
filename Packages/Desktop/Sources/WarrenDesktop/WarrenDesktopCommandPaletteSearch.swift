import Foundation
import WarrenClientCore
import WarrenDomain

/// Command-palette search over everything the desktop shell can navigate to.
///
/// Matching, ranking, and the query grammar live in `WarrenSearchIndex` so the
/// three Warren clients behave identically. This type only decides *what* the
/// desktop indexes and how a hit turns into a row.
enum WarrenDesktopCommandPaletteSearch {
    enum Kind: Hashable, Sendable {
        case task(TaskID)
        case project(ProjectID)
        case workspace(WorkspaceID)
        case terminalGroup(TerminalGroupID)
        case session(TerminalSessionID)
        case tab(String)

        var id: String {
            switch self {
            case .task(let id): return "task.\(id)"
            case .project(let id): return "project.\(id)"
            case .workspace(let id): return "workspace.\(id)"
            case .terminalGroup(let id): return "terminalGroup.\(id)"
            case .session(let id): return "session.\(id)"
            case .tab(let id): return "tab.\(id)"
            }
        }

        var scope: WarrenSearchScope {
            switch self {
            case .task: return .task
            case .project: return .project
            case .workspace: return .workspace
            case .terminalGroup: return .terminalGroup
            case .session: return .session
            case .tab: return .tab
            }
        }

        var label: String { scope.label }
        var sortPriority: Int { scope.sortPriority }

        var systemImage: String {
            switch self {
            case .task: return "checklist"
            case .project: return "folder"
            case .workspace: return "arrow.triangle.branch"
            case .terminalGroup: return "rectangle.stack"
            case .session: return "terminal"
            case .tab: return "rectangle"
            }
        }
    }

    enum Status: Hashable, Sendable {
        case activity(AgentActivityState)
        case pinned

        var label: String {
            switch self {
            case .activity(.working): return "Working"
            case .activity(.blocked): return "Blocked"
            case .activity(.stalled): return "Stalled"
            case .activity(.failed): return "Failed"
            case .activity(.ready): return "Ready"
            case .activity(.exited): return "Exited"
            case .pinned: return "Pinned"
            }
        }

        /// Ranking weight. Blocked work is what a user opens the palette to find,
        /// so it outranks everything, and a pin is an explicit user signal that
        /// stacks on top of whatever the agent is doing.
        static func boost(activity: AgentActivityState?, pinned: Bool) -> Int {
            let activityBoost = switch activity {
            case .blocked: 70
            case .stalled: 65
            case .failed: 60
            case .working: 50
            case .ready: 20
            case .exited, nil: 0
            }
            return activityBoost + (pinned ? 30 : 0)
        }
    }

    struct Result: Identifiable, Hashable, Sendable {
        let kind: Kind
        let title: String
        /// Which UTF8 byte ranges of `title` the query covered, resolved by the
        /// index rather than re-derived per row while rendering.
        let titleRanges: [Range<Int>]
        /// The row's ancestry, already formatted: `Warren › feature/search`.
        let context: String
        /// The field that explains the match, when it was not the title.
        let evidence: WarrenSearchEvidence?
        let status: Status?
        /// The Agent family bound to this Session, so the row can name the
        /// provider with its own mark instead of a generic terminal glyph.
        ///
        /// This reads the Agent binding, not what Warren launched: a shell the
        /// Host has promoted to Claude Code is a Claude row.
        let providerKind: TerminalSessionKind?

        var id: String { kind.id }
    }

    /// A built index plus the live status it was built against.
    ///
    /// Status is captured here rather than inside `WarrenSearchIndex` because the
    /// engine reads it through a closure: ranking and filtering by activity needs
    /// no knowledge of what Warren calls its states.
    struct Index: Sendable {
        private let core: WarrenSearchIndex<Kind>
        private let statuses: [Kind: Status]
        private let boosts: [Kind: Int]
        private let providerKinds: [Kind: TerminalSessionKind]

        var count: Int { core.count }

        init(projection: WarrenDesktopProjection) {
            var builder = Builder(projection: projection)
            builder.build()
            self.core = WarrenSearchIndex(builder.descriptors)
            self.statuses = builder.statuses
            self.boosts = builder.boosts
            self.providerKinds = builder.providerKinds
        }

        func results(for query: String, limit: Int = 60) -> [Result] {
            results(for: WarrenSearchQuery(query), limit: limit)
        }

        /// Takes an already-parsed query so a caller that needs the parsed form
        /// for its own rendering does not pay for parsing it twice.
        func results(for query: WarrenSearchQuery, limit: Int = 60) -> [Result] {
            map(core.results(
                for: query,
                limit: limit,
                boost: { boosts[$0] ?? 0 },
                accepts: { accepts($0, statuses: query.statuses) }
            ))
        }

        /// Empty-query suggestions stay deliberately narrow: only live or pinned
        /// resources appear, so the palette does not open onto a second,
        /// unranked copy of the sidebar.
        func suggestions(limit: Int = 8) -> [Result] {
            map(core.suggestions(limit: limit, boost: { boosts[$0] ?? 0 }))
        }

        private func accepts(_ kind: Kind, statuses filter: Set<String>) -> Bool {
            guard !filter.isEmpty else { return true }
            guard let status = statuses[kind] else { return false }
            return filter.contains(status.label.lowercased())
        }

        private func map(_ results: [WarrenSearchResult<Kind>]) -> [Result] {
            results.map { result in
                Result(
                    kind: result.key,
                    title: result.title,
                    titleRanges: result.titleRanges,
                    context: result.subtitle,
                    evidence: result.evidence,
                    status: statuses[result.key],
                    providerKind: providerKinds[result.key]
                )
            }
        }
    }

    static func results(
        for query: String,
        in projection: WarrenDesktopProjection
    ) -> [Result] {
        Index(projection: projection).results(for: query)
    }

    /// Walks the projection once, resolving each resource's ancestry and the
    /// textual facets a user might search it by.
    ///
    /// Only resources the shell can actually navigate to are indexed. An ended
    /// Session and a Task with no Workspace own nothing to open, so offering
    /// them as results would be a dead end.
    fileprivate struct Builder {
        let projection: WarrenDesktopProjection

        private(set) var descriptors: [WarrenSearchDescriptor<Kind>] = []
        private(set) var statuses: [Kind: Status] = [:]
        private(set) var boosts: [Kind: Int] = [:]
        private(set) var providerKinds: [Kind: TerminalSessionKind] = [:]

        private var workspaceContext: [WorkspaceID: (project: Project, workspace: Workspace)] = [:]
        private var terminalGroupsByID: [TerminalGroupID: TerminalGroup] = [:]

        init(projection: WarrenDesktopProjection) {
            self.projection = projection
        }

        mutating func build() {
            descriptors.reserveCapacity(
                projection.taskGroups.count
                    + projection.groups.count
                    + projection.terminalGroups.count
                    + projection.sessions.count
                    + projection.tabs.count
            )
            addProjectsAndWorkspaces()
            addTasks()
            addTerminalGroups()
            addSessions()
            addPendingTabs()
        }

        private mutating func add(
            _ kind: Kind,
            title: String,
            context: String = "",
            path: String? = nil,
            aliases: [String?] = [],
            contextValues: [String?] = [],
            kinds: [String?] = [],
            providerKind: TerminalSessionKind? = nil,
            status: Status? = nil,
            boost: Int = 0
        ) {
            descriptors.append(WarrenSearchDescriptor(
                key: kind,
                scope: kind.scope,
                title: title,
                subtitle: context,
                path: path,
                aliases: Self.cleaned(aliases),
                context: Self.cleaned(contextValues),
                kinds: Self.cleaned(kinds)
            ))
            if let status { statuses[kind] = status }
            if boost > 0 { boosts[kind] = boost }
            if let providerKind { providerKinds[kind] = providerKind }
        }

        private static func cleaned(_ values: [String?]) -> [String] {
            values.compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        // MARK: Projects and workspaces

        private mutating func addProjectsAndWorkspaces() {
            for group in projection.groups {
                let project = group.project
                // The project name ranks as the title, but the full path and its
                // basename are aliases so both `warren` and `warren-feature`
                // find a checkout the user only knows by directory.
                add(
                    .project(project.id),
                    title: project.name,
                    context: Self.displayPath(project.rootPath),
                    path: project.rootPath,
                    aliases: [(project.rootPath as NSString).lastPathComponent],
                    status: project.pinned ? .pinned : nil,
                    boost: project.pinned ? 30 : 0
                )
                for workspace in group.workspaces {
                    workspaceContext[workspace.id] = (project, workspace)
                    addWorkspace(workspace, in: project)
                }
            }
        }

        private mutating func addWorkspace(_ workspace: Workspace, in project: Project) {
            let title = Self.workspaceTitle(workspace)
            let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let activity = projection.activity(in: workspace.id)
            // A worktree whose branch equals its name would otherwise render as
            // `Project › review` next to a title that already says `review`.
            let context = title.lowercased() == workspace.name.lowercased()
                ? project.name
                : "\(project.name) › \(workspace.name)"
            add(
                .workspace(workspace.id),
                title: title,
                context: context,
                path: workspace.path,
                aliases: [
                    workspace.name,
                    branch,
                    (workspace.path as NSString).lastPathComponent,
                ],
                contextValues: [project.name, workspace.name, branch],
                status: activity.map(Status.activity) ?? (workspace.pinned ? .pinned : nil),
                boost: Status.boost(activity: activity, pinned: workspace.pinned)
            )
        }

        // MARK: Tasks

        /// A Task is the unit of work a user resumes, so it is searchable by the
        /// branches and projects it spans, not only by its own name.
        private mutating func addTasks() {
            for group in projection.taskGroups {
                // A Task with no Workspace has nothing to navigate to.
                guard !group.workspaces.isEmpty else { continue }
                let task = group.task
                var projectNames: [String] = []
                var branches: [String] = []
                var activity: AgentActivityState?
                for workspace in group.workspaces {
                    if let project = workspaceContext[workspace.id]?.project,
                       !projectNames.contains(project.name) {
                        projectNames.append(project.name)
                    }
                    branches.append(Self.workspaceTitle(workspace))
                    activity = Self.dominant(activity, projection.activity(in: workspace.id))
                }
                let context = projectNames.isEmpty
                    ? Self.workspaceCountLabel(group.workspaces.count)
                    : "\(projectNames.joined(separator: " · ")) · \(Self.workspaceCountLabel(group.workspaces.count))"
                add(
                    .task(task.id),
                    title: task.name,
                    context: context,
                    aliases: [task.source, task.externalID] + branches,
                    contextValues: projectNames,
                    status: activity.map(Status.activity) ?? (task.pinned ? .pinned : nil),
                    boost: Status.boost(activity: activity, pinned: task.pinned)
                )
            }
        }

        private static func workspaceCountLabel(_ count: Int) -> String {
            count == 1 ? "1 workspace" : "\(count) workspaces"
        }

        /// The state a container should report: whichever of its children is
        /// most in need of attention.
        private static func dominant(
            _ lhs: AgentActivityState?,
            _ rhs: AgentActivityState?
        ) -> AgentActivityState? {
            let left = Status.boost(activity: lhs, pinned: false)
            let right = Status.boost(activity: rhs, pinned: false)
            return right > left ? rhs : lhs
        }

        // MARK: Terminal groups

        private mutating func addTerminalGroups() {
            for group in projection.terminalGroups {
                terminalGroupsByID[group.id] = group
                let activity = projection.activity(in: group.id)
                add(
                    .terminalGroup(group.id),
                    title: group.name,
                    context: group.home.map(Self.displayPath) ?? "Standalone sessions",
                    path: group.home,
                    aliases: [group.home.map { ($0 as NSString).lastPathComponent }],
                    status: activity.map(Status.activity),
                    boost: Status.boost(activity: activity, pinned: false)
                )
            }
        }

        // MARK: Sessions

        private mutating func addSessions() {
            let tabsByID = Dictionary(
                projection.tabs.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for session in projection.sessions where session.state.isActive {
                addSession(session, tab: session.tabID.flatMap { tabsByID[$0] })
            }
        }

        private mutating func addSession(_ session: WarrenDesktopSession, tab: ClientTab?) {
            let workspaceID = projection.sessionWorkspaceIDs[session.id] ?? session.workspaceID
            let terminalGroupID = projection.sessionTerminalGroupIDs[session.id]
                ?? session.terminalGroupID
            let pair = workspaceID.flatMap { workspaceContext[$0] }
            let terminalGroup = terminalGroupID.flatMap { terminalGroupsByID[$0] }
            let context: String
            if let pair {
                context = "\(pair.project.name) › \(Self.workspaceTitle(pair.workspace))"
            } else if let terminalGroup {
                context = terminalGroup.name
            } else {
                context = ""
            }
            let title = Self.sessionTitle(session, tab: tab)
            let command = TerminalSessionPresentation.commandLabel(
                kind: session.presentedKind,
                process: session.runtimeProcess,
                commandLine: session.runtimeCommandLine
            )
            let branch = pair?.workspace.branch ?? ""
            add(
                .session(session.id),
                title: title,
                context: context,
                path: session.workingDirectory,
                aliases: [
                    Self.searchableTitle(session),
                    session.customTitle,
                    // `commandLabel` already resolves the best of the process and
                    // the command line, and it resolves empty for a shell sitting
                    // at its prompt. Indexing the bare process name on top would
                    // make every shell match "zsh" and would let that one word
                    // outrank the command line it is a prefix of.
                    command,
                    session.runtimeCommandLine,
                    tab?.title,
                    (session.workingDirectory as NSString).lastPathComponent,
                ],
                contextValues: [
                    context,
                    pair?.project.name,
                    pair?.workspace.name,
                    branch,
                    terminalGroup?.name,
                ],
                kinds: [session.presentedKind.displayName],
                providerKind: session.presentedKind,
                status: session.activity.map(Status.activity)
                    ?? (session.pinned ? .pinned : nil),
                boost: Status.boost(activity: session.activity, pinned: session.pinned)
            )
        }

        // MARK: Pending tabs

        /// A tab with no Session has no Host resource behind it, so it needs its
        /// own row. Session-backed tabs are already represented by the richer
        /// Session result.
        private mutating func addPendingTabs() {
            for tab in projection.tabs where tab.sessionID == nil {
                add(
                    .tab(tab.id),
                    title: tab.title,
                    context: "Pending \(tab.kind.displayName) tab",
                    kinds: [tab.kind.displayName],
                    providerKind: tab.kind
                )
            }
        }

        // MARK: Shared labels

        private static func workspaceTitle(_ workspace: Workspace) -> String {
            let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branch.isEmpty ? workspace.name : branch
        }

        private static func sessionTitle(
            _ session: WarrenDesktopSession,
            tab: ClientTab?
        ) -> String {
            cleaned([session.displayTitle, tab?.title, session.presentedKind.displayName])
                .first ?? "Session"
        }

        /// The Host fixes a Session's `title` at creation from its kind, so an
        /// unnamed shell carries the literal word "Shell". Indexing that would
        /// make every unnamed session match "shell" and would offer the word
        /// back as the reason it matched, which explains nothing.
        private static func searchableTitle(_ session: WarrenDesktopSession) -> String? {
            TerminalSessionPresentation.isGeneratedDefaultTitle(
                session.title,
                kind: session.presentedKind
            ) ? nil : session.title
        }

        private static func displayPath(_ path: String) -> String {
            (path as NSString).abbreviatingWithTildeInPath
        }
    }
}
