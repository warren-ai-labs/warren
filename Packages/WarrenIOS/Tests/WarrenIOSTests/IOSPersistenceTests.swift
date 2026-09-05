import XCTest
@testable import WarrenIOS
import WarrenTransport
import WarrenProtocol
import WarrenDomain

final class IOSPersistenceTests: XCTestCase {
    func testSessionRailAggregatesOnlyAboveTwoSessions() {
        XCTAssertEqual(sessionRailLayout(for: 0), .tabs)
        XCTAssertEqual(sessionRailLayout(for: 2), .tabs)
        XCTAssertEqual(sessionRailLayout(for: 3), .aggregate)
    }

    func testAgentModelAndCopyFeedbackFormatting() {
        XCTAssertEqual(formatAgentModel("5.6-sol"), "5.6 Sol")
        XCTAssertEqual(formatAgentModel("openai/gpt-5.4"), "GPT 5.4")
        XCTAssertEqual(formatAgentModel("z-ai/xxx-xxx-xx"), "Xxx Xxx Xx")
        XCTAssertEqual(formatAgentModel("z-ai/glm-4-flash"), "Glm 4 Flash")
        XCTAssertEqual(formatAgentModel("anthropic/claude-3-7-sonnet-20250219"), "Claude 3.7 Sonnet")
        XCTAssertEqual(formatAgentModel("claude-3-5-haiku-20241022"), "Claude 3.5 Haiku")
        XCTAssertEqual(formatAgentModel("openai/gpt-4o"), "GPT 4o")
        XCTAssertEqual(formatAgentModel("deepseek/deepseek-r1"), "DeepSeek R1")
        XCTAssertEqual(formatAgentModel("deepseek-chat"), "DeepSeek Chat")
        XCTAssertEqual(formatAgentModel("google/gemini-2-5-pro"), "Gemini 2.5 Pro")
        XCTAssertEqual(formatAgentModel("qwen/qwen-2.5-coder-32b-instruct"), "Qwen 2.5 Coder 32B Instruct")
        XCTAssertEqual(formatAgentModel("o1-mini"), "o1 Mini")
        XCTAssertNil(formatAgentModel(""))
        XCTAssertEqual(cleanCopiedText("  hello\r\nworld  "), "hello\nworld")
        XCTAssertEqual(truncateCopiedText(String(repeating: "x", count: 121))?.count, 121)
        XCTAssertNil(truncateCopiedText("   "))
    }

    @MainActor
    func testParseSessionDeepLink() {
        let store = IOSLocalStore(defaults: UserDefaults(suiteName: "test-\(UUID())")!, keychain: IOSKeychainStore(service: "test"))
        let model = IOSApplicationModel(configuration: .init(name: "Host", url: "ws://localhost:9000"), localStore: store)
        XCTAssertEqual(model.parseSessionDeepLink(URL(string: "warren://session/session-123")!), "session-123")
        XCTAssertEqual(model.parseSessionDeepLink(URL(string: "warren:///session/session-456")!), "session-456")
        XCTAssertNil(model.parseSessionDeepLink(URL(string: "https://example.com/session/123")!))
        XCTAssertNil(model.parseSessionDeepLink(URL(string: "warren://other/123")!))
    }

    func testComposerActionInterruptsOnlyWhileWorking() {
        XCTAssertEqual(agentComposerAction(activity: .working, hasControl: true, hasText: false), .interrupt)
        XCTAssertEqual(agentComposerAction(activity: .ready, hasControl: true, hasText: true), .send)
        XCTAssertEqual(agentComposerAction(activity: .ready, hasControl: true, hasText: false), .unavailable)
        XCTAssertEqual(agentComposerAction(activity: .failed, hasControl: true, hasText: true), .unavailable)
        XCTAssertEqual(agentComposerAction(activity: .blocked, hasControl: true, hasText: true), .unavailable)
        let approval = WarrenRemoteAgentAttention(kind: .approval, reason: "permission")
        XCTAssertEqual(
            agentComposerAction(activity: .blocked, hasControl: true, hasText: true, attention: approval),
            .unavailable
        )
        let question = WarrenRemoteAgentAttention(kind: .input, reason: "question")
        XCTAssertEqual(
            agentComposerAction(activity: .blocked, hasControl: true, hasText: true, attention: question),
            .send
        )
    }

    func testAgentActivityPulseIsReservedForWorking() {
        XCTAssertTrue(iosAgentActivityShouldPulse(.working))
        XCTAssertFalse(iosAgentActivityShouldPulse(.ready))
        XCTAssertFalse(iosAgentActivityShouldPulse(.blocked))
        XCTAssertFalse(iosAgentActivityShouldPulse(.stalled))
        XCTAssertFalse(iosAgentActivityShouldPulse(.failed))
        XCTAssertFalse(iosAgentActivityShouldPulse(.exited))
    }

