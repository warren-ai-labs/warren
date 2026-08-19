import Foundation
import XCTest
import WarrenDomain
@testable import Warren

final class WarrenRemoteModelTests: XCTestCase {
    @MainActor
    func testRemoteModelStartsInConnectingState() {
        let model = WarrenRemoteApplicationModel()

        XCTAssertEqual(model.projection.connectionState, .connecting)
    }

    @MainActor
    func testConnectIsIdempotentForTheSameEndpoint() {
        let model = WarrenRemoteApplicationModel()
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Test",
            url: "http://127.0.0.1:9",
            token: "token",
            ssh: nil
        )

        model.connect(endpoint)
        XCTAssertTrue(model.isConnected(to: endpoint))

        // A root `.task` restart on full-screen transitions calls connect
        // again; this must not tear down the healthy connection.
        model.connect(endpoint)
        XCTAssertTrue(model.isConnected(to: endpoint))

        model.disconnect()
        XCTAssertFalse(model.isConnected(to: endpoint))
        model.disconnect()
        XCTAssertFalse(model.isConnected(to: endpoint))
    }

    @MainActor
    func testEqualProjectionDoesNotPublishAgain() {
        let model = WarrenRemoteApplicationModel()
        let initial = model.projection

        XCTAssertFalse(model.publishProjectionIfChanged(initial))
        XCTAssertEqual(model.projectionPublicationCount, 0)

        let changed = type(of: initial).empty(host: Host(name: "Changed"))
        XCTAssertTrue(model.publishProjectionIfChanged(changed))
        XCTAssertEqual(model.projectionPublicationCount, 1)
        XCTAssertFalse(model.publishProjectionIfChanged(changed))
        XCTAssertEqual(model.projectionPublicationCount, 1)
    }

    func testRemoteAttachParametersCarryViewportWithoutClaimingFocus() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: size),
            [
                "id": sessionID.description,
                "focused": "false",
                "cols": "117",
                "rows": "38",
            ]
        )
    }

    func testRemoteAttachParametersRemainExplicitlyPassiveWithoutGrid() {
        let sessionID = TerminalSessionID()

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(sessionID: sessionID, size: nil),
            ["id": sessionID.description, "focused": "false"]
        )
    }

    func testRemoteAttachParametersIncludeRecoveryAnchorWhenKnown() throws {
        let sessionID = TerminalSessionID()
        let size = try XCTUnwrap(TerminalSize(columns: 117, rows: 38))
        let anchor = TerminalOutputAnchor(epoch: 3, sequence: 4096)

        XCTAssertEqual(
            WarrenRemoteTerminalProtocol.attachParameters(
                sessionID: sessionID,
                size: size,
                anchor: anchor
            ),
            [
                "id": sessionID.description,
                "focused": "false",
                "cols": "117",
                "rows": "38",
                "epoch": "3",
                "sequence": "4096",
            ]
        )
    }

    func testRemoteRosterAttachesInitialTabAndDoesNotDuplicateMountedSurface() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 1
        ))
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-2",
            mountedSurfaceCount: 1
        ))
        XCTAssertFalse(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: nil,
            nextTabID: nil,
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterReattachesSameTabAfterTransportReset() {
        XCTAssertTrue(WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: "tab-1",
            nextTabID: "tab-1",
            mountedSurfaceCount: 0
        ))
    }

    func testRemoteRosterDecodesOptionalWorkspaceMergeState() throws {
        let data = Data(
            """
            {
              "host": {"id": "11111111-1111-4111-8111-111111111111", "name": "Mac"},
              "projects": [],
              "workspaces": [
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "review",
                  "path": "/tmp/review",
                  "branch": "review",
                  "mergeState": "merged"
                },
                {
                  "id": "44444444-4444-4444-8444-444444444444",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "legacy",
                  "path": "/tmp/legacy",
                  "branch": "legacy"
                },
                {
                  "id": "55555555-5555-4555-8555-555555555555",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "future",
                  "path": "/tmp/future",
                  "branch": "future",
                  "mergeState": "future-state"
                }
              ],
              "terminalGroups": [],
              "sessions": []
            }
            """.utf8
        )

        let roster = try JSONDecoder().decode(RemoteRoster.self, from: data)
        XCTAssertEqual(roster.workspaces[0].mergeState, "merged")
        XCTAssertNil(roster.workspaces[1].mergeState)
        XCTAssertEqual(roster.workspaces[2].mergeState, "future-state")
        XCTAssertEqual(
            roster.workspaces[0].mergeState.flatMap(WorkspaceMergeState.init(rawValue:)),
            .merged
        )
        XCTAssertNil(
            roster.workspaces[2].mergeState.flatMap(WorkspaceMergeState.init(rawValue:))
        )
    }

    func testReconnectDelayBacksOffExponentiallyAndCapsAtThirtySeconds() {
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 0), 500)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 1), 1_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 2), 2_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 6), 30_000)
        XCTAssertEqual(WarrenRemoteApplicationModel.reconnectDelay(attempt: 99), 30_000)
    }

    func testRemoteTabOrderingMovesBeforeDestinationAndToEnd() {
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-c", before: "tab-a", in: [
                "tab-a", "tab-b", "tab-c",
            ]),
            ["tab-c", "tab-a", "tab-b"]
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: nil, in: [
                "tab-a", "tab-b", "tab-c",
            ]),
            ["tab-b", "tab-c", "tab-a"]
        )
    }

    func testRemoteTabOrderingRejectsInvalidMoves() {
        let tabs = ["tab-a", "tab-b", "tab-c"]

        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("missing", before: "tab-a", in: tabs),
            tabs
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: "missing", in: tabs),
            tabs
        )
        XCTAssertEqual(
            WarrenRemoteTabOrdering.moving("tab-a", before: "tab-a", in: tabs),
            tabs
        )
    }

    func testRemoteTabOrderingReconcilesRosterChanges() {
        XCTAssertEqual(
            WarrenRemoteTabOrdering.reconciling(
                preferredOrder: ["tab-c", "closed", "tab-a", "tab-c"],
                availableTabIDs: ["tab-a", "tab-b", "tab-c", "tab-new"]
            ),
            ["tab-c", "tab-a", "tab-b", "tab-new"]
        )
    }

    func testStaleSessionDeleteErrorIsBenign() {
        let sessionID = TerminalSessionID()

        XCTAssertTrue(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: \(sessionID)",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "session not found: another-id",
            ]),
            sessionID: sessionID
        ))
        XCTAssertFalse(WarrenRemoteApplicationModel.isSessionAlreadyClosed(
            NSError(domain: "WarrenRemote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "tmux kill failed",
            ]),
            sessionID: sessionID
        ))
    }

    func testActivityDismissalHidesOnlyTheDismissedState() {
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .ready,
                dismissed: nil
            ),
            WarrenActivityDismissal.Presentation(
                activity: .ready,
                clearsDismissal: false
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .ready,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: nil,
                clearsDismissal: false
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: .working,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: .working,
                clearsDismissal: true
            )
        )
        XCTAssertEqual(
            WarrenActivityDismissal.presentedActivity(
                candidate: nil,
                dismissed: .ready
            ),
            WarrenActivityDismissal.Presentation(
                activity: nil,
                clearsDismissal: true
            )
        )
        XCTAssertTrue(WarrenActivityDismissal.canDismiss(
            candidate: .working,
            expected: .working
        ))
        XCTAssertFalse(WarrenActivityDismissal.canDismiss(
            candidate: .waitingForInput,
            expected: .working
        ))
    }

    func testLosslessAsyncBufferBackpressuresAndPreservesOrder() async throws {
        let buffer = WarrenLosslessAsyncBuffer<Int>(capacity: 2)
        let progress = SendProgress()
        let producer = Task {
            for value in 0..<100 {
                guard await buffer.send(value) else { return false }
                await progress.recordSend()
            }
            return true
        }

        await progress.waitForSends(2)
        try await Task.sleep(for: .milliseconds(2))
        let sentBeforeConsumption = await progress.sentCount
        XCTAssertEqual(sentBeforeConsumption, 2)

        var iterator = buffer.stream.makeAsyncIterator()
        var received: [Int] = []
        for _ in 0..<100 {
            let next = await iterator.next()
            received.append(try XCTUnwrap(next))
        }
        let completed = await producer.value
        XCTAssertTrue(completed)
        buffer.finish()
        XCTAssertEqual(received, Array(0..<100))
    }

    func testOrderedInputBridgePreservesBracketedPasteFenceposts() async throws {
        let recorder = LockedDataRecorder()
        let bridge = WarrenOrderedInputBridge { data in
            recorder.append(data)
        }
        let pasteStart = Data("\u{1b}[200~".utf8)
        let pasteEnd = Data("\u{1b}[201~".utf8)
        let pasteCount = 10_000
        var expected = Data()
        for index in 0..<pasteCount {
            expected.append(pasteStart)
            expected.append(Data("payload-\(index)".utf8))
            expected.append(pasteEnd)
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for index in 0..<pasteCount {
                    bridge.send(pasteStart)
                    bridge.send(Data("payload-\(index)".utf8))
                    bridge.send(pasteEnd)
                }
                continuation.resume()
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while recorder.count < expected.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recorder.data, expected)
    }

    func testTerminalOutputBufferDeduplicatesOverlapAndKeepsSequenceGaps() {
        var buffer = WarrenTerminalOutputBuffer()
        buffer.reset(epoch: 7, sequence: 0)
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 0, payload: Data("abcdef".utf8))
        buffer.append(epoch: 7, sequence: 3, payload: Data("defghi".utf8))

        var slices: [WarrenTerminalOutputSlice] = []
        while let slice = buffer.take(maxBytes: 4) { slices.append(slice) }
        XCTAssertEqual(slices.map(\.sequence), [0, 4, 6])
        XCTAssertEqual(
            Data(slices.flatMap { $0.payload }),
            Data("abcdefghi".utf8)
        )
        XCTAssertEqual(buffer.enqueuedSequence, 9)

        buffer.append(epoch: 8, sequence: 100, payload: Data("xyz".utf8))
        XCTAssertEqual(buffer.take(maxBytes: 8), WarrenTerminalOutputSlice(
            epoch: 8,
            sequence: 100,
            payload: Data("xyz".utf8)
        ))
    }
}

private actor SendProgress {
    private(set) var sentCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordSend() {
        sentCount += 1
        let ready = waiters.filter { sentCount >= $0.count }
        waiters.removeAll { sentCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSends(_ count: Int) async {
        guard sentCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private final class LockedDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}
