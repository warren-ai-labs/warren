import Foundation
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

/// A flat, pre-normalized search index for command-palette navigation.
///
/// Resource relationships are resolved once when the projection changes.
/// Querying the index never rescans the project/session graph, which keeps
/// keyboard input responsive even when a Host owns many workspaces.
struct WarrenDesktopCommandPaletteSearch {
    enum Kind: Hashable, Sendable {
        case project(ProjectID)
        case workspace(WorkspaceID)
        case terminalGroup(TerminalGroupID)
        case session(TerminalSessionID)
        case tab(String)

        var id: String {
            switch self {
            case .project(let id): return "project.\(id)"
            case .workspace(let id): return "workspace.\(id)"
            case .terminalGroup(let id): return "terminalGroup.\(id)"
            case .session(let id): return "session.\(id)"
            case .tab(let id): return "tab.\(id)"
            }
        }

        var label: String {
            switch self {
            case .project: return "Project"
            case .workspace: return "Workspace"
            case .terminalGroup: return "Terminal Group"
            case .session: return "Session"
            case .tab: return "Tab"
            }
        }

        var systemImage: String {
            switch self {
            case .project: return "folder"
            case .workspace: return "arrow.triangle.branch"
            case .terminalGroup: return "rectangle.stack"
            case .session: return "terminal"
            case .tab: return "rectangle"
            }
        }

