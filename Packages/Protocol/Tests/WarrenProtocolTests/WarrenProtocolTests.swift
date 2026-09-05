import Foundation
import XCTest
@testable import WarrenProtocol
import WarrenDomain

final class WarrenProtocolTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let clientID = ClientID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    func testClientMessagesRoundTripAndCarryVersion() throws {
        let version = ProtocolVersion(major: 2, minor: 7)
        let messages: [ClientControlMessage] = [
            .resize(ResizeRequest(version: version, sessionID: sessionID, attachmentID: attachmentID, size: TerminalSize(columns: 120, rows: 40)!)),
            .focus(FocusRequest(version: version, sessionID: sessionID, attachmentID: attachmentID, focused: true)),
            .requestControl(ControlRequest(version: version, sessionID: sessionID, attachmentID: attachmentID)),
            .releaseControl(ReleaseControlRequest(version: version, sessionID: sessionID, attachmentID: attachmentID)),
            .detach(DetachRequest(version: version, sessionID: sessionID, attachmentID: attachmentID)),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for message in messages {
            let data = try encoder.encode(message)
            XCTAssertEqual(message, try decoder.decode(ClientControlMessage.self, from: data))
            XCTAssertEqual(message.version, version)
        }
    }

    func testServerMessagesRoundTrip() throws {
        let version = ProtocolVersion.current
        let messages: [ServerControlMessage] = [
            .attached(AttachedMessage(version: version, sessionID: sessionID, attachmentID: attachmentID, epoch: 2, sequence: 8)),
            .error(try XCTUnwrap(ProtocolError(version: version, code: .controlRequired, message: "Request control before sending input."))),
            .exit(ExitMessage(version: version, sessionID: sessionID, epoch: 2, sequence: 8, exitCode: 0)),
            .title(TitleMessage(version: version, sessionID: sessionID, title: "shell")),
            .synced(SyncedMessage(version: version, sessionID: sessionID, anchor: RecoveryAnchor(epoch: 2, sequence: 8))),
            .controlChanged(ControlChangedMessage(version: version, sessionID: sessionID, controllerAttachmentID: attachmentID)),
        ]

        for message in messages {
            let data = try JSONEncoder().encode(message)
            XCTAssertEqual(message, try JSONDecoder().decode(ServerControlMessage.self, from: data))
        }
    }

    func testInputMetadataDoesNotContainPTYPayload() throws {
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 3)
        )
        let data = try JSONEncoder().encode(metadata)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("payloadBytes"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("data"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("payloadLength"))
        XCTAssertFalse(InputMetadata.supportsIdempotentSequence)
    }

    func testBinaryHeaderContainsOnlyFrameMetadata() throws {
        let header = try XCTUnwrap(BinaryOutputFrameHeader(sessionID: sessionID, epoch: 3, sequence: 11, payloadLength: 5))
        let decoded = try JSONDecoder().decode(BinaryOutputFrameHeader.self, from: JSONEncoder().encode(header))
        XCTAssertEqual(header, decoded)
        XCTAssertEqual(header.payloadLength, 5)
    }

    func testRecoveryBoundaries() {
        let anchorEpoch: UInt64 = 4
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: nil),
            .reanchor
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch + 1, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 15)),
            .reanchor
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 20)),
            .exact
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 10)),
            .tail(from: 10)
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 9)),
            .reanchor
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 10, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 21)),
            .reanchor
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 20, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 20)),
            .exact
        )
        XCTAssertEqual(
            RecoveryPlanner.plan(serverEpoch: anchorEpoch, bufferLowerSequence: 21, bufferUpperSequence: 20, anchor: RecoveryAnchor(epoch: anchorEpoch, sequence: 20)),
            .reanchor
        )
    }

    func testInvalidWireValuesAreRejectedDuringDecoding() throws {
        let inputJSON = """
        {"version":{"major":1,"minor":0},"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","attachmentID":"cccccccc-cccc-cccc-cccc-cccccccccccc","payloadLength":-1,"sequence":null}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(InputMetadata.self, from: Data(inputJSON.utf8)))

        let headerJSON = """
        {"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","epoch":1,"sequence":2,"payloadLength":-1}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(BinaryOutputFrameHeader.self, from: Data(headerJSON.utf8)))

        for message in ["", " ", "\n\t"] {
            let errorJSON = """
            {"version":{"major":1,"minor":0},"code":"invalid_message","message":"\(message)","retryable":false}
            """
            XCTAssertThrowsError(try JSONDecoder().decode(ProtocolError.self, from: Data(errorJSON.utf8)))
        }
        XCTAssertNil(ProtocolError(code: .invalidMessage, message: " \n"))
    }

    func testProtocolVersionCanDecodeBoundaries() {
        let local = ProtocolVersion(major: 2, minor: 3)
        XCTAssertTrue(local.canDecode(ProtocolVersion(major: 2, minor: 0)))
        XCTAssertTrue(local.canDecode(ProtocolVersion(major: 2, minor: 3)))
        XCTAssertFalse(local.canDecode(ProtocolVersion(major: 2, minor: 4)))
        XCTAssertFalse(local.canDecode(ProtocolVersion(major: 1, minor: 99)))
        XCTAssertFalse(ProtocolVersion(major: 2, minor: 0).canDecode(local))
    }

    func testCurrentProtocolVersionIsProtocolThree() {
        XCTAssertEqual(ProtocolVersion.current, ProtocolVersion(major: 3, minor: 0))
        XCTAssertTrue(ProtocolVersion.current.canDecode(ProtocolVersion(major: 3, minor: 0)))
        XCTAssertFalse(ProtocolVersion.current.canDecode(ProtocolVersion(major: 1, minor: 0)))
    }
}
