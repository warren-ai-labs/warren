import XCTest
@testable import WarrenDesktop
import WarrenDomain

@MainActor
private final class StubGitClient: WarrenDesktopGitClient {
    var panel: WarrenDesktopGitPanel
    var diff: WarrenDesktopGitDiff
    var commandMessage = "ok"
    var error: Error?

    var panelCalls = 0
    var pullCalls = 0
    var pushCalls = 0
    var checkoutCalls: [(branch: String, create: Bool)] = []
    var commitCalls: [String] = []
    var diffCalls: [(path: String, staged: Bool, commit: String?)] = []
    var prCalls: [(title: String, body: String)] = []

    init(
        panel: WarrenDesktopGitPanel,
        diff: WarrenDesktopGitDiff = WarrenDesktopGitDiff(
            diff: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n",
            content: "new\n"
        ),
        error: Error? = nil
    ) {
        self.panel = panel
        self.diff = diff
        self.error = error
    }

    private func throwing() throws {
        if let error { throw error }
    }

    func panel(workspaceID: String, fetch: Bool, force: Bool) async throws -> WarrenDesktopGitPanel {
        panelCalls += 1
        try throwing()
        return panel
    }

    func diff(workspaceID: String, path: String, staged: Bool, commit: String?) async throws -> WarrenDesktopGitDiff {
        diffCalls.append((path, staged, commit))
        try throwing()
        return diff
    }

    func pull(workspaceID: String) async throws -> WarrenDesktopGitCommandResult {
        pullCalls += 1
        try throwing()
        return WarrenDesktopGitCommandResult(message: commandMessage)
    }

    func push(workspaceID: String) async throws -> WarrenDesktopGitCommandResult {
        pushCalls += 1
        try throwing()
        return WarrenDesktopGitCommandResult(message: commandMessage)
    }

    func checkout(workspaceID: String, branch: String, create: Bool) async throws -> WarrenDesktopGitCommandResult {
        checkoutCalls.append((branch, create))
        try throwing()
        return WarrenDesktopGitCommandResult(message: commandMessage)
    }

    func commit(workspaceID: String, message: String) async throws -> WarrenDesktopGitCommandResult {
        commitCalls.append(message)
        try throwing()
        return WarrenDesktopGitCommandResult(message: commandMessage)
    }

    func createPullRequest(workspaceID: String, title: String, body: String) async throws -> WarrenDesktopGitPullRequest {
        prCalls.append((title, body))
        try throwing()
        return WarrenDesktopGitPullRequest(title: title, body: body)
    }
}

@MainActor
private final class MemoryPersistence: WarrenDesktopGitPanelPersistence {
    var stored: [String: WarrenDesktopGitPanelUIState] = [:]

    func load(workspaceID: String) -> WarrenDesktopGitPanelUIState? {
        stored[workspaceID]
    }

    func save(_ state: WarrenDesktopGitPanelUIState, workspaceID: String) {
        stored[workspaceID] = state
    }

    func remove(workspaceID: String) {
        stored[workspaceID] = nil
    }
}

@MainActor
final class WarrenDesktopGitPanelTests: XCTestCase {
    private func samplePanel() -> WarrenDesktopGitPanel {
        WarrenDesktopGitPanel(
            workspace: "workspace",
            branch: "feature/panel",
            upstream: "origin/feature/panel",
            ahead: 2,
            behind: 1,
            aheadOfMain: 3,
            remote: "git@example.com:repo.git",
            mainBranch: "origin/main",
            merged: false,
            changes: [
                WarrenDesktopGitChange(path: "a.txt", status: "M", staged: true, added: 2, deleted: 1),
                WarrenDesktopGitChange(path: "b.txt", status: "?", staged: false),
            ],
            commits: [
                WarrenDesktopGitCommit(
                    hash: "abc123",
                    short: "abc1234",
                    subject: "feat: one",
                    author: "Ada",
                    time: "2026-08-20T10:00:00Z",
                    files: [WarrenDesktopGitChange(path: "a.txt", status: "M", added: 1, deleted: 0)]
                ),
            ],
            unmergedCommits: [
                WarrenDesktopGitCommit(
                    hash: "def456",
                    short: "def4567",
                    subject: "feat: two",
                    author: "Grace",
                    time: "2026-08-21T10:00:00Z"
                ),
            ],
            branches: [
                WarrenDesktopGitBranch(name: "feature/panel", remote: false),
                WarrenDesktopGitBranch(name: "main", remote: false),
                WarrenDesktopGitBranch(name: "origin/main", remote: true),
            ]
        )
    }

