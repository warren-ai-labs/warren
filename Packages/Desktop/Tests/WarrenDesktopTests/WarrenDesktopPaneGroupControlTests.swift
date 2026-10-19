import SwiftUI
import XCTest
import WarrenClientCore
import WarrenDomain
import WarrenObservation
@testable import WarrenDesktop

/// The group pill's gesture and keyboard contract, held down without a
/// pointer: the two stages share one aim, and the keys only take what names a
/// real member.
@MainActor
final class WarrenDesktopPaneGroupControlTests: XCTestCase {
    func testAimIsIgnoredAtRestAndPreviewedOnceLifted() {
        let resting = WarrenDesktopPaneGroupHover()
        resting.aim("a")
        XCTAssertNil(resting.hotTabID)
        XCTAssertNil(resting.peekTabID)

        let lifted = WarrenDesktopPaneGroupHover(phase: .lifted)
        lifted.aim("b")
        XCTAssertEqual(lifted.peekTabID, "b")
        lifted.aim(nil)
        XCTAssertNil(lifted.peekTabID, "Aiming at the title previews no pane")
    }

    func testDropReturnsToRestAndClearsTheAim() {
        let hover = WarrenDesktopPaneGroupHover(phase: .pulled, hotTabID: "a")
        hover.drop()
        XCTAssertEqual(hover.phase, .rest)
        XCTAssertNil(hover.hotTabID)
    }

    func testAPullFromTheLiftedPillOpensTheShelf() {
        let hover = WarrenDesktopPaneGroupHover(phase: .lifted)
        hover.pull()
        XCTAssertEqual(hover.phase, .pulled)
    }

    func testADragStandsBothStagesDown() {
        let hover = WarrenDesktopPaneGroupHover(phase: .pulled, hotTabID: "a")
        hover.dragBegan()
        XCTAssertEqual(hover.phase, .rest)
    }

    func testKeyboardAimWrapsThroughTheMembers() {
        let hover = WarrenDesktopPaneGroupHover()
        hover.openFromKeyboard(aiming: "a")
        XCTAssertTrue(hover.isKeyboardDriven)
        XCTAssertEqual(hover.phase, .pulled)
        hover.moveKeyboardAim(in: ["a", "b", "c"], by: 1)
        XCTAssertEqual(hover.hotTabID, "b")
        hover.moveKeyboardAim(in: ["a", "b", "c"], by: 2)
        XCTAssertEqual(hover.hotTabID, "a")
        hover.moveKeyboardAim(in: ["a", "b", "c"], by: -1)
        XCTAssertEqual(hover.hotTabID, "c")
    }

    func testOptionDigitsMapToMemberNumbers() {
        XCTAssertEqual(WarrenDesktopPaneGroupKeys.memberNumber(keyCode: 18), 1)
        XCTAssertEqual(WarrenDesktopPaneGroupKeys.memberNumber(keyCode: 21), 4)
        XCTAssertEqual(WarrenDesktopPaneGroupKeys.memberNumber(keyCode: 25), 9)
        XCTAssertNil(WarrenDesktopPaneGroupKeys.memberNumber(keyCode: 29), "0 names no member")
    }

    func testUnitFramesCoverTheLayout() {
        let tree = SplitLayoutTree.leaf(SplitPaneItem(id: "p-a", tabID: "a"))
            .split(targetPaneID: "p-a", newTabID: "b", axis: .horizontal)
        let frames = tree.unitFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames["a"]?.minX ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual((frames["a"]?.width ?? 0) + (frames["b"]?.width ?? 0), 1, accuracy: 0.001)
    }

    func testActivityLinePrefersTheQuestionThenTheCommand() {
        let asking = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "t",
            kind: .claude,
            agentStatus: AgentStatus(
                activity: .blocked,
                attention: AgentAttention(kind: .input, reason: "Which radius?")
            ),
            runtimeCommandLine: "claude"
        )
        XCTAssertEqual(WarrenDesktopRoot<EmptyView>.paneActivityLine(asking), "Which radius?")

        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "t",
            kind: .codex,
            activity: .working
        )
        XCTAssertEqual(WarrenDesktopRoot<EmptyView>.paneActivityLine(working), "Working")
    }
}

/// The shelf's commands, driven through the real window root.
@MainActor
final class WarrenDesktopPaneGroupShelfCommandTests: XCTestCase {
    private struct Surface: View {
        let context: WarrenDesktopTerminalContext
        var body: some View { Color.clear }
    }

