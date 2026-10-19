import XCTest
import SwiftUI
import AppKit
@testable import WarrenDesktop
import WarrenDomain
import WarrenClientCore

/// A stand-in for the Host behind the real root view.
///
/// It applies the same rules the Host's `UpdatePaneGroup` does — assign an
/// identity to a leaf that has none, bump the revision — and publishes the
/// result as a new projection, so a split or a drop runs through the exact
/// path the app takes, from the command to the roster's echo.
@MainActor
final class PaneGroupFlowHost: ObservableObject {
    let host = WarrenDomain.Host(name: "Flow Host")
    let project: Project
    let workspace: Workspace
    let otherWorkspace: Workspace
    @Published private(set) var projection: WarrenDesktopProjection
    @Published var navigation: WarrenDesktopNavigationState
    @Published var creating: Set<WorkspaceID> = []
    private(set) var sessions: [WarrenDesktopSession] = []
    private(set) var groups: [PaneGroup] = []
    private(set) var commits: [PaneNode] = []
    private(set) var actions: [WarrenDesktopAction] = []
    private(set) var rejected = 0

    /// How long the Host takes to echo an accepted tree, and to publish a
    /// created Session. The real roster gives no ordering between the two.
    var echoDelay: TimeInterval = 0.05
    var sessionDelay: TimeInterval = 0.05