    func testNavigationRoundTripDoesNotContainEndpointToken() throws {
        let defaults = UserDefaults(suiteName: "warren-ios-test-\(UUID())")!
        let store = IOSLocalStore(defaults: defaults, keychain: IOSKeychainStore(service: "warren-ios-test"))
        store.navigation = IOSNavigationState(
            workspaceID: "workspace",
            terminalGroupID: nil,
            sessionID: "session",
            displayMode: .agent
        )
        let data = try XCTUnwrap(defaults.data(forKey: "warren.ios.navigation"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
        XCTAssertEqual(store.navigation.displayMode, .agent)
    }

    func testLastSessionKindIsStoredAsLocalPreference() {
        let defaults = UserDefaults(suiteName: "warren-ios-session-kind-\(UUID())")!
        let store = IOSLocalStore(
            defaults: defaults,
            keychain: IOSKeychainStore(service: "warren-ios-session-kind")
        )

        XCTAssertEqual(store.lastSessionKind, "shell")
        store.lastSessionKind = "claude"

        let restored = IOSLocalStore(
            defaults: defaults,
            keychain: IOSKeychainStore(service: "warren-ios-session-kind")
        )
        XCTAssertEqual(restored.lastSessionKind, "claude")
    }

    func testMultipleEndpointsRoundTripAndRememberActiveHost() {
        let defaults = UserDefaults(suiteName: "warren-ios-endpoints-\(UUID())")!
        let store = IOSLocalStore(
            defaults: defaults,
            keychain: IOSKeychainStore(service: "warren-ios-endpoints-\(UUID())")
        )
        let first = WarrenRemoteEndpointConfiguration(
            name: "Office",
            url: "http://office.example.test"
        )
        let second = WarrenRemoteEndpointConfiguration(
            name: "Home",
            url: "http://home.example.test"
        )

        store.endpoint = first
        store.saveEndpoint(second)
        XCTAssertEqual(store.endpoints.map(\.name), ["Office", "Home"])
        XCTAssertEqual(store.endpoint?.name, "Home")

        XCTAssertTrue(store.activateEndpoint(named: "Office"))
        let restored = IOSLocalStore(
            defaults: defaults,
            keychain: store.keychain
        )
        XCTAssertEqual(restored.endpoint?.name, "Office")
        XCTAssertEqual(restored.endpoints.map(\.url), [
            "http://office.example.test",
            "http://home.example.test",
        ])
    }

    func testDevelopmentEndpointIsAddedWithoutChangingActiveRelay() {
        let defaults = UserDefaults(suiteName: "warren-ios-development-endpoint-\(UUID())")!
        let keychain = IOSKeychainStore(service: "warren-ios-development-endpoint-\(UUID())")
        let store = IOSLocalStore(defaults: defaults, keychain: keychain)
        let relay = WarrenRemoteEndpointConfiguration(
            name: "Remote Relay",
            url: "https://relay.example.test",
            token: "relay-token",
            type: "relay",
            hostID: "host-1",
            routeID: "route-1"
        )
        let development = WarrenRemoteEndpointConfiguration(
            name: "Warren LAN",
            url: "http://192.0.2.10:8789",
            token: "local-token"
        )

        store.endpoint = relay
        XCTAssertTrue(store.ensureDevelopmentEndpoint(development))
        XCTAssertEqual(store.endpoint?.name, relay.name)
        XCTAssertEqual(store.endpoint?.url, relay.url)
        XCTAssertEqual(store.endpoint?.token, relay.token)
        XCTAssertEqual(store.endpoints.map(\.name), [relay.name, development.name])
        XCTAssertEqual(store.endpoint(named: development.name)?.url, development.url)
        XCTAssertEqual(store.endpoint(named: development.name)?.token, development.token)
    }

    func testDevelopmentEndpointRefreshDoesNotReplaceRelayWithSameName() {
        let defaults = UserDefaults(suiteName: "warren-ios-development-relay-name-\(UUID())")!
        let keychain = IOSKeychainStore(service: "warren-ios-development-relay-name-\(UUID())")
        let store = IOSLocalStore(defaults: defaults, keychain: keychain)
        let relay = WarrenRemoteEndpointConfiguration(
            name: "Warren LAN",
            url: "https://relay.example.test",
            token: "relay-token",
            type: "relay",
            hostID: "host-2",
            routeID: "route-2"
        )
        let development = WarrenRemoteEndpointConfiguration(
            name: "Warren LAN",
            url: "http://192.0.2.11:8789",
            token: "local-token"
        )

        store.endpoint = relay
        XCTAssertFalse(store.ensureDevelopmentEndpoint(development))
        XCTAssertEqual(store.endpoints, [relay])
        XCTAssertEqual(store.endpoint?.hostID, relay.hostID)
        XCTAssertEqual(store.endpoint?.routeID, relay.routeID)
        XCTAssertEqual(store.endpoint?.token, relay.token)
    }

    func testAgentDraftKeySeparatesEndpointAndSessionPunctuation() {
        let first = IOSLocalStore.agentDraftKey(endpointIdentity: "host.a", sessionID: "session")
        let second = IOSLocalStore.agentDraftKey(endpointIdentity: "host", sessionID: "a.session")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("warren.agent-draft."))
    }

    @MainActor
    func testCreatedAgentSessionDefaultsToAgentDisplayMode() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "44444444-4444-4444-4444-444444444444"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[{\"id\":\"workspace-1\",\"name\":\"Workspace\",\"path\":\"/tmp/workspace\"}],\"terminalGroups\":[],\"sessions\":[]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-create-agent-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-create-agent")
            )
        )
        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await waitForSentMessages(task, count: 1)

