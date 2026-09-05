import XCTest
@testable import WarrenIOS
import WarrenTransport

final class IOSAgentEventStoreTests: XCTestCase {
    var tempDBURL: URL!
    var store: IOSAgentEventStore!

    override func setUp() async throws {
        try await super.setUp()
        let filename = "test-agent-\(UUID().uuidString).sqlite3"
        tempDBURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        store = IOSAgentEventStore(databasePath: tempDBURL.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDBURL)
        try await super.tearDown()
    }

    func testSaveAndLoadRecentEvents() async throws {
        let sessionID = "test-session-1"
        let epoch: UInt64 = 100

        let events = [
            WarrenRemoteAgentEvent(sequence: 1, type: "user", role: "user", content: "hello"),
            WarrenRemoteAgentEvent(sequence: 2, type: "assistant", role: "assistant", content: "hi there"),
            WarrenRemoteAgentEvent(sequence: 3, type: "tool_call", toolName: "read_file"),
            WarrenRemoteAgentEvent(sequence: 4, type: "tool_output", output: "content"),
        ]

        try await store.saveEvents(events, sessionID: sessionID, epoch: epoch)

        let maxSeq = await store.maxSequence(sessionID: sessionID, epoch: epoch)
        XCTAssertEqual(maxSeq, 4)

        let loaded = await store.loadRecentEvents(sessionID: sessionID, limit: 10)
        XCTAssertEqual(loaded.count, 4)
        XCTAssertEqual(loaded[0].sequence, 1)
        XCTAssertEqual(loaded[0].content, "hello")
        XCTAssertEqual(loaded[1].sequence, 2)
        XCTAssertEqual(loaded[1].content, "hi there")
        XCTAssertEqual(loaded[2].sequence, 3)
        XCTAssertEqual(loaded[2].toolName, "read_file")
        XCTAssertEqual(loaded[3].sequence, 4)
        XCTAssertEqual(loaded[3].output, "content")
    }

    func testLoadEventsWithRange() async throws {
        let sessionID = "test-session-range"
        let epoch: UInt64 = 200

        var events: [WarrenRemoteAgentEvent] = []
        for i in 1...10 {
            events.append(WarrenRemoteAgentEvent(sequence: UInt64(i), type: "assistant", content: "msg \(i)"))
        }

        try await store.saveEvents(events, sessionID: sessionID, epoch: epoch)

        // Query since 3, before 7 -> 3, 4, 5, 6
        let range = await store.loadEvents(sessionID: sessionID, epoch: epoch, since: 3, before: 7, limit: 10)
        XCTAssertEqual(range.count, 4)
        XCTAssertEqual(range.map(\.sequence), [3, 4, 5, 6])
    }

    func testLoadRecentEventsCanBeScopedToEpoch() async throws {
        let sessionID = "test-session-epochs"
        let firstEpoch: UInt64 = 500
        let secondEpoch: UInt64 = 501

        try await store.saveEvents(
            [WarrenRemoteAgentEvent(sequence: 1, type: "assistant", content: "old")],
            sessionID: sessionID,
            epoch: firstEpoch
        )
        try await store.saveEvents(
            [WarrenRemoteAgentEvent(sequence: 1, type: "assistant", content: "new")],
            sessionID: sessionID,
            epoch: secondEpoch
        )

        let loaded = await store.loadRecentEvents(sessionID: sessionID, epoch: secondEpoch, limit: 10)
        XCTAssertEqual(loaded.map(\.content), ["new"])
    }

    func testSyncStateResetsMaxSequenceWhenEpochChanges() async throws {
        let sessionID = "test-session-sync-epoch"
        try await store.saveEvents(
            [WarrenRemoteAgentEvent(sequence: 42, type: "assistant", content: "old")],
            sessionID: sessionID,
            epoch: 600
        )
        try await store.saveEvents(
            [WarrenRemoteAgentEvent(sequence: 3, type: "assistant", content: "new")],
            sessionID: sessionID,
            epoch: 601
        )

        let state = await store.syncState(sessionID: sessionID)
        XCTAssertEqual(state?.epoch, 601)
        XCTAssertEqual(state?.maxSequence, 3)
    }

    func testPurgeOrphanSessionsWithEmptyRoster() async throws {
        let sessionID = "test-session-orphan"
        try await store.saveEvents(
            [WarrenRemoteAgentEvent(sequence: 1, type: "assistant", content: "orphan")],
            sessionID: sessionID,
            epoch: 700
        )

        await store.purgeOrphanSessions(activeSessionIDs: [])

        let state = await store.syncState(sessionID: sessionID)
        let events = await store.loadRecentEvents(sessionID: sessionID, limit: 10)
        XCTAssertNil(state)
        XCTAssertTrue(events.isEmpty)
    }

    func testClearSession() async throws {
        let sessionID = "test-session-clear"
        let epoch: UInt64 = 300

        let events = [
            WarrenRemoteAgentEvent(sequence: 1, type: "user", content: "clear me")
        ]
        try await store.saveEvents(events, sessionID: sessionID, epoch: epoch)

        var loaded = await store.loadRecentEvents(sessionID: sessionID, limit: 10)
        XCTAssertEqual(loaded.count, 1)

        await store.clearSession(sessionID: sessionID)

        loaded = await store.loadRecentEvents(sessionID: sessionID, limit: 10)
        XCTAssertTrue(loaded.isEmpty)
        let maxSeq = await store.maxSequence(sessionID: sessionID, epoch: epoch)
        XCTAssertEqual(maxSeq, 0)
    }

    func testSaveOversizedToolOutputIsClipped() async throws {
        let sessionID = "test-session-clip"
        let epoch: UInt64 = 400

        let longOutput = String(repeating: "A", count: 10000)
        let longContent = String(repeating: "B", count: 50000)
        let events = [
            WarrenRemoteAgentEvent(sequence: 1, type: "tool_output", output: longOutput),
            WarrenRemoteAgentEvent(sequence: 2, type: "assistant", role: "assistant", content: longContent),
        ]

        try await store.saveEvents(events, sessionID: sessionID, epoch: epoch)

        let loaded = await store.loadRecentEvents(sessionID: sessionID, limit: 10)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue((loaded[0].output?.count ?? 0) <= 4097)
        XCTAssertTrue(loaded[0].output?.hasSuffix("…") == true)
        // Conversational messages must NEVER be clipped regardless of size
        XCTAssertEqual(loaded[1].content?.count, 50000)
        XCTAssertEqual(loaded[1].content, longContent)
    }
}
