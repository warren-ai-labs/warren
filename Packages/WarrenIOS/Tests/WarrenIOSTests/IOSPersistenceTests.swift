import XCTest
@testable import WarrenIOS
import WarrenTransport

final class IOSPersistenceTests: XCTestCase {
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

        XCTAssertFalse(shell.isAgentBacked)
        XCTAssertTrue(codex.isAgentBacked)
        XCTAssertTrue(boundShell.isAgentBacked)
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
    func testQueuesAgentMessagesWhileWorkingUntilReady() async throws {
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
        XCTAssertEqual(model.agentQueuedMessageCountBySessionID[sessionID], 1)
        let sentWhileWorking = await task.sentMessages
        XCTAssertEqual(binaryPayloads(from: sentWhileWorking).count, 0)

        await task.enqueue(.text(
            "{\"t\":\"agent.status\",\"session\":\"" + sessionID + "\",\"epoch\":1,\"status\":{\"activity\":\"ready\"}}"
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
        XCTAssertEqual(payloads[0], Data("queued while working".utf8))
        XCTAssertEqual(payloads[1], Data([0x1B, 0x5B, 0x31, 0x33, 0x75]))
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