    func testActivateLoadsPanelAndSelectsCurrentBranch() async throws {
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        let workspaceID = WorkspaceID()

        model.activate(workspaceID: workspaceID)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.panel?.branch, "feature/panel")
        XCTAssertEqual(model.branchSelection, "feature/panel")
        XCTAssertFalse(model.branchTouched)
        XCTAssertEqual(model.stagedChanges.count, 1)
        XCTAssertEqual(model.unstagedChanges.count, 1)
        XCTAssertEqual(model.changeCount, 2)
        XCTAssertEqual(client.panelCalls, 1)
        model.deactivate()
    }

    func testPullAndPushRoundTripReloadsPanel() async throws {
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))

        model.pull()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.pullCalls, 1)
        XCTAssertNil(model.activeAction)
        XCTAssertNil(model.errorMessage)

        model.push()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.pushCalls, 1)
        XCTAssertNil(model.activeAction)
        model.deactivate()
    }

    func testCommitAndPushCommitsThenPushes() async throws {
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))

        model.commitAndPush(message: "  feat: commit message  ")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.commitCalls, ["feat: commit message"])
        XCTAssertEqual(client.pushCalls, 1)
        XCTAssertNil(model.activeAction)
        XCTAssertNil(model.errorMessage)
        model.deactivate()
    }

    func testCheckoutNewBranchPassesCreateFlag() async throws {
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))

        model.checkout(branch: "feat/new", create: true)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(client.checkoutCalls.count, 1)
        XCTAssertEqual(client.checkoutCalls.first?.branch, "feat/new")
        XCTAssertEqual(client.checkoutCalls.first?.create, true)
        model.deactivate()
    }

    func testOpenFileLoadsDiffAndToggleCloses() async throws {
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))

        let change = WarrenDesktopGitChange(path: "b.txt", status: "?", staged: false)
        model.openFile(change: change)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.fileView?.path, "b.txt")
        XCTAssertEqual(client.diffCalls.count, 1)
        XCTAssertEqual(client.diffCalls.first?.path, "b.txt")
        XCTAssertFalse(model.fileDiff.loading)
        XCTAssertEqual(model.fileDiff.diff, client.diff.diff)

        model.openFile(change: change)
        XCTAssertNil(model.fileView)
        XCTAssertNil(model.selectedKey)
        model.deactivate()
    }

    func testMutationErrorSurfacesMessage() async throws {
        let client = StubGitClient(
            panel: samplePanel(),
            error: URLError(.notConnectedToInternet)
        )
        let model = WarrenDesktopGitPanelModel(
            client: client,
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.errorMessage, "Not connected")
        XCTAssertFalse(model.showsLoading)
        model.deactivate()
    }

    func testCanCreatePullRequestGate() async throws {
        let panel = samplePanel()
        let model = WarrenDesktopGitPanelModel(
            client: StubGitClient(panel: panel),
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.canCreatePullRequest)
        XCTAssertEqual(model.mainShort, "main")
        model.deactivate()

        var merged = panel
        merged.merged = true
        let mergedModel = WarrenDesktopGitPanelModel(
            client: StubGitClient(panel: merged),
            persistence: MemoryPersistence()
        )
        mergedModel.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mergedModel.canCreatePullRequest)
        mergedModel.deactivate()

        var withPR = panel
        withPR.pullRequest = WarrenDesktopGitPullRequest(title: "Open PR")
        let prModel = WarrenDesktopGitPanelModel(
            client: StubGitClient(panel: withPR),
            persistence: MemoryPersistence()
        )
        prModel.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(prModel.canCreatePullRequest)
        prModel.deactivate()
    }

    func testHistoryCommitsPreferUnmergedWhenMainKnown() async throws {
        let panel = samplePanel()
        let model = WarrenDesktopGitPanelModel(
            client: StubGitClient(panel: panel),
            persistence: MemoryPersistence()
        )
        model.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.historyCommits.map(\.hash), ["def456"])
        model.deactivate()

        var operation = panel
        operation.operation = "rebase"
        let operationModel = WarrenDesktopGitPanelModel(
            client: StubGitClient(panel: operation),
            persistence: MemoryPersistence()
        )
        operationModel.activate(workspaceID: WorkspaceID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(operationModel.historyCommits.map(\.hash), ["abc123"])
        XCTAssertEqual(operationModel.operationLabel, "Rebase")
        operationModel.deactivate()
    }

    func testPersistenceRestoresUIState() async throws {
        let persistence = MemoryPersistence()
        let workspaceID = WorkspaceID()
        let client = StubGitClient(panel: samplePanel())
        let model = WarrenDesktopGitPanelModel(client: client, persistence: persistence)

        model.activate(workspaceID: workspaceID)
        try await Task.sleep(for: .milliseconds(50))
        model.setBranchSelection("main")
        model.togglePane(.pr)
        model.togglePane(.history)
        model.toggleCommitExpanded("def456")
        let change = WarrenDesktopGitChange(path: "b.txt", status: "?", staged: false)
        model.openFile(change: change)
        try await Task.sleep(for: .milliseconds(50))
        model.diffViewTab = .file
        model.diffStyle = .split
        model.deactivate()

        XCTAssertEqual(Set(persistence.stored[workspaceID.description]?.openPanes ?? []), ["checkout", "changes"])
        XCTAssertEqual(persistence.stored[workspaceID.description]?.branch, "main")
        XCTAssertEqual(persistence.stored[workspaceID.description]?.fileView?.path, "b.txt")
        XCTAssertEqual(persistence.stored[workspaceID.description]?.viewTab, "file")
        XCTAssertEqual(persistence.stored[workspaceID.description]?.diffStyle, "split")

        let restored = WarrenDesktopGitPanelModel(client: client, persistence: persistence)
        restored.activate(workspaceID: workspaceID)
        XCTAssertEqual(restored.openPanes, Set([WarrenDesktopGitPanelModel.Pane.checkout, .changes]))
        XCTAssertEqual(restored.branchSelection, "main")
        XCTAssertTrue(restored.branchTouched)
        XCTAssertEqual(restored.expandedCommits, ["def456"])
        XCTAssertEqual(restored.fileView?.path, "b.txt")
        XCTAssertEqual(restored.diffViewTab, .file)
        XCTAssertEqual(restored.diffStyle, .split)
        restored.deactivate()
    }

    func testUserDefaultsPersistenceNormalizesInvalidValues() {
        let suite = "WarrenDesktopGitPanelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = WarrenDesktopGitPanelUserDefaultsPersistence(defaults: defaults)
        let workspaceID = WorkspaceID().description

        persistence.save(
            WarrenDesktopGitPanelUIState(
                openPanes: ["checkout", "bogus", "history"],
                selectedKey: "s:a.txt",
                expanded: ["", "abc"],
                branch: "main",
                viewTab: "bogus",
                diffStyle: "unified",
                fileView: WarrenDesktopGitFileViewSnapshot(path: "a.txt", staged: true, commit: nil)
            ),
            workspaceID: workspaceID
        )

        let loaded = persistence.load(workspaceID: workspaceID)
        XCTAssertEqual(loaded?.openPanes, ["checkout", "history"])
        XCTAssertEqual(loaded?.selectedKey, "s:a.txt")
        XCTAssertEqual(loaded?.expanded, ["abc"])
        XCTAssertEqual(loaded?.viewTab, nil)
        XCTAssertEqual(loaded?.diffStyle, "unified")
        XCTAssertEqual(loaded?.fileView?.path, "a.txt")
    }

    func testDiffParserTracksLineNumbers() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 123..456 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         context
        -old
        +new
        """
        let lines = WarrenDesktopGitDiffParser.parse(diff)
        XCTAssertEqual(lines.count, 8)
        XCTAssertEqual(lines[0].kind, .meta)
        XCTAssertEqual(lines[4].kind, .hunk)
        XCTAssertEqual(lines[4].text, "@@ -1,2 +1,2 @@")
        XCTAssertEqual(lines[5].kind, .context)
        XCTAssertEqual(lines[5].oldLine, 1)
        XCTAssertEqual(lines[5].newLine, 1)
        XCTAssertEqual(lines[6].kind, .del)
        XCTAssertEqual(lines[6].oldLine, 2)
        XCTAssertEqual(lines[6].newLine, nil)
        XCTAssertEqual(lines[7].kind, .add)
        XCTAssertEqual(lines[7].oldLine, nil)
        XCTAssertEqual(lines[7].newLine, 2)
    }

    func testRelativeTimeAndStatusLabels() {
        XCTAssertEqual(WarrenDesktopGitRelativeTime.string(from: ""), "")
        XCTAssertEqual(
            WarrenDesktopGitRelativeTime.string(
                from: "2026-08-20T10:00:00Z",
                now: ISO8601DateFormatter().date(from: "2026-08-20T10:05:00Z")!
            ),
            "5 minutes ago"
        )
        XCTAssertEqual(WarrenDesktopGitStatusLabel.label(for: "M"), "Modified")
        XCTAssertEqual(WarrenDesktopGitStatusLabel.label(for: "?"), "Untracked")
        XCTAssertEqual(WarrenDesktopGitStatusLabel.symbol(for: "?"), "??")
        XCTAssertEqual(WarrenDesktopGitStatusLabel.symbol(for: "A"), "A")
    }
}