    init(sessionCount: Int, splitAll: Bool, splitCount: Int? = nil) {
        project = Project(hostID: host.id, name: "Project", rootPath: "/tmp/project")
        workspace = Workspace(projectID: project.id, name: "Workspace", path: "/tmp/project")
        otherWorkspace = Workspace(projectID: project.id, name: "Other", path: "/tmp/other")
        projection = WarrenDesktopProjection(host: host, groups: [])
        navigation = WarrenDesktopNavigationState(selection: nil, selectedTabID: nil)
        for index in 0..<sessionCount {
            sessions.append(Self.session(workspaceID: workspace.id, title: "S\(index)"))
        }
        if splitAll, sessions.count > 1 {
            var tree = PaneNode.leaf(paneID: PaneID(), sessionID: sessions[0].id)
            for session in sessions.prefix(splitCount ?? sessions.count).dropFirst() {
                tree = .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: tree,
                    second: .leaf(paneID: PaneID(), sessionID: session.id)
                )
            }
            groups = [PaneGroup(hostID: host.id, workspaceID: workspace.id, tree: tree, revision: 1)]
        }
        publish()
        navigation = WarrenDesktopNavigationState(
            selection: .workspace(workspace.id),
            selectedTabID: sessions.last.map { tabID($0.id) }
        )
    }

    static func session(workspaceID: WorkspaceID, title: String) -> WarrenDesktopSession {
        let id = TerminalSessionID()
        return WarrenDesktopSession(
            id: id,
            workspaceID: workspaceID,
            tabID: WarrenDesktopPaneGroupMapping.tabID(for: id),
            title: title
        )
    }

    func tabID(_ id: TerminalSessionID) -> String {
        WarrenDesktopPaneGroupMapping.tabID(for: id)
    }

    var groupTree: PaneNode? { groups.first { $0.workspaceID == workspace.id }?.tree }

    func send(_ action: WarrenDesktopAction) {
        actions.append(action)
        switch action {
        case .requestNewSession(let workspaceID):
            // The model marks the Workspace as creating, the roster publishes
            // the Session, and only then does the model clear the mark and
            // select the new Tab — the order `createSession` runs in.
            creating.insert(workspaceID)
            let created = Self.session(workspaceID: workspaceID, title: "New")
            DispatchQueue.main.asyncAfter(deadline: .now() + sessionDelay) {
                self.sessions.append(created)
                self.publish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sessionDelay + 0.1) {
                self.creating.remove(workspaceID)
                self.navigation = WarrenDesktopNavigationReducer.reduce(
                    self.navigation,
                    action: .selectTab(self.tabID(created.id)),
                    in: self.projection
                )
            }
        case .deleteSession(let sessionID):
            // The Host ends the Session and reconciles every arrangement that
            // showed it, which bumps that group's revision on its own.
            navigation = WarrenDesktopNavigationReducer.reduce(navigation, action: action, in: projection)
            DispatchQueue.main.asyncAfter(deadline: .now() + sessionDelay) {
                self.sessions.removeAll { $0.id == sessionID }
                for index in self.groups.indices {
                    let before = self.groups[index].tree
                    guard let pruned = Self.removing(sessionID, from: before) else { continue }
                    if pruned != before {
                        self.groups[index].tree = pruned
                        self.groups[index].revision += 1
                    }
                }
                self.publish()
            }
        case .selectTab(let tabID):
            navigation = WarrenDesktopNavigationReducer.reduce(navigation, action: .selectTab(tabID), in: projection)
        default:
            break
        }
    }

    /// `pane-group.create` + `pane-group.update`, answered after a delay the
    /// way the roster echo is.
    func commit(owner: WarrenDesktopPaneOwner, tree: PaneNode, target: WarrenDesktopPaneGroupTarget) {
        commits.append(tree)
        // The window names the arrangement it renders; a new arrangement is
        // created around the tree's first Session. `commitPaneTree` names the
        // revision the projection reported when the write was issued, and the
        // Host rejects the write if it moved since.
        let observedGroup: PaneGroupID?
        let observed: UInt64?
        switch target {
        case .group(let id):
            observedGroup = id
            observed = projection.paneGroups.first { $0.id == id }?.revision
        case .newGroup:
            observedGroup = nil
            observed = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + echoDelay) {
            let assigned = Self.assigningPaneIDs(tree)
            if let observedGroup {
                guard let index = self.groups.firstIndex(where: { $0.id == observedGroup }) else {
                    self.publish()
                    return
                }
                var group = self.groups[index]
                guard observed == group.revision else {
                    self.rejected += 1
                    self.publish()
                    return
                }
                group.tree = assigned
                group.revision += 1
                self.groups[index] = group
            } else {
                self.groups.append(PaneGroup(hostID: self.host.id, workspaceID: owner.workspaceID, tree: assigned, revision: 2))
            }
            self.publish()
        }
    }

    static func removing(_ sessionID: TerminalSessionID, from node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf(_, let id):
            return id == sessionID ? nil : node
        case .split(let axis, let ratio, let first, let second):
            switch (removing(sessionID, from: first), removing(sessionID, from: second)) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            }
        }
    }

    static func assigningPaneIDs(_ node: PaneNode) -> PaneNode {
        switch node {
        case .leaf(let paneID, let sessionID):
            return .leaf(paneID: paneID ?? PaneID(), sessionID: sessionID)
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: assigningPaneIDs(first), second: assigningPaneIDs(second))
        }
    }

    /// An Agent status event, which the model applies to the projection it
    /// already has instead of waiting for the next roster.
    func publishAgentStatus(for sessionID: TerminalSessionID) {
        projection = projection.withSessionAgentStatus(AgentStatus(activity: .working), for: sessionID)
    }

    func publish() {
        projection = WarrenDesktopProjection(
            host: host,
            groups: [WarrenDesktopProjectGroup(project: project, workspaces: [workspace, otherWorkspace])],
            sessions: sessions,
            tabs: sessions.map { ClientTab(id: tabID($0.id), title: $0.title, sessionID: $0.id) },
            paneGroups: groups
        )
    }
}

private struct PaneGroupFlowSurface: View {
    let context: WarrenDesktopTerminalContext
    var body: some View { Text("surface:\(context.tab.id)") }
}

private struct PaneGroupFlowRoot: View {
    @ObservedObject var host: PaneGroupFlowHost

