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
                    WarrenBranchGlyph(size: 11)
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
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack(alignment: .center, spacing: WarrenSpacing.small) {
                WarrenBranchGlyph(size: 13)
                    .foregroundStyle(tokens.mutedForeground)
                VStack(alignment: .leading, spacing: 1) {
                    Text(panel.branch.isEmpty ? "Detached HEAD" : panel.branch)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    meta(standing, tokens: tokens)
                }
                Spacer(minLength: 0)
                syncButton("Pull", symbol: "arrow.down", badge: panel.behind, action: "pull", tokens: tokens) { inspector.pull() }
                    .disabled(panel.upstream == nil)
                syncButton("Push", symbol: "arrow.up", badge: panel.ahead, action: "push", tokens: tokens) { inspector.push() }
                    .disabled(panel.remote == nil && panel.upstream == nil)
            }
            if let operation = panel.operation, !operation.isEmpty {
                Label("A \(operation) is in progress", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.warning)
            }
            if inspector.canCreatePullRequest {
                if composingPR {
                    VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                        Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
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
                                Image(systemName: "arrow.triangle.pull").font(.system(size: 10.5))
                            }
                            Text("Create pull request into \(panel.mainBranchShortName ?? "main")")
                                .font(.system(size: 11.5))
                                .lineLimit(1)
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
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: WarrenSpacing.small) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 10.5))
                            .foregroundStyle(pr.state.lowercased() == "merged" ? tokens.success : tokens.info)
                        Text(pr.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text([pr.number > 0 ? "#\(pr.number)" : nil, pr.draft ? "Draft" : pr.state.capitalized]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(tokens.mutedForeground)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help([pr.title, pr.base.isEmpty ? nil : "into \(pr.base)", pr.url].compactMap { $0 }.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
        .background(tokens.inputSurface.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
    }

    /// Upstream and the main line as one quiet line under the branch name.
    private var standing: String {
        var parts = [panel.upstream ?? "Not published"]
        if let main = panel.mainBranchShortName, panel.branch != main {
            // HEAD inside main is true of a branch that landed and of one that
            // has not started yet, so neither reads as merged.
            parts.append(panel.merged ? "even with \(main)" : "\(panel.aheadOfMain) ahead of \(main)")
        }
        return parts.joined(separator: " · ")
    }

    private func meta(_ text: String, tokens: WarrenColorTokens) -> some View {
        Text(text)
            .font(.system(size: 11))
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
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(tokens.tertiaryWash, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(inspector.action != nil)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A Git branch: a trunk with one line bending off it to a second tip, the
/// mark Git tools share. Strokes in the current foreground style.
struct WarrenBranchGlyph: View {
    var size: CGFloat = 12

    var body: some View {
        Shape().stroke(style: StrokeStyle(lineWidth: max(1, size / 11), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private struct Shape: SwiftUI.Shape {
        func path(in rect: CGRect) -> Path {
            // Laid out on a 24-point grid, then scaled into the frame.
            let unit = min(rect.width, rect.height) / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
            }
            func dot(_ x: CGFloat, _ y: CGFloat) -> CGRect {
                CGRect(x: rect.minX + (x - 2.75) * unit, y: rect.minY + (y - 2.75) * unit, width: 5.5 * unit, height: 5.5 * unit)
            }
            var path = Path()
            path.move(to: point(6, 3))
            path.addLine(to: point(6, 15.25))
            path.addEllipse(in: dot(6, 18))
            path.addEllipse(in: dot(18, 6))
            path.move(to: point(18, 8.75))
            path.addQuadCurve(to: point(8.6, 17.4), control: point(18, 17.4))
            return path
        }
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
///
/// One AppKit text view draws the whole diff: SwiftUI rows inside the
/// horizontal scroller could not be lazy, so a large diff laid out every line
/// at once and left gaps where estimated row heights met real ones.
struct WarrenDiffView: View {
    let diff: String
    var truncated = false
    @Environment(\.colorScheme) private var colorScheme

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
        VStack(alignment: .leading, spacing: 0) {
            WarrenDiffTextView(diff: diff, dark: colorScheme == .dark)
            if truncated {
                Text("Diff truncated by the Host.")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(WarrenSpacing.compact)
            }
        }
    }
}

/// The diff's rows laid out once: fixed heights, so the view knows its height
/// without laying out text, and the text view draws only what is visible.
@MainActor
struct WarrenDiffLayout {
    static let rowHeight: CGFloat = 18
    static let hunkHeight: CGFloat = 22
    static let verticalPadding = WarrenSpacing.xs
    static let markerWidth: CGFloat = 16
    static let trailingPadding = WarrenSpacing.medium
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let hunkFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    let lines: [WarrenDiffView.Line]
    /// The top of each row, from the top of the text.
    let offsets: [CGFloat]
    let numberWidth: CGFloat
    let contentWidth: CGFloat

    var gutterWidth: CGFloat { numberWidth * 2 + Self.markerWidth }
    var height: CGFloat { (offsets.last ?? 0) + Self.verticalPadding * 2 }

    init(diff: String) {
        let lines = WarrenDiffView.parse(diff).map { line in
            WarrenDiffView.Line(id: line.id, kind: line.kind, old: line.old, new: line.new, text: line.text.replacingOccurrences(of: "\t", with: "    "))
        }
        self.lines = lines
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(lines.count + 1)
        var widest = 0
        for line in lines {
            offsets.append(offsets[offsets.count - 1] + (line.kind == .hunk ? Self.hunkHeight : Self.rowHeight))
            // Wide characters take about two cells; measuring each line with
            // TextKit would mean laying out the whole diff up front.
            let cells = line.text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            widest = max(widest, cells)
        }
        self.offsets = offsets
        let digits = max(2, String(lines.compactMap { $0.new ?? $0.old }.max() ?? 0).count)
        numberWidth = CGFloat(digits) * 7 + 8
        let advance = ("0" as NSString).size(withAttributes: [.font: Self.codeFont]).width
        contentWidth = numberWidth * 2 + Self.markerWidth + CGFloat(widest) * advance + Self.trailingPadding
    }

    /// The row whose band holds a y measured from the top of the text.
    func row(at y: CGFloat) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid + 1] <= y { low = mid + 1 } else { high = mid }
        }
        return min(low, max(0, lines.count - 1))
    }
}

struct WarrenDiffTextView: NSViewRepresentable {
    let diff: String
    let dark: Bool

    @MainActor
    final class Coordinator {
        var diff: String?
        var dark: Bool?
        var layout = WarrenDiffLayout(diff: "")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WarrenDiffScrollView {
        let scrollView = WarrenDiffScrollView()
        update(scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: WarrenDiffScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WarrenDiffScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? context.coordinator.layout.contentWidth, height: context.coordinator.layout.height)
    }

    private func update(_ scrollView: WarrenDiffScrollView, coordinator: Coordinator) {
        // The Inspector polls every few seconds; an unchanged diff keeps its
        // text, selection, and scroll position.
        guard coordinator.diff != diff || coordinator.dark != dark else { return }
        if coordinator.diff != diff { coordinator.layout = WarrenDiffLayout(diff: diff) }
        coordinator.diff = diff
        coordinator.dark = dark
        scrollView.show(coordinator.layout, tokens: WarrenColorTokens.resolved(for: dark ? .dark : .light))
    }
}

/// Scrolls sideways only; a vertical swipe belongs to the Inspector's list.
final class WarrenDiffScrollView: NSScrollView {
    let textView = WarrenDiffTextContent()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ layout: WarrenDiffLayout, tokens: WarrenColorTokens) {
        textView.show(layout, tokens: tokens)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: max(contentView.bounds.width, textView.layout.contentWidth), height: textView.layout.height)
        if textView.frame.size != size { textView.setFrameSize(size) }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The diff's code as selectable text, with row tints, line numbers, and
/// +/− marks painted beside it so a copy takes only the code.
final class WarrenDiffTextContent: NSTextView {
    private(set) var layout = WarrenDiffLayout(diff: "")
    private var colors = Colors()

    private struct Colors {
        var number = NSColor.secondaryLabelColor
        var addition = NSColor.systemGreen
        var deletion = NSColor.systemRed
        var additionGround = NSColor.clear
        var deletionGround = NSColor.clear
        var hunkGround = NSColor.clear
        var hunk = NSColor.secondaryLabelColor
        var code = NSColor.labelColor
        var context = NSColor.labelColor
    }

    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        // Contiguous on purpose: non-contiguous layout guesses where text it
        // has not laid out sits, and the guess drifts off the painted rows.
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: layout.gutterWidth, y: WarrenDiffLayout.verticalPadding)
    }

    func show(_ layout: WarrenDiffLayout, tokens: WarrenColorTokens) {
        self.layout = layout
        colors = Colors(
            number: NSColor(tokens.mutedForeground).withAlphaComponent(0.55),
            addition: NSColor(tokens.success),
            deletion: NSColor(tokens.destructive),
            additionGround: NSColor(tokens.success).withAlphaComponent(0.11),
            deletionGround: NSColor(tokens.destructive).withAlphaComponent(0.11),
            hunkGround: NSColor(tokens.info).withAlphaComponent(0.06),
            hunk: NSColor(tokens.mutedForeground).withAlphaComponent(0.8),
            code: NSColor(tokens.foreground).withAlphaComponent(0.95),
            context: NSColor(tokens.foreground).withAlphaComponent(0.78)
        )
        selectedTextAttributes = [.backgroundColor: NSColor(tokens.info).withAlphaComponent(0.28)]
        textStorage?.setAttributedString(text(for: layout))
        needsDisplay = true
    }

    private func text(for layout: WarrenDiffLayout) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func paragraph(_ height: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            return style
        }
        let row = paragraph(WarrenDiffLayout.rowHeight)
        let hunkRow = paragraph(WarrenDiffLayout.hunkHeight)
        // A fixed line height sets glyphs on its floor; lift them to the middle.
        func lift(_ font: NSFont, _ height: CGFloat) -> CGFloat {
            (height - (font.ascender - font.descender)) / 2
        }
        let code: [NSAttributedString.Key: Any] = [.font: WarrenDiffLayout.codeFont, .paragraphStyle: row, .foregroundColor: colors.code,
                                                   .baselineOffset: lift(WarrenDiffLayout.codeFont, WarrenDiffLayout.rowHeight)]
        var context = code
        context[.foregroundColor] = colors.context
        let hunk: [NSAttributedString.Key: Any] = [.font: WarrenDiffLayout.hunkFont, .paragraphStyle: hunkRow, .foregroundColor: colors.hunk,
                                                   .baselineOffset: lift(WarrenDiffLayout.hunkFont, WarrenDiffLayout.hunkHeight)]
        for (index, line) in layout.lines.enumerated() {
            let attributes = line.kind == .hunk ? hunk : line.kind == .context ? context : code
            result.append(NSAttributedString(string: line.text + (index == layout.lines.count - 1 ? "" : "\n"), attributes: attributes))
        }
        return result
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !layout.lines.isEmpty else { return }
        let top = WarrenDiffLayout.verticalPadding
        let first = layout.row(at: max(0, rect.minY - top))
        let last = layout.row(at: max(0, rect.maxY - top))
        let numbers: [NSAttributedString.Key: Any] = [.font: WarrenDiffLayout.numberFont, .foregroundColor: colors.number]
        for index in first...last {
            let line = layout.lines[index]
            let band = NSRect(x: 0, y: top + layout.offsets[index], width: bounds.width, height: layout.offsets[index + 1] - layout.offsets[index])
            switch line.kind {
            case .addition: colors.additionGround.setFill(); band.fill()
            case .deletion: colors.deletionGround.setFill(); band.fill()
            case .hunk: colors.hunkGround.setFill(); band.fill()
            case .context: break
            }
            if line.kind == .hunk {
                draw("⋯", attributes: [.font: WarrenDiffLayout.hunkFont, .foregroundColor: colors.hunk], in: band, x: WarrenSpacing.compact, alignRight: false)
                continue
            }
            if let old = line.old {
                draw("\(old)", attributes: numbers, in: band, x: layout.numberWidth, alignRight: true)
            }
            if let new = line.new {
                draw("\(new)", attributes: numbers, in: band, x: layout.numberWidth * 2, alignRight: true)
            }
            if line.kind != .context {
                let mark = line.kind == .addition ? "+" : "−"
                let tint = line.kind == .addition ? colors.addition : colors.deletion
                draw(mark, attributes: [.font: WarrenDiffLayout.codeFont, .foregroundColor: tint], in: band,
                     x: layout.numberWidth * 2 + (WarrenDiffLayout.markerWidth - 7) / 2, alignRight: false)
            }
        }
    }

    private func draw(_ string: String, attributes: [NSAttributedString.Key: Any], in band: NSRect, x: CGFloat, alignRight: Bool) {
        let label = string as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: alignRight ? x - size.width : x, y: band.minY + (band.height - size.height) / 2), withAttributes: attributes)
    }
}
