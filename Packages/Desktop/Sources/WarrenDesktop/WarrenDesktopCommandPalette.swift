import Foundation
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

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

/// Task, project, workspace, terminal-group, session, and tab search presented
/// from the AppKit-owned Command+K menu.
///
/// Rows render in one global ranking rather than in per-kind sections. Sections
/// would have to reorder results to group them, and a section that appears and
/// disappears as the query changes moves every row under the cursor; the leading
/// glyph already says what kind each row is.
struct WarrenDesktopCommandPalette: View {
    let projection: WarrenDesktopProjection
    let onAction: (WarrenDesktopAction) -> Void
    let onDismiss: () -> Void
    let width: CGFloat
    let resultsMaxHeight: CGFloat

    /// Everything one keystroke produces, written as a single value.
    ///
    /// Keeping the parsed query beside its rows means the query is parsed once
    /// per keystroke instead of once per row per frame, and it makes each
    /// keystroke one state write rather than several — SwiftUI re-evaluates the
    /// body for each write, and that cost lands on typing latency.
    private struct Outcome {
        var query: WarrenSearchQuery = WarrenSearchQuery("")
        var rows: [WarrenDesktopCommandPaletteSearch.Result] = []
        var selectedIndex = 0

        var hasQuery: Bool { !query.isEmpty }
    }

