import Foundation
import Observation
import WarrenDomain

/// UI state machine for the desktop Git panel. It owns the panel's data
/// lifecycle (load, poll, mutations) and its local UI state (open panes,
/// expanded commits, commit and pull request forms, the open file diff).
/// The view layer only reads this model and forwards user intents to it.
@MainActor
@Observable
public final class WarrenDesktopGitPanelModel {
    public enum Action: String, Sendable {
        case pull
        case push
        case checkout
        case commit
        case prCreate
    }

    public enum Pane: String, Sendable, CaseIterable {
        case checkout
        case pr
        case changes
        case history
    }

    public enum DiffViewTab: String, Sendable {
        case diff
        case file
    }

    public enum DiffStyle: String, Sendable {
        case split
        case unified
    }

    public struct FileView: Equatable, Sendable {
        public let path: String
        public let staged: Bool
        public let commit: String?
    }

    public struct FileDiffState: Equatable, Sendable {
        public var loading = false
        public var diff = ""
        public var content = ""
        public var errorMessage: String?

        public init() {}
    }

    /// Mirrors the web client's five-minute panel poll.
    private static let pollInterval: Duration = .seconds(5 * 60)
    private static let backgroundNoticeDuration: Duration = .seconds(2)

    public private(set) var panel: WarrenDesktopGitPanel?
    public private(set) var isRefreshing = false
    public private(set) var errorMessage: String?
    public private(set) var activeAction: Action?
    public private(set) var backgroundNotice = false

    public private(set) var openPanes: Set<Pane>
    public private(set) var expandedCommits: Set<String>
    public private(set) var selectedKey: String?
    public var branchSelection: String
    public private(set) var branchTouched: Bool
    public var newBranchName = ""
    public private(set) var createBranchMode = false
    public private(set) var commitOpen = false
    public var commitMessage = ""
    public private(set) var prOpen = false
    public var prTitle = ""
    public var prBody = ""

    public private(set) var fileView: FileView?
    public private(set) var fileDiff = FileDiffState()
    public var diffViewTab: DiffViewTab
    public var diffStyle: DiffStyle

    private let client: any WarrenDesktopGitClient
    private let persistence: any WarrenDesktopGitPanelPersistence
    private var workspaceID: WorkspaceID?
    private var pollTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var diffGeneration = 0
    private var noticeTask: Task<Void, Never>?

    public init(
        client: any WarrenDesktopGitClient,
        persistence: any WarrenDesktopGitPanelPersistence = WarrenDesktopGitPanelUserDefaultsPersistence()
    ) {
        self.client = client
        self.persistence = persistence
        openPanes = Set(Pane.allCases)
        expandedCommits = []
        branchSelection = ""
        branchTouched = false
        diffViewTab = .diff
        diffStyle = .unified
    }

    // MARK: - Lifecycle

    /// Binds the model to a workspace, restores its saved UI, loads the panel
    /// immediately, and starts the background poll. Calling again with the
    /// same workspace is a no-op.
    public func activate(workspaceID: WorkspaceID) {
        guard self.workspaceID != workspaceID else { return }
        persistCurrentUI()
        self.workspaceID = workspaceID
        resetData()
        restoreUI(workspaceID: workspaceID)
        load(force: true)
        startPolling()
    }

    /// Unbinds from the workspace, persists UI state, and stops the poll.
    public func deactivate() {
        persistCurrentUI()
        workspaceID = nil
        stopPolling()
        resetData()
    }

    // MARK: - Data loading

    public func refresh() {
        load(force: true)
    }

