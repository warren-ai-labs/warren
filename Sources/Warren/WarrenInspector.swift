import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenTransport

// The Inspector: the region beside the terminal that shows what the work in a
// Workspace has changed (after Synara's right dock). Changes and History read
// the Host's Git panel, so they work for any Host; Files reads the checkout on
// disk and so only for a local Host.

// MARK: - Model

@MainActor
final class WarrenInspectorModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case changes, history, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .changes: "Changes"
            case .history: "History"
            case .files: "Files"
            }
        }
    }

    enum DiffState: Equatable {
        case loading
        case loaded(WarrenRemoteGitDiff)
        case failed(String)
    }

    let workspaceID: String
    var path: String
    private let client: () throws -> WarrenRemoteClient

    @Published var tab: Tab = .changes
    @Published private(set) var panel: WarrenRemoteGitPanel?
    @Published private(set) var loadError: String?
    @Published private(set) var action: String?
    @Published var actionError: String?
    @Published var commitMessage = ""
    @Published var expanded: Set<String> = []
    @Published private(set) var diffs: [String: DiffState] = [:]
    @Published var openFile: String?

    /// The +/− a loaded diff was fetched for, so an edit made after it was
    /// opened reloads it instead of showing the old text.
    private var diffSignatures: [String: String] = [:]

    init(workspaceID: String, path: String, client: @escaping () throws -> WarrenRemoteClient) {
        self.workspaceID = workspaceID
        self.path = path
        self.client = client
    }

    var changeCount: Int { panel?.changes.count ?? 0 }

    func refresh(force: Bool = false) async {
        do {
            let next = try await client().gitPanel(workspaceID: workspaceID, force: force)
            if next != panel { panel = next }
            loadError = nil
            reloadStaleDiffs()
        } catch {
            if panel == nil { loadError = error.localizedDescription }
        }
    }

    // MARK: Diffs

    static func changeKey(_ change: WarrenRemoteGitChange) -> String {
        "\(change.staged ? "index" : "tree"):\(change.path)"
    }

    static func commitKey(_ commit: WarrenRemoteGitCommit) -> String { "commit:\(commit.hash)" }

    static func commitFileKey(_ commit: WarrenRemoteGitCommit, _ file: WarrenRemoteGitChange) -> String {
        "commit:\(commit.hash):\(file.path)"
    }

    func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    func toggleDiff(key: String, path: String, staged: Bool, commit: String?, signature: String) {
        toggle(key)
        guard expanded.contains(key) else { return }
        if diffs[key] == nil || diffSignatures[key] != signature {
            loadDiff(key: key, path: path, staged: staged, commit: commit, signature: signature)
        }
    }

    private func loadDiff(key: String, path: String, staged: Bool, commit: String?, signature: String) {
        diffSignatures[key] = signature
        if case .loaded = diffs[key] {} else { diffs[key] = .loading }
        Task { @MainActor in
            do {
                let diff = try await client().gitDiff(workspaceID: workspaceID, path: path, staged: staged, commit: commit)
                diffs[key] = .loaded(diff)
            } catch {
                diffs[key] = .failed(error.localizedDescription)
            }
        }
    }

    private func reloadStaleDiffs() {
        guard let panel else { return }
        for change in panel.changes {
            let key = Self.changeKey(change)
            let signature = "\(change.added):\(change.deleted):\(change.status)"
            if expanded.contains(key), diffSignatures[key] != signature {
                loadDiff(key: key, path: change.path, staged: change.staged, commit: nil, signature: signature)
            }
        }
    }

    // MARK: Commands

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, action == nil else { return }
        run("commit") { client in
            _ = try await client.gitCommit(workspaceID: self.workspaceID, message: message)
            self.commitMessage = ""
        }
    }

    func push() { run("push") { client in _ = try await client.gitPush(workspaceID: self.workspaceID) } }

    /// Opens a pull request for the branch; the Host pushes it first if needed.
    func createPullRequest(title: String, body: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        run("pr") { client in
            _ = try await client.gitCreatePullRequest(workspaceID: self.workspaceID, title: title, body: body)
        }
    }

    /// The same rule as the Web panel: a published remote, a branch off the
    /// main line with commits of its own, no operation, and no PR yet.
    var canCreatePullRequest: Bool {
        guard let panel, panel.remote != nil, !panel.branch.isEmpty,
              let main = panel.mainBranchShortName, panel.branch != main,
              !panel.merged, panel.operation?.isEmpty ?? true,
              panel.pullRequest == nil, panel.pullRequestError == nil,
              !panel.unmergedCommits.isEmpty else { return false }
        return true
    }
    func pull() { run("pull") { client in _ = try await client.gitPull(workspaceID: self.workspaceID) } }

    private func run(_ name: String, _ body: @escaping (WarrenRemoteClient) async throws -> Void) {
        guard action == nil else { return }
        action = name
        actionError = nil
        Task { @MainActor in
            do {
                try await body(client())
            } catch {
                actionError = error.localizedDescription
            }
            action = nil
            await refresh(force: true)
        }
    }
}

