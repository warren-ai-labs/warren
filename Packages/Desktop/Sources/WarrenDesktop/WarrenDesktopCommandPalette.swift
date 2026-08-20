import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

/// Pure search index for the command palette.
///
/// Keeping matching separate from the view makes the searchable fields
/// explicit and prevents SwiftUI body evaluation from becoming the source of
/// navigation rules.
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
    }

    struct Result: Identifiable, Hashable, Sendable {
        let kind: Kind
        let title: String
        let detail: String

        var id: String { kind.id }
    }

    static func results(
        for query: String,
        in projection: WarrenDesktopProjection
    ) -> [Result] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        var results: [Result] = []
        for group in projection.groups {
            appendProjectResults(
                for: group,
                query: normalizedQuery,
                projection: projection,
                into: &results
            )
        }

        for terminalGroup in projection.terminalGroups {
            appendTerminalGroupResults(
                for: terminalGroup,
                query: normalizedQuery,
                projection: projection,
                into: &results
            )
        }

        // Pending tabs do not have a Host session yet, so they are not covered
        // by the session index. Keep their visible tab titles searchable too.
        for tab in projection.tabs where tab.sessionID == nil {
            guard matches(normalizedQuery, [tab.title, tab.kind.displayName]) else {
                continue
            }
            results.append(Result(
                kind: .tab(tab.id),
                title: tab.title,
                detail: tab.kind.displayName
            ))
        }
        return Array(results.prefix(60))
    }

    private static func appendProjectResults(
        for group: WarrenDesktopProjectGroup,
        query: String,
        projection: WarrenDesktopProjection,
        into results: inout [Result]
    ) {
        let projectMatches = matches(query, [
            group.project.name,
            group.project.rootPath,
        ])
        let matchingWorkspaces = group.workspaces.filter { workspace in
            matches(query, [
                workspace.name,
                workspace.path,
                workspace.branch,
            ])
        }
        let workspaceIDs = Set(group.workspaces.map(\.id))
        let sessions = projection.sessions.filter { session in
            guard let workspaceID = projection.sessionWorkspaceIDs[session.id]
                ?? session.workspaceID else { return false }
            return workspaceIDs.contains(workspaceID)
        }
        let matchingSessions = sessions.filter {
            sessionMatches(query, session: $0, projection: projection)
        }

        guard projectMatches || !matchingWorkspaces.isEmpty || !matchingSessions.isEmpty else {
            return
        }

        results.append(Result(
            kind: .project(group.project.id),
            title: group.project.name,
            detail: group.project.rootPath
        ))

        let visibleWorkspaces = projectMatches ? group.workspaces : matchingWorkspaces
        for workspace in visibleWorkspaces {
            results.append(Result(
                kind: .workspace(workspace.id),
                title: workspace.branch?.isEmpty == false ? workspace.branch! : workspace.name,
                detail: [
                    group.project.name,
                    workspace.path,
                ].joined(separator: " · ")
            ))
        }

        for session in matchingSessions {
            let workspace = projection.sessionWorkspaceIDs[session.id]
                .flatMap(projection.workspace(id:))
                ?? session.workspaceID.flatMap(projection.workspace(id:))
            guard let workspace else {
                continue
            }
            appendSessionResult(
                session,
                context: "\(group.project.name) · \(workspace.name)",
                workspace: workspace,
                projection: projection,
                into: &results
            )
        }
    }

    private static func appendTerminalGroupResults(
        for terminalGroup: TerminalGroup,
        query: String,
        projection: WarrenDesktopProjection,
        into results: inout [Result]
    ) {
        let groupMatches = matches(query, [terminalGroup.name, terminalGroup.home])
        let matchingSessions = projection.sessions(in: terminalGroup.id).filter {
            sessionMatches(query, session: $0, projection: projection)
        }
        guard groupMatches || !matchingSessions.isEmpty else { return }

        results.append(Result(
            kind: .terminalGroup(terminalGroup.id),
            title: terminalGroup.name,
            detail: terminalGroup.home ?? ""
        ))
        for session in matchingSessions {
            appendSessionResult(
                session,
                context: terminalGroup.name,
                workspace: nil,
                projection: projection,
                into: &results
            )
        }
    }

    private static func appendSessionResult(
        _ session: WarrenDesktopSession,
        context: String,
        workspace: Workspace?,
        projection: WarrenDesktopProjection,
        into results: inout [Result]
    ) {
        let tab = session.tabID.flatMap { tabID in
            projection.tabs.first { $0.id == tabID }
        }
        let title = sessionTitle(session, tab: tab)
        let metadata = [
            context,
            session.runtimeProcess,
            session.workingDirectory,
            tab.map {
                WarrenDesktopTabTitle.displayTitle(
                    tab: $0,
                    session: session,
                    workspace: workspace
                )
            },
        ]
            .compactMap { value in
                let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty ? nil : value
            }
            .joined(separator: " · ")
        results.append(Result(
            kind: .session(session.id),
            title: title,
            detail: metadata
        ))
    }

    private static func sessionMatches(
        _ query: String,
        session: WarrenDesktopSession,
        projection: WarrenDesktopProjection
    ) -> Bool {
        let tab = session.tabID.flatMap { tabID in
            projection.tabs.first { $0.id == tabID }
        }
        let workspace = projection.sessionWorkspaceIDs[session.id]
            .flatMap(projection.workspace(id:))
            ?? session.workspaceID.flatMap(projection.workspace(id:))
        let generatedTitle = tab.map {
            WarrenDesktopTabTitle.displayTitle(
                tab: $0,
                session: session,
                workspace: workspace
            )
        }
        return matches(query, [
            session.displayTitle,
            session.title,
            session.customTitle,
            session.runtimeProcess,
            session.workingDirectory,
            tab?.title,
            generatedTitle,
        ])
    }

    private static func sessionTitle(
        _ session: WarrenDesktopSession,
        tab: ClientTab?
    ) -> String {
        let candidates = [
            session.displayTitle,
            tab?.title,
            session.kind.displayName,
        ]
        return candidates.compactMap { value in
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.first ?? "Session"
    }

    private static func matches(_ query: String, _ values: [String?]) -> Bool {
        values.contains { value in
            guard let value else { return false }
            return normalize(value).contains(query)
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    @State private var debouncedQuery = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var hasQuery: Bool {
        !debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rows: [WarrenDesktopCommandPaletteSearch.Result] {
        WarrenDesktopCommandPaletteSearch.results(for: debouncedQuery, in: projection)
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            inputRow(tokens: tokens)

            if hasQuery {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)

                if rows.isEmpty {
                    Text("No results found.")
                        .font(WarrenTypography.body)
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
                            LazyVStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                                ForEach(rows) { row in
                                    resultRow(row, tokens: tokens)
                                }
                            }
                            .padding(WarrenLayoutMetrics.commandPaletteResultsPadding)
                        }
                        .frame(maxHeight: min(resultsMaxHeight, WarrenLayoutMetrics.commandPaletteResultsMaxHeight))
                        .onChange(of: selectedIndex) { _, newIndex in
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
        .onAppear { focusSearchField() }
        .task {
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onExitCommand(perform: onDismiss)
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let value = newValue
            searchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                debouncedQuery = value
                selectedIndex = 0
            }
        }
        .onChange(of: rows.count) { _, count in
            if !rows.indices.contains(selectedIndex) {
                selectedIndex = max(0, count - 1)
            }
        }
    }

    private func inputRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            TextField("Search projects, workspaces, sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(WarrenTypography.popoverItem)
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard rows.indices.contains(selectedIndex) else { return .ignored }
                    choose(rows[selectedIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }

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
                    Text(row.title)
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(WarrenTypography.popoverMeta)
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Text(row.kind.label)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .id(row.id)
        .onHover { isHovered in
            if isHovered, let index = rows.firstIndex(where: { $0.id == row.id }) {
                selectedIndex = index
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), rows.count - 1)
        selectedIndex = next
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

    private func focusSearchField() {
        searchFocused = true
    }
}
