import XCTest
@testable import WarrenIOS
import WarrenTransport

final class WarrenAgentEventStoreTests: XCTestCase {
    private var tempDBURL: URL!
    private var store: WarrenAgentEventStore!
    private let owner = WarrenAgentEventStore.Namespace(hostID: "host-1", accessScopeID: "scope-owner")
    private let shared = WarrenAgentEventStore.Namespace(hostID: "host-1", accessScopeID: "scope-shared")

    override func setUp() async throws {
        try await super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-agent-\(UUID().uuidString).sqlite3")
        store = WarrenAgentEventStore(databasePath: tempDBURL.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDBURL)
        try await super.tearDown()
    }

    private func event(
        _ sequence: UInt64,
        id: String,
        type: String = "message.created",
        content: String? = nil
    ) -> WarrenRemoteAgentEvent {
        WarrenRemoteAgentEvent(
            sequence: sequence,
            eventID: id,
            streamID: "exec-1",
            executionID: "exec-1",
            type: type,
            payload: content.map { ["content": .string($0)] }
        )
    }

    func testNamespaceAndStreamKeysAreIsolated() async throws {
        try await store.saveEvents([event(1, id: "evt-1")], namespace: owner, streamID: "exec-1")
        try await store.saveEvents([event(1, id: "evt-shared")], namespace: shared, streamID: "exec-1")
        try await store.saveEvents([event(1, id: "evt-other")], namespace: owner, streamID: "exec-2")

        let ownerEvents = await store.loadRecentEvents(namespace: owner, streamID: "exec-1")
        let sharedEvents = await store.loadRecentEvents(namespace: shared, streamID: "exec-1")
        let otherEvents = await store.loadRecentEvents(namespace: owner, streamID: "exec-2")
        XCTAssertEqual(ownerEvents.map(\.eventID), ["evt-1"])
        XCTAssertEqual(sharedEvents.map(\.eventID), ["evt-shared"])
        XCTAssertEqual(otherEvents.map(\.eventID), ["evt-other"])
    }

    func testDuplicateIsIdempotentAndConflictsAreRejected() async throws {
        let first = event(1, id: "evt-1", content: "hello")
        let state = try await store.saveEvents([first], namespace: owner, streamID: "exec-1")
        XCTAssertEqual(state.headSequence, 1)
        XCTAssertEqual(state.contiguousThrough, 1)

        _ = try await store.saveEvents([first], namespace: owner, streamID: "exec-1")
        let initialEvents = await store.loadRecentEvents(namespace: owner, streamID: "exec-1")
        XCTAssertEqual(initialEvents.count, 1)

        do {
            _ = try await store.saveEvents(
                [event(1, id: "evt-other", content: "different")],
                namespace: owner,
                streamID: "exec-1"
            )
            XCTFail("expected a sequence conflict")
        } catch {
            XCTAssertEqual(error as? WarrenAgentEventStoreError, .sequenceConflict(streamID: "exec-1", sequence: 1))
        }

        do {
            _ = try await store.saveEvents(
                [event(2, id: "evt-1", content: "hello")],
                namespace: owner,
                streamID: "exec-1"
            )
            XCTFail("expected an event conflict")
        } catch {
            XCTAssertEqual(error as? WarrenAgentEventStoreError, .eventConflict(streamID: "exec-1", eventID: "evt-1"))
        }
    }

    func testGapCursorAndCheckpointRemainExplicit() async throws {
        _ = try await store.saveEvents(
            [event(1, id: "evt-1"), event(3, id: "evt-3")],
            namespace: owner,
            streamID: "exec-1"
        )
        let initialState = await store.syncState(namespace: owner, streamID: "exec-1")
        var state = try XCTUnwrap(initialState)
        XCTAssertEqual(state.headSequence, 3)
        XCTAssertEqual(state.contiguousThrough, 1)

        state = try await store.saveEvents(
            [event(2, id: "evt-2")],
            namespace: owner,
            streamID: "exec-1",
            checkpointSequence: 3,
            checkpoint: ["status": .string("working")]
        )
        XCTAssertEqual(state.contiguousThrough, 3)
        XCTAssertEqual(state.checkpointSequence, 3)
        XCTAssertEqual(state.checkpoint?["status"], .string("working"))

        state = try await store.saveEvents([], namespace: owner, streamID: "exec-1")
        XCTAssertEqual(state.checkpoint?["status"], .string("working"))
    }

    func testHistoryRangeAndLifecycleCleanup() async throws {
        _ = try await store.saveEvents(
            (1...4).map { event(UInt64($0), id: "evt-\($0)") },
            namespace: owner,
            streamID: "exec-1"
        )
        let range = await store.loadEvents(
            namespace: owner,
            streamID: "exec-1",
            afterSequence: 1,
            beforeSequence: 4,
            limit: 20
        )
        XCTAssertEqual(range.map(\.sequence), [2, 3])

        await store.clearStream(namespace: owner, streamID: "exec-1")
        let clearedState = await store.syncState(namespace: owner, streamID: "exec-1")
        XCTAssertNil(clearedState)

        _ = try await store.saveEvents([event(1, id: "evt-2")], namespace: owner, streamID: "exec-2")
        _ = try await store.saveEvents([event(1, id: "evt-3")], namespace: shared, streamID: "exec-1")
        await store.clearNamespace(owner)
        let ownerEvents = await store.loadRecentEvents(namespace: owner, streamID: "exec-2")
        let sharedEvents = await store.loadRecentEvents(namespace: shared, streamID: "exec-1")
        XCTAssertTrue(ownerEvents.isEmpty)
        XCTAssertEqual(sharedEvents.count, 1)
    }
}
