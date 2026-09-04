import Foundation
import XCTest
import WarrenDomain
import WarrenProtocol
@testable import WarrenClientCore

final class WarrenClientCoreTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let clientID = ClientID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private let windowID = ClientWindowID(rawValue: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
    private let workspaceID = WorkspaceID(rawValue: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    func testLayoutMutationsDoNotSendWireMessages() async throws {
        let transport = InMemoryHostTransport()
        let layouts = try ClientLayoutStore(clientID: clientID, defaultWindowID: windowID)
        try await layouts.start()

        try await layouts.setSidebarCollapsed(true, in: windowID)
        try await layouts.upsertTab(
            ClientTab(id: "tab-1", title: "Shell", sessionID: sessionID),
            workspaceID: workspaceID,
            select: true,
            in: windowID
        )

        let window = await layouts.window(id: windowID)
        XCTAssertTrue(window.sidebarCollapsed)
        XCTAssertNil(window.activeWorkspaceID)
        XCTAssertEqual(window.workspaceView(for: workspaceID)?.activeTabID, "tab-1")
        XCTAssertEqual(window.workspaceView(for: workspaceID)?.tabs.map(\.id), ["tab-1"])
        let messages = await transport.sentMessages
        XCTAssertTrue(messages.isEmpty)
    }

    func testInMemoryTransportObservesBinaryInputAndRejectsLengthMismatch() async throws {
        let transport = InMemoryHostTransport()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 3)
        )
        try await transport.sendInput(metadata: metadata, payload: Data([1, 2, 3]))
        let sentInputs = await transport.sentInputs
        XCTAssertEqual(sentInputs.count, 1)
        XCTAssertEqual(sentInputs[0].metadata, metadata)
        XCTAssertEqual(sentInputs[0].payload, Data([1, 2, 3]))

        do {
            try await transport.sendInput(metadata: metadata, payload: Data([1]))
            XCTFail("an input length mismatch must be rejected")
        } catch let error as HostTransportError {
            XCTAssertEqual(
                error,
                .inputPayloadLengthMismatch(expected: 3, actual: 1)
            )
        }
    }

    func testControlChangedProjectsControllerAndLease() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 1, sequence: 0)
        ))
        let leaseID = ControlLeaseID()
        _ = try await store.consume(.controlChanged(
            ControlChangedMessage(
                sessionID: sessionID,
                controllerAttachmentID: attachmentID,
                leaseID: leaseID
            )
        ))

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.controllerAttachmentID, attachmentID)
        XCTAssertEqual(snapshot.controlLeaseID, leaseID)
    }

    func testRuntimeMetadataProjectsAndSurvivesTransportDisconnect() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.runtimeMetadata(
            RuntimeMetadataMessage(
                sessionID: sessionID,
                process: "codex",
                workingDirectory: "/tmp/warren"
            )
        ))
        await store.markDisconnected()

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.runtimeProcess, "codex")
        XCTAssertEqual(snapshot.workingDirectory, "/tmp/warren")
        XCTAssertEqual(snapshot.connectionState, .disconnected)
    }

    func testOutOfOrderAndEpochChangedBinaryHeadersAreRejected() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 3, sequence: 10)
        ))

        let acceptedHeader = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 10, payloadLength: 4)
        )
        _ = try await store.consume(binaryHeader: acceptedHeader)
        let acceptedSnapshot = await store.snapshot()
        XCTAssertEqual(acceptedSnapshot.recoveryAnchor, RecoveryAnchor(epoch: 3, sequence: 14))

        let outOfOrder = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 15, payloadLength: 1)
        )
        do {
            _ = try await store.consume(binaryHeader: outOfOrder)
            XCTFail("An out-of-order frame must be rejected")
        } catch {
            // Expected.
        }
        let outOfOrderSnapshot = await store.snapshot()
        XCTAssertTrue(outOfOrderSnapshot.reanchorRequired)

        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 3, sequence: 20)
        ))
        let changedEpoch = try XCTUnwrap(
            BinaryOutputFrameHeader(sessionID: sessionID, epoch: 4, sequence: 20, payloadLength: 1)
        )
        do {
            _ = try await store.consume(binaryHeader: changedEpoch)
            XCTFail("A frame from another epoch must be rejected")
        } catch {
            // Expected.
        }
        let changedEpochSnapshot = await store.snapshot()
        XCTAssertTrue(changedEpochSnapshot.reanchorRequired)
    }

    func testHeaderOnlyAcceptsLargeLegalLengthWithoutAllocatingPayload() async throws {
        let store = ClientSessionStore(sessionID: sessionID, clientID: clientID)
        _ = try await store.consume(.attached(
            AttachedMessage(sessionID: sessionID, attachmentID: attachmentID, epoch: 8, sequence: 0)
        ))
        let hugeHeader = try XCTUnwrap(
            BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: 8,
                sequence: 0,
                payloadLength: Int.max
            )
        )

        _ = try await store.consume(binaryHeader: hugeHeader)
        let snapshot = await store.snapshot()
        XCTAssertEqual(
            snapshot.recoveryAnchor,
            RecoveryAnchor(epoch: 8, sequence: UInt64(Int.max))
        )
    }

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