    @State private var query = ""
    @State private var searchIndex: WarrenDesktopCommandPaletteSearch.Index
    @State private var outcome: Outcome
    @State private var indexTask: Task<Void, Never>?
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
        _outcome = State(initialValue: Outcome(rows: index.suggestions()))
    }

    private var rows: [WarrenDesktopCommandPaletteSearch.Result] { outcome.rows }
    private var selectedIndex: Int { outcome.selectedIndex }
    private var hasQuery: Bool { outcome.hasQuery }

    /// Searches inside the field's own edit callback rather than reacting to the
    /// query afterwards.
    ///
    /// Querying is synchronous — a ranked pass over a Host's resources costs
    /// about a millisecond, so a background hop would only add latency and risk
    /// showing results for a query the user has already moved past. Doing it
    /// here also keeps a keystroke to a single render pass: `onChange(of:)` fires
    /// after the body has already been evaluated with the new text and the old
    /// rows, so reacting there costs an extra pass on every keystroke.
    private var queryBinding: Binding<String> {
        Binding(
            get: { query },
            set: { newValue in
                query = newValue
                outcome = search(newValue, using: searchIndex)
            }
        )
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
                    Text("No results found.")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WarrenSpacing.large)
                } else {
                    resultsList(tokens: tokens)
                }
            } else {
                idlePrompt(tokens: tokens)
            }
        }
        .frame(width: width)
        .warrenPresentationSurface(role: .commandSurface, cornerRadius: WarrenRadius.base)
        .onExitCommand(perform: onDismiss)
        .onChange(of: projection) { newProjection in
            rebuildIndex(for: newProjection)
        }
        .onDisappear { indexTask?.cancel() }
    }

    /// Rebuilding walks every project, workspace, and session, so it runs off the
    /// main actor. The Host streams roster deltas while the palette is open and a
    /// synchronous rebuild would hitch on each one.
    private func rebuildIndex(for newProjection: WarrenDesktopProjection) {
        indexTask?.cancel()
        let selectedID = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
        let querySnapshot = query
        indexTask = Task { @MainActor in
            let rebuilt = await Task.detached(priority: .userInitiated) {
                WarrenDesktopCommandPaletteSearch.Index(projection: newProjection)
            }.value
            guard !Task.isCancelled else { return }
            searchIndex = rebuilt
            var next = search(querySnapshot, using: rebuilt)
            // Keep the cursor on the row the user was already looking at.
            if let selectedID,
               let restored = next.rows.firstIndex(where: { $0.id == selectedID }) {
                next.selectedIndex = restored
            }
            outcome = next
        }
    }

    private func search(
        _ raw: String,
        using index: WarrenDesktopCommandPaletteSearch.Index
    ) -> Outcome {
        let parsed = WarrenSearchQuery(raw)
        return Outcome(
            query: parsed,
            rows: parsed.isEmpty ? index.suggestions() : index.results(for: parsed),
            selectedIndex: 0
        )
    }

    // MARK: - Layout

    private func resultsList(tokens: WarrenColorTokens) -> some View {
        ScrollViewReader { proxy in
            WarrenOverflowFadeScrollView(
                .vertical,
                fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
                surface: tokens.popoverSurface
            ) {
                LazyVStack(alignment: .leading, spacing: WarrenSpacing.hairline) {
                    ForEach(rows) { row in
                        resultRow(row, tokens: tokens)
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

    private func inputRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            WarrenDesktopCommandPaletteTextField(
                text: queryBinding,
                placeholder: "Search tasks, workspaces, sessions…  w: p: s: @blocked",
                onMove: moveSelection,
                onSubmit: chooseSelection,
                onCancel: onDismiss
            )

            if !query.isEmpty {
                Button {
                    // Through the binding, so clearing also refreshes the rows.
                    queryBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear search")
            }

            keyCap("esc", tokens: tokens)
        }
        .padding(.horizontal, WarrenLayoutMetrics.commandPaletteInputHorizontalPadding)
        .frame(height: WarrenLayoutMetrics.commandInputHeight)
        .background(tokens.popoverSurface)
    }

    private func keyCap(_ label: String, tokens: WarrenColorTokens) -> some View {
        Text(label)
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

    private func idlePrompt(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)

            Text("Start typing to search, or narrow with w: p: s: t: g: and @blocked")
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

    // MARK: - Result row

    /// One line, three fields: what it is, where it lives, and why it matched.
    ///
    /// The kind glyph carries the row's activity as colour, which is why no row
    /// spends horizontal space on a "Session" or "Working" label.
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
                rowGlyph(row, tokens: tokens)
                    .frame(width: 16, height: 16)

                highlighted(
                    row.title,
                    ranges: row.titleRanges,
                    tokens: tokens,
                    isPrimary: true
                )
                    .lineLimit(1)
                    .layoutPriority(3)

                if !row.context.isEmpty {
                    Text(row.context)
                        .font(WarrenTypography.popoverMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(2)
                }

                Spacer(minLength: WarrenSpacing.compact)

                if let evidence = row.evidence {
                    highlighted(
                        evidence.text,
                        ranges: evidence.ranges,
                        tokens: tokens,
                        isPrimary: false
                    )
                    .font(evidence.role == .path
                        ? WarrenTypography.externalIDEPath
                        : WarrenTypography.popoverMeta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                }

                // Activity is its own mark rather than the glyph's colour: the
                // glyph carries the provider, and the sidebar already uses this
                // indicator, so both surfaces read the same way.
                if case .mark(let mark) = row.status {
                    WarrenDesktopActivityIndicator(mark: mark)
                }

                if row.status == .pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityHidden(true)
                }

                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, WarrenLayoutMetrics.commandPaletteItemHorizontalPadding)
            .frame(height: WarrenLayoutMetrics.commandPaletteRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .id(row.id)
        .accessibilityLabel(accessibilityLabel(row))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A Session row leads with its provider's own mark, so the kind reads at a
    /// glance instead of every session looking like a bare terminal. Scopes with
    /// no provider keep their SF Symbol.
    @ViewBuilder
    private func rowGlyph(
        _ row: WarrenDesktopCommandPaletteSearch.Result,
        tokens: WarrenColorTokens
    ) -> some View {
        if let preset = row.providerKind.flatMap(WarrenDesktopSessionPreset.builtIn(for:)) {
            WarrenDesktopPresetIcon(preset: preset)
        } else {
            Image(systemName: row.kind.systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
        }
    }

    private func accessibilityLabel(
        _ row: WarrenDesktopCommandPaletteSearch.Result
    ) -> String {
        [
            // The provider is drawn, not written, so the label has to say it.
            row.providerKind?.displayName ?? row.kind.label,
            row.title,
            row.context,
            row.evidence?.text,
            row.status?.label,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    /// Emboldens the characters the query actually matched.
    ///
    /// Ranges always come from the index, which folded this text once at build
    /// time. Re-deriving them here would normalize a string per row per frame,
    /// and that lands directly on typing latency.
    private func highlighted(
        _ value: String,
        ranges: [Range<Int>],
        tokens: WarrenColorTokens,
        isPrimary: Bool
    ) -> Text {
        let base = isPrimary ? tokens.foreground : tokens.mutedForeground
        guard !ranges.isEmpty else { return Text(value).foregroundColor(base) }
        let segments = WarrenSearchHighlight.segments(text: value, ranges: ranges)
        guard segments.contains(where: \.isMatch) else {
            return Text(value).foregroundColor(base)
        }
        return segments.reduce(Text("")) { accumulated, segment in
            let piece = Text(segment.text)
                .foregroundColor(segment.isMatch ? tokens.foreground : base)
            return accumulated + (segment.isMatch ? piece.bold() : piece)
        }
    }


    // MARK: - Selection

    private func moveSelection(_ movement: WarrenDesktopCommandPaletteSelection.Movement) {
        guard let next = WarrenDesktopCommandPaletteSelection.index(
            after: movement,
            currentIndex: selectedIndex,
            count: rows.count
        ) else { return }
        // Arrow keys move the cursor without re-running the search, so only the
        // selection is written back.
        outcome.selectedIndex = next
    }

    private func chooseSelection() {
        guard rows.indices.contains(selectedIndex) else { return }
        choose(rows[selectedIndex])
    }

    private func choose(_ row: WarrenDesktopCommandPaletteSearch.Result) {
        let action: WarrenDesktopAction
        switch row.kind {
        case .task(let id):
            // A Task is a container: opening one means opening the work it
            // holds, so it navigates to its first Workspace.
            guard let workspace = projection.taskGroups
                .first(where: { $0.task.id == id })?
                .workspaces
                .first
            else { return }
            action = .selectWorkspace(workspace.id)
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