    var body: some View {
        WarrenDesktopRoot(
            projection: host.projection,
            navigation: host.navigation,
            actions: WarrenDesktopActions(send: { host.send($0) }),
            creatingSessionWorkspaceIDs: host.creating,
            onCommitPaneTree: { host.commit(owner: $0, tree: $1, target: $2) },
            persistenceEnabled: false
        ) { context in
            PaneGroupFlowSurface(context: context)
        }
    }
}

@MainActor
final class WarrenDesktopPaneGroupFlowTests: XCTestCase {
    private func mount(_ host: PaneGroupFlowHost) -> NSHostingView<PaneGroupFlowRoot> {
        let view = NSHostingView(rootView: PaneGroupFlowRoot(host: host))
        view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        settle(view)
        return view
    }

    private func settle(_ view: NSView, seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func sessionIDs(_ tree: PaneNode?) -> [TerminalSessionID] {
        tree?.sessionIDs ?? []
    }

    func testSplittingAnExistingSplitAddsAPaneAndKeepsEverySession() {
        let host = PaneGroupFlowHost(sessionCount: 2, splitAll: true)
        let view = mount(host)
        let before = sessionIDs(host.groupTree)
        XCTAssertEqual(before.count, 2)

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
        settle(view, seconds: 0.8)

        let after = sessionIDs(host.groupTree)
        XCTAssertEqual(after.count, 3, "commits: \(host.commits) actions: \(host.actions)")
        XCTAssertEqual(Array(after.prefix(2)), before)
    }

    func testSplittingTwiceFromOnePaneBuildsThreePanes() {
        let host = PaneGroupFlowHost(sessionCount: 1, splitAll: false)
        let view = mount(host)

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
        settle(view, seconds: 0.8)
        XCTAssertEqual(sessionIDs(host.groupTree).count, 2, "commits: \(host.commits)")

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitBelow, object: nil)
        settle(view, seconds: 0.8)
        XCTAssertEqual(sessionIDs(host.groupTree).count, 3, "commits: \(host.commits) actions: \(host.actions)")
    }

    /// A Session the arrangement on screen does not hold gets an arrangement of
    /// its own. The split must not fold it into the layout the user is not
    /// looking at, and the layout that was on screen keeps every pane it had.
    func testSplittingFromAVisitedSessionOpensASecondArrangement() {
        let host = PaneGroupFlowHost(sessionCount: 3, splitAll: true, splitCount: 2)
        let view = mount(host)
        let before = sessionIDs(host.groupTree)
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(host.navigation.selectedTabID, host.tabID(host.sessions[2].id))

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
        settle(view, seconds: 0.8)

        XCTAssertEqual(host.groups.count, 2, "commits: \(host.commits) actions: \(host.actions)")
        XCTAssertEqual(sessionIDs(host.groupTree), before, "the on-screen arrangement is untouched")
        let created = sessionIDs(host.groups.last?.tree)
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.first, host.sessions[2].id, "the visited Session leads its own arrangement")
        XCTAssertEqual(host.rejected, 0)
    }

    /// An Agent status event between two splits used to rebuild the projection
    /// without its Pane Groups. The scope then looked unarranged: the split
    /// collapsed to the selected Tab, and the next split asked the Host to
    /// create a second group around a Session it already showed.
    func testAgentStatusUpdateKeepsTheSplitAndTheNextSplitLands() {
        let host = PaneGroupFlowHost(sessionCount: 2, splitAll: true)
        let view = mount(host)
        let before = sessionIDs(host.groupTree)

        host.publishAgentStatus(for: host.sessions[0].id)
        settle(view)
        XCTAssertEqual(host.projection.paneGroups.count, 1)

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
        settle(view, seconds: 0.8)

        let after = sessionIDs(host.groupTree)
        XCTAssertEqual(after.count, 3, "commits: \(host.commits)")
        XCTAssertEqual(Array(after.prefix(2)), before)
        XCTAssertEqual(host.rejected, 0)
    }
}
