import Foundation
import XCTest
import WarrenDomain
@testable import WarrenClientCore

final class WarrenClientCoreTests: XCTestCase {
    private let sessionID = TerminalSessionID()
    private let clientID = ClientID()
    private let windowID = ClientWindowID()
    private let workspaceID = WorkspaceID()

    func testSidebarWidthRejectsNonFiniteAndNonPositiveValues() async throws {
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()
        let initial = await layouts.window(id: windowID)
        for width: Double in [0, -1, Double.infinity, -Double.infinity, Double.nan] {
            do {
                try await layouts.setSidebarWidth(width, in: windowID)
                XCTFail("Invalid sidebar width should be rejected: \(width)")
            } catch let error as ClientLayoutStoreError {
                guard case .invalidSidebarWidth(let received) = error else {
                    XCTFail("Unexpected layout error: \(error)")
                    continue
                }
                if width.isNaN {
                    XCTAssertTrue(received.isNaN)
                } else {
                    XCTAssertEqual(received, width)
                }
            }
        }
        let unchanged = await layouts.window(id: windowID)
        XCTAssertEqual(unchanged.sidebarWidth, initial.sidebarWidth)
        XCTAssertNil(ClientWindowLayout(id: windowID, sidebarWidth: 0))
    }

    func testWorkspaceViewsKeepIndependentTabOrderAndSelection() async throws {
        let secondWorkspaceID = WorkspaceID()
        let secondSessionID = TerminalSessionID()
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()

        try await layouts.upsertTab(
            ClientTab(id: "tab-a", title: "A", sessionID: sessionID),
            workspaceID: workspaceID,
            select: true,
            in: windowID
        )
        try await layouts.upsertTab(
            ClientTab(id: "tab-b", title: "B", sessionID: secondSessionID),
            workspaceID: secondWorkspaceID,
            select: true,
            in: windowID
        )
        try await layouts.selectWorkspace(workspaceID, in: windowID)

        let window = await layouts.window(id: windowID)
        XCTAssertEqual(window.activeWorkspaceID, workspaceID)
        XCTAssertEqual(window.workspaceView(for: workspaceID)?.tabs.map(\.id), ["tab-a"])
        XCTAssertEqual(window.workspaceView(for: workspaceID)?.activeTabID, "tab-a")
        XCTAssertEqual(window.workspaceView(for: secondWorkspaceID)?.tabs.map(\.id), ["tab-b"])
        XCTAssertEqual(window.workspaceView(for: secondWorkspaceID)?.activeTabID, "tab-b")
    }

    func testTerminalGroupViewsKeepIndependentTabOrderAndSelection() async throws {
        let groupID = TerminalGroupID()
        let secondGroupID = TerminalGroupID()
        let secondSessionID = TerminalSessionID()
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()

        try await layouts.upsertTab(
            ClientTab(id: "group-tab-a", title: "A", sessionID: sessionID),
            terminalGroupID: groupID,
            select: true,
            in: windowID
        )
        try await layouts.upsertTab(
            ClientTab(id: "group-tab-b", title: "B", sessionID: secondSessionID),
            terminalGroupID: secondGroupID,
            select: true,
            in: windowID
        )
        try await layouts.selectTerminalGroup(groupID, in: windowID)
        try await layouts.selectTab("group-tab-a", terminalGroupID: groupID, in: windowID)

        let window = await layouts.window(id: windowID)
        XCTAssertEqual(window.activeTerminalGroupID, groupID)
        XCTAssertNil(window.activeWorkspaceID)
        XCTAssertEqual(window.terminalGroupView(for: groupID)?.tabs.map(\.id), ["group-tab-a"])
        XCTAssertEqual(window.terminalGroupView(for: groupID)?.activeTabID, "group-tab-a")
        XCTAssertEqual(window.terminalGroupView(for: secondGroupID)?.tabs.map(\.id), ["group-tab-b"])
        XCTAssertEqual(window.terminalGroupView(for: secondGroupID)?.activeTabID, "group-tab-b")
    }

    func testMovingTabsKeepsSelectionAndSessionBindings() async throws {
        let thirdSessionID = TerminalSessionID()
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()
        for tab in [
            ClientTab(id: "tab-a", title: "A", sessionID: sessionID),
            ClientTab(id: "tab-b", title: "B", sessionID: TerminalSessionID()),
            ClientTab(id: "tab-c", title: "C", sessionID: thirdSessionID),
        ] {
            try await layouts.upsertTab(
                tab,
                workspaceID: workspaceID,
                select: tab.id == "tab-b",
                in: windowID
            )
        }

        try await layouts.moveTab(
            id: "tab-c",
            before: "tab-a",
            workspaceID: workspaceID,
            in: windowID
        )
        try await layouts.moveTab(
            id: "tab-a",
            before: nil,
            workspaceID: workspaceID,
            in: windowID
        )

        let view = await layouts.window(id: windowID).workspaceView(for: workspaceID)
        XCTAssertEqual(view?.tabs.map(\.id), ["tab-c", "tab-b", "tab-a"])
        XCTAssertEqual(view?.activeTabID, "tab-b")
        XCTAssertEqual(view?.tabs.first?.sessionID, thirdSessionID)
    }

    func testRemovingSessionReferencesCleansTabsAndSelectionAcrossWindows() async throws {
        let secondWindowID = ClientWindowID()
        let retainedSessionID = TerminalSessionID()
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()
        for targetWindow in [windowID, secondWindowID] {
            try await layouts.upsertTab(
                ClientTab(id: "delete-\(targetWindow)", title: "Delete", sessionID: sessionID),
                workspaceID: workspaceID,
                select: true,
                in: targetWindow
            )
            try await layouts.upsertTab(
                ClientTab(id: "keep-\(targetWindow)", title: "Keep", sessionID: retainedSessionID),
                workspaceID: workspaceID,
                select: false,
                in: targetWindow
            )
        }

        let removed = try await layouts.removeReferences(to: sessionID)

        XCTAssertEqual(removed.count, 2)
        for targetWindow in [windowID, secondWindowID] {
            let view = await layouts.window(id: targetWindow).workspaceView(for: workspaceID)
            XCTAssertEqual(view?.tabs.compactMap(\.sessionID), [retainedSessionID])
            XCTAssertEqual(view?.activeTabID, "keep-\(targetWindow)")
        }
    }
}