        model.createSession(
            workspaceID: "workspace-1",
            command: "codex",
            kind: "codex"
        )
        let messages = await waitForSentMessages(task, count: 2)
        let createMessage = try XCTUnwrap(messages.first(where: { requestMethod($0) == "session.create" }))
        let createID = try requestID(from: createMessage)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + createID + "\",\"ok\":true,\"result\":{\"id\":\"" + sessionID + "\",\"workspace\":\"workspace-1\",\"title\":\"Codex\",\"kind\":\"codex\",\"lifecycle\":\"running\"}}"
        ))
        for _ in 0..<400 {
            if model.displayMode == .agent { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.displayMode, .agent)
        model.stop()
    }

    @MainActor
    func testBufferedStopDoesNotPublishOfflineWhileConnectionIsRequested() async throws {
        let task = IOSScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-lifecycle-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-lifecycle")
            )
        )
        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.connectionState, .connected)

        // This simulates a transport lifecycle stop arriving after the UI has
        // already requested a foreground connection. It must not flash the
        // user-facing Offline state.
        await client.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(model.connectionState, .stopped)
        model.stop()
    }

    @MainActor
    func testAgentHistoryLoadsOlderConversationPages() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "55555555-5555-5555-5555-555555555555"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Codex\",\"kind\":\"codex\",\"agentSessionId\":\"agent-1\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"ready\"}}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-agent-history-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-agent-history")
            )
        )
        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(sessionID)
        let subscriptionMessages = await waitForSentMessages(task, count: 2)
        let subscribeID = try XCTUnwrap(
            subscriptionMessages.first(where: { requestMethod($0) == "session.subscribe" }).flatMap { try? requestID(from: $0) }
        )
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))

        model.loadOlderAgentHistory()
        var messages = await waitForSentMessages(task, count: 3)
        let firstHistory = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.history" }))
        XCTAssertEqual(requestParams(firstHistory)?["priority"], "conversation")
        XCTAssertEqual(requestParams(firstHistory)?["before"], nil)
        let firstHistoryID = try requestID(from: firstHistory)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + firstHistoryID + "\",\"ok\":true,\"result\":{\"epoch\":1,\"events\":[{\"seq\":2,\"type\":\"user\",\"role\":\"user\",\"content\":\"Earlier prompt\"},{\"seq\":3,\"type\":\"assistant\",\"role\":\"assistant\",\"content\":\"Earlier answer\"}],\"cursor\":2,\"hasMore\":true}}"
        ))
        for _ in 0..<400 {
            if model.agentEventsBySessionID[sessionID]?.count == 2,
               model.historyLoadingBySessionID.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.map(\.sequence), [2, 3])

        model.loadOlderAgentHistory()
        messages = await waitForSentMessages(task, count: 4)
        let secondHistory = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.history" }))
        XCTAssertEqual(requestParams(secondHistory)?["before"], "2")
        let secondHistoryID = try requestID(from: secondHistory)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + secondHistoryID + "\",\"ok\":true,\"result\":{\"epoch\":1,\"events\":[{\"seq\":1,\"type\":\"user\",\"role\":\"user\",\"content\":\"Oldest prompt\"}],\"cursor\":1,\"hasMore\":false}}"
        ))
        for _ in 0..<400 {
            if model.agentEventsBySessionID[sessionID]?.count == 3,
               model.historyLoadingBySessionID.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.map(\.sequence), [1, 2, 3])
        XCTAssertFalse(model.agentHistoryHasMore(for: sessionID))
        model.stop()
    }

    @MainActor
    func testAgentSubscriptionDoesNotMarkCachedHistoryAsLoaded() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "66666666-6666-6666-6666-666666666666"
        let cachedEvent = WarrenRemoteAgentEvent(
            sequence: 99,
            type: "assistant",
            role: "assistant",
            content: "Cached tail"
        )
        try await IOSAgentEventStore.shared.saveEvents([cachedEvent], sessionID: sessionID, epoch: 1)

        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Codex\",\"kind\":\"codex\",\"agentSessionId\":\"agent-1\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"ready\"}}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-agent-cache-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-agent-cache")
            )
        )
        defer {
            model.stop()
            Task { await IOSAgentEventStore.shared.clearSession(sessionID: sessionID) }
        }

        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(sessionID)
        model.ensureAgentSubscribed(for: sessionID)
        let messages = await waitForSentMessages(task, count: 3)
        let sessionSubscribe = try XCTUnwrap(messages.first(where: { requestMethod($0) == "session.subscribe" }))
        let agentSubscribe = try XCTUnwrap(messages.first(where: { requestMethod($0) == "agent.subscribe" }))
        let sessionSubscribeID = try requestID(from: sessionSubscribe)
        let agentSubscribeID = try requestID(from: agentSubscribe)
        XCTAssertEqual(requestParams(agentSubscribe)?["epoch"], "1")
        XCTAssertEqual(requestParams(agentSubscribe)?["lastSequence"], "99")

        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + sessionSubscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + agentSubscribeID + "\",\"ok\":true,\"result\":{\"session\":{\"id\":\"" + sessionID + "\",\"kind\":\"codex\",\"lifecycle\":\"running\"},\"snapshot\":{\"epoch\":1,\"turn\":{\"id\":0,\"status\":\"idle\"},\"sequence\":99}}}"
        ))
        for _ in 0..<400 {
            if model.agentEventsBySessionID[sessionID]?.contains(where: { $0.sequence == cachedEvent.sequence }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.map(\.sequence), [99])
        XCTAssertFalse(model.agentHistoryLoaded(for: sessionID))
    }

    @MainActor
    func testAgentSequenceGapIsFilledAcrossMultiplePages() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "77777777-7777-7777-7777-777777777777"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Codex\",\"kind\":\"codex\",\"agentSessionId\":\"agent-1\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"ready\"}}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-agent-gap-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-agent-gap")
            )
        )
        defer { model.stop() }

        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(sessionID)
        model.ensureAgentSubscribed(for: sessionID)
        let initial = await waitForSentMessages(task, count: 3)
        let sessionSubscribe = try XCTUnwrap(initial.first(where: { requestMethod($0) == "session.subscribe" }))
        let agentSubscribe = try XCTUnwrap(initial.first(where: { requestMethod($0) == "agent.subscribe" }))
        let sessionSubscribeID = try requestID(from: sessionSubscribe)
        let agentSubscribeID = try requestID(from: agentSubscribe)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + sessionSubscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + agentSubscribeID + "\",\"ok\":true,\"result\":{\"session\":{\"id\":\"" + sessionID + "\",\"kind\":\"codex\",\"lifecycle\":\"running\"},\"snapshot\":{\"epoch\":1,\"turn\":{\"id\":1,\"status\":\"started\"},\"sequence\":250}}}"
        ))

        func historyResponse(
            requestID: String,
            range: ClosedRange<Int>,
            hasMore: Bool
        ) throws -> String {
            let events: [[String: Any]] = range.map { sequence in
                [
                    "seq": sequence,
                    "type": "assistant",
                    "role": "assistant",
                    "content": "event \(sequence)",
                ]
            }
            let result: [String: Any] = [
                "epoch": 1,
                "events": events,
                "hasMore": hasMore,
            ]
            let envelope: [String: Any] = [
                "t": "response",
                "id": requestID,
                "ok": true,
                "result": result,
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            return String(decoding: data, as: UTF8.self)
        }

        var messages = await waitForSentMessages(task, count: 4)
        var history = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.history" }))
        XCTAssertEqual(requestParams(history)?["since"], "1")
        XCTAssertEqual(requestParams(history)?["before"], "251")
        await task.enqueue(try .text(historyResponse(requestID: requestID(from: history), range: 1...100, hasMore: true)))

        messages = await waitForSentMessages(task, count: 5)
        history = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.history" }))
        XCTAssertEqual(requestParams(history)?["since"], "101")
        await task.enqueue(try .text(historyResponse(requestID: requestID(from: history), range: 101...200, hasMore: true)))

        messages = await waitForSentMessages(task, count: 6)
        history = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.history" }))
        XCTAssertEqual(requestParams(history)?["since"], "201")
        await task.enqueue(try .text(historyResponse(requestID: requestID(from: history), range: 201...250, hasMore: false)))

        for _ in 0..<400 {
            if model.agentEventsBySessionID[sessionID]?.count == 250 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.map(\.sequence), Array(1...250).map(UInt64.init))
    }

    func testEndpointURLUsesWebSocketAndFixedProtocolPath() {
        let endpoint = WarrenRemoteEndpointConfiguration(name: "Host", url: "https://example.test/base")
        XCTAssertEqual(endpoint.webSocketURL?.absoluteString, "wss://example.test/v1/ws")
    }

    func testRelayEndpointUsesHostScopedControlPlanePaths() {
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: "https://relay.example.test/relay",
            token: "access",
            type: "relay",
            hostID: "host-123",
            routeID: "route-456"
        )
        XCTAssertEqual(
            endpoint.webSocketURL?.absoluteString,
            "wss://relay.example.test/relay/h/host-123/v1/client/connect"
        )
        XCTAssertEqual(
            endpoint.relaySessionExchangeURL?.absoluteString,
            "https://relay.example.test/relay/h/host-123/v1/session/exchange"
        )
        XCTAssertEqual(
            endpoint.relaySessionRefreshURL?.absoluteString,
            "https://relay.example.test/relay/h/host-123/v1/session/refresh"
        )
        XCTAssertEqual(
            endpoint.relayLiveActivityRegistrationURL?.absoluteString,
            "https://relay.example.test/relay/h/host-123/v1/live-activities"
        )
        let defaults = UserDefaults(suiteName: "warren-ios-relay-metadata-\(UUID())")!
        let store = IOSLocalStore(
            defaults: defaults,
            keychain: IOSKeychainStore(service: "warren-ios-relay-metadata")
        )
        store.endpoint = endpoint
        XCTAssertEqual(store.endpoint?.routeID, "route-456")
    }

    func testRelayPairingParsesOneTimeFragmentTicket() throws {
        let url = try XCTUnwrap(URL(string: "https://relay.example.test/relay/h/host-123/#t=one-time%2Fticket"))
        let pairing = try WarrenRelayPairingClient.parse(url)
        XCTAssertEqual(pairing.relayURL, "https://relay.example.test/relay")
        XCTAssertEqual(pairing.hostID, "host-123")
        XCTAssertEqual(pairing.pairingTicket, "one-time/ticket")
    }

    func testRelayPairingParsesQueryTicketAndKeepsProxyPrefix() throws {
        let url = try XCTUnwrap(URL(string: "wss://relay.example.test/edge/h/host-123/?pairing_ticket=one-time"))
        let pairing = try WarrenRelayPairingClient.parse(url)
        XCTAssertEqual(pairing.relayURL, "https://relay.example.test/edge")
        XCTAssertEqual(pairing.hostID, "host-123")
        XCTAssertEqual(pairing.pairingTicket, "one-time")
    }

    func testRelayPairingParsesOpaqueInviteWithoutExposingHost() throws {
        let inviteID = "Abc_123-def"
        let url = try XCTUnwrap(URL(string: "https://relay.example.test/edge/invite/\(inviteID)/"))
        let pairing = try WarrenRelayPairingClient.parse(url)
        XCTAssertEqual(pairing.relayURL, "https://relay.example.test/edge")
        XCTAssertEqual(pairing.hostID, "")
        XCTAssertEqual(pairing.inviteID, inviteID)
        XCTAssertEqual(pairing.pairingTicket, "")
    }

    func testRelayPairingRejectsUnsupportedOrAmbiguousLinks() throws {
        XCTAssertThrowsError(try WarrenRelayPairingClient.parse(URL(string: "ftp://relay.example.test/h/host-123/#t=ticket")!)) { error in
            XCTAssertEqual(error as? WarrenRelayPairingError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try WarrenRelayPairingClient.parse(URL(string: "https://relay.example.test/h/host-123/extra/#t=ticket")!)) { error in
            XCTAssertEqual(error as? WarrenRelayPairingError, .missingHostID)
        }
        XCTAssertThrowsError(try WarrenRelayPairingClient.parse(URL(string: "https://relay.example.test/h/host%2F123/#t=ticket")!)) { error in
            XCTAssertEqual(error as? WarrenRelayPairingError, .missingHostID)
        }
        XCTAssertThrowsError(try WarrenRelayPairingClient.parse(URL(string: "https://relay.example.test/invite/not.safe/")!)) { error in
            XCTAssertEqual(error as? WarrenRelayPairingError, .missingHostID)
        }
    }

    @MainActor
    func testEditingRelayEndpointToDirectHostDropsRelayScope() {
        let defaults = UserDefaults(suiteName: "warren-ios-relay-edit-\(UUID())")!
        let store = IOSLocalStore(
            defaults: defaults,
            keychain: IOSKeychainStore(service: "warren-ios-relay-edit-\(UUID())")
        )
        let relay = WarrenRemoteEndpointConfiguration(
            name: "Relay",
            url: "https://relay.example.test",
            token: "access",
            type: "relay",
            hostID: "host-123"
        )
        store.endpoint = relay
        let model = IOSApplicationModel(configuration: relay, localStore: store)

        XCTAssertTrue(model.saveEndpoint(name: "LAN Host", url: "http://192.168.1.50:8789"))
        XCTAssertFalse(store.endpoint?.isRelay == true)
        XCTAssertNil(store.endpoint?.hostID)
        XCTAssertEqual(store.endpoint?.webSocketURL?.absoluteString, "ws://192.168.1.50:8789/v1/ws")
    }

    func testAgentActivityRequiresAnAgentBackedSession() {
        let working = WarrenRemoteAgentStatus(activity: .working)
        let shell = WarrenRemoteRoster.Session(
            id: "shell",
            kind: "shell",
            agentStatus: working
        )
        let codex = WarrenRemoteRoster.Session(
            id: "codex",
            kind: "codex",
            agentStatus: working
        )
        let boundShell = WarrenRemoteRoster.Session(
            id: "bound-shell",
            kind: "shell",
            agentSessionID: "thread-1",
            agentStatus: working
        )

        let antigravity = WarrenRemoteRoster.Session(
            id: "antigravity",
            kind: "antigravity",
            agentStatus: working
        )
        let trae = WarrenRemoteRoster.Session(
            id: "trae",
            kind: "trae",
            agentStatus: working
        )
        let claude = WarrenRemoteRoster.Session(
            id: "claude",
            kind: "claude",
            agentStatus: working
        )
        let opencode = WarrenRemoteRoster.Session(
            id: "opencode",
            kind: "opencode",
            agentStatus: working
        )
        let pi = WarrenRemoteRoster.Session(
            id: "pi",
            kind: "pi",
            agentStatus: working
        )
        let qoder = WarrenRemoteRoster.Session(
            id: "qoder",
            kind: "qoder",
            agentStatus: working
        )
        let shellWithAgyCommand = WarrenRemoteRoster.Session(
            id: "shell-agy",
            kind: "shell",
            command: "agy --model auto"
        )

        XCTAssertFalse(shell.isAgentBacked)
        XCTAssertTrue(codex.isAgentBacked)
        XCTAssertTrue(boundShell.isAgentBacked)
        XCTAssertTrue(antigravity.isAgentBacked)
        XCTAssertTrue(trae.isAgentBacked)
        XCTAssertTrue(claude.isAgentBacked)
        XCTAssertTrue(opencode.isAgentBacked)
        XCTAssertTrue(pi.isAgentBacked)
        XCTAssertTrue(qoder.isAgentBacked)
        XCTAssertTrue(shellWithAgyCommand.isAgentBacked)

        XCTAssertEqual(sessionProviderID(for: antigravity), "antigravity")
        XCTAssertEqual(sessionProviderID(for: codex), "codex")
        XCTAssertEqual(sessionProviderID(for: claude), "claude")
        XCTAssertEqual(sessionProviderID(for: opencode), "opencode")
        XCTAssertEqual(sessionProviderID(for: pi), "pi")
        XCTAssertEqual(sessionProviderID(for: qoder), "qoder")
        XCTAssertEqual(sessionProviderID(for: trae), "trae")
        XCTAssertEqual(sessionProviderID(for: shellWithAgyCommand), "antigravity")
        XCTAssertEqual(sessionProviderID(for: shell), "shell")
    }

    @MainActor
    func testDeletingCurrentSessionReturnsToItsScopeWhenNoSiblingRemains() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text("{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"shell\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-delete-" + UUID().uuidString)!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(defaults: defaults, keychain: IOSKeychainStore(service: "warren-ios-delete"))
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(sessionID)
        let initialMessages = await waitForSentMessages(task, count: 2)
        let subscribeID = try requestID(from: initialMessages[1])
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"))

        model.deleteSession(sessionID)
        XCTAssertEqual(model.currentSessionID, sessionID)

        let deleteMessages = await waitForSentMessages(task, count: 3)
        let deleteMessage = try XCTUnwrap(deleteMessages.first(where: { requestMethod($0) == "session.delete" }))
        let deleteID = try requestID(from: deleteMessage)
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + deleteID + "\",\"ok\":true,\"result\":{\"deleted\":true}}"))
        let messages = await waitForSentMessages(task, count: 4)
        if let unsubscribe = messages.first(where: { requestMethod($0) == "session.unsubscribe" }) {
            let id = try requestID(from: unsubscribe)
            await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + id + "\",\"ok\":true,\"result\":{\"unsubscribed\":true}}"))
        }
        for _ in 0..<400 {
            if !model.isMutating { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await task.enqueue(.text("{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":2,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[]}}"))
        for _ in 0..<400 {
            if model.roster?.revision == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.currentSessionID)
        XCTAssertNil(model.sessionDeletionDestination)
        model.stop()
    }

    @MainActor
    func testDeletingCurrentSessionSelectsAnotherSessionInTheSameWorkspace() async throws {
        let task = IOSScriptedWebSocketTask()
        let firstID = "11111111-1111-1111-1111-111111111111"
        let siblingID = "22222222-2222-2222-2222-222222222222"
        let otherWorkspaceID = "33333333-3333-3333-3333-333333333333"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[{\"id\":\"workspace-1\",\"name\":\"Workspace\",\"path\":\"/tmp/workspace\"},{\"id\":\"workspace-2\",\"name\":\"Other\",\"path\":\"/tmp/other\"}],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + firstID + "\",\"workspace\":\"workspace-1\",\"title\":\"First\",\"kind\":\"shell\",\"lifecycle\":\"running\"},{\"id\":\"" + siblingID + "\",\"workspace\":\"workspace-1\",\"title\":\"Sibling\",\"kind\":\"shell\",\"lifecycle\":\"running\"},{\"id\":\"" + otherWorkspaceID + "\",\"workspace\":\"workspace-2\",\"title\":\"Other\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-delete-sibling-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-delete-sibling")
            )
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(firstID)
        let initial = await waitForSentMessages(task, count: 2)
        let initialSubscribeID = try requestID(from: initial[1])
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + initialSubscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"))

        model.deleteSession(firstID)
        let withDelete = await waitForSentMessages(task, count: 3)
        let deleteMessage = try XCTUnwrap(withDelete.first(where: { requestMethod($0) == "session.delete" }))
        let deleteID = try requestID(from: deleteMessage)
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + deleteID + "\",\"ok\":true,\"result\":{\"deleted\":true}}"))

        var sent = await task.sentMessages
        for _ in 0..<400 {
            sent = await task.sentMessages
            if let unsubscribe = sent.first(where: { requestMethod($0) == "session.unsubscribe" }) {
                let unsubscribeID = try requestID(from: unsubscribe)
                await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + unsubscribeID + "\",\"ok\":true,\"result\":{\"unsubscribed\":true}}"))
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<400 {
            if model.currentSessionID == siblingID { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.currentSessionID, siblingID)
        XCTAssertEqual(model.navigation.workspaceID, "workspace-1")
        XCTAssertNil(model.sessionDeletionDestination)
        model.stop()
    }

    @MainActor
    func testRejectedSessionSwitchRestoresThePreviousSessionRoute() async throws {
        let task = IOSScriptedWebSocketTask()
        let firstID = "aaaaaaaa-1111-1111-1111-111111111111"
        let secondID = "bbbbbbbb-2222-2222-2222-222222222222"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + firstID + "\",\"title\":\"First\",\"kind\":\"shell\",\"lifecycle\":\"running\"},{\"id\":\"" + secondID + "\",\"title\":\"Second\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-switch-failure-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-switch-failure")
            )
        )
        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        model.selectSession(firstID)
        let initial = await waitForSentMessages(task, count: 2)
        let firstSubscribeID = try XCTUnwrap(
            initial.first(where: { requestMethod($0) == "session.subscribe" }).flatMap { try? requestID(from: $0) }
        )
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + firstSubscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"))
        try await Task.sleep(for: .milliseconds(20))

        model.selectSession(secondID)
        var messages = await waitForSentMessages(task, count: 3)
        let unsubscribe = try XCTUnwrap(messages.last(where: { requestMethod($0) == "session.unsubscribe" }))
        let unsubscribeID = try requestID(from: unsubscribe)
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + unsubscribeID + "\",\"ok\":true,\"result\":{\"unsubscribed\":true}}"))
        messages = await waitForSentMessages(task, count: 4)
        let secondSubscribe = try XCTUnwrap(messages.last(where: { requestMethod($0) == "session.subscribe" && (try? requestID(from: $0)) != firstSubscribeID }))
        let secondSubscribeID = try requestID(from: secondSubscribe)
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + secondSubscribeID + "\",\"ok\":false,\"error\":\"Session is unavailable\"}"))

        for _ in 0..<400 {
            if model.currentSessionID == firstID { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.currentSessionID, firstID)
        XCTAssertEqual(model.navigation.sessionID, firstID)
        model.stop()
    }

    @MainActor
    func testLateSendNowSuccessSettlesTheQueueAfterSessionSwitch() async throws {
        let task = IOSScriptedWebSocketTask()
        let firstID = "cccccccc-1111-1111-1111-111111111111"
        let secondID = "dddddddd-2222-2222-2222-222222222222"
        await task.enqueue(.text(
            "{\"t\":\"welcome\",\"version\":\"2.0\",\"capabilities\":[\"agent-interrupt-v1\"]}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":["
                + "{\"id\":\"" + firstID + "\",\"title\":\"First\",\"kind\":\"codex\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"working\"},\"agentTurn\":{\"id\":1,\"status\":\"working\"}},"
                + "{\"id\":\"" + secondID + "\",\"title\":\"Second\",\"kind\":\"codex\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"ready\"}}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-send-now-switch-\(UUID())")!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-send-now-switch")
            )
        )
        model.start()
        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        model.selectSession(firstID)
        var messages = await waitForSentMessages(task, count: 2)
        let subscribeID = try XCTUnwrap(
            messages.last(where: { requestMethod($0) == "session.subscribe" }).flatMap { try? requestID(from: $0) }
        )
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"attached\",\"session\":\"" + firstID + "\",\"epoch\":1,\"sequence\":0,\"reanchor\":true}"
        ))
        model.focusTerminal()
        messages = await waitForSentMessages(task, count: 3)
        let focusID = try XCTUnwrap(
            messages.last(where: { requestMethod($0) == "session.focus" }).flatMap { try? requestID(from: $0) }
        )
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + focusID + "\",\"ok\":true,\"result\":{\"focused\":true,\"resized\":false}}"
        ))
        for _ in 0..<400 {
            if model.hasControlLease { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.hasControlLease)

        XCTAssertTrue(model.sendAgentMessageNow("replace me"))
        messages = await waitForSentMessages(task, count: 4)
        let interrupt = try XCTUnwrap(messages.last(where: { requestMethod($0) == "agent.turn.interrupt" }))
        let interruptID = try requestID(from: interrupt)
        let queuedID = try XCTUnwrap(model.agentQueueBySessionID[firstID]?.items.first?.id)

        model.selectSession(secondID)
        messages = await waitForSentMessages(task, count: 5)
        let unsubscribe = try XCTUnwrap(messages.last(where: { requestMethod($0) == "session.unsubscribe" }))
        let unsubscribeID = try requestID(from: unsubscribe)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + unsubscribeID + "\",\"ok\":true,\"result\":{\"unsubscribed\":true}}"
        ))
        messages = await waitForSentMessages(task, count: 6)
        let secondSubscribe = try XCTUnwrap(messages.last(where: { requestMethod($0) == "session.subscribe" }))
        let secondSubscribeID = try requestID(from: secondSubscribe)
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + secondSubscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + interruptID + "\",\"ok\":true,\"result\":{\"accepted\":true,\"session\":\"" + firstID + "\",\"turn\":1,\"clientMessageId\":\"" + queuedID + "\"}}"
        ))

        for _ in 0..<400 {
            if model.agentQueueBySessionID[firstID]?.items.contains(where: { $0.id == queuedID }) == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.agentQueueBySessionID[firstID]?.items.contains(where: { $0.id == queuedID }) ?? false)
        model.stop()
    }

    @MainActor
    func testControlWaitsForOutputRegistrationBeforePromotingFocus() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text("{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"shell\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-control-" + UUID().uuidString)!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(defaults: defaults, keychain: IOSKeychainStore(service: "warren-ios-control"))
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNotNil(model.roster)

        model.selectSession(sessionID)
        let subscribeMessages = await waitForSentMessages(task, count: 2)
        XCTAssertEqual(subscribeMessages.count, 2)
        let subscribeID = try requestID(from: subscribeMessages[1])

        // The subscribe response alone is not enough: the Host has not
        // registered the output stream until it emits `attached`.
        model.focusTerminal()
        let sentBeforeAttached = await task.sentMessages
        XCTAssertEqual(sentBeforeAttached.count, 2)

        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"))
        await task.enqueue(.text("{\"t\":\"attached\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"sequence\":0,\"reanchor\":true}"))
        let focusMessages = await waitForSentMessages(task, count: 3)
        XCTAssertEqual(focusMessages.count, 3)
        XCTAssertEqual(requestMethod(focusMessages[2]), "session.focus")
        // A rapid second tap must not enqueue another focus request whose late
        // response could race the first lease transition.
        model.focusTerminal()
        try await Task.sleep(for: .milliseconds(20))
        let sentAfterDuplicateTap = await task.sentMessages
        let duplicateFocusMessages = sentAfterDuplicateTap.filter { requestMethod($0) == "session.focus" }
        XCTAssertEqual(duplicateFocusMessages.count, 1)

        let focusID = try requestID(from: focusMessages[2])
        await task.enqueue(.text("{\"t\":\"response\",\"id\":\"" + focusID + "\",\"ok\":true,\"result\":{\"focused\":true,\"resized\":false}}"))
        for _ in 0..<400 {
            if model.hasControlLease { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.hasControlLease)
        model.stop()
    }

    @MainActor
    func testQueuesAgentMessagesWhileWorkingUntilExecutableBoundary() async throws {
        let task = IOSScriptedWebSocketTask()
        let sessionID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Codex\",\"kind\":\"codex\",\"lifecycle\":\"running\",\"agentStatus\":{\"activity\":\"working\"}}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-agent-queue-" + UUID().uuidString)!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-agent-queue")
            )
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.connectionState, .connected)
        model.selectSession(sessionID)

        let subscribeMessages = await waitForSentMessages(task, count: 2)
        let subscribeID = try requestID(from: subscribeMessages[1])
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"attached\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"sequence\":0,\"reanchor\":true}"
        ))

        model.focusTerminal()
        let focusMessages = await waitForSentMessages(task, count: 3)
        let focusID = try requestID(from: focusMessages[2])
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + focusID + "\",\"ok\":true,\"result\":{\"focused\":true,\"resized\":false}}"
        ))
        for _ in 0..<400 {
            if model.hasControlLease { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.hasControlLease)
        XCTAssertTrue(model.canSendAgent)

        model.sendAgentMessage("queued while working")
        model.sendAgentMessage("remove this locally")
        XCTAssertEqual(model.agentQueuedMessageCountBySessionID[sessionID], 2)
        let queued = try XCTUnwrap(model.agentQueueBySessionID[sessionID]?.items.first)
        let removable = try XCTUnwrap(model.agentQueueBySessionID[sessionID]?.items.last)
        XCTAssertTrue(model.editQueuedAgentMessage(sessionID: sessionID, itemID: queued.id, text: "edited locally"))
        XCTAssertEqual(model.agentQueueBySessionID[sessionID]?.items.first?.text, "edited locally")
        XCTAssertTrue(model.deleteQueuedAgentMessage(sessionID: sessionID, itemID: removable.id))
        XCTAssertEqual(model.agentQueuedMessageCountBySessionID[sessionID], 1)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID] ?? [], [])
        let sentWhileWorking = await task.sentMessages
        XCTAssertEqual(binaryPayloads(from: sentWhileWorking).count, 0)

        await task.enqueue(.text(
            "{\"t\":\"agent.status\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"status\":{\"activity\":\"blocked\",\"attention\":{\"kind\":\"input\",\"reason\":\"question\"}}}"
        ))
        var sent = await task.sentMessages
        for _ in 0..<400 {
            sent = await task.sentMessages
            if binaryPayloads(from: sent).count >= 2,
               model.agentQueuedMessageCountBySessionID[sessionID] == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let payloads = binaryPayloads(from: sent)
        XCTAssertEqual(model.agentQueuedMessageCountBySessionID[sessionID], nil)
        XCTAssertGreaterThanOrEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0], Data("edited locally".utf8))
        XCTAssertEqual(payloads[1], Data([0x1B, 0x5B, 0x31, 0x33, 0x75]))
        model.stop()
    }

    @MainActor
    func testAgentStreamingContentDeltasAreCoalescedIntoSingleMessage() async throws {
        let sessionID = "agent-stream-test"
        let task = IOSScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Agent\",\"kind\":\"claude\",\"lifecycle\":\"running\"}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-agent-deltas-" + UUID().uuidString)!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-agent-deltas")
            )
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.connectionState, .connected)
        model.selectSession(sessionID)

        let subscribeMessages = await waitForSentMessages(task, count: 2)
        let subscribeID = try requestID(from: subscribeMessages[1])
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"attached\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"sequence\":0,\"reanchor\":true}"
        ))

        // 1. Initial seed event with contentDelta=false
        await task.enqueue(.text(
            "{\"t\":\"agent\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"events\":[{\"seq\":1,\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Hello\",\"contentDelta\":false}]}"
        ))
        for _ in 0..<200 {
            if (model.agentEventsBySessionID[sessionID]?.count ?? 0) >= 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.count, 1)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.first?.content, "Hello")

        // 2. Stream delta 1 with contentDelta=true
        await task.enqueue(.text(
            "{\"t\":\"agent\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"events\":[{\"seq\":2,\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\" world\",\"contentDelta\":true}]}"
        ))
        for _ in 0..<200 {
            if model.agentEventsBySessionID[sessionID]?.first?.content == "Hello world" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.count, 1)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.first?.content, "Hello world")

        // 3. Stream delta 2 with contentDelta=true
        await task.enqueue(.text(
            "{\"t\":\"agent\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"events\":[{\"seq\":3,\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\"!\",\"contentDelta\":true}]}"
        ))
        for _ in 0..<200 {
            if model.agentEventsBySessionID[sessionID]?.first?.content == "Hello world!" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.count, 1)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.first?.content, "Hello world!")

        // 4. Duplicate sequence delivery does not duplicate content
        await task.enqueue(.text(
            "{\"t\":\"agent\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"events\":[{\"seq\":3,\"id\":\"msg-1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\"!\",\"contentDelta\":true}]}"
        ))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.count, 1)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.first?.content, "Hello world!")

        // 5. New independent message creates a second event
        await task.enqueue(.text(
            "{\"t\":\"agent\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"events\":[{\"seq\":4,\"id\":\"msg-2\",\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Next\",\"contentDelta\":false}]}"
        ))
        for _ in 0..<200 {
            if (model.agentEventsBySessionID[sessionID]?.count ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.count, 2)
        XCTAssertEqual(model.agentEventsBySessionID[sessionID]?.last?.content, "Next")

        model.stop()
    }

    @MainActor
    func testTerminalBufferOverrunRequestsRecoveryWithoutDuplication() async throws {
        let sessionUUID = UUID()
        let sessionID = sessionUUID.uuidString.lowercased()
        let task = IOSScriptedWebSocketTask()
        await task.enqueue(.text("{\"t\":\"welcome\",\"version\":\"2.0\"}"))
        await task.enqueue(.text(
            "{\"t\":\"roster\",\"state\":{\"schema\":1,\"revision\":1,\"host\":{\"id\":\"host-1\",\"name\":\"Test Host\"},\"projects\":[],\"workspaces\":[],\"terminalGroups\":[],\"sessions\":[{\"id\":\"" + sessionID + "\",\"title\":\"Shell\",\"kind\":\"shell\",\"lifecycle\":\"running\"}]}}"
        ))
        let client = WarrenRemoteClient(
            configuration: WarrenRemoteEndpointConfiguration(name: "Host", url: "http://example.test"),
            task: task
        )
        let defaults = UserDefaults(suiteName: "warren-ios-term-overrun-" + UUID().uuidString)!
        let model = IOSApplicationModel(
            client: client,
            localStore: IOSLocalStore(
                defaults: defaults,
                keychain: IOSKeychainStore(service: "warren-ios-term-overrun")
            )
        )
        model.start()

        for _ in 0..<400 {
            if model.connectionState == .connected, model.roster != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.selectSession(sessionID)

        let subscribeMessages = await waitForSentMessages(task, count: 2)
        let subscribeID = try requestID(from: subscribeMessages[1])
        await task.enqueue(.text(
            "{\"t\":\"response\",\"id\":\"" + subscribeID + "\",\"ok\":true,\"result\":{\"subscribed\":true}}"
        ))
        await task.enqueue(.text(
            "{\"t\":\"attached\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"sequence\":0,\"reanchor\":true}"
        ))

        // Send first chunk (4.5 MB)
        let chunk1 = Data(repeating: 0x41, count: 4_500_000)
        let header1 = try XCTUnwrap(BinaryOutputFrameHeader(sessionID: TerminalSessionID(rawValue: sessionUUID), epoch: 1, sequence: 0, payloadLength: chunk1.count))
        let wire1 = try WarrenWireCodec().encodeOutput(header: header1, payload: chunk1)
        await task.enqueue(.binary(wire1))

        for _ in 0..<400 {
            if (model.terminalOutputBySessionID[sessionID]?.count ?? 0) >= 4_500_000 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.terminalOutputBySessionID[sessionID]?.count, 4_500_000)

        // Send second chunk (4.5 MB) taking total data to 9 MB (> 8 MB maxBytes)
        let chunk2 = Data(repeating: 0x42, count: 4_500_000)
        let header2 = try XCTUnwrap(BinaryOutputFrameHeader(sessionID: TerminalSessionID(rawValue: sessionUUID), epoch: 1, sequence: 4_500_000, payloadLength: chunk2.count))
        let wire2 = try WarrenWireCodec().encodeOutput(header: header2, payload: chunk2)
        await task.enqueue(.binary(wire2))

        // When exceeding maxBytes, it should mark terminal not ready and request recovery (subscription with anchor=nil)
        for _ in 0..<400 {
            if model.terminalReadyBySessionID[sessionID] == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.terminalReadyBySessionID[sessionID], false)

        // Wait for the recovery subscribe request
        let messages = await waitForSentMessages(task, count: 3)
        let recoverySubscribe = try XCTUnwrap(messages.last(where: { requestMethod($0) == "session.subscribe" && (try? requestID(from: $0)) != subscribeID }))
        let params = requestParams(recoverySubscribe)
        XCTAssertNil(params?["anchor"])

        model.stop()
    }

    @MainActor
    private func waitForSentMessages(
        _ task: IOSScriptedWebSocketTask,
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

    private func requestID(from message: WarrenWebSocketMessage) throws -> String {
        guard case .text(let text) = message,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? String else {
            throw WarrenRemoteClientError.invalidResponse
        }
        return id
    }

    private func requestMethod(_ message: WarrenWebSocketMessage) -> String? {
        guard case .text(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object["method"] as? String
    }

    private func requestParams(_ message: WarrenWebSocketMessage) -> [String: String]? {
        guard case .text(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let params = object["params"] as? [String: Any] else {
            return nil
        }
        return params.compactMapValues { $0 as? String }
    }

    private func binaryPayloads(from messages: [WarrenWebSocketMessage]) -> [Data] {
        messages.compactMap { message in
            guard case .binary(let bytes) = message else { return nil }
            return Data(bytes)
        }
    }

    func testDashboardAllCardsCollapseLogic() {
        let ws1 = sessionScopeID(kind: "workspace", id: "ws-1")
        let ws2 = sessionScopeID(kind: "workspace", id: "ws-2")
        let grp1 = sessionScopeID(kind: "group", id: "grp-1")
        let allIDs: Set<String> = [ws1, ws2, grp1]

        var collapsedIDs: Set<String> = []
        let isAllCollapsedInitial = !allIDs.isEmpty && allIDs.isSubset(of: collapsedIDs)
        XCTAssertFalse(isAllCollapsedInitial)

        // Collapse all
        collapsedIDs.formUnion(allIDs)
        let isAllCollapsedAfter = !allIDs.isEmpty && allIDs.isSubset(of: collapsedIDs)
        XCTAssertTrue(isAllCollapsedAfter)

        // Expand all
        collapsedIDs.removeAll()
        let isAllCollapsedCleared = !allIDs.isEmpty && allIDs.isSubset(of: collapsedIDs)
        XCTAssertFalse(isAllCollapsedCleared)
    }
}

private enum IOSScriptedWebSocketTaskError: Error {
    case notResumed
    case cancelled
}

private actor IOSScriptedWebSocketTask: WarrenWebSocketTaskAdapter {
    private var incoming: [WarrenWebSocketMessage] = []
    private var waiter: CheckedContinuation<WarrenWebSocketMessage, Error>?
    private var resumed = false
    private var cancelled = false
    private var sent: [WarrenWebSocketMessage] = []

    func resume() async { resumed = true }

    func cancel() async {
        cancelled = true
        waiter?.resume(throwing: IOSScriptedWebSocketTaskError.cancelled)
        waiter = nil
    }

    func send(_ message: WarrenWebSocketMessage) async throws {
        guard resumed else { throw IOSScriptedWebSocketTaskError.notResumed }
        guard !cancelled else { throw IOSScriptedWebSocketTaskError.cancelled }
        sent.append(message)
    }

    func receive() async throws -> WarrenWebSocketMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        guard !cancelled else { throw IOSScriptedWebSocketTaskError.cancelled }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if !incoming.isEmpty {
                    continuation.resume(returning: incoming.removeFirst())
                } else if cancelled {
                    continuation.resume(throwing: IOSScriptedWebSocketTaskError.cancelled)
                } else {
                    waiter = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    func enqueue(_ message: WarrenWebSocketMessage) {
        guard !cancelled else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    var sentMessages: [WarrenWebSocketMessage] { sent }
}