        fileprivate var sortPriority: Int {
            switch self {
            case .session: return 0
            case .workspace: return 1
            case .project: return 2
            case .terminalGroup: return 3
            case .tab: return 4
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
    }

    struct Result: Identifiable, Hashable, Sendable {
        let kind: Kind
        let title: String
        let detail: String
        let status: Status?
        fileprivate let score: Int
        fileprivate let ordinal: Int

        var id: String { kind.id }
        var accessoryLabel: String { status?.label ?? kind.label }
    }

    struct Index: Hashable, Sendable {
        private let entries: [Entry]

        init(projection: WarrenDesktopProjection) {
            var entries: [Entry] = []
            var workspaceContext: [WorkspaceID: (project: Project, workspace: Workspace)] = [:]
            var terminalGroupsByID: [TerminalGroupID: TerminalGroup] = [:]
            let tabsByID = Dictionary(uniqueKeysWithValues: projection.tabs.map { ($0.id, $0) })

            func append(
                kind: Kind,
                title: String,
                detail: String,
                path: String? = nil,
                aliases: [String] = [],
                context: [String] = [],
                status: Status? = nil,
                priorityBoost: Int = 0
            ) {
                let titleField = Field(value: title, priority: .title)
                var fields = [titleField]
                var normalizedValues = Set([titleField.normalizedValue])
                func appendFields(_ values: [String], priority: FieldPriority) {
                    for value in values {
                        let normalizedValue = Self.normalize(value)
                        guard !normalizedValue.isEmpty,
                              normalizedValues.insert(normalizedValue).inserted else {
                            continue
                        }
                        fields.append(Field(
                            normalizedValue: normalizedValue,
                            priority: priority
                        ))
                    }
                }
                appendFields(aliases, priority: .alias)
                appendFields(context, priority: .context)
                appendFields([path].compactMap { $0 }, priority: .path)
                appendFields([kind.label], priority: .kind)
                entries.append(Entry(
                    kind: kind,
                    title: title,
                    detail: detail,
                    pathDetail: path.map(Self.displayPath),
                    fields: fields,
                    status: status,
                    priorityBoost: priorityBoost,
                    ordinal: entries.count
                ))
            }

            for group in projection.groups {
                // Project: searchable by name, path and kind. Keep the primary title as the
                // project name for ranking, but expose the full path and its basename as
                // additional aliases so "warren" or "warren-feature" both match.
                let projectPathBasename = (group.project.rootPath as NSString).lastPathComponent
                append(
                    kind: .project(group.project.id),
                    title: group.project.name,
                    detail: Self.displayPath(group.project.rootPath),
                    path: group.project.rootPath,
                    aliases: [projectPathBasename, group.project.name].compactMap { $0.isEmpty ? nil : $0 },
                    context: [group.project.name, Self.displayPath(group.project.rootPath)],
                    status: group.project.pinned ? .pinned : nil,
                    priorityBoost: group.project.pinned ? 30 : 0
                )
                for workspace in group.workspaces {
                    workspaceContext[workspace.id] = (group.project, workspace)
                    let title = Self.workspaceTitle(workspace)
                    let activity = projection.activity(in: workspace.id)
                    let workspaceDetail: String
                    if title.lowercased() == workspace.name.lowercased() {
                        workspaceDetail = group.project.name
                    } else {
                        workspaceDetail = "\(group.project.name) › \(workspace.name)"
                    }
                    let pathBasename = (workspace.path as NSString).lastPathComponent
                    let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    append(
                        kind: .workspace(workspace.id),
                        title: title,
                        detail: workspaceDetail,
                        path: workspace.path,
                        aliases: [workspace.name, branch, pathBasename].compactMap { $0.isEmpty ? nil : $0 },
                        context: [group.project.name, workspace.name, branch].compactMap { $0.isEmpty ? nil : $0 },
                        status: activity.map(Status.activity)
                            ?? (workspace.pinned ? .pinned : nil),
                        priorityBoost: Self.priorityBoost(
                            activity: activity,
                            pinned: workspace.pinned
                        )
                    )
                }
            }

            for terminalGroup in projection.terminalGroups {
                terminalGroupsByID[terminalGroup.id] = terminalGroup
                let activity = projection.activity(in: terminalGroup.id)
                let homeBasename = terminalGroup.home.map { ($0 as NSString).lastPathComponent } ?? ""
                let activityLabel = activity.map { Status.activity($0).label } ?? ""
                append(
                    kind: .terminalGroup(terminalGroup.id),
                    title: terminalGroup.name,
                    detail: terminalGroup.home.map(Self.displayPath) ?? "Standalone sessions",
                    path: terminalGroup.home,
                    aliases: [homeBasename, activityLabel].compactMap { $0.isEmpty ? nil : $0 },
                    context: [terminalGroup.name],
                    status: activity.map(Status.activity),
                    priorityBoost: Self.priorityBoost(activity: activity, pinned: false)
                )
            }

            for session in projection.sessions where session.state.isActive {
                let tab = session.tabID.flatMap { tabsByID[$0] }
                let workspaceID = projection.sessionWorkspaceIDs[session.id] ?? session.workspaceID
                let terminalGroupID = projection.sessionTerminalGroupIDs[session.id]
                    ?? session.terminalGroupID
                let context: String
                let workspace: Workspace?
                if let workspaceID, let pair = workspaceContext[workspaceID] {
                    workspace = pair.workspace
                    context = "\(pair.project.name) › \(Self.workspaceTitle(pair.workspace))"
                } else if let terminalGroupID, let terminalGroup = terminalGroupsByID[terminalGroupID] {
                    workspace = nil
                    context = terminalGroup.name
                } else {
                    workspace = nil
                    context = "Session"
                }
                let generatedTitle = tab.map {
                    WarrenDesktopTabTitle.displayTitle(
                        tab: $0,
                        session: session,
                        workspace: workspace
                    )
                }
                let status = session.activity.map(Status.activity)
                    ?? (session.pinned ? .pinned : nil)
                let sessionTitleValue = Self.sessionTitle(session, tab: tab)
                let trimmedRuntime = session.runtimeProcess.trimmingCharacters(in: .whitespacesAndNewlines)
                let sessionDetail: String
                if trimmedRuntime.isEmpty
                    || trimmedRuntime.lowercased() == sessionTitleValue.lowercased()
                {
                    sessionDetail = context
                } else {
                    sessionDetail = [context, trimmedRuntime].joined(separator: " · ")
                }
                // Comprehensive aliases: expose every textual facet so "very complete"
                // search finds sessions by workspace/branch/project, directory, kind,
                // runtime, custom title, tab title, generated title and status.
                let workingDirBasename = (session.workingDirectory as NSString).lastPathComponent
                let workspaceBranch = workspace?.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let workspaceName = workspace?.name ?? ""
                let projectName: String?
                if let workspaceID, let pair = workspaceContext[workspaceID] {
                    projectName = pair.project.name
                } else if let terminalGroupID, let tg = terminalGroupsByID[terminalGroupID] {
                    projectName = tg.name
                } else {
                    projectName = nil
                }
                let activityLabel = session.activity.map { Status.activity($0).label } ?? ""
                let pinnedLabel = session.pinned ? Status.pinned.label : ""
                let kindLabel = session.kind.displayName
                append(
                    kind: .session(session.id),
                    title: sessionTitleValue,
                    detail: sessionDetail,
                    path: session.workingDirectory,
                    aliases: [
                        session.title,
                        session.customTitle,
                        session.runtimeProcess,
                        tab?.title,
                        generatedTitle,
                        workspaceName,
                        workspaceBranch,
                        workingDirBasename,
                        kindLabel,
                        activityLabel,
                        pinnedLabel,
                    ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                    context: [context, projectName, workspaceName, workspaceBranch].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                    status: status,
                    priorityBoost: Self.priorityBoost(
                        activity: session.activity,
                        pinned: session.pinned
                    )
                )
            }

            // Pending tabs have no Host session and therefore need their own
            // navigation entry. Session-backed tabs are represented once by
            // the richer session result above.
            for tab in projection.tabs where tab.sessionID == nil {
                append(
                    kind: .tab(tab.id),
                    title: tab.title,
                    detail: "Pending \(tab.kind.displayName) tab",
                    aliases: [tab.kind.displayName]
                )
            }

            self.entries = entries
        }

        func results(for query: String, limit: Int = 60) -> [Result] {
            let normalizedQuery = Self.normalize(query)
            guard !normalizedQuery.isEmpty, limit > 0 else { return [] }
            let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

            // Collect a slightly larger heap to allow visual deduplication without starving the limit.
            let heapLimit = min(limit * 2, limit + 20)
            var bestResults: [Result] = []
            bestResults.reserveCapacity(heapLimit)
            for entry in entries {
                guard let match = entry.match(query: normalizedQuery, tokens: tokens) else { continue }
                let detail = match.pathMatched
                    && entry.pathDetail != nil
                    && entry.pathDetail != entry.detail
                    ? [entry.detail, entry.pathDetail].compactMap { $0 }.joined(separator: " · ")
                    : entry.detail
                Self.insert(
                    Result(
                        kind: entry.kind,
                        title: entry.title,
                        detail: detail,
                        status: entry.status,
                        score: match.score + entry.priorityBoost,
                        ordinal: entry.ordinal
                    ),
                    into: &bestResults,
                    limit: heapLimit
                )
            }
            let sorted = bestResults.sorted(by: Self.resultPrecedes)
            // Deduplicate by identity and collapse visually identical rows. A session
            // should never appear multiple times; without collapsing, common titles like
            // "Shell" with the same context produce repeated-looking rows.
            var seenIDs = Set<String>()
            var seenVisualKeys = Set<String>()
            var deduped: [Result] = []
            deduped.reserveCapacity(limit)
            for result in sorted {
                guard seenIDs.insert(result.id).inserted else { continue }
                let visualKey = "\(result.title.lowercased())|\(result.detail.lowercased())|\(result.kind.label.lowercased())"
                guard seenVisualKeys.insert(visualKey).inserted else { continue }
                deduped.append(result)
                if deduped.count >= limit { break }
            }
            // Diversify: avoid flooding with many rows sharing the same detail context
            // (e.g., dozens of sessions in the same workspace). Cap per detail to keep
            // the list scannable while preserving ranking.
            if deduped.count > 8 {
                var perDetailCount: [String: Int] = [:]
                var diversified: [Result] = []
                diversified.reserveCapacity(limit)
                for result in deduped {
                    let detailKey = result.detail.lowercased()
                    let count = perDetailCount[detailKey, default: 0]
                    // Allow at most 3 rows per identical detail context.
                    if count >= 3 { continue }
                    perDetailCount[detailKey] = count + 1
                    diversified.append(result)
                    if diversified.count >= limit { break }
                }
                // Only use diversified if it still leaves enough distinct results.
                if diversified.count >= 8 || diversified.count == deduped.count {
                    return diversified
                }
            }
            return deduped
        }

        /// Empty-query suggestions stay deliberately narrow: only live or
        /// pinned resources appear, avoiding a second unranked resource tree.
        func suggestions(limit: Int = 8) -> [Result] {
            guard limit > 0 else { return [] }
            return entries.compactMap { entry -> Result? in
                guard entry.priorityBoost > 0 else { return nil }
                return Result(
                    kind: entry.kind,
                    title: entry.title,
                    detail: entry.detail,
                    status: entry.status,
                    score: entry.priorityBoost,
                    ordinal: entry.ordinal
                )
            }
            .sorted(by: Self.resultPrecedes)
            .prefix(limit)
            .map { $0 }
        }

        private static func resultPrecedes(_ lhs: Result, _ rhs: Result) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.kind.sortPriority != rhs.kind.sortPriority {
                return lhs.kind.sortPriority < rhs.kind.sortPriority
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.ordinal < rhs.ordinal
        }

        /// Maintains a heap whose root is the worst retained result. Search
        /// only renders a bounded result set, so sorting every match adds work
        /// without changing anything the user can see.
        private static func insert(
            _ candidate: Result,
            into heap: inout [Result],
            limit: Int
        ) {
            if heap.count < limit {
                heap.append(candidate)
                siftUpWorst(in: &heap, from: heap.count - 1)
                return
            }
            guard let worst = heap.first, resultPrecedes(candidate, worst) else { return }
            heap[0] = candidate
            siftDownWorst(in: &heap, from: 0)
        }

        private static func siftUpWorst(in heap: inout [Result], from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWorse(heap[child], than: heap[parent]) else { return }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        private static func siftDownWorst(in heap: inout [Result], from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                let right = left + 1
                var worseChild = left
                if right < heap.count, isWorse(heap[right], than: heap[left]) {
                    worseChild = right
                }
                guard isWorse(heap[worseChild], than: heap[parent]) else { return }
                heap.swapAt(parent, worseChild)
                parent = worseChild
            }
        }

        private static func isWorse(_ lhs: Result, than rhs: Result) -> Bool {
            resultPrecedes(rhs, lhs)
        }

        fileprivate static func normalize(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        private static func workspaceTitle(_ workspace: Workspace) -> String {
            let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branch.isEmpty ? workspace.name : branch
        }

        private static func sessionTitle(
            _ session: WarrenDesktopSession,
            tab: ClientTab?
        ) -> String {
            [session.displayTitle, tab?.title, session.kind.displayName]
                .compactMap { value in
                    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return value.isEmpty ? nil : value
                }
                .first ?? "Session"
        }

        private static func displayPath(_ path: String) -> String {
            (path as NSString).abbreviatingWithTildeInPath
        }

        private static func priorityBoost(
            activity: AgentActivityState?,
            pinned: Bool
        ) -> Int {
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

    static func results(
        for query: String,
        in projection: WarrenDesktopProjection
    ) -> [Result] {
        Index(projection: projection).results(for: query)
    }

    private enum FieldPriority: Int, Hashable, Sendable {
        case title = 500
        case alias = 350
        case context = 180
        case path = 80
        case kind = 20
    }

    private struct Field: Hashable, Sendable {
        let normalizedValue: String
        let words: [String]
        let priority: FieldPriority

        init(value: String, priority: FieldPriority) {
            self.init(normalizedValue: Index.normalize(value), priority: priority)
        }

        init(normalizedValue: String, priority: FieldPriority) {
            self.normalizedValue = normalizedValue
            self.words = priority == .path
                ? []
                : normalizedValue
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
            self.priority = priority
        }

        func score(for token: String) -> Int? {
            guard !normalizedValue.isEmpty else { return nil }
            if normalizedValue == token { return priority.rawValue + 400 }
            if normalizedValue.hasPrefix(token) { return priority.rawValue + 300 }
            if words.contains(where: { $0.hasPrefix(token) }) {
                return priority.rawValue + 220
            }
            if normalizedValue.contains(token) { return priority.rawValue + 100 }
            return nil
        }
    }

    private struct Entry: Hashable, Sendable {
        let kind: Kind
        let title: String
        let detail: String
        let pathDetail: String?
        let fields: [Field]
        let status: Status?
        let priorityBoost: Int
        let ordinal: Int

        func match(query: String, tokens: [String]) -> (score: Int, pathMatched: Bool)? {
            var score = 0
            var pathMatched = false
            var singleTokenScore: Int?
            for token in tokens {
                var bestScore: Int?
                var bestIsPath = false
                for field in fields {
                    guard let fieldScore = field.score(for: token) else { continue }
                    if let bestScore, fieldScore <= bestScore { continue }
                    bestScore = fieldScore
                    bestIsPath = field.priority == .path
                }
                guard let bestScore else { return nil }
                score += bestScore
                pathMatched = pathMatched || bestIsPath
                singleTokenScore = bestScore
            }

            // A contiguous phrase is more intentional than the same tokens
            // scattered across unrelated metadata fields.
            if tokens.count == 1, let singleTokenScore {
                score += singleTokenScore
            } else {
                var phraseScore: Int?
                for field in fields {
                    guard let fieldScore = field.score(for: query) else { continue }
                    if let phraseScore, fieldScore <= phraseScore { continue }
                    phraseScore = fieldScore
                }
                if let phraseScore { score += phraseScore }
            }
            return (score, pathMatched)
        }
    }
}

enum WarrenDesktopCommandPaletteSelection {
    enum Movement: Hashable, Sendable {
        case previous
        case next
        case first
        case last
    }

    static func index(
        after movement: Movement,
        currentIndex: Int,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        switch movement {
        case .previous:
            return currentIndex <= 0 ? count - 1 : min(currentIndex - 1, count - 1)
        case .next:
            return currentIndex >= count - 1 ? 0 : max(currentIndex + 1, 0)
        case .first:
            return 0
        case .last:
            return count - 1
        }
    }
}

/// Project, workspace, terminal-group, session, and tab search presented from
/// the AppKit-owned Command+K menu.
struct WarrenDesktopCommandPalette: View {
    let projection: WarrenDesktopProjection
    let onAction: (WarrenDesktopAction) -> Void
    let onDismiss: () -> Void
    let width: CGFloat
    let resultsMaxHeight: CGFloat

    @State private var query = ""
    @State private var searchIndex: WarrenDesktopCommandPaletteSearch.Index
    @State private var rows: [WarrenDesktopCommandPaletteSearch.Result]
    @State private var selectedIndex = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var indexTask: Task<Void, Never>?
    @State private var isSearching = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        projection: WarrenDesktopProjection,
        onAction: @escaping (WarrenDesktopAction) -> Void,
        onDismiss: @escaping () -> Void,
        width: CGFloat,
        resultsMaxHeight: CGFloat
    ) {
        self.projection = projection
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.width = width
        self.resultsMaxHeight = resultsMaxHeight
        let index = WarrenDesktopCommandPaletteSearch.Index(projection: projection)
        _searchIndex = State(initialValue: index)
        _rows = State(initialValue: index.suggestions())
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct GroupedSection: Identifiable {
        let priority: Int
        let title: String
        var rows: [WarrenDesktopCommandPaletteSearch.Result]
        var id: Int { priority }
    }

    private var groupedRows: [GroupedSection] {
        guard !rows.isEmpty else { return [] }
        var sections: [GroupedSection] = []
        var currentPriority: Int?
        var currentRows: [WarrenDesktopCommandPaletteSearch.Result] = []
        var currentTitle = ""
        func title(for priority: Int) -> String {
            switch priority {
            case 0: return "Sessions"
            case 1: return "Workspaces"
            case 2: return "Projects"
            case 3: return "Terminal Groups"
            default: return "Tabs"
            }
        }
        for row in rows {
            let p = row.kind.sortPriority
            if p != currentPriority {
                if let cp = currentPriority {
                    sections.append(GroupedSection(priority: cp, title: currentTitle, rows: currentRows))
                }
                currentPriority = p
                currentTitle = title(for: p)
                currentRows = [row]
            } else {
                currentRows.append(row)
            }
        }
        if let cp = currentPriority {
            sections.append(GroupedSection(priority: cp, title: currentTitle, rows: currentRows))
        }
        // If grouping fragmented the global ranking (scores interleave priorities),
        // fall back to flat rendering to preserve score order.
        if sections.count > 3 {
            let flatPriority = sections.map(\.priority)
            let isFragmented = zip(flatPriority, flatPriority.dropFirst()).contains { $0 != $1 && $0 > $1 }
            if isFragmented { return [GroupedSection(priority: 0, title: "Results", rows: rows)] }
        }
        return sections
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            inputRow(tokens: tokens)

            if !rows.isEmpty || hasQuery {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)

                if rows.isEmpty {
                    Text(isSearching ? "Searching…" : "No results found.")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WarrenSpacing.large)
                } else {
                    ScrollViewReader { proxy in
                        WarrenOverflowFadeScrollView(
                            .vertical,
                            fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                            surface: tokens.popoverSurface
                        ) {
                            LazyVStack(alignment: .leading, spacing: WarrenSpacing.small) {
                                ForEach(groupedRows, id: \.priority) { section in
                                    VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                        if groupedRows.count > 1 {
                                            Text(section.title.uppercased())
                                                .font(WarrenTypography.sectionLabel)
                                                .tracking(0.6)
                                                .foregroundStyle(tokens.mutedForeground)
                                                .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
                                                .padding(.top, section.priority == groupedRows.first?.priority ? 0 : WarrenSpacing.small)
                                        }
                                        ForEach(section.rows) { row in
                                            resultRow(row, tokens: tokens)
                                        }
                                    }
                                }
                            }
                            .padding(WarrenLayoutMetrics.commandPaletteResultsPadding)
                        }
                        .frame(maxHeight: min(resultsMaxHeight, WarrenLayoutMetrics.commandPaletteResultsMaxHeight))
                        .onChange(of: selectedIndex) { newIndex in
                            guard rows.indices.contains(newIndex) else { return }
                            proxy.scrollTo(rows[newIndex].id, anchor: .center)
                        }
                    }
                }
            } else {
                idlePrompt(tokens: tokens)
            }
        }
        .frame(width: width)
        .warrenPresentationSurface(role: .commandSurface, cornerRadius: WarrenRadius.base)
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) { newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                isSearching = false
                rows = searchIndex.suggestions()
                selectedIndex = 0
                return
            }
            // Immediate, cancellable search without artificial debounce. Previous
            // 80ms sleep added perceptible input lag on every keystroke.
            let snapshot = newValue
            let indexSnapshot = searchIndex
            // Keep the previous rows visible until the new results arrive to avoid
            // flicker; do not toggle isSearching for the query path.
            searchTask = Task { @MainActor in
                // Yield to allow cancellation of superseded keystrokes without delay.
                await Task.yield()
                guard !Task.isCancelled else { return }
                let computed = await Task.detached(priority: .userInitiated) {
                    indexSnapshot.results(for: snapshot)
                }.value
                guard !Task.isCancelled else { return }
                rows = computed
                // New query already reset to 0 at start, keep current keyboard
                // position only if it remains valid (e.g., projection refresh).
                if !rows.indices.contains(selectedIndex) {
                    selectedIndex = 0
                }
            }
        }
        .onChange(of: projection) { newProjection in
            indexTask?.cancel()
            searchTask?.cancel()
            let querySnapshot = query
            let hasQuery = !querySnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasQuery { isSearching = true }
            // Preserve the currently selected row identity across roster refreshes.
            let preservedID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
            indexTask = Task { @MainActor in
                let newIndex = await Task.detached(priority: .userInitiated) {
                    WarrenDesktopCommandPaletteSearch.Index(projection: newProjection)
                }.value
                guard !Task.isCancelled else { return }
                searchIndex = newIndex
                if hasQuery {
                    let computed = await Task.detached(priority: .userInitiated) {
                        newIndex.results(for: querySnapshot)
                    }.value
                    guard !Task.isCancelled else { return }
                    rows = computed
                    isSearching = false
                    if let preservedID, let newIdx = rows.firstIndex(where: { $0.id == preservedID }) {
                        selectedIndex = newIdx
                    } else if !rows.indices.contains(selectedIndex) {
                        selectedIndex = 0
                    }
                } else {
                    rows = newIndex.suggestions()
                    isSearching = false
                    if let preservedID, let newIdx = rows.firstIndex(where: { $0.id == preservedID }) {
                        selectedIndex = newIdx
                    } else if !rows.indices.contains(selectedIndex) {
                        selectedIndex = 0
                    }
                }
            }
        }
        .onChange(of: rows.count) { count in
            if !rows.indices.contains(selectedIndex) {
                selectedIndex = max(0, count - 1)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            indexTask?.cancel()
        }
    }

