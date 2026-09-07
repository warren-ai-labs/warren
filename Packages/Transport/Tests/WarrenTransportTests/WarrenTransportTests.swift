import XCTest
import WarrenClientCore
import WarrenDomain
import WarrenProtocol
@testable import WarrenTransport

final class WarrenWireCodecTests: XCTestCase {
    private let sessionID = TerminalSessionID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let attachmentID = TerminalAttachmentID(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    private func header(payloadLength: Int) -> BinaryOutputFrameHeader {
        BinaryOutputFrameHeader(
            sessionID: sessionID,
            epoch: 7,
            sequence: 12,
            payloadLength: payloadLength
        )!
    }

    func testInputAndOutputRoundTrips() throws {
        let codec = WarrenWireCodec()
        let inputMetadata = try XCTUnwrap(
            InputMetadata(
                sessionID: sessionID,
                attachmentID: attachmentID,
                payloadLength: 3,
                sequence: 12
            )
        )
        let inputWire = try codec.encodeInput(metadata: inputMetadata, payload: Data([0, 1, 255]))
        let decodedInput = try codec.decodeInputFrame(inputWire)
        XCTAssertEqual(decodedInput.metadata, inputMetadata)
        XCTAssertEqual(decodedInput.payload, Data([0, 1, 255]))
        XCTAssertEqual(try codec.decodeInputFrame(inputWire), decodedInput)
        if case .input(let message) = try codec.decodeFrame(inputWire) {
            XCTAssertEqual(message, decodedInput)
        } else {
            XCTFail("input envelope must remain distinguishable")
        }

        let wire = try codec.encodeOutput(header: header(payloadLength: 3), payload: Data([0, 1, 255]))
        let decoded = try codec.decodeOutputFrame(wire)
        XCTAssertEqual(decoded.header, header(payloadLength: 3))
        XCTAssertEqual(decoded.payload, Data([0, 1, 255]))
        XCTAssertEqual(try codec.decodeFrame(wire), .output(decoded))
    }

    func testAtomicStateRoundTripRemainsDistinctFromOutput() throws {
        let codec = WarrenWireCodec()
        let payload = Data("GHOSTSNP-state".utf8)
        let header = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 11,
            sequence: 4096,
            format: "ghostty-vt-snapshot-v1",
            payloadLength: payload.count
        ))
        let wire = try codec.encodeAtomicState(header: header, payload: payload)
        let decoded = try codec.decodeAtomicStateFrame(wire)
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(try codec.decodeFrame(wire), .atomicState(decoded))
        XCTAssertThrowsError(try codec.decodeOutputFrame(wire))
    }

    func testExactLimitsAreAcceptedAndOneBeyondIsRejected() throws {
        let payload = [UInt8](repeating: 4, count: 8)
        let frameHeader = header(payloadLength: payload.count)
        let baseline = WarrenWireCodec()
        let binary = try baseline.encodeOutput(header: frameHeader, payload: Data(payload))
        let headerLength = readUInt32(binary, at: 7)

        XCTAssertNoThrow(try WarrenWireCodec(maxHeader: Int(headerLength)).decodeOutputFrame(binary))
        XCTAssertThrowsError(try WarrenWireCodec(maxHeader: Int(headerLength) - 1).decodeOutputFrame(binary))
        XCTAssertNoThrow(try WarrenWireCodec(maxPayload: payload.count).decodeOutputFrame(binary))
        XCTAssertThrowsError(try WarrenWireCodec(maxPayload: payload.count - 1).decodeOutputFrame(binary))
    }

    func testAtomicStateUsesTheSharedSixtyFourMiBLimit() throws {
        let codec = WarrenWireCodec()
        let format = "ghostline-vt-replay-v1"

        let aboveOrdinaryOutput = Data(
            repeating: 0x41,
            count: WarrenWireCodec.defaultMaxPayload + 1
        )
        let aboveOutputHeader = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 1,
            sequence: 0,
            format: format,
            payloadLength: aboveOrdinaryOutput.count
        ))
        XCTAssertNoThrow(try codec.encodeAtomicState(
            header: aboveOutputHeader,
            payload: aboveOrdinaryOutput
        ))

        let atAtomicLimit = Data(
            repeating: 0x42,
            count: WarrenWireCodec.defaultMaxAtomicStatePayload
        )
        let atLimitHeader = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 1,
            sequence: 0,
            format: format,
            payloadLength: atAtomicLimit.count
        ))
        let wire = try codec.encodeAtomicState(header: atLimitHeader, payload: atAtomicLimit)
        XCTAssertEqual(try codec.decodeAtomicStateFrame(wire).payload.count, atAtomicLimit.count)

        let aboveAtomicLimit = Data(
            repeating: 0x43,
            count: WarrenWireCodec.defaultMaxAtomicStatePayload + 1
        )
        let aboveLimitHeader = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 1,
            sequence: 0,
            format: format,
            payloadLength: aboveAtomicLimit.count
        ))
        XCTAssertThrowsError(try codec.encodeAtomicState(
            header: aboveLimitHeader,
            payload: aboveAtomicLimit
        ))
    }

    func testBinaryErrorMatrixRejectsMalformedEnvelope() throws {
        let codec = WarrenWireCodec()
        let wire = try codec.encodeOutput(header: header(payloadLength: 2), payload: Data([1, 2]))

        var short = wire
        short.removeLast()
        XCTAssertThrowsError(try codec.decodeOutputFrame(short))

        var magic = wire
        magic[0] ^= 0xFF
        XCTAssertThrowsError(try codec.decodeOutputFrame(magic))

        var version = wire
        version[4] = WarrenWireCodec.binaryVersion &+ 1
        XCTAssertThrowsError(try codec.decodeOutputFrame(version))

        var trailing = wire
        trailing.append(9)
        XCTAssertThrowsError(try codec.decodeOutputFrame(trailing))

        let negative = Array("{\"sessionID\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"epoch\":1,\"sequence\":2,\"payloadLength\":-1}".utf8)
        let negativeWire = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.output.rawValue,
            header: negative,
            payloadLength: 0,
            payload: []
        )
        XCTAssertThrowsError(try codec.decodeOutputFrame(negativeWire))

    }

    func testDirectionAndKindAreValidatedBeforeHeaderDecode() throws {
        let codec = WarrenWireCodec()
        let metadata = try XCTUnwrap(
            InputMetadata(sessionID: sessionID, attachmentID: attachmentID, payloadLength: 1)
        )
        let input = try codec.encodeInput(metadata: metadata, payload: Data([8]))
        XCTAssertThrowsError(try codec.decodeOutputFrame(input)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .invalidDirection(expected: .hostToClient, received: .clientToHost)
            )
        }

        var invalidDirection = input
        invalidDirection[5] = BinaryFrameDirection.hostToClient.rawValue
        XCTAssertThrowsError(try codec.decodeInputFrame(invalidDirection)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .kindDirectionMismatch(kind: .input, direction: .hostToClient)
            )
        }

        var invalidDirectionValue = input
        invalidDirectionValue[5] = 99
        XCTAssertThrowsError(try codec.decodeFrame(invalidDirectionValue)) { error in
            XCTAssertEqual(error as? WarrenWireCodecError, .invalidDirectionValue(received: 99))
        }

        var invalidKindValue = input
        invalidKindValue[6] = 99
        XCTAssertThrowsError(try codec.decodeFrame(invalidKindValue)) { error in
            XCTAssertEqual(error as? WarrenWireCodecError, .invalidKindValue(received: 99))
        }
    }

    func testEnvelopeLengthsAreBoundedAndMustMatchHeaderAndPayload() throws {
        let codec = WarrenWireCodec(maxHeader: 128, maxPayload: 2)
        let outputHeader = try JSONEncoder().encode(header(payloadLength: 1))
        let tooLargeHeader = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.output.rawValue,
            header: Array(outputHeader),
            payloadLength: 3,
            payload: [1, 2, 3]
        )
        XCTAssertThrowsError(try codec.decodeOutputFrame(tooLargeHeader)) { error in
            XCTAssertEqual(error as? WarrenWireCodecError, .payloadTooLarge(actual: 3, limit: 2))
        }

        let valid = try WarrenWireCodec().encodeOutput(header: header(payloadLength: 1), payload: Data([1]))
        var mismatchedEnvelopeLength = valid
        writeUInt32(2, to: &mismatchedEnvelopeLength, at: 11)
        mismatchedEnvelopeLength.append(2)
        XCTAssertThrowsError(try codec.decodeOutputFrame(mismatchedEnvelopeLength))

        var oversizedHeaderLength = valid
        writeUInt32(UInt32.max, to: &oversizedHeaderLength, at: 7)
        XCTAssertThrowsError(try WarrenWireCodec().decodeOutputFrame(oversizedHeaderLength)) { error in
            XCTAssertEqual(
                error as? WarrenWireCodecError,
                .headerTooLarge(actual: Int(UInt32.max), limit: WarrenWireCodec.defaultMaxHeader)
            )
        }

        let atomicHeader = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 2,
            sequence: 3,
            format: "ghostline-vt-replay-v1",
            payloadLength: 1
        ))
        let atomicWire = try WarrenWireCodec().encodeAtomicState(
            header: atomicHeader,
            payload: Data([7])
        )
        let mismatchedAtomicHeader = try XCTUnwrap(BinaryAtomicStateFrameHeader(
            sessionID: sessionID,
            epoch: 2,
            sequence: 3,
            format: "ghostline-vt-replay-v1",
            payloadLength: 2
        ))
        let atomicHeaderMismatch = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.atomicState.rawValue,
            header: Array(try JSONEncoder().encode(mismatchedAtomicHeader)),
            payloadLength: 1,
            payload: [7]
        )
        XCTAssertThrowsError(try WarrenWireCodec().decodeAtomicStateFrame(atomicHeaderMismatch))

        var wrongDirection = atomicWire
        wrongDirection[5] = BinaryFrameDirection.clientToHost.rawValue
        XCTAssertThrowsError(try WarrenWireCodec().decodeAtomicStateFrame(wrongDirection))

        let invalidFormatJSON = Array(
            "{\"sessionID\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"epoch\":2,\"sequence\":3,\"format\":\"\",\"payloadLength\":1}".utf8
        )
        let invalidFormat = makeEnvelope(
            direction: BinaryFrameDirection.hostToClient.rawValue,
            kind: BinaryFrameKind.atomicState.rawValue,
            header: invalidFormatJSON,
            payloadLength: 1,
            payload: [7]
        )
        XCTAssertThrowsError(try WarrenWireCodec().decodeAtomicStateFrame(invalidFormat))
    }

    func testFuzzishMutationsNeverCrashAndPayloadLengthIsChecked() throws {
        let codec = WarrenWireCodec(maxPayload: 64)
        let wire = try codec.encodeOutput(header: header(payloadLength: 4), payload: Data([1, 2, 3, 4]))
        for index in 0..<wire.count {
            var mutation = wire
            mutation[index] ^= 0xA5
            _ = try? codec.decodeOutputFrame(mutation)
        }

        let mismatch = try codec.encodeOutput(header: header(payloadLength: 3), payload: Data([1, 2, 3]))
        var truncated = mismatch
        truncated.removeLast()
        XCTAssertThrowsError(try codec.decodeOutputFrame(truncated))
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

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}