    private struct Fixture {
        let projection: WarrenDesktopProjection
        let workspace: Workspace
        let tabIDs: [String]
        var scopeKey: String { "endpoint-local-workspace-\(workspace.id.rawValue.uuidString)" }
    }

    private func fixture() -> Fixture {
        let host = WarrenDomain.Host(name: "Host")
        let project = Project(hostID: host.id, name: "warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "cards", path: "/tmp/cards", branch: "feat/cards")
        let ids = [TerminalSessionID(), TerminalSessionID(), TerminalSessionID()]
        let sessions = ids.enumerated().map { index, id in
            WarrenDesktopSession(id: id, workspaceID: workspace.id, title: "S\(index)")
        }
        let tabs = sessions.map { ClientTab(id: "remote-\($0.id.description)", title: $0.title, sessionID: $0.id) }
        let group = PaneGroup(
            id: PaneGroupID(),
            hostID: host.id,
            workspaceID: workspace.id,
            tree: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(sessionID: ids[0]),
                second: .split(axis: .vertical, ratio: 0.5, first: .leaf(sessionID: ids[1]), second: .leaf(sessionID: ids[2]))
            )
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: Dictionary(uniqueKeysWithValues: ids.map { ($0, workspace.id) }),
            tabWorkspaceIDs: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, workspace.id) }),
            paneGroups: [group]
        )
        return Fixture(projection: projection, workspace: workspace, tabIDs: tabs.map(\.id))
    }

    private func mount(
        _ fixture: Fixture,
        hover: WarrenDesktopPaneGroupHover,
        recorder: WarrenSemanticRecorder,
        onAction: @escaping @MainActor (WarrenDesktopAction) -> Void = { _ in }
    ) -> NSHostingView<AnyView> {
        let root = WarrenDesktopRoot(
            projection: fixture.projection,
            navigation: WarrenDesktopNavigationState(
                selection: .workspace(fixture.workspace.id),
                selectedTabID: fixture.tabIDs[0]
            ),
            actions: WarrenDesktopActions(send: onAction),
            persistenceEnabled: false
        ) { Surface(context: $0) }
        .environment(\.warrenPaneGroupHover, hover)
        .environment(\.warrenSemanticRecorder, recorder)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        settle(hosting)
        return hosting
    }

    private func settle(_ hosting: NSView) {
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testUngroupDissolvesTheGroupAndKeepsEverySession() throws {
        let fixture = fixture()
        let recorder = WarrenSemanticRecorder()
        let hover = WarrenDesktopPaneGroupHover(phase: .pulled)
        var deleted: [TerminalSessionID] = []
        let hosting = mount(fixture, hover: hover, recorder: recorder) { action in
            if case .deleteSession(let id) = action { deleted.append(id) }
        }
        let groupID = "tabgroup.\(fixture.scopeKey)"
        XCTAssertTrue(recorder.snapshot().nodes.contains { $0.id == groupID })

        try recorder.perform(.press, on: "\(groupID).ungroup")
        settle(hosting)

        let ids = Set(recorder.snapshot().nodes.map(\.id))
        XCTAssertFalse(ids.contains(groupID), "One pane is not a group")
        XCTAssertTrue(ids.contains("pane.solo"), "The focused pane stays on screen alone")
        XCTAssertTrue(deleted.isEmpty, "Ungrouping ends no Session")
    }

    func testMaximizeKeepsTheGroupAndTogglesBack() throws {
        let fixture = fixture()
        let recorder = WarrenSemanticRecorder()
        let hover = WarrenDesktopPaneGroupHover(phase: .pulled, hotTabID: fixture.tabIDs[1])
        let hosting = mount(fixture, hover: hover, recorder: recorder)
        let maximize = "tabgroup.\(fixture.scopeKey).row.\(fixture.tabIDs[1]).maximize"

        try recorder.perform(.press, on: maximize)
        settle(hosting)
        let node = recorder.snapshot().nodes.first { $0.id == maximize }
        XCTAssertEqual(node?.label, "Restore Pane")
        XCTAssertTrue(recorder.snapshot().nodes.contains { $0.id == "tabgroup.\(fixture.scopeKey)" })

        try recorder.perform(.press, on: maximize)
        settle(hosting)
        XCTAssertEqual(recorder.snapshot().nodes.first { $0.id == maximize }?.label, "Maximize Pane")
    }
}