// MARK: - Surface

struct WarrenInspectorSurface: View {
    @ObservedObject var inspector: WarrenInspectorModel
    let readsLocalFiles: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            header(tokens: tokens)
            Rectangle().fill(tokens.chromeDivider).frame(height: WarrenSpacing.hairline)
            Group {
                switch inspector.tab {
                case .changes: WarrenInspectorChanges(inspector: inspector)
                case .history: WarrenInspectorHistory(inspector: inspector)
                case .files:
                    if readsLocalFiles {
                        WarrenInspectorFiles(inspector: inspector)
                    } else {
                        WarrenInspectorEmpty(
                            symbol: "externaldrive.badge.icloud",
                            title: "Files are read from this Mac",
                            detail: "Open the Workspace on a local Host to browse and edit its files."
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(tokens.background)
        .task(id: inspector.workspaceID) {
            // The Host caches the panel and revalidates it behind a cached
            // answer, so a steady poll costs one small message.
            while !Task.isCancelled {
                await inspector.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 2) {
            ForEach(WarrenInspectorModel.Tab.allCases) { tab in
                let selected = inspector.tab == tab
                Button {
                    inspector.tab = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                        if tab == .changes, inspector.changeCount > 0 {
                            Text("\(inspector.changeCount)")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(tokens.mutedForeground)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(tokens.tertiaryWash, in: Capsule())
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? tokens.foreground : tokens.mutedForeground)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(selected ? tokens.tertiaryWash : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: WarrenSpacing.compact)
            if let panel = inspector.panel {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(panel.branch.isEmpty ? "detached" : panel.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
                .help(panel.upstream.map { "Tracks \($0)" } ?? "No upstream")
            }
            Button {
                Task { await inspector.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
    }
}

// MARK: - Changes

private struct WarrenInspectorChanges: View {
    @ObservedObject var inspector: WarrenInspectorModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let panel = inspector.panel {
            let staged = panel.changes.filter(\.staged)
            let unstaged = panel.changes.filter { !$0.staged }
            ScrollView {
                VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                    WarrenInspectorBranchCard(inspector: inspector, panel: panel)
                    if !panel.changes.isEmpty {
                        WarrenInspectorCommitBox(inspector: inspector, count: panel.changes.count)
                    }
                    if let error = inspector.actionError {
                        Text(error)
                            .font(WarrenTypography.supporting)
                            .foregroundStyle(tokens.destructive)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if panel.changes.isEmpty {
                        WarrenInspectorEmpty(symbol: "checkmark.circle", title: "No changes", detail: "The working tree matches \(panel.branch.isEmpty ? "HEAD" : panel.branch).")
                            .padding(.top, WarrenSpacing.large)
                    }
                    if !staged.isEmpty {
                        changeSection("Staged", changes: staged, tokens: tokens)
                    }
                    if !unstaged.isEmpty {
                        changeSection(staged.isEmpty ? "Changes" : "Not staged", changes: unstaged, tokens: tokens)
                    }
                }
                .padding(WarrenSpacing.medium)
            }
        } else if let error = inspector.loadError {
            WarrenInspectorEmpty(symbol: "exclamationmark.triangle", title: "Git is unavailable here", detail: error)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changeSection(_ title: String, changes: [WarrenRemoteGitChange], tokens: WarrenColorTokens) -> some View {
        let additions = changes.reduce(0) { $0 + $1.added }
        let deletions = changes.reduce(0) { $0 + $1.deleted }
        return VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            HStack(spacing: WarrenSpacing.small) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tokens.mutedForeground)
                Text("\(changes.count)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(tokens.mutedForeground.opacity(0.7))
                Spacer(minLength: 0)
                WarrenInspectorCounts(additions: additions, deletions: deletions)
            }
            .padding(.horizontal, WarrenSpacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(changes.enumerated()), id: \.element) { index, change in
                    if index > 0 { Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline) }
                    let key = WarrenInspectorModel.changeKey(change)
                    WarrenInspectorFileRow(
                        path: change.path,
                        detail: change.renameFrom.map { "from \($0)" },
                        status: change.status,
                        additions: change.added,
                        deletions: change.deleted,
                        expanded: inspector.expanded.contains(key)
                    ) {
                        inspector.toggleDiff(
                            key: key,
                            path: change.path,
                            staged: change.staged,
                            commit: nil,
                            signature: "\(change.added):\(change.deleted):\(change.status)"
                        )
                    }
                    if inspector.expanded.contains(key) {
                        WarrenInspectorDiffState(state: inspector.diffs[key])
                    }
                }
            }
            .background(tokens.inputSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Branch, how it stands against its upstream and the main line, any Git
/// operation in progress, and the pull request for it.
private struct WarrenInspectorBranchCard: View {
    @ObservedObject var inspector: WarrenInspectorModel
    let panel: WarrenRemoteGitPanel
    @Environment(\.colorScheme) private var colorScheme
    @State private var composingPR = false
    @State private var prTitle = ""
    @State private var prBody = ""

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                Text(panel.branch.isEmpty ? "Detached HEAD" : panel.branch)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                syncButton("Pull", symbol: "arrow.down", badge: panel.behind, action: "pull", tokens: tokens) { inspector.pull() }
                    .disabled(panel.upstream == nil)
                syncButton("Push", symbol: "arrow.up", badge: panel.ahead, action: "push", tokens: tokens) { inspector.push() }
                    .disabled(panel.remote == nil && panel.upstream == nil)
            }
            HStack(spacing: WarrenSpacing.small) {
                if let upstream = panel.upstream {
                    meta("Tracks \(upstream)", tokens: tokens)
                } else {
                    meta("Not published", tokens: tokens)
                }
                if let main = panel.mainBranchShortName, panel.branch != main {
                    Text("·").foregroundStyle(tokens.mutedForeground.opacity(0.6))
                    if panel.merged {
                        // HEAD is inside main: true of a branch that landed
                        // and of one that has not started yet, so no badge.
                        meta("No commits beyond \(main)", tokens: tokens)
                    } else {
                        meta(panel.aheadOfMain == 1 ? "1 commit ahead of \(main)" : "\(panel.aheadOfMain) commits ahead of \(main)", tokens: tokens)
                    }
                }
            }
            if let operation = panel.operation, !operation.isEmpty {
                Label("A \(operation) is in progress", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.warning)
            }
            if inspector.canCreatePullRequest {
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                if composingPR {
                    VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                        TextField("Title", text: $prTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                        TextField("Description", text: $prBody, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(2...6)
                        HStack {
                            Spacer(minLength: 0)
                            Button("Cancel") { composingPR = false }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                            Button {
                                inspector.createPullRequest(title: prTitle, body: prBody)
                                composingPR = false
                            } label: {
                                Text("Create")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.background)
                                    .padding(.horizontal, 10)
                                    .frame(height: 22)
                                    .background(tokens.foreground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } else {
                    Button {
                        prTitle = panel.unmergedCommits.last?.subject ?? ""
                        prBody = panel.unmergedCommits.count > 1
                            ? panel.unmergedCommits.reversed().map { "- \($0.subject)" }.joined(separator: "\n")
                            : ""
                        composingPR = true
                    } label: {
                        HStack(spacing: WarrenSpacing.small) {
                            if inspector.action == "pr" {
                                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "arrow.triangle.pull").font(.system(size: 11))
                            }
                            Text("Create pull request into \(panel.mainBranchShortName ?? "main")")
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(tokens.link)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inspector.action != nil)
                }
            }
            if let pr = panel.pullRequest {
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.small) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 11))
                            .foregroundStyle(pr.state.lowercased() == "merged" ? tokens.success : tokens.info)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pr.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text([pr.number > 0 ? "#\(pr.number)" : nil, pr.draft ? "Draft" : pr.state.capitalized, pr.base.isEmpty ? nil : "into \(pr.base)"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(tokens.mutedForeground)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pr.url)
            }
        }
        .padding(WarrenSpacing.medium)
        .background(tokens.inputSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
    }

    private func meta(_ text: String, tokens: WarrenColorTokens) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tokens.mutedForeground)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func syncButton(
        _ title: String,
        symbol: String,
        badge: Int,
        action name: String,
        tokens: WarrenColorTokens,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 3) {
                if inspector.action == name {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
            }
            .foregroundStyle(badge > 0 ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(tokens.tertiaryWash, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(inspector.action != nil)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Commit everything in the working tree, as the Web panel does. ⌘Return
/// commits from the field.
private struct WarrenInspectorCommitBox: View {
    @ObservedObject var inspector: WarrenInspectorModel
    let count: Int
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let canCommit = !inspector.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inspector.action == nil
        VStack(alignment: .leading, spacing: 0) {
            TextField("Commit message", text: $inspector.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.top, 10)
                .padding(.bottom, WarrenSpacing.small)
                .onSubmit { if canCommit { inspector.commit() } }
            HStack {
                Text(count == 1 ? "Commits 1 file" : "Commits all \(count) files")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
                Button {
                    inspector.commit()
                } label: {
                    HStack(spacing: 4) {
                        if inspector.action == "commit" {
                            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        }
                        Text("Commit")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(canCommit ? tokens.background : tokens.mutedForeground)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(canCommit ? tokens.foreground : tokens.tertiaryWash, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Commit (⌘Return)")
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.bottom, WarrenSpacing.compact)
        }
        .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? tokens.focusRing.opacity(0.6) : tokens.border, lineWidth: WarrenSpacing.hairline)
        )
    }
}

// MARK: - History

private struct WarrenInspectorHistory: View {
    @ObservedObject var inspector: WarrenInspectorModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let panel = inspector.panel {
            let unmerged = Set(panel.unmergedCommits.map(\.hash))
            let earlier = panel.commits.filter { !unmerged.contains($0.hash) }
            ScrollView {
                VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                    if !panel.unmergedCommits.isEmpty {
                        section(
                            panel.mainBranchShortName.map { "Not on \($0)" } ?? "This branch",
                            commits: panel.unmergedCommits,
                            highlighted: true,
                            tokens: tokens
                        )
                    }
                    if !earlier.isEmpty {
                        section(panel.unmergedCommits.isEmpty ? "Recent" : "Earlier", commits: earlier, highlighted: false, tokens: tokens)
                    }
                    if panel.commits.isEmpty && panel.unmergedCommits.isEmpty {
                        WarrenInspectorEmpty(symbol: "clock", title: "No commits yet", detail: "Commits on this branch appear here.")
                            .padding(.top, WarrenSpacing.large)
                    }
                }
                .padding(WarrenSpacing.medium)
            }
        } else if let error = inspector.loadError {
            WarrenInspectorEmpty(symbol: "exclamationmark.triangle", title: "Git is unavailable here", detail: error)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ title: String, commits: [WarrenRemoteGitCommit], highlighted: Bool, tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            HStack(spacing: WarrenSpacing.small) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tokens.mutedForeground)
                Text("\(commits.count)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(tokens.mutedForeground.opacity(0.7))
            }
            .padding(.horizontal, WarrenSpacing.xs)
            VStack(spacing: 0) {
                ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                    if index > 0 { Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline) }
                    commitRow(commit, highlighted: highlighted, tokens: tokens)
                }
            }
            .background(tokens.inputSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private func commitRow(_ commit: WarrenRemoteGitCommit, highlighted: Bool, tokens: WarrenColorTokens) -> some View {
        let key = WarrenInspectorModel.commitKey(commit)
        let open = inspector.expanded.contains(key)
        Button {
            inspector.toggle(key)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.compact) {
                Circle()
                    .fill(highlighted ? tokens.info : tokens.mutedForeground.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(commit.subject)
                        .font(.system(size: 12.5))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(open ? nil : 1)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(commit.short).font(.system(size: 11, design: .monospaced))
                        Text("·")
                        Text(commit.author).lineLimit(1)
                        if let time = commit.time {
                            Text("·")
                            Text(time, format: .relative(presentation: .named))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                }
                Spacer(minLength: 0)
                if !commit.files.isEmpty {
                    WarrenInspectorCounts(
                        additions: commit.files.reduce(0) { $0 + $1.added },
                        deletions: commit.files.reduce(0) { $0 + $1.deleted }
                    )
                }
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenInspectorRowStyle())
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
        if open {
            VStack(spacing: 0) {
                ForEach(commit.files, id: \.self) { file in
                    let fileKey = WarrenInspectorModel.commitFileKey(commit, file)
                    Rectangle().fill(tokens.border.opacity(0.6)).frame(height: WarrenSpacing.hairline)
                    WarrenInspectorFileRow(
                        path: file.path,
                        detail: nil,
                        status: file.status,
                        additions: file.added,
                        deletions: file.deleted,
                        expanded: inspector.expanded.contains(fileKey),
                        indent: 14
                    ) {
                        inspector.toggleDiff(key: fileKey, path: file.path, staged: false, commit: commit.hash, signature: commit.hash)
                    }
                    if inspector.expanded.contains(fileKey) {
                        WarrenInspectorDiffState(state: inspector.diffs[fileKey])
                    }
                }
            }
            .background(tokens.background.opacity(0.35))
        }
    }
}

// MARK: - Shared rows

private struct WarrenInspectorFileRow: View {
    let path: String
    let detail: String?
    let status: String
    let additions: Int
    let deletions: Int
    let expanded: Bool
    var indent: CGFloat = 0
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        Button(action: action) {
            HStack(spacing: WarrenSpacing.compact) {
                WarrenFileIcon(name: name, isDirectory: false)
                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(status == "D" ? tokens.mutedForeground : tokens.foreground)
                        .strikethrough(status == "D", color: tokens.mutedForeground)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(detail ?? directory)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: WarrenSpacing.small)
                WarrenInspectorCounts(additions: additions, deletions: deletions)
                WarrenInspectorStatus(status: status)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.leading, WarrenSpacing.medium + indent)
            .padding(.trailing, WarrenSpacing.medium)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenInspectorRowStyle())
        .help(path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

/// The porcelain status as one letter in its colour: Added, Modified,
/// Deleted, Renamed, Untracked.
private struct WarrenInspectorStatus: View {
    let status: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let letter = status == "?" || status == "??" ? "U" : String(status.prefix(1))
        let tint: Color = switch letter {
        case "A", "U": tokens.success
        case "D": tokens.destructive
        case "R", "C": tokens.info
        default: tokens.warning
        }
        Text(letter.isEmpty ? "M" : letter)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 12)
    }
}

private struct WarrenInspectorCounts: View {
    let additions: Int
    let deletions: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if additions > 0 || deletions > 0 {
            HStack(spacing: 4) {
                if additions > 0 { Text("+\(additions)").foregroundStyle(tokens.success) }
                if deletions > 0 { Text("−\(deletions)").foregroundStyle(tokens.destructive) }
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}

private struct WarrenInspectorRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        configuration.label
            .background(configuration.isPressed ? tokens.fillHover : (hovering ? tokens.fillHover.opacity(0.6) : Color.clear))
            .onHover { hovering = $0 }
    }
}

struct WarrenInspectorEmpty: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: WarrenSpacing.compact) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(tokens.mutedForeground.opacity(0.8))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.foreground.opacity(0.85))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WarrenSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A file's mark: its Seti icon where the SVG decodes, a document glyph
/// otherwise.
struct WarrenFileIcon: View {
    let name: String
    let isDirectory: Bool
    var open = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Group {
            if isDirectory {
                Image(systemName: open ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground.opacity(0.75))
            } else if let image = WarrenSetiIcons.image(for: name) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - Diff

private struct WarrenInspectorDiffState: View {
    let state: WarrenInspectorModel.DiffState?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Group {
            switch state {
            case .loaded(let diff):
                if diff.diff.isEmpty {
                    Text(diff.content.isEmpty ? "No textual changes." : "Binary or unchanged content.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(WarrenSpacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    WarrenDiffView(diff: diff.diff, truncated: diff.diffTruncated)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.destructive)
                    .padding(WarrenSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loading, nil:
                ProgressView().controlSize(.small).padding(WarrenSpacing.medium).frame(maxWidth: .infinity)
            }
        }
        .background(tokens.background.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(tokens.border.opacity(0.6)).frame(height: WarrenSpacing.hairline) }
    }
}

/// A unified diff as a two-number gutter over tinted lines; hunk headers are
/// quiet separators rather than code.
struct WarrenDiffView: View {
    let diff: String
    var truncated = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewportWidth: CGFloat = 0

    struct Line: Identifiable {
        enum Kind { case context, addition, deletion, hunk }
        let id: Int
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    static func parse(_ diff: String, limit: Int = 3000) -> [Line] {
        var lines: [Line] = []
        var old = 0
        var new = 0
        var inHunk = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= limit { break }
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                // @@ -a,b +c,d @@ context
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let context = line.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                lines.append(Line(id: lines.count, kind: .hunk, old: nil, new: nil, text: context))
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                lines.append(Line(id: lines.count, kind: .addition, old: nil, new: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(Line(id: lines.count, kind: .deletion, old: old, new: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                continue
            } else if line.isEmpty, raw.endIndex == diff.endIndex {
                continue
            } else {
                lines.append(Line(id: lines.count, kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return lines
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = Self.parse(diff)
        let gutter = CGFloat(max(2, String(lines.compactMap { $0.new ?? $0.old }.max() ?? 0).count)) * 7 + 8
        ScrollView(.horizontal, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    if line.kind == .hunk {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis").font(.system(size: 9))
                            Text(line.text.isEmpty ? " " : line.text).lineLimit(1)
                        }
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.8))
                        .padding(.horizontal, WarrenSpacing.compact)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tokens.info.opacity(0.06))
                    } else {
                        HStack(spacing: 0) {
                            Text(line.old.map(String.init) ?? "")
                                .frame(width: gutter, alignment: .trailing)
                            Text(line.new.map(String.init) ?? "")
                                .frame(width: gutter, alignment: .trailing)
                            Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                                .frame(width: 16)
                                .foregroundStyle(line.kind == .addition ? tokens.success : line.kind == .deletion ? tokens.destructive : .clear)
                            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                                .foregroundStyle(tokens.foreground.opacity(line.kind == .context ? 0.78 : 0.95))
                                .fixedSize()
                                .padding(.trailing, WarrenSpacing.medium)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.55))
                        .frame(height: 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            line.kind == .addition ? tokens.success.opacity(0.11)
                                : line.kind == .deletion ? tokens.destructive.opacity(0.11) : Color.clear
                        )
                    }
                }
                if truncated {
                    Text("Diff truncated by the Host.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(WarrenSpacing.compact)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, WarrenSpacing.xs)
            // Short lines still tint the whole row.
            .frame(minWidth: viewportWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }
}