final class WarrenANSIVisibilityRewriterTests: XCTestCase {
    func testRewritesOnlyPureBlackTruecolorForeground() {
        var rewriter = WarrenANSIVisibilityRewriter()
        let input = Data("\u{1B}[38;2;0;0;0mWorking \u{1B}[48;2;0;0;0mbackground".utf8)

        let output = rewriter.rewrite(input)

        XCTAssertEqual(
            String(decoding: output, as: UTF8.self),
            "\u{1B}[38;2;234;232;230mWorking \u{1B}[48;2;0;0;0mbackground"
        )
    }

    func testCarriesSplitSGRAcrossChunks() {
        var rewriter = WarrenANSIVisibilityRewriter()

        let first = rewriter.rewrite(Data("prefix\u{1B}[38;2;0;".utf8))
        let second = rewriter.rewrite(Data("0;0mWorking".utf8))

        XCTAssertEqual(String(decoding: first, as: UTF8.self), "prefix")
        XCTAssertEqual(
            String(decoding: second, as: UTF8.self),
            "\u{1B}[38;2;234;232;230mWorking"
        )
    }

    func testLeavesNearMissAndIndexedColorsUntouched() {
        var rewriter = WarrenANSIVisibilityRewriter()
        let input = Data(
            "\u{1B}[138;2;0;0;0mnear \u{1B}[30mindexed \u{1B}[38;2;1;0;0mred".utf8
        )

        XCTAssertEqual(rewriter.rewrite(input), input)
    }

    func testResetDiscardsAnIncompleteSequence() {
        var rewriter = WarrenANSIVisibilityRewriter()
        XCTAssertEqual(
            rewriter.rewrite(Data("\u{1B}[38;2;0;".utf8)),
            Data()
        )

        rewriter.reset()

        XCTAssertEqual(
            rewriter.rewrite(Data("0;0mtext".utf8)),
            Data("0;0mtext".utf8)
        )
    }
}
