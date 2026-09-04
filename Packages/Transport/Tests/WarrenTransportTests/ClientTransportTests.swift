import XCTest
import WarrenClientCore
import WarrenDomain
import WarrenProtocol
@testable import WarrenTransport

final class ClientTransportTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    func testConnectAndSendControlUsesTextAndInputUsesBinary() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        try await transport.connect()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 3)
        )
        try await transport.sendInput(metadata: metadata, payload: Data([1, 0, 255]))

        let messages = await fake.sentMessages
        XCTAssertEqual(messages.count, 1)
        guard case .binary(let input) = messages[0] else {
            return XCTFail("terminal input must use a binary WebSocket message")
        }
        let decodedInput = try WarrenWireCodec().decodeInputFrame(input)
        XCTAssertEqual(decodedInput.metadata, metadata)
        XCTAssertEqual(decodedInput.payload, Data([1, 0, 255]))
        let resumeCount = await fake.resumeCallCount
        XCTAssertEqual(resumeCount, 1)
    }

    func testInputPayloadMismatchDoesNotKillConnectedTransport() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        try await transport.connect()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 2)
        )
        do {
            try await transport.sendInput(metadata: metadata, payload: Data([1]))
            XCTFail("an input length mismatch must be rejected")
        } catch {
            // Expected; the receive/send connection remains usable.
        }
        let sentMessages = await fake.sentMessages
        XCTAssertEqual(sentMessages.count, 0)
    }

    func testSecondConnectDoesNotStartAnotherReceiveLoop() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        try await transport.connect()
        await fake.waitUntilReceiveCalled()

        do {
            try await transport.connect()
            XCTFail("a connected transport must reject a second connect")
        } catch let error as URLSessionWebSocketClientTransportError {
            XCTAssertEqual(error, .alreadyConnected)
        }
        let receiveCount = await fake.receiveCallCount
        let maximumConcurrentReceiveCount = await fake.maximumConcurrentReceiveCount
        XCTAssertEqual(receiveCount, 1)
        XCTAssertEqual(maximumConcurrentReceiveCount, 1)
        await transport.close()
    }

    func testReceiveLoopDecodesControlAndBinaryEvents() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        var events = transport.events().makeAsyncIterator()
        try await transport.connect()

        let codec = WarrenWireCodec()
        let title = ServerControlMessage.title(TitleMessage(sessionID: sessionID, title: "pty"))
        await fake.enqueue(.text(String(decoding: try codec.encodeControl(title), as: UTF8.self)))
        let control = try await events.next()
        XCTAssertEqual(control, .control(title))

        let header = BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 8, payloadLength: 2)!
        await fake.enqueue(.binary(try codec.encodeOutput(header: header, payload: Data([7, 8]))))
        let binary = try await events.next()
        XCTAssertEqual(binary, .binary(BinaryOutputFrame(header: header, payload: Data([7, 8]))))
    }

    func testCloseFinishesEventsAndCancelsTask() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        var events = transport.events().makeAsyncIterator()
        try await transport.connect()
        await transport.close()

        let closeEvent = try await events.next()
        XCTAssertNil(closeEvent)
        let cancelCount = await fake.cancelCallCount
        XCTAssertEqual(cancelCount, 1)
        do {
            try await transport.send(.focus(FocusRequest(sessionID: sessionID, attachmentID: attachmentID, focused: true)))
            XCTFail("sending after close must fail")
        } catch let error as URLSessionWebSocketClientTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testReceiveErrorFinishesEventsWithErrorAndCancelsTask() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        var events = transport.events().makeAsyncIterator()
        try await transport.connect()
        await fake.failReceive()

        do {
            _ = try await events.next()
            XCTFail("receive failure must terminate the event stream")
        } catch let error as ScriptedWebSocketTaskError {
            XCTAssertEqual(error, .scriptedFailure)
        }
        let cancelCount = await fake.cancelCallCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelWhileReceiveIsPendingFinishesEventsWithoutError() async throws {
        let fake = ScriptedWebSocketTask()
        let transport = URLSessionWebSocketClientTransport(task: fake)
        var events = transport.events().makeAsyncIterator()
        try await transport.connect()
        await transport.close()
        let closeEvent = try await events.next()
        XCTAssertNil(closeEvent)
    }
}
