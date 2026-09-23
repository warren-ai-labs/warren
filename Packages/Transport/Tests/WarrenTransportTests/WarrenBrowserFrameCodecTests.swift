import XCTest
import WarrenDomain
import WarrenProtocol
@testable import WarrenTransport

/// One screencast still for a Warren Browser Session rides in its own DENB kind
/// (RFC 0022 §7.3). A browser Session has no PTY, so these bytes must never be
/// mistaken for terminal output or for a VT snapshot.
final class WarrenBrowserFrameCodecTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)

    /// A synthetic JPEG still: SOI, an APP0/JFIF marker, then EOI. The codec only
    /// has to keep the bytes intact, but a realistic payload keeps the test
    /// honest about what a screencast frame actually looks like.
    private let jpeg = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xD9,
    ])

    private func header(
        sequence: UInt64 = 91,
        epoch: UInt64 = 4,
        format: String = WarrenRemoteClient.browserFrameFormat,
        payloadLength: Int
    ) -> BinaryBrowserFrameHeader {
        BinaryBrowserFrameHeader(
            sessionID: sessionID,
            epoch: epoch,
            sequence: sequence,
            format: format,
            payloadLength: payloadLength
        )!
    }

    func testBrowserFrameRoundTripsSessionSequenceAndPayload() throws {
        let codec = WarrenWireCodec()
        let wire = try codec.encodeBrowserFrame(header: header(payloadLength: jpeg.count), payload: jpeg)

        let decoded = try codec.decodeBrowserFrame(wire)
        XCTAssertEqual(decoded.header.sessionID, sessionID)
        XCTAssertEqual(decoded.header.epoch, 4)
        XCTAssertEqual(decoded.header.sequence, 91)
        XCTAssertEqual(decoded.header.format, WarrenRemoteClient.browserFrameFormat)
        XCTAssertEqual(decoded.header.payloadLength, jpeg.count)
        XCTAssertEqual(decoded.payload, jpeg)
        XCTAssertEqual(try codec.decodeFrame(wire), .browserFrame(decoded))
        XCTAssertEqual(try codec.decodeBrowserFrame(wire), decoded)
    }

    func testBrowserFrameKindIsFourAndDistinctFromEveryOtherKind() throws {
        XCTAssertEqual(BinaryFrameKind.input.rawValue, 1)
        XCTAssertEqual(BinaryFrameKind.output.rawValue, 2)
        XCTAssertEqual(BinaryFrameKind.atomicState.rawValue, 3)
        XCTAssertEqual(BinaryFrameKind.browserFrame.rawValue, 4)

        let codec = WarrenWireCodec()
        let wire = try codec.encodeBrowserFrame(header: header(payloadLength: jpeg.count), payload: jpeg)
        XCTAssertEqual(wire[6], BinaryFrameKind.browserFrame.rawValue)
        if case .browserFrame(let decoded) = try codec.decodeFrame(wire) {
            XCTAssertEqual(decoded.header.sequence, 91)
        } else {
            XCTFail("browser envelope must remain distinguishable")
        }

        // A browser frame is not terminal output and not a VT snapshot, even
        // though all three travel host-to-client.
        XCTAssertThrowsError(try codec.decodeOutputFrame(wire)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .kindDirectionMismatch(kind: .browserFrame, direction: .hostToClient)
            )
        }
        XCTAssertThrowsError(try codec.decodeAtomicStateFrame(wire)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .kindDirectionMismatch(kind: .browserFrame, direction: .hostToClient)
            )
        }
    }

    func testBrowserFrameIsHostToClientOnly() throws {
        let codec = WarrenWireCodec()
        let wire = try codec.encodeBrowserFrame(header: header(payloadLength: jpeg.count), payload: jpeg)
        XCTAssertEqual(wire[5], BinaryFrameDirection.hostToClient.rawValue)
        XCTAssertEqual(BinaryFrameKind.browserFrame.direction, .hostToClient)

        var clientToHost = wire
        clientToHost[5] = BinaryFrameDirection.clientToHost.rawValue
        XCTAssertThrowsError(try codec.decodeBrowserFrame(clientToHost)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .kindDirectionMismatch(kind: .browserFrame, direction: .clientToHost)
            )
        }
        // A Host endpoint never accepts one back as input.
        XCTAssertThrowsError(try codec.decodeInputFrame(wire)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .invalidDirection(expected: .clientToHost, received: .hostToClient)
            )
        }
    }

    /// Both directions refuse a frame over the budget. Encoding refuses first,
    /// which is what stops Warren from ever putting one on the wire; decoding
    /// refuses too, because the frame may have come from a Host that does not
    /// share this client's limits.
    func testBrowserFrameAcceptsTheFourMiBLimitAndRejectsOneBeyondIt() throws {
        let codec = WarrenWireCodec()
        let atLimit = Data(repeating: 0x00, count: WarrenWireCodec.defaultMaxBrowserFramePayload)
        let atLimitWire = try codec.encodeBrowserFrame(
            header: header(sequence: 0, epoch: 0, payloadLength: atLimit.count),
            payload: atLimit
        )
        XCTAssertEqual(try codec.decodeBrowserFrame(atLimitWire).payload.count, atLimit.count)

        let aboveLimit = Data(repeating: 0x01, count: WarrenWireCodec.defaultMaxBrowserFramePayload + 1)
        XCTAssertThrowsError(
            try codec.encodeBrowserFrame(
                header: header(sequence: 0, epoch: 0, payloadLength: aboveLimit.count),
                payload: aboveLimit
            )
        ) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .payloadTooLarge(
                    actual: aboveLimit.count,
                    limit: WarrenWireCodec.defaultMaxBrowserFramePayload
                )
            )
        }
        // The encoder refused, so the oversized envelope is built by hand to
        // prove the decoder refuses the same bytes independently.
        let handBuilt = handBuiltBrowserFrame(payloadLength: aboveLimit.count)
        XCTAssertThrowsError(try codec.decodeBrowserFrame(handBuilt)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .payloadTooLarge(
                    actual: aboveLimit.count,
                    limit: WarrenWireCodec.defaultMaxBrowserFramePayload
                )
            )
        }
    }

    /// Builds a browser frame envelope without going through the encoder, for
    /// the cases where the encoder correctly refuses to produce the bytes or
    /// where the header itself is what is under test.
    private func handBuiltBrowserFrame(payloadLength: Int, format: String? = nil) -> [UInt8] {
        let frameFormat = format ?? WarrenRemoteClient.browserFrameFormat
        let headerJSON = """
        {"sessionID":"\(sessionID.description)","epoch":4,"sequence":91,"format":"\(frameFormat)","payloadLength":\(payloadLength)}
        """
        let header = Array(headerJSON.utf8)
        var wire: [UInt8] = Array(WarrenWireCodec.binaryMagic)
        wire.append(WarrenWireCodec.binaryVersion)
        wire.append(BinaryFrameDirection.hostToClient.rawValue)
        wire.append(BinaryFrameKind.browserFrame.rawValue)
        wire.append(contentsOf: bigEndianUInt32(UInt32(header.count)))
        wire.append(contentsOf: bigEndianUInt32(UInt32(payloadLength)))
        wire.append(contentsOf: header)
        wire.append(contentsOf: repeatElement(0x00, count: payloadLength))
        return wire
    }

    private func bigEndianUInt32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// The envelope itself enforces the browser frame budget, not just the
    /// header decoder. Go applies the same per-kind budget in `parseEnvelope`,
    /// so a frame over 4 MiB is a malformed envelope on both sides of the wire
    /// rather than something one binding accepts and the other rejects.
    func testTheEnvelopeParserEnforcesTheBrowserFrameBudget() throws {
        let codec = WarrenWireCodec()
        let oversized = Data(repeating: 0x00, count: WarrenWireCodec.defaultMaxBrowserFramePayload + 1)
        let wire = try handBuiltBrowserFrame(payloadLength: oversized.count)

        XCTAssertThrowsError(try codec.parseEnvelope(wire)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .payloadTooLarge(
                    actual: oversized.count,
                    limit: WarrenWireCodec.defaultMaxBrowserFramePayload
                )
            )
        }
        // The per-kind budget is per kind: the same byte count is legal as
        // terminal output, which is bounded by the ordinary payload limit.
        let asOutput = try codec.encodeOutput(
            header: BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: 0,
                sequence: 0,
                payloadLength: oversized.count
            )!,
            payload: oversized
        )
        XCTAssertEqual(try codec.parseEnvelope(asOutput).payload.count, oversized.count)
    }

    /// The format is the codec's contract, not the image decoder's discovery.
    /// A frame naming an encoding Warren does not produce is refused here, which
    /// is where Go refuses it too.
    func testTheCodecRefusesABrowserFrameWithAnUnsupportedFormat() throws {
        let codec = WarrenWireCodec()
        // An empty format is refused one step earlier: the header type itself
        // will not be built without one, so the frame never reaches the format
        // check. Both refusals are correct; they are just different rules.
        XCTAssertNil(
            BinaryBrowserFrameHeader(
                sessionID: sessionID,
                epoch: 4,
                sequence: 91,
                format: "",
                payloadLength: jpeg.count
            )
        )
        for format in ["browser-frame-png-v1", "browser-frame-jpeg-v2", "ghostline-vt-replay-v1"] {
            // Built by hand: the header type refuses an empty format outright,
            // so the encoder cannot produce the frame this test needs.
            let wire = handBuiltBrowserFrame(payloadLength: jpeg.count, format: format)
            XCTAssertThrowsError(try codec.decodeBrowserFrame(wire), "format \(format) was accepted") { error in
                XCTAssertEqual(
                    error as? WarrenWireCodecError,
                    .unsupportedFrameFormat(format)
                )
            }
        }
    }

    func testBrowserFrameHonoursAPerCodecLimitSmallerThanTheDefault() throws {
        let codec = WarrenWireCodec(maxBrowserFramePayload: 8)
        let accepted = Data([0xFF, 0xD8, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        let wire = try codec.encodeBrowserFrame(header: header(payloadLength: accepted.count), payload: accepted)
        XCTAssertEqual(try codec.decodeBrowserFrame(wire).payload, accepted)

        let oversized = Data(repeating: 0x7F, count: 9)
        XCTAssertThrowsError(
            try codec.encodeBrowserFrame(header: header(payloadLength: oversized.count), payload: oversized)
        ) { error in
            XCTAssertEqual(error as? WarrenWireCodecError, .payloadTooLarge(actual: 9, limit: 8))
        }
        XCTAssertThrowsError(try codec.decodeBrowserFrame(handBuiltBrowserFrame(payloadLength: 9))) { error in
            XCTAssertEqual(error as? WarrenWireCodecError, .payloadTooLarge(actual: 9, limit: 8))
        }
    }

    /// The socket budget must admit one legal screencast frame even when the
    /// browser frame budget is the largest payload budget a codec was built with.
    func testMaximumEnvelopeBytesIncludesTheBrowserFrameBudget() {
        let browserOnly = WarrenWireCodec(
            maxHeader: 32,
            maxPayload: 64,
            maxAtomicStatePayload: 16,
            maxBrowserFramePayload: 4096
        )
        XCTAssertEqual(
            browserOnly.maximumEnvelopeBytes,
            WarrenWireCodec.binaryPrefixLength + 32 + 4096
        )
        // A default codec is still bounded by its atomic-state budget: a browser
        // frame is far smaller than a VT snapshot.
        XCTAssertEqual(
            WarrenWireCodec().maximumEnvelopeBytes,
            WarrenWireCodec.binaryPrefixLength
                + WarrenWireCodec.defaultMaxHeader
                + WarrenWireCodec.defaultMaxAtomicStatePayload
        )
    }

    func testBrowserFrameRejectsALengthThatDisagreesWithTheEnvelope() throws {
        let codec = WarrenWireCodec()
        let wire = try codec.encodeBrowserFrame(header: header(payloadLength: jpeg.count), payload: jpeg)
        var truncated = wire
        truncated.removeLast()
        XCTAssertThrowsError(try codec.decodeBrowserFrame(truncated))

        var trailing = wire
        trailing.append(9)
        XCTAssertThrowsError(try codec.decodeBrowserFrame(trailing))

        // The header claims one more byte than the envelope actually carries.
        let headerJSON = Array(
            """
            {"sessionID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","epoch":4,"sequence":91,"format":"browser-frame-jpeg-v1","payloadLength":\(jpeg.count + 1)}
            """.utf8
        )
        let mismatchedLength = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.browserFrame.rawValue,
            header: headerJSON,
            payloadLength: UInt32(jpeg.count),
            payload: Array(jpeg)
        )
        XCTAssertThrowsError(try codec.decodeBrowserFrame(mismatchedLength))
    }

    private func makeEnvelope(
        direction: UInt8,
        kind: UInt8,
        header: [UInt8],
        payloadLength: UInt32,
        payload: [UInt8]
    ) -> [UInt8] {
        var result = WarrenWireCodec.binaryMagic
        result.append(WarrenWireCodec.binaryVersion)
        result.append(direction)
        result.append(kind)
        appendUInt32(UInt32(header.count), to: &result)
        appendUInt32(payloadLength, to: &result)
        result.append(contentsOf: header)
        result.append(contentsOf: payload)
        return result
    }

    private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}
