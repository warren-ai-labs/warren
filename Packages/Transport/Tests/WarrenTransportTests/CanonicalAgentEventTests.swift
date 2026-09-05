import XCTest
@testable import WarrenTransport

final class CanonicalAgentEventTests: XCTestCase {
    func testUnknownEventPreservesEnvelopeAndOpaqueTurnID() throws {
        let wire: [String: Any] = [
            "eventId": "evt-1", "streamId": "exec-1", "executionId": "exec-1", "sequence": 1,
            "turnId": "turn-opaque", "type": "future.event", "causedBy": "cmd-1",
            "occurredAt": "2026-01-01T00:00:00Z", "recordedAt": "2026-01-01T00:00:01Z",
            "origin": ["kind": "host", "confidence": "native"], "payload": ["future": ["value": 42]],
        ]
        let data = try JSONSerialization.data(withJSONObject: wire)
        let event = try JSONDecoder().decode(WarrenRemoteAgentEvent.self, from: data)
        let encoded = try JSONEncoder().encode(event)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(roundTrip, wire as NSDictionary)
        for field in ["eventId", "streamId", "executionId", "sequence", "origin", "payload", "occurredAt", "recordedAt"] {
            var malformed = wire
            malformed.removeValue(forKey: field)
            XCTAssertThrowsError(try JSONDecoder().decode(WarrenRemoteAgentEvent.self, from: JSONSerialization.data(withJSONObject: malformed)))
        }
    }

    func testLateHistoryPageDoesNotSkipMissingPrefix() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WarrenAgentEventStore(databasePath: url.path)
        let scope = WarrenAgentEventStore.Namespace(hostID: "host", accessScopeID: "owner")
        func event(_ sequence: UInt64) -> WarrenRemoteAgentEvent {
            .init(sequence: sequence, eventID: "evt-\(sequence)", streamID: "exec", executionID: "exec", type: "future.event", payload: [:])
        }
        let late = try await store.saveEvents([event(3)], namespace: scope, streamID: "exec", checkpointSequence: 3, checkpoint: [:])
        XCTAssertEqual(late.headSequence, 3)
        XCTAssertEqual(late.contiguousThrough, 0)
        let complete = try await store.saveEvents([event(1), event(2)], namespace: scope, streamID: "exec")
        XCTAssertEqual(complete.contiguousThrough, 3)
    }

    func testHistoryBoundaryInstallsReplacementCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WarrenAgentEventStore(databasePath: url.path)
        let scope = WarrenAgentEventStore.Namespace(hostID: "host", accessScopeID: "owner")
        func event(_ sequence: UInt64) -> WarrenRemoteAgentEvent {
            .init(sequence: sequence, eventID: "evt-\(sequence)", streamID: "exec", executionID: "exec", type: "future.event", payload: [:])
        }
        _ = try await store.saveEvents([event(1)], namespace: scope, streamID: "exec")
        let state = try await store.installHistoryBoundary(
            namespace: scope,
            streamID: "exec",
            retainedFromSequence: 3,
            headSequence: 5,
            checkpointSequence: 5,
            checkpoint: [:]
        )
        XCTAssertEqual(state.retainedFromSequence, 3)
        XCTAssertEqual(state.contiguousThrough, 5)
        XCTAssertEqual(state.headSequence, 5)
        let cached = await store.loadRecentEvents(namespace: scope, streamID: "exec")
        XCTAssertTrue(cached.isEmpty)
    }
}
