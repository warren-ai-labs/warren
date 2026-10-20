import AppKit
import SwiftUI
import XCTest
import WarrenDomain
import WarrenTransport
@testable import WarrenDesktop
@testable import Warren

/// Opt-in acceptance of split panes against a running, disposable Host.
///
/// The real model and the real root view are wired the way the composition
/// root wires them, so a split runs through the model's Session creation, the
/// `pane-group.create`/`pane-group.update` writes, and the roster echo — the
/// whole path a unit test with a fake Host cannot reach.
///
/// Set `WARREN_PANE_LIVE_URL`, `WARREN_PANE_LIVE_TOKEN`, and
/// `WARREN_PANE_LIVE_WORKSPACE` to a Host nobody else uses: the test creates and
/// deletes Sessions in that Workspace.
final class WarrenPaneGroupLiveTests: XCTestCase {
    private struct LiveRoot: View {
        @ObservedObject var model: WarrenRemoteApplicationModel

        var body: some View {
            WarrenDesktopRoot(
                projection: model.projection,
                navigation: model.navigation,
                actions: WarrenDesktopActions { action in
                    if case .requestNewSession(let workspaceID, let token) = action {
                        model.createSession(workspaceID: workspaceID, request: .shell, token: token)
                    } else {
                        model.perform(action)
                    }
                },
                creatingSessionWorkspaceIDs: model.creatingSessionWorkspaceIDs,
                createdSessionIDsByToken: model.createdSessionIDsByToken,
                onCommitPaneTree: { model.commitPaneTree(owner: $0, tree: $1, target: $2) },
                onPaneDiagnostic: { print("diag \($0) \($1.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))") },
                persistenceEnabled: false
            ) { context in
                Text("surface:\(context.tab.id.suffix(8))")
                    .font(.system(size: 28))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue.opacity(0.2))
            }
        }
    }

    @MainActor
    private func waitUntil(
        _ view: NSView,
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    @MainActor
    private func settle(_ view: NSView, seconds: TimeInterval) {
        _ = waitUntil(view, timeout: seconds) { false }
    }

    @MainActor
    private func snapshot(_ view: NSView, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_PANE_LIVE_IMAGES"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testSplittingAnExistingSplitOnALiveHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_PANE_LIVE_URL"],
              let token = environment["WARREN_PANE_LIVE_TOKEN"],
              let rawWorkspace = environment["WARREN_PANE_LIVE_WORKSPACE"],
              let workspaceID = WorkspaceID(uuidString: rawWorkspace) else {
            throw XCTSkip("Set WARREN_PANE_LIVE_URL, WARREN_PANE_LIVE_TOKEN, and WARREN_PANE_LIVE_WORKSPACE")
        }
        let model = WarrenRemoteApplicationModel(initialNavigationScope: "pane-live")
        model.connect(WarrenRemoteEndpointConfiguration(name: "pane-live", url: url, token: token))
        let view = NSHostingView(rootView: LiveRoot(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)

        XCTAssertTrue(waitUntil(view) { model.projection.workspace(id: workspaceID) != nil })
        model.perform(.selectWorkspace(workspaceID))
        let group = { model.projection.paneGroups(in: workspaceID).first }
        let tabs = { model.projection.tabs(in: workspaceID) }

        if tabs().isEmpty {
            model.createSession(workspaceID: workspaceID, request: .shell)
            XCTAssertTrue(waitUntil(view) { !tabs().isEmpty && model.navigation.selectedTabID != nil })
        }
        settle(view, seconds: 0.5)

        if ProcessInfo.processInfo.environment["WARREN_PANE_LIVE_SELECT_IN_SPLIT"] != nil,
           let last = group()?.tree.sessionIDs.last {
            model.perform(.selectTab(WarrenDesktopPaneGroupMapping.tabID(for: last)))
            settle(view, seconds: 0.5)
        }
        let initial = group()?.paneCount ?? 1
        snapshot(view, name: "start")
        print("pane-live start: panes=\(initial) selected=\(model.navigation.selectedTabID ?? "nil") tabs=\(tabs().count) tree=\(String(describing: group()?.tree))")
        var counts: [Int] = []
        for step in 0..<(4 - initial) {
            let before = group()?.paneCount ?? 1
            NotificationCenter.default.post(
                name: step.isMultiple(of: 2) ? WarrenDesktopCommand.splitRight : WarrenDesktopCommand.splitBelow,
                object: nil
            )
            let grew = waitUntil(view) { (group()?.paneCount ?? 1) == before + 1 }
            settle(view, seconds: 1)
            counts.append(group()?.paneCount ?? 1)
            snapshot(view, name: "step\(step)")
            print("pane-live step \(step): panes=\(group()?.paneCount ?? 0) rev=\(group()?.revision ?? 0) tabs=\(tabs().count) selected=\(model.navigation.selectedTabID ?? "nil") sessions=\(group()?.tree.sessionIDs.map { $0.shortDescription } ?? [])")
            XCTAssertTrue(grew, "step \(step) did not add a pane; counts=\(counts)")
        }
        XCTAssertEqual(group()?.paneCount, 4)
    }

    /// The field bug: split once, visit a Session the arrangement does not
    /// hold, then split again. The second split must open a second arrangement
    /// and leave the first arrangement's panes exactly as they were.
    @MainActor
    func testSplittingFromAVisitedSessionOpensASecondGroupOnALiveHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_PANE_LIVE_URL"],
              let token = environment["WARREN_PANE_LIVE_TOKEN"],
              let rawWorkspace = environment["WARREN_PANE_LIVE_WORKSPACE"],
              let workspaceID = WorkspaceID(uuidString: rawWorkspace) else {
            throw XCTSkip("Set WARREN_PANE_LIVE_URL, WARREN_PANE_LIVE_TOKEN, and WARREN_PANE_LIVE_WORKSPACE")
        }
        let model = WarrenRemoteApplicationModel(initialNavigationScope: "pane-live")
        model.connect(WarrenRemoteEndpointConfiguration(name: "pane-live", url: url, token: token))
        let view = NSHostingView(rootView: LiveRoot(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        XCTAssertTrue(waitUntil(view) { model.projection.workspace(id: workspaceID) != nil })
        model.perform(.selectWorkspace(workspaceID))
        let groups = { model.projection.paneGroups(in: workspaceID) }
        let tabs = { model.projection.tabs(in: workspaceID) }

        if tabs().isEmpty {
            model.createSession(workspaceID: workspaceID, request: .shell)
            XCTAssertTrue(waitUntil(view) { !tabs().isEmpty && model.navigation.selectedTabID != nil })
        }
        settle(view, seconds: 0.5)
        if groups().isEmpty {
            NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
            XCTAssertTrue(waitUntil(view) { groups().first?.paneCount == 2 })
            settle(view, seconds: 1)
        }
        guard let first = groups().first else { return XCTFail("no arrangement was created") }
        let firstSessions = first.tree.sessionIDs

        // A Session the arrangement does not hold: creating one adds an
        // ordinary Tab, exactly like a Session picked from the sidebar.
        model.createSession(workspaceID: workspaceID, request: .shell)
        XCTAssertTrue(waitUntil(view) { tabs().count > firstSessions.count })
        settle(view, seconds: 1)
        guard let selectedTab = model.navigation.selectedTabID,
              let visited = tabs().first(where: { $0.id == selectedTab })?.sessionID,
              !firstSessions.contains(visited) else {
            return XCTFail("expected the new Session to be selected outside the arrangement")
        }

        NotificationCenter.default.post(name: WarrenDesktopCommand.splitRight, object: nil)
        XCTAssertTrue(waitUntil(view, timeout: 10) { groups().count == 2 })
        settle(view, seconds: 1)

        XCTAssertEqual(groups().count, 2, "the split opened a second arrangement")
        XCTAssertEqual(groups().first?.tree.sessionIDs, firstSessions, "the on-screen arrangement is untouched")
        XCTAssertEqual(groups().last?.tree.sessionIDs.first, visited, "the visited Session leads its own arrangement")
        XCTAssertEqual(groups().last?.tree.paneCount, 2)
    }

    /// The sequence from the field log: split twice, close the last pane, click
    /// the third and close it, then split again from the first pane.
    @MainActor
    func testFieldSequenceOnALiveHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_PANE_LIVE_URL"],
              let token = environment["WARREN_PANE_LIVE_TOKEN"],
              let rawWorkspace = environment["WARREN_PANE_LIVE_WORKSPACE"],
              let workspaceID = WorkspaceID(uuidString: rawWorkspace) else {
            throw XCTSkip("Set WARREN_PANE_LIVE_URL, WARREN_PANE_LIVE_TOKEN, and WARREN_PANE_LIVE_WORKSPACE")
        }
        let model = WarrenRemoteApplicationModel(initialNavigationScope: "pane-live")
        model.connect(WarrenRemoteEndpointConfiguration(name: "pane-live", url: url, token: token))
        let view = NSHostingView(rootView: LiveRoot(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        XCTAssertTrue(waitUntil(view) { model.projection.workspace(id: workspaceID) != nil })
        model.perform(.selectWorkspace(workspaceID))
        let group = { model.projection.paneGroups(in: workspaceID).first }
        settle(view, seconds: 0.5)
        func log(_ label: String) {
            let tree = group()?.tree.sessionIDs.map(\.shortDescription) ?? []
            print("field \(label): host=\(tree) rev=\(group()?.revision ?? 0) selected=\(model.navigation.selectedTabID?.dropFirst(7).prefix(8) ?? "nil") tabs=\(model.projection.tabs(in: workspaceID).count)")
        }
        func select(pane index: Int) {
            guard let id = group()?.tree.sessionIDs[index] else { return }
            model.perform(.selectTab(WarrenDesktopPaneGroupMapping.tabID(for: id)))
            settle(view, seconds: 0.4)
        }
        func post(_ name: Notification.Name, wait: TimeInterval) {
            NotificationCenter.default.post(name: name, object: nil)
            settle(view, seconds: wait)
        }
        log("start")
        select(pane: 1)
        post(WarrenDesktopCommand.splitRight, wait: 1.2); log("split1")
        post(WarrenDesktopCommand.splitRight, wait: 1.2); log("split2")
        post(WarrenDesktopCommand.closePane, wait: 0.5); log("close-last")
        select(pane: 2)
        post(WarrenDesktopCommand.closePane, wait: 1.2); log("close-third")
        post(WarrenDesktopCommand.splitRight, wait: 3); log("split3")
        snapshot(view, name: "field")
        XCTAssertEqual(group()?.paneCount, 3)
    }

    /// The 20:02 field log: split twice, visit another Workspace and come back,
    /// close the two new panes, then split again.
    @MainActor
    func testVisitAnotherWorkspaceThenSplit() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_PANE_LIVE_URL"],
              let token = environment["WARREN_PANE_LIVE_TOKEN"],
              let rawWorkspace = environment["WARREN_PANE_LIVE_WORKSPACE"],
              let workspaceID = WorkspaceID(uuidString: rawWorkspace),
              let rawOther = environment["WARREN_PANE_LIVE_OTHER_WORKSPACE"],
              let otherID = WorkspaceID(uuidString: rawOther) else {
            throw XCTSkip("Set the WARREN_PANE_LIVE_* variables")
        }
        let model = WarrenRemoteApplicationModel(initialNavigationScope: "pane-live")
        model.connect(WarrenRemoteEndpointConfiguration(name: "pane-live", url: url, token: token))
        let view = NSHostingView(rootView: LiveRoot(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        XCTAssertTrue(waitUntil(view) { model.projection.workspace(id: workspaceID) != nil })
        let group = { model.projection.paneGroups(in: workspaceID).first }
        func log(_ label: String) {
            let tree = group()?.tree.sessionIDs.map(\.shortDescription) ?? []
            print("visit \(label): host=\(tree) rev=\(group()?.revision ?? 0) selected=\(model.navigation.selectedTabID?.dropFirst(7).prefix(8) ?? "nil")")
        }
        func open(_ id: TerminalSessionID?) {
            guard let id else { return }
            model.perform(.openSession(id))
            settle(view, seconds: 0.6)
        }
        func post(_ name: Notification.Name, wait: TimeInterval) {
            NotificationCenter.default.post(name: name, object: nil)
            settle(view, seconds: wait)
        }
        open(group()?.tree.sessionIDs.last)
        log("start")
        post(WarrenDesktopCommand.splitRight, wait: 1.5); log("split1")
        post(WarrenDesktopCommand.splitBelow, wait: 1.5); log("split2")
        let added = Array(group()?.tree.sessionIDs.dropFirst(2) ?? [])
        open(model.projection.sessions.first { $0.workspaceID == otherID }?.id); log("visit-other")
        open(group()?.tree.sessionIDs[1]); log("back")
        for id in added {
            model.perform(.selectTab(WarrenDesktopPaneGroupMapping.tabID(for: id)))
            settle(view, seconds: 0.4)
            let wait = Double(ProcessInfo.processInfo.environment["WARREN_PANE_LIVE_CLOSE_WAIT"] ?? "1.0") ?? 1.0
            post(WarrenDesktopCommand.closePane, wait: wait); log("close")
        }
        post(WarrenDesktopCommand.splitRight, wait: 3); log("split3")
        let rendered = model.projection.paneGroups(in: workspaceID).first.map { _ in "" } ?? ""
        print("visit rendered-tabs-in-model=\(model.projection.tabs(in: workspaceID).count)\(rendered)")
        snapshot(view, name: "visit")
        XCTAssertEqual(group()?.paneCount, 3)
    }
}
