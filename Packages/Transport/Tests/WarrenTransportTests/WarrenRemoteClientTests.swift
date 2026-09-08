import Foundation
import XCTest
import WarrenDomain
import WarrenProtocol
@testable import WarrenTransport

final class WarrenRemoteClientTests: XCTestCase {
    private let sessionUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testAuthAndImmediateWelcomeAreHandledWithoutAReceiveRace() async throws {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"4.0\",\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\",\"version\":\"dev\"},\"accessScopeId\":\"scope-owner\",\"capabilities\":[\"roster-delta\"]}"))
        await task.enqueue(.text(rosterJSON(revision: 1)))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let recorder = EventRecorder()
        let consuming = recordEvents(from: client.events(), into: recorder)
        await client.start()

        try await waitUntil { await client.state() == .connected }
        let sent = await waitForSentMessages(task, count: 1)
        guard case .text(let auth) = sent[0] else {
            XCTFail("auth must be sent as text")
            return
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "auth")
        XCTAssertEqual(object["version"] as? String, "4.0")
        XCTAssertEqual(object["terminalStateFormats"] as? [String], ["ghostline-vt-replay-v1"])
        XCTAssertEqual(object["capabilities"] as? [String], ["roster-delta"])

        try await waitUntil { await client.roster() != nil }
        let initialRevision = await client.roster()?.revision
        XCTAssertEqual(initialRevision, 1)
        let sawWelcome = await recorder.contains { event in
            if case .welcome(version: "4.0") = event { return true }
            return false
        }
        XCTAssertTrue(sawWelcome)
        await client.stop()
        consuming.cancel()
    }

    func testTerminalStateFormatIsConfiguredPerClient() async throws {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"4.0\",\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"accessScopeId\":\"scope-owner\"}"))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Desktop", url: "http://example.test"),
            task: task,
            terminalStateFormats: [WarrenRemoteClient.snapshotTerminalStateFormat]
        )
        let consuming = recordEvents(from: client.events(), into: EventRecorder())
        await client.start()
        try await waitUntil { await client.state() == .connected }
        let sent = await waitForSentMessages(task, count: 1)
        guard case .text(let auth) = sent[0],
              let object = try JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any] else {
            XCTFail("auth must be sent as JSON text")
            return
        }
        XCTAssertEqual(
            object["terminalStateFormats"] as? [String],
            [WarrenRemoteClient.snapshotTerminalStateFormat]
        )
        await client.stop()
        consuming.cancel()
    }

    func testProtocolVersionRequiresExactMatch() {
        XCTAssertTrue(WarrenRemoteClient.compatibleProtocolVersion("4.0", with: "4.0"))
        XCTAssertFalse(WarrenRemoteClient.compatibleProtocolVersion("4.1", with: "4.0"))
        XCTAssertFalse(WarrenRemoteClient.compatibleProtocolVersion("3.0", with: "4.0"))
    }

    func testRelayAuthUsesAccessTokenAndHostScopedEndpoint() async throws {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"4.0\",\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\",\"version\":\"dev\"},\"accessScopeId\":\"scope-owner\",\"capabilities\":[\"roster-delta\"]}"))
        await task.enqueue(.text(rosterJSON(revision: 1)))
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: "https://relay.example.test/relay",
            token: "relay-access",
            type: "relay",
            hostID: "host-123",
            clientID: "desktop-client-1"
        )
        let client = WarrenRemoteClient(configuration: endpoint, task: task)
        let consuming = recordEvents(from: client.events(), into: EventRecorder())
        await client.start()

        try await waitUntil { await client.state() == .connected }
        let sent = await waitForSentMessages(task, count: 1)
        guard case .text(let auth) = sent[0],
              let object = try JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any] else {
            XCTFail("relay auth must be sent as JSON text")
            return
        }
        XCTAssertEqual(object["access_token"] as? String, "relay-access")
        XCTAssertEqual(object["client_id"] as? String, "desktop-client-1")
        XCTAssertNil(object["token"])
        XCTAssertEqual(endpoint.webSocketURL?.absoluteString, "wss://relay.example.test/relay/h/host-123/v1/client/connect")
        await client.stop()
        consuming.cancel()
    }

    func testLiveActivityPushTokenRegistrationUsesHostScopedHTTPAPI() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LiveActivityURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        LiveActivityURLProtocol.reset()
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: "https://relay.example.test/relay",
            token: "relay-access",
            type: "relay",
            hostID: "host-123"
        )
        let client = WarrenRemoteClient(
            configuration: endpoint,
            task: ScriptedWebSocketTask(),
            urlSession: session
        )

        let registered = try await client.registerLiveActivityPushToken(sessionID: "session-1", token: "aabb")
        let unregistered = try await client.unregisterLiveActivityPushToken(sessionID: "session-1", token: "aabb")
        XCTAssertTrue(registered)
        XCTAssertTrue(unregistered)
        let requests = LiveActivityURLProtocol.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        for request in requests {
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://relay.example.test/relay/h/host-123/v1/live-activities"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer relay-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
    }

    func testIncompatibleWelcomeReportsProtocolError() async throws {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"1.0\"}"))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let recorder = EventRecorder()
        let consuming = recordEvents(from: client.events(), into: recorder)
        await client.start()
        try await waitUntil {
            await recorder.contains { event in
                if case .disconnected(let reason) = event {
                    return reason.contains("protocol mismatch")
                }
                return false
            }
        }
        await client.stop()
        consuming.cancel()
    }

    func testRejectedProtocolAndTerminalFormatStopReconnecting() async throws {
        for rejection in [
            "incompatible protocol version: client=4.0 server=3.0",
            "upgrade required: client does not support a compatible atomic terminal state format",
        ] {
            let task = ScriptedWebSocketTask()
            let data = try JSONSerialization.data(withJSONObject: ["t": "error", "error": rejection])
            await task.enqueue(.text(String(decoding: data, as: UTF8.self)))
            let client = WarrenRemoteClient(
                configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://127.0.0.1:9"),
                task: task
            )
            let recorder = EventRecorder()
            let consuming = recordEvents(from: client.events(), into: recorder)
            await client.start()
            try await waitUntil { await client.state() == .disconnected }
            // The old path retries after 500 ms; a fatal rejection must stay stopped.
            try await Task.sleep(for: .milliseconds(650))
            let state = await client.state()
            XCTAssertEqual(state, .disconnected)
            let sawReason = await recorder.contains {
                if case .disconnected(let reason) = $0 {
                    return reason.contains(rejection) && !reason.contains("authentication failed")
                }
                return false
            }
            XCTAssertTrue(sawReason)
            await client.stop()
            consuming.cancel()
        }
    }

    func testAuthenticationRejectionKeepsItsReasonAndRetryPolicy() async throws {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text(#"{"t":"error","error":"unauthorized"}"#))
        let client = WarrenRemoteClient(
            configuration: .init(name: "Host", url: "http://127.0.0.1:9"), task: task
        )
        let recorder = EventRecorder()
        let consuming = recordEvents(from: client.events(), into: recorder)
        await client.start()
        try await waitUntil { await client.state() == .reconnecting }
        let sawReason = await recorder.contains {
            if case .disconnected(let reason) = $0 { return reason.contains("authentication failed: unauthorized") }
            return false
        }
        XCTAssertTrue(sawReason)
        await client.stop()
        consuming.cancel()
    }

    func testRequestResponseUsesRequestIDAndDecodesResult() async throws {
        let (client, task, consuming, _) = try await connectedClient()
        let request = Task {
            try await client.request("roster", decoding: WarrenRemoteRoster.self)
        }
        let sent = await waitForSentMessages(task, count: 2)
        guard case .text(let requestText) = sent[1],
              let object = try? JSONSerialization.jsonObject(with: Data(requestText.utf8)) as? [String: Any],
              let id = object["id"] as? String else {
            XCTFail("request envelope missing id")
            return
        }
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"\(id)\",\"ok\":true,\"result\":\(rosterJSONValue())}"))
        let roster = try await request.value
        XCTAssertEqual(roster.host.name, "Test Host")
        await client.stop()
        consuming.cancel()
    }

    func testRosterDecodesCurrentTaskAndOwnershipFields() throws {
        let json = """
        {
          "schema": 2,
          "revision": 4,
          "host": {"id": "host-1", "name": "Test Host", "version": "dev"},
          "tasks": [{
            "id": "task-1", "name": "Fix protocol", "source": "tracker",
            "externalID": "ext-1", "url": "https://tracker.invalid/1",
            "creationRequestId": "request-1", "creationRequestHash": "hash-1",
            "pinned": true, "order": 3, "createdAt": "2026-01-02T03:04:05Z"
          }],
          "projects": [{
            "id": "project-1", "name": "Warren", "path": "/tmp/warren",
            "setupScript": "scripts/setup.sh", "autoImportGitWorktrees": true
          }],
          "workspaces": [{
            "id": "workspace-1", "project": "project-1", "task": "task-1",
            "name": "feature/protocol", "path": "/tmp/warren-worktree",
            "branch": "feature/protocol", "kind": "worktree"
          }],
          "terminalGroups": [],
          "sessions": []
        }
        """
        let roster = try JSONDecoder().decode(WarrenRemoteRoster.self, from: Data(json.utf8))
        let task = try XCTUnwrap(roster.tasks.first)
        XCTAssertEqual(task.id, "task-1")
        XCTAssertEqual(task.creationRequestID, "request-1")
        XCTAssertTrue(task.pinned)
        XCTAssertEqual(roster.projects.first?.setupScript, "scripts/setup.sh")
        XCTAssertEqual(roster.workspaces.first?.taskID, "task-1")
    }

    func testRosterDeltaAppliesTaskChanges() throws {
        let roster = WarrenRemoteRoster(
            revision: 1,
            host: .init(id: "host-1", name: "Test Host"),
            tasks: [.init(id: "task-1", name: "Old")]
        )
        let delta = WarrenRemoteRoster.Delta(
            baseRevision: 1,
            revision: 2,
            tasks: .init(
                upsert: [.init(id: "task-1", name: "Updated"), .init(id: "task-2", name: "New")],
                remove: [],
                order: ["task-2", "task-1"]
            )
        )
        let merged = try XCTUnwrap(roster.applying(delta))
        XCTAssertEqual(merged.tasks.map(\.id), ["task-2", "task-1"])
        XCTAssertEqual(merged.tasks.first?.name, "New")
        XCTAssertEqual(merged.tasks.last?.name, "Updated")
    }

    func testRosterDeltaMergesAndAStaleBaseRequestsAnAtomicRoster() async throws {
        let (client, task, consuming, recorder) = try await connectedClient()
        let initialRoster = await client.roster()
        let initial = try XCTUnwrap(initialRoster)
        XCTAssertEqual(initial.revision, 1)
        let delta = "{\"t\":\"roster.delta\",\"baseRevision\":1,\"revision\":2,\"sessions\":{\"upsert\":[{\"id\":\"\(sessionUUID.uuidString.lowercased())\",\"workspace\":\"workspace-2\",\"scope\":\"workspace\",\"title\":\"shell\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"
        await task.enqueue(.text(delta))
        try await waitUntil { await client.roster()?.revision == 2 }
        let mergedWorkspace = await client.roster()?.sessions.first?.workspaceID
        XCTAssertEqual(mergedWorkspace, "workspace-2")

        // A mismatched base revision causes the client to request a fresh
        // snapshot instead of applying a potentially destructive patch.
        await task.enqueue(.text("{\"t\":\"roster.delta\",\"baseRevision\":99,\"revision\":100}"))
        let sent = await waitForSentMessages(task, count: 2)
        guard case .text(let requestText) = sent.last,
              let object = try? JSONSerialization.jsonObject(with: Data(requestText.utf8)) as? [String: Any],
              let id = object["id"] as? String else {
            XCTFail("roster recovery request missing")
            return
        }
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"\(id)\",\"ok\":true,\"result\":\(rosterJSONValue(revision: 3))}"))
        try await waitUntil { await client.roster()?.revision == 3 }
        let sawDelta = await recorder.contains { event in
            if case .rosterDelta = event { return true }
            return false
        }
        XCTAssertTrue(sawDelta)
        await client.stop()
        consuming.cancel()
    }

    func testBinaryRecoveryUpdatesAnchorAndWaitsForSynced() async throws {
        let (client, task, consuming, recorder) = try await connectedClient()
        let session = TerminalSessionID(rawValue: sessionUUID)
        let codec = WarrenWireCodec()
        let payload = Data("prompt$ ".utf8)
        let header = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: session,
            epoch: 8,
            sequence: 64,
            format: "ghostline-vt-replay-v1",
            payloadLength: payload.count
        ))
        await task.enqueue(.text("{\"t\":\"attached\",\"session\":\"\(sessionUUID.uuidString.lowercased())\",\"epoch\":8,\"sequence\":64,\"reanchor\":true}"))
        await task.enqueue(.binary(try codec.encodeAtomicState(header: header, payload: payload)))
        await task.enqueue(.text("{\"t\":\"synced\",\"session\":\"\(sessionUUID.uuidString.lowercased())\",\"epoch\":8,\"sequence\":64}"))

        try await waitUntil {
            await client.recoveryAnchor(for: self.sessionUUID.uuidString.lowercased()) == WarrenRemoteRecoveryAnchor(epoch: 8, sequence: 64)
        }
        try await waitUntil {
            await recorder.contains { event in
                if case .atomicState(let state) = event { return state.payload == payload }
                return false
            }
        }
        try await waitUntil {
            await recorder.contains { event in
                if case .anchor(let anchor) = event { return anchor.synced }
                return false
            }
        }
        await client.stop()
        consuming.cancel()
    }

    func testWorkspaceCreateResultDecodesEmbeddedWorkspace() throws {
        let data = Data("""
        {"id":"workspace-1","project":"project-1","name":"feature/chat","path":"/tmp/chat","branch":"feature/chat","kind":"worktree","created":true,"gitWorktree":true}
        """.utf8)
        let result = try JSONDecoder().decode(WarrenRemoteWorkspaceCreateResult.self, from: data)
        XCTAssertEqual(result.workspace.id, "workspace-1")
        XCTAssertEqual(result.workspace.projectID, "project-1")
        XCTAssertTrue(result.created)
        XCTAssertTrue(result.gitWorktree)
    }

    func testSubscribeThenUnsubscribeAreSentInOrder() async throws {
        let (client, task, consuming, _) = try await connectedClient()
        let sessionID = sessionUUID.uuidString.lowercased()
        let subscribe = Task { try await client.subscribe(sessionID: sessionID) }
        let subscribeMessages = await waitForSentMessages(task, count: 2)
        let subscribeMessage = try XCTUnwrap(subscribeMessages.dropFirst().first)
        let subscribeID = try requestID(from: subscribeMessage)
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"\(subscribeID)\",\"ok\":true,\"result\":{\"subscribed\":true,\"attachmentId\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\"}}"))
        let subscribeResult = try await subscribe.value
        XCTAssertTrue(subscribeResult.subscribed)

        let unsubscribe = Task { try await client.unsubscribe(sessionID: sessionID) }
        let messages = await waitForSentMessages(task, count: 3)
        let unsubscribeID = try requestID(from: messages[2])
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"\(unsubscribeID)\",\"ok\":true,\"result\":{\"unsubscribed\":true}}"))
        let unsubscribed = try await unsubscribe.value
        XCTAssertTrue(unsubscribed)
        await client.stop()
        consuming.cancel()
    }

    func testAgentEventsHistoryUsesCanonicalCursors() async throws {
        let (client, task, consuming, _) = try await connectedClient()
        let request = Task {
            try await client.agentEventsHistory(
                streamID: "exec-001",
                beforeSequence: 42,
                limit: 12
            )
        }
        let messages = await waitForSentMessages(task, count: 2)
        let requestMessage = try XCTUnwrap(messages.last)
        guard case .text(let text) = requestMessage,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let params = object["params"] as? [String: Any] else {
            XCTFail("agent history request is malformed")
            return
        }
        XCTAssertEqual(params["streamId"] as? String, "exec-001")
        XCTAssertEqual(params["beforeSequence"] as? UInt64, 42)
        XCTAssertEqual(params["limit"] as? Int, 12)
        let id = try XCTUnwrap(object["id"] as? String)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + id + "\",\"ok\":true,\"result\":{\"streamId\":\"exec-001\",\"events\":[],\"headSequence\":0,\"hasMore\":false}}"
        ))
        let page = try await request.value
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertFalse(page.hasMore)
        await client.stop()
        consuming.cancel()
    }

    private func connectedClient() async throws -> (
        WarrenRemoteClient,
        ScriptedWebSocketTask,
        Task<Void, Never>,
        EventRecorder
    ) {
        let task = ScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"4.0\",\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\",\"version\":\"dev\"},\"accessScopeId\":\"scope-owner\",\"capabilities\":[\"roster-delta\"]}"))
        await task.enqueue(.text(rosterJSON(revision: 1)))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let recorder = EventRecorder()
        let consuming = recordEvents(from: client.events(), into: recorder)
        await client.start()
        try await waitUntil { await client.state() == .connected }
        return (client, task, consuming, recorder)
    }

    private func requestID(from message: WarrenWebSocketMessage) throws -> String {
        guard case .text(let text) = message,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? String else {
            throw WarrenRemoteClientError.invalidResponse
        }
        return id
    }

    private func rosterJSON(revision: Int = 1) -> String {
        "{\"t\":\"roster\",\"state\":\(rosterJSONValue(revision: revision))}"
    }

    private func rosterJSONValue(revision: Int = 1) -> String {
        "{\"schema\":1,\"revision\":\(revision),\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\",\"version\":\"dev\"},\"tasks\":[],\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[]}"
    }

    private func waitForSentMessages(
        _ task: ScriptedWebSocketTask,
        count: Int,
        timeout: Duration = .seconds(2)
    ) async -> [WarrenWebSocketMessage] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let messages = await task.sentMessages
            if messages.count >= count { return messages }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await task.sentMessages
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition timed out")
    }

    private func recordEvents(
        from stream: AsyncStream<WarrenRemoteEvent>,
        into recorder: EventRecorder
    ) -> Task<Void, Never> {
        Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
    }
}

private final class LiveActivityURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func reset() {
            lock.lock()
            requests.removeAll()
            lock.unlock()
        }
    }

    private static let state = State()

    static func reset() {
        state.reset()
    }

    static func requests() -> [URLRequest] {
        state.snapshot()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: WarrenRemoteClientError.invalidEndpoint)
            return
        }
        Self.state.append(request)
        let body: Data
        let status: Int
        if request.httpMethod == "POST" {
            body = Data(#"{"registered":true}"#.utf8)
            status = 200
        } else {
            body = Data(#"{"unregistered":true}"#.utf8)
            status = 200
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: WarrenRemoteClientError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


private actor EventRecorder {
    private var events: [WarrenRemoteEvent] = []

    func append(_ event: WarrenRemoteEvent) { events.append(event) }

    func contains(_ predicate: (WarrenRemoteEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}
