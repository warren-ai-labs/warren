import Foundation
import XCTest
@testable import WarrenProtocol
import WarrenDomain

final class WarrenProtocolTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    func testInputMetadataDoesNotContainPTYPayload() throws {
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 3)
        )
        let data = try JSONEncoder().encode(metadata)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("payloadBytes"))
        XCTAssertFalse(json.contains("data"))
        XCTAssertTrue(json.contains("payloadLength"))
        XCTAssertFalse(InputMetadata.supportsIdempotentSequence)
    }

    func testBinaryHeaderContainsOnlyFrameMetadata() throws {
        let header = try XCTUnwrap(
            BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: 3,
                sequence: 11,
                payloadLength: 5
            )
        )
        let decoded = try JSONDecoder().decode(
            BinaryOutputFrameHeader.self,
            from: JSONEncoder().encode(header)
        )
        XCTAssertEqual(header, decoded)
        XCTAssertEqual(header.payloadLength, 5)
    }

    /// A browser Session has no PTY, so its screencast still needs its own kind
    /// to stay out of a VT output parser (RFC 0022 §7.3).
    func testBrowserFrameKindIsFourAndHostToClientOnly() {
        XCTAssertEqual(BinaryFrameKind.browserFrame.rawValue, 4)
        XCTAssertEqual(BinaryFrameKind.browserFrame.direction, .hostToClient)
        XCTAssertEqual(BinaryFrameKind(rawValue: 4), .browserFrame)
        XCTAssertNil(BinaryFrameKind(rawValue: 5))

        let kinds: [BinaryFrameKind] = [.input, .output, .atomicState, .browserFrame]
        XCTAssertEqual(Set(kinds).count, 4)
        XCTAssertEqual(kinds.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertEqual(kinds.map(\.direction), [
            .clientToHost,
            .hostToClient,
            .hostToClient,
            .hostToClient,
        ])
    }

    func testBinaryBrowserFrameHeaderRoundTripsThroughJSON() throws {
        let header = try XCTUnwrap(
            BinaryBrowserFrameHeader(
                sessionID: sessionID,
                epoch: 4,
                sequence: 91,
                format: "browser-frame-jpeg-v1",
                payloadLength: 5
            )
        )
        let decoded = try JSONDecoder().decode(
            BinaryBrowserFrameHeader.self,
            from: JSONEncoder().encode(header)
        )
        XCTAssertEqual(header, decoded)
        XCTAssertEqual(decoded.format, "browser-frame-jpeg-v1")
        XCTAssertEqual(decoded.payloadLength, 5)
    }

    func testBinaryBrowserFrameHeaderRejectsAnEmptyFormatOrNegativeLength() throws {
        XCTAssertNil(BinaryBrowserFrameHeader(
            sessionID: sessionID,
            epoch: 1,
            sequence: 2,
            format: "",
            payloadLength: 1
        ))
        XCTAssertNil(BinaryBrowserFrameHeader(
            sessionID: sessionID,
            epoch: 1,
            sequence: 2,
            format: "browser-frame-jpeg-v1",
            payloadLength: -1
        ))

        let emptyFormatJSON = """
        {"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","epoch":1,"sequence":2,"format":"","payloadLength":1}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BinaryBrowserFrameHeader.self,
                from: Data(emptyFormatJSON.utf8)
            )
        )
        let negativeLengthJSON = """
        {"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","epoch":1,"sequence":2,"format":"browser-frame-jpeg-v1","payloadLength":-1}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BinaryBrowserFrameHeader.self,
                from: Data(negativeLengthJSON.utf8)
            )
        )
    }

    func testProtocolVersionRequiresAnExactCleanBreakMatch() {
        let current = ProtocolVersion.current
        XCTAssertTrue(current.canDecode(current))
        XCTAssertFalse(current.canDecode(ProtocolVersion(major: 4, minor: 1)))
        XCTAssertFalse(current.canDecode(ProtocolVersion(major: 3, minor: 0)))
        XCTAssertFalse(ProtocolVersion(major: 4, minor: 1).canDecode(current))
    }

    func testInvalidWireValuesAreRejectedDuringDecoding() throws {
        let inputJSON = """
        {"version":{"major":1,"minor":0},"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","attachmentID":"cccccccc-cccc-cccc-cccc-cccccccccccc","payloadLength":-1,"sequence":null}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(InputMetadata.self, from: Data(inputJSON.utf8))
        )

        let headerJSON = """
        {"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","epoch":1,"sequence":2,"payloadLength":-1}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(BinaryOutputFrameHeader.self, from: Data(headerJSON.utf8))
        )
    }
}