    private func load(force: Bool) {
        guard let workspaceID = self.workspaceID else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isRefreshing = true
        errorMessage = nil
        activeAction = nil
        Task {
            do {
                let panel = try await client.panel(
                    workspaceID: workspaceID.description,
                    fetch: true,
                    force: force
                )
                guard generation == loadGeneration else { return }
                apply(panel)
            } catch {
                guard generation == loadGeneration else { return }
                isRefreshing = false
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func apply(_ panel: WarrenDesktopGitPanel) {
        self.panel = panel
        isRefreshing = false
        if !branchTouched,
           !panel.branch.isEmpty,
           panel.branches.contains(where: { !$0.remote && $0.name == panel.branch }) {
            branchSelection = panel.branch
        }
        if panel.refreshing {
            presentBackgroundNotice()
        }
    }

    private func presentBackgroundNotice() {
        backgroundNotice = true
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: Self.backgroundNoticeDuration)
            guard !Task.isCancelled else { return }
            backgroundNotice = false
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.load(force: false)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        loadGeneration &+= 1
        isRefreshing = false
    }

    private func resetData() {
        loadGeneration &+= 1
        panel = nil
        errorMessage = nil
        activeAction = nil
        isRefreshing = false
        backgroundNotice = false
        noticeTask?.cancel()
        noticeTask = nil
        selectedKey = nil
        commitOpen = false
        commitMessage = ""
        prOpen = false
        prTitle = ""
        prBody = ""
        newBranchName = ""
        createBranchMode = false
        clearFileView()
    }

    // MARK: - Mutations

    public func pull() {
        runAction(.pull) { [client] workspaceID in
            _ = try await client.pull(workspaceID: workspaceID)
        }
    }

    public func push() {
        runAction(.push) { [client] workspaceID in
            _ = try await client.push(workspaceID: workspaceID)
        }
    }

    public func checkout(branch: String, create: Bool) {
        runAction(.checkout) { [client] workspaceID in
            _ = try await client.checkout(workspaceID: workspaceID, branch: branch, create: create)
        }
    }

    public func commitAndPush(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commitOpen = false
        commitMessage = ""
        activeAction = .commit
        errorMessage = nil
        Task {
            do {
                guard let workspaceID = self.workspaceID else { return }
                _ = try await client.commit(workspaceID: workspaceID.description, message: trimmed)
                activeAction = nil
                load(force: true)
                push()
            } catch {
                activeAction = nil
                errorMessage = Self.message(for: error)
            }
        }
    }

    public func createPullRequest(title: String, body: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prOpen = false
        activeAction = .prCreate
        errorMessage = nil
        Task {
            do {
                guard let workspaceID = self.workspaceID else { return }
                _ = try await client.createPullRequest(
                    workspaceID: workspaceID.description,
                    title: trimmed,
                    body: body.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                activeAction = nil
                load(force: true)
            } catch {
                activeAction = nil
                errorMessage = Self.message(for: error)
            }
        }
    }

    private func runAction(
        _ action: Action,
        operation: @escaping @MainActor (String) async throws -> Void
    ) {
        activeAction = action
        errorMessage = nil
        Task {
            do {
                guard let workspaceID = self.workspaceID else { return }
                try await operation(workspaceID.description)
                activeAction = nil
                load(force: true)
            } catch {
                activeAction = nil
                errorMessage = Self.message(for: error)
            }
        }
    }

    // MARK: - UI state

    public func togglePane(_ pane: Pane) {
        if openPanes.contains(pane) {
            openPanes.remove(pane)
        } else {
            openPanes.insert(pane)
        }
    }

    public func toggleCommitExpanded(_ hash: String) {
        if expandedCommits.contains(hash) {
            expandedCommits.remove(hash)
        } else {
            expandedCommits.insert(hash)
        }
    }

    public func setBranchSelection(_ branch: String) {
        branchSelection = branch
        branchTouched = true
    }

    public func toggleCreateMode() {
        createBranchMode.toggle()
        newBranchName = ""
    }

    public func openCommitForm() {
        commitMessage = ""
        commitOpen = true
    }

    public func cancelCommit() {
        commitOpen = false
        commitMessage = ""
    }

    public func openPullRequestForm() {
        let commits = panel?.unmergedCommits ?? []
        prTitle = commits.first?.subject ?? panel?.branch ?? ""
        prBody = commits.map { "- \($0.subject) (\($0.short))" }.joined(separator: "\n")
        prOpen = true
    }

    public func cancelPullRequestForm() {
        prOpen = false
        prTitle = ""
        prBody = ""
    }

    public func openFile(change: WarrenDesktopGitChange, commit: String = "") {
        let key = Self.changeKey(change, commit: commit)
        if selectedKey == key {
            selectedKey = nil
            clearFileView()
            return
        }
        selectedKey = key
        setFileView(path: change.path, staged: change.staged, commit: commit.isEmpty ? nil : commit)
    }

    public func closeFileView() {
        selectedKey = nil
        clearFileView()
    }

    private func setFileView(path: String, staged: Bool, commit: String?) {
        fileView = FileView(path: path, staged: staged, commit: commit)
        diffGeneration &+= 1
        let generation = diffGeneration
        fileDiff = FileDiffState()
        fileDiff.loading = true
        Task {
            do {
                guard let workspaceID = self.workspaceID else { return }
                let result = try await client.diff(
                    workspaceID: workspaceID.description,
                    path: path,
                    staged: staged,
                    commit: commit
                )
                guard generation == diffGeneration else { return }
                fileDiff = FileDiffState()
                fileDiff.diff = result.diff
                fileDiff.content = result.content
            } catch {
                guard generation == diffGeneration else { return }
                fileDiff = FileDiffState()
                fileDiff.errorMessage = Self.message(for: error)
            }
        }
    }

    private func clearFileView() {
        fileView = nil
        diffGeneration &+= 1
        fileDiff = FileDiffState()
    }

    // MARK: - Derived presentation

    public var showsLoading: Bool {
        isRefreshing && panel == nil
    }

    public var showsSpinner: Bool {
        (isRefreshing && panel != nil) || backgroundNotice
    }

    public var busy: Bool {
        activeAction != nil
    }

    public var changeCount: Int {
        (panel?.changes ?? []).filter { $0.staged }.count
            + (panel?.changes ?? []).filter { !$0.staged }.count
    }

    public var stagedChanges: [WarrenDesktopGitChange] {
        (panel?.changes ?? []).filter(\.staged)
    }

    public var unstagedChanges: [WarrenDesktopGitChange] {
        (panel?.changes ?? []).filter { !$0.staged }
    }

    public var historyCommits: [WarrenDesktopGitCommit] {
        guard let panel else { return [] }
        if panel.mainBranch != nil && panel.operation == nil {
            return panel.unmergedCommits ?? []
        }
        return panel.commits
    }

    public var mainShort: String {
        guard let mainBranch = panel?.mainBranch else { return "" }
        if let slash = mainBranch.firstIndex(of: "/") {
            return String(mainBranch[mainBranch.index(after: slash)...])
        }
        return mainBranch
    }

    public var canCreatePullRequest: Bool {
        guard let panel,
              panel.remote != nil,
              !panel.branch.isEmpty,
              let mainBranch = panel.mainBranch,
              !mainBranch.isEmpty else { return false }
        return panel.branch != mainShort
            && !panel.merged
            && panel.operation == nil
            && panel.pullRequest == nil
            && (panel.pullRequestError ?? "").isEmpty
            && !(panel.unmergedCommits ?? []).isEmpty
    }

    public var pullRequestStateLabel: String {
        switch panel?.pullRequest?.state {
        case "open": "Open"
        case "merged": "Merged"
        case "closed": "Closed"
        default: panel?.pullRequest?.state ?? ""
        }
    }

    public var operationLabel: String {
        switch panel?.operation {
        case "rebase": "Rebase"
        case "merge": "Merge"
        case "cherry-pick": "Cherry-pick"
        case "revert": "Revert"
        default: panel?.operation ?? ""
        }
    }

    public var actionLabel: String {
        switch activeAction {
        case .pull: "Pulling"
        case .push: "Pushing"
        case .checkout: "Switching branches"
        case .commit: "Committing"
        case .prCreate: "Creating pull request"
        case nil: ""
        }
    }

    public func localBranches() -> [String] {
        (panel?.branches ?? []).filter { !$0.remote }.map(\.name)
    }

    public func remoteBranches() -> [String] {
        (panel?.branches ?? []).filter(\.remote).map(\.name)
    }

    // MARK: - Persistence

    private func restoreUI(workspaceID: WorkspaceID) {
        guard let saved = persistence.load(workspaceID: workspaceID.description) else { return }
        let restoredPanes = Set(saved.openPanes.compactMap(Pane.init(rawValue:)))
        openPanes = restoredPanes.isEmpty ? Set(Pane.allCases) : restoredPanes
        selectedKey = saved.selectedKey
        expandedCommits = Set(saved.expanded)
        if let branch = saved.branch {
            branchSelection = branch
            branchTouched = true
        }
        if let viewTab = saved.viewTab {
            diffViewTab = DiffViewTab(rawValue: viewTab) ?? .diff
        }
        if let diffStyle = saved.diffStyle {
            self.diffStyle = DiffStyle(rawValue: diffStyle) ?? .unified
        }
        if let fileView = saved.fileView {
            setFileView(path: fileView.path, staged: fileView.staged, commit: fileView.commit)
        }
    }

    private func persistCurrentUI() {
        guard let workspaceID else { return }
        persistence.save(
            WarrenDesktopGitPanelUIState(
                openPanes: openPanes.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue),
                selectedKey: selectedKey,
                expanded: Array(expandedCommits),
                branch: branchTouched ? branchSelection : nil,
                viewTab: diffViewTab.rawValue,
                diffStyle: diffStyle.rawValue,
                fileView: fileView.map {
                    WarrenDesktopGitFileViewSnapshot(
                        path: $0.path,
                        staged: $0.staged,
                        commit: $0.commit
                    )
                }
            ),
            workspaceID: workspaceID.description
        )
    }

    // MARK: - Helpers

    private static func changeKey(_ change: WarrenDesktopGitChange, commit: String) -> String {
        commit.isEmpty
            ? "\(change.staged ? "s" : "u"):\(change.path)"
            : "\(commit):\(change.path)"
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "Not connected"
        }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let detail = underlying?.localizedDescription ?? nsError.localizedDescription
        let method = nsError.userInfo["WarrenRemoteMethod"] as? String
        if let method, !method.isEmpty, detail.isEmpty == false {
            return "\(method): \(detail)"
        }
        return detail.isEmpty ? "Request failed" : detail
    }
}