    private func inputRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            WarrenDesktopCommandPaletteTextField(
                text: $query,
                placeholder: "Search projects, workspaces, sessions…",
                onMove: moveSelection,
                onSubmit: chooseSelection,
                onCancel: onDismiss
            )

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear search")
            }

            Text("esc")
                .font(WarrenTypography.shortcut)
                .tracking(0.5)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tokens.muted)
                .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.xs)
                        .stroke(tokens.ring, lineWidth: WarrenSpacing.hairline)
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, WarrenLayoutMetrics.commandPaletteInputHorizontalPadding)
        .frame(height: WarrenLayoutMetrics.commandInputHeight)
        .background(tokens.popoverSurface)
    }

    private func idlePrompt(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)

            Text("Start typing to search projects, workspaces, sessions, and terminal groups")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarrenLayoutMetrics.commandPaletteInputHorizontalPadding)
        .frame(height: WarrenLayoutMetrics.commandPaletteIdleHeight)
        .background(tokens.popoverSurface)
        .accessibilityElement(children: .combine)
    }

    private func resultRow(
        _ row: WarrenDesktopCommandPaletteSearch.Result,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = rows.indices.contains(selectedIndex)
            && rows[selectedIndex].id == row.id
        return Button {
            choose(row)
        } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: row.kind.systemImage)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    highlightedText(row.title)
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        highlightedText(row.detail)
                            .font(WarrenTypography.popoverMeta)
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Text(row.accessoryLabel)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(accessoryColor(row.status, tokens: tokens))
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .id(row.id)
        .accessibilityLabel("\(row.kind.label), \(row.title), \(row.detail), \(row.accessoryLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func highlightedText(_ value: String) -> Text {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = value.range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive]
              ) else {
            return Text(value)
        }
        return Text(value[..<range.lowerBound])
            + Text(value[range]).bold()
            + Text(value[range.upperBound...])
    }

    private func accessoryColor(
        _ status: WarrenDesktopCommandPaletteSearch.Status?,
        tokens: WarrenColorTokens
    ) -> Color {
        switch status {
        case .activity(.working), .activity(.ready): return tokens.success
        case .activity(.blocked), .activity(.stalled): return tokens.warning
        case .activity(.failed): return tokens.destructive
        case .activity(.exited), .pinned, nil: return tokens.mutedForeground
        }
    }

    private func refreshResults(
        using index: WarrenDesktopCommandPaletteSearch.Index? = nil
    ) {
        let index = index ?? searchIndex
        rows = hasQuery
            ? index.results(for: query)
            : index.suggestions()
        selectedIndex = 0
    }

    private func moveSelection(_ movement: WarrenDesktopCommandPaletteSelection.Movement) {
        guard let next = WarrenDesktopCommandPaletteSelection.index(
            after: movement,
            currentIndex: selectedIndex,
            count: rows.count
        ) else { return }
        selectedIndex = next
    }

    private func chooseSelection() {
        guard rows.indices.contains(selectedIndex) else { return }
        choose(rows[selectedIndex])
    }

    private func choose(_ row: WarrenDesktopCommandPaletteSearch.Result) {
        let action: WarrenDesktopAction
        switch row.kind {
        case .project(let id): action = .selectProject(id)
        case .workspace(let id): action = .selectWorkspace(id)
        case .terminalGroup(let id): action = .selectTerminalGroup(id)
        case .session(let id): action = .openSession(id)
        case .tab(let id): action = .selectTab(id)
        }
        onAction(action)
        onDismiss()
    }
}
