import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// A focused, searchable view of every live terminal session.
///
/// Every session is a flat two-line row. Workspace order is retained as the
/// baseline so related rows remain adjacent without introducing a second
/// project/workspace hierarchy; sessions that just became ready are promoted.
struct WarrenDesktopActiveSessionsPopover: View {
    private static let recentlyReadyInterval: TimeInterval = 10 * 60

    let projection: WarrenDesktopProjection
    let onAction: (WarrenDesktopAction) -> Void
    let onDismiss: () -> Void
    let width: CGFloat
    let resultsMaxHeight: CGFloat

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focusedSessionID: TerminalSessionID?
    @Environment(\.colorScheme) private var colorScheme

    private struct SessionItem: Identifiable, Hashable {
        let session: WarrenDesktopSession
        let projectName: String?
        let workspaceName: String?
        let context: String

        var id: TerminalSessionID { session.id }

        var title: String {
            let value = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Session" : value
        }

        var searchValues: [String] {
            [
                title,
                projectName,
                workspaceName,
                context,
                session.kind.displayName,
                session.runtimeProcess,
                session.workingDirectory,
            ].compactMap { $0 }
        }
    }

    private var allItems: [SessionItem] {
        let activeSessions = projection.sessions.filter { $0.state.isActive }
        var sessionsByWorkspaceID: [WorkspaceID: [WarrenDesktopSession]] = [:]
        for session in activeSessions {
            let workspaceID = projection.sessionWorkspaceIDs[session.id] ?? session.workspaceID
            if let workspaceID {
                sessionsByWorkspaceID[workspaceID, default: []].append(session)
            }
        }

        var items: [SessionItem] = []
        var groupedSessionIDs = Set<TerminalSessionID>()
        for projectGroup in projection.groups {
            for workspace in projectGroup.workspaces {
                guard let sessions = sessionsByWorkspaceID[workspace.id], !sessions.isEmpty else {
                    continue
                }
                let workspaceTitle = Self.workspaceTitle(workspace)
                let heading = "\(projectGroup.project.name) · \(workspaceTitle)"
                let workspaceItems = sessions.map { session in
                    groupedSessionIDs.insert(session.id)
                    return SessionItem(
                        session: session,
                        projectName: projectGroup.project.name,
                        workspaceName: workspaceTitle,
                        context: heading
                    )
                }
                items.append(contentsOf: workspaceItems)
            }
        }

        // Terminal-group and otherwise unresolved sessions remain separate.
        for session in activeSessions where !groupedSessionIDs.contains(session.id) {
            let terminalGroupID = projection.sessionTerminalGroupIDs[session.id]
                ?? session.terminalGroupID
            let context = terminalGroupID
                .flatMap { projection.terminalGroup(id: $0)?.name }
                ?? "Standalone session"
            let item = SessionItem(
                session: session,
                projectName: nil,
                workspaceName: nil,
                context: context
            )
            items.append(item)
        }
        let now = Date()
        return items.enumerated()
            .sorted { lhs, rhs in
                let lhsRecentlyReady = Self.isRecentlyReady(lhs.element.session, now: now)
                let rhsRecentlyReady = Self.isRecentlyReady(rhs.element.session, now: now)
                if lhsRecentlyReady != rhsRecentlyReady {
                    return lhsRecentlyReady
                }
                // `sorted` is not required to be stable; retain the project /
                // workspace order for items with the same recency rank.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var filteredItems: [SessionItem] {
        let tokens = Self.normalizedTokens(query)
        guard !tokens.isEmpty else { return allItems }
        return allItems.filter { Self.matches(tokens, in: $0.searchValues) }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromePopoverSurface(
            title: "Active Sessions",
            width: width,
            onDismiss: onDismiss,
            role: .commandSurface,
            titleLeading: AnyView(
                Image(systemName: "bolt.horizontal")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityHidden(true)
            ),
            titleTrailing: AnyView(
                Text("\(allItems.count)")
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityLabel("\(allItems.count) active sessions")
            )
        ) {
            VStack(spacing: 0) {
                searchField(tokens: tokens)
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)

                if allItems.isEmpty {
                    emptyState(tokens: tokens)
                } else if filteredItems.isEmpty {
                    Text("No active sessions match your search")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WarrenSpacing.large)
                } else {
                    sessionsList(tokens: tokens)
                }
            }
        }
        .accessibilityIdentifier("active-sessions.popover")
        .onChange(of: query) { _ in
            selectedIndex = 0
        }
        .onChange(of: projection) { _ in
            if !filteredItems.indices.contains(selectedIndex) {
                selectedIndex = max(0, filteredItems.count - 1)
            }
        }
        .onChange(of: filteredItems.count) { count in
            if !filteredItems.indices.contains(selectedIndex) {
                selectedIndex = max(0, count - 1)
            }
        }
    }

    private func searchField(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            WarrenDesktopCommandPaletteTextField(
                text: $query,
                placeholder: "Search active sessions…",
                onMove: moveSelection,
                onSubmit: chooseSelection,
                onCancel: onDismiss
            )
            .accessibilityIdentifier("active-sessions.search")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear active session search")
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

    private func sessionsList(tokens: WarrenColorTokens) -> some View {
        ScrollViewReader { proxy in
            WarrenOverflowFadeScrollView(
                .vertical,
                fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                surface: tokens.popoverSurface
            ) {
                LazyVStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    ForEach(filteredItems) { item in
                        sessionRow(item, tokens: tokens)
                            .id(item.id)
                    }
                }
                .padding(WarrenLayoutMetrics.commandPaletteResultsPadding)
            }
            .frame(maxHeight: resultsMaxHeight)
            .onChange(of: selectedIndex) { newIndex in
                guard filteredItems.indices.contains(newIndex) else { return }
                proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
            }
        }
    }

    private func sessionRow(
        _ item: SessionItem,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = filteredItems.indices.contains(selectedIndex)
            && filteredItems[selectedIndex].id == item.id
        return Button {
            onAction(.openSession(item.session.id))
            onDismiss()
        } label: {
            HStack(spacing: WarrenSpacing.compact) {
                activityDot(for: item.session)
                    .frame(width: 18, height: 18, alignment: .center)

                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    highlightedText(item.title, tokens: tokens)
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    highlightedText(item.context, tokens: tokens)
                        .font(WarrenTypography.popoverMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(
            isSelected: isSelected,
            isFocused: focusedSessionID == item.id,
            cornerRadius: WarrenRadius.row
        ))
        .focused($focusedSessionID, equals: item.id)
        .accessibilityLabel("Open session \(item.title)")
        .accessibilityValue(item.context)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "active-session.\(item.id.description)",
            role: .button,
            label: "Session \(item.title)",
            value: item.context,
            isEnabled: true,
            isSelected: isSelected,
            action: {
                onAction(.openSession(item.session.id))
                onDismiss()
            }
        )
    }

    @ViewBuilder
    private func activityDot(
        for session: WarrenDesktopSession
    ) -> some View {
        if let activity = session.activity {
            WarrenDesktopActivityIndicator(activity: activity)
        }
    }

    private static func isRecentlyReady(
        _ session: WarrenDesktopSession,
        now: Date
    ) -> Bool {
        guard session.activity == .ready,
              let updatedAt = session.activityUpdatedAt else {
            return false
        }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age <= recentlyReadyInterval
    }

    private func emptyState(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.small) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
            Text("No active sessions")
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground)
            Text("Running sessions will appear here.")
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WarrenSpacing.large)
    }

    private func highlightedText(_ value: String, tokens: WarrenColorTokens) -> Text {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return Text(value)
        }
        return Text(value[..<range.lowerBound])
            + Text(value[range]).foregroundColor(tokens.highlight)
            + Text(value[range.upperBound...])
    }

    private func moveSelection(_ movement: WarrenDesktopCommandPaletteSelection.Movement) {
        guard let next = WarrenDesktopCommandPaletteSelection.index(
            after: movement,
            currentIndex: selectedIndex,
            count: filteredItems.count
        ) else { return }
        selectedIndex = next
    }

    private func chooseSelection() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        onAction(.openSession(filteredItems[selectedIndex].session.id))
        onDismiss()
    }

    private static func workspaceTitle(_ workspace: Workspace) -> String {
        let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? (name.isEmpty ? "Workspace" : name) : branch
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        normalized(value)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func matches(_ tokens: [String], in values: [String]) -> Bool {
        let normalizedValues = values.map(normalized)
        return tokens.allSatisfy { token in
            normalizedValues.contains { $0.contains(token) }
        }
    }

    private static func matches(_ tokens: [String], in value: String) -> Bool {
        matches(tokens, in: [value])
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
