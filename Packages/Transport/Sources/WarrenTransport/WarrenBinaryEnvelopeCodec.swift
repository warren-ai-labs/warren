import Foundation
import WarrenDomain
import WarrenProtocol

extension WarrenWireCodec {
    /// Encodes Host-to-Client PTY output.
    public func encodeOutput(
        header: BinaryOutputFrameHeader,
        payload: Data
    ) throws -> [UInt8] {
        try encodeEnvelope(
            kind: .output,
            header: header,
            payload: Array(payload),
            headerPayloadLength: header.payloadLength
        )
    }

    /// Encodes Client-to-Host terminal input. The metadata is the sole input
    /// header model; its payload length is checked against both payloads.
    public func encodeInput(
        metadata: InputMetadata,
        payload: Data
    ) throws -> [UInt8] {
        try encodeEnvelope(
            kind: .input,
            header: metadata,
            payload: Array(payload),
            headerPayloadLength: metadata.payloadLength
        )
    }

    /// Encodes one Host-to-Client native terminal state. This deliberately
    /// uses a separate binary kind from PTY output.
    public func encodeAtomicState(
        header: BinaryAtomicStateFrameHeader,
        payload: Data
    ) throws -> [UInt8] {
        try encodeEnvelope(
            kind: .atomicState,
            header: header,
            payload: Array(payload),
            headerPayloadLength: header.payloadLength
        )
    }

    public func decodeOutputFrame(_ bytes: [UInt8]) throws -> WarrenDecodedOutputFrame {
        let envelope = try parseEnvelope(bytes)
        guard envelope.direction == .hostToClient else {
            throw WarrenWireCodecError.invalidDirection(
                expected: .hostToClient,
                received: envelope.direction
            )
        }
        guard envelope.kind == .output else {
            throw WarrenWireCodecError.kindDirectionMismatch(
                kind: envelope.kind,
                direction: envelope.direction
            )
        }
        return try decodeOutputHeader(envelope)
    }

    public func decodeInputFrame(_ bytes: [UInt8]) throws -> WarrenDecodedInputFrame {
        let envelope = try parseEnvelope(bytes)
        guard envelope.direction == .clientToHost else {
            throw WarrenWireCodecError.invalidDirection(
                expected: .clientToHost,
                received: envelope.direction
            )
        }
        guard envelope.kind == .input else {
            throw WarrenWireCodecError.kindDirectionMismatch(
                kind: envelope.kind,
                direction: envelope.direction
            )
        }
        return try decodeInputHeader(envelope)
    }

    public func decodeAtomicStateFrame(_ bytes: [UInt8]) throws -> WarrenDecodedAtomicStateFrame {
        let envelope = try parseEnvelope(bytes)
        guard envelope.direction == .hostToClient else {
            throw WarrenWireCodecError.invalidDirection(
                expected: .hostToClient,
                received: envelope.direction
            )
        }
        guard envelope.kind == .atomicState else {
            throw WarrenWireCodecError.kindDirectionMismatch(
                kind: envelope.kind,
                direction: envelope.direction
            )
        }
        return try decodeAtomicStateHeader(envelope)
    }

    private func encodeEnvelope<Header: Encodable>(
        kind: BinaryFrameKind,
        header: Header,
        payload: [UInt8],
        headerPayloadLength: Int
    ) throws -> [UInt8] {
        guard headerPayloadLength >= 0 else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        guard payload.count == headerPayloadLength else {
            throw WarrenWireCodecError.payloadLengthMismatch(
                expected: headerPayloadLength,
                actual: payload.count
            )
        }
        let payloadLimit = kind == .atomicState ? maxAtomicStatePayload : maxPayload
        guard payload.count <= payloadLimit else {
            throw WarrenWireCodecError.payloadTooLarge(actual: payload.count, limit: payloadLimit)
        }
        guard payload.count <= UInt32.max else {
            throw WarrenWireCodecError.integerOverflow
        }

        let headerBytes: Data
        do {
            headerBytes = try JSONEncoder().encode(header)
        } catch {
            throw WarrenWireCodecError.invalidHeaderJSON
        }
        guard headerBytes.count <= maxHeader else {
            throw WarrenWireCodecError.headerTooLarge(actual: headerBytes.count, limit: maxHeader)
        }
        guard headerBytes.count <= UInt32.max else {
            throw WarrenWireCodecError.integerOverflow
        }

        let prefixLength = Self.binaryPrefixLength
        let (withHeader, headerOverflow) = prefixLength.addingReportingOverflow(headerBytes.count)
        let (totalLength, payloadOverflow) = withHeader.addingReportingOverflow(payload.count)
        guard !headerOverflow, !payloadOverflow else {
            throw WarrenWireCodecError.integerOverflow
        }

        var result = [UInt8]()
        result.reserveCapacity(totalLength)
        result.append(contentsOf: Self.binaryMagic)
        result.append(Self.binaryVersion)
        result.append(kind.direction.rawValue)
        result.append(kind.rawValue)
        appendUInt32(UInt32(headerBytes.count), to: &result)
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(contentsOf: headerBytes)
        result.append(contentsOf: payload)
        return result
    }

    func decodeOutputHeader(_ envelope: ParsedEnvelope) throws -> WarrenDecodedOutputFrame {
        let raw: RawOutputHeader
        do {
            raw = try JSONDecoder().decode(RawOutputHeader.self, from: Data(envelope.headerBytes))
        } catch {
            throw WarrenWireCodecError.invalidHeaderJSON
        }
        guard raw.payloadLength >= 0 else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        guard raw.payloadLength <= maxPayload else {
            throw WarrenWireCodecError.payloadTooLarge(actual: raw.payloadLength, limit: maxPayload)
        }
        guard raw.payloadLength == envelope.payloadLength else {
            throw WarrenWireCodecError.payloadLengthMismatch(
                expected: raw.payloadLength,
                actual: envelope.payloadLength
            )
        }
        guard let header = BinaryOutputFrameHeader(
            sessionID: raw.sessionID,
            epoch: raw.epoch,
            sequence: raw.sequence,
            payloadLength: raw.payloadLength
        ) else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        return WarrenDecodedOutputFrame(header: header, payload: envelope.payload)
    }

    func decodeInputHeader(_ envelope: ParsedEnvelope) throws -> WarrenDecodedInputFrame {
        let raw: RawInputHeader
        do {
            raw = try JSONDecoder().decode(RawInputHeader.self, from: Data(envelope.headerBytes))
        } catch {
            throw WarrenWireCodecError.invalidHeaderJSON
        }
        guard raw.payloadLength >= 0 else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        guard raw.payloadLength <= maxPayload else {
            throw WarrenWireCodecError.payloadTooLarge(actual: raw.payloadLength, limit: maxPayload)
        }
        guard raw.payloadLength == envelope.payloadLength else {
            throw WarrenWireCodecError.payloadLengthMismatch(
                expected: raw.payloadLength,
                actual: envelope.payloadLength
            )
        }
        let versionParts = raw.version.split(separator: ".", omittingEmptySubsequences: true)
        guard versionParts.count == 2,
              let major = UInt16(versionParts[0]),
              let minor = UInt16(versionParts[1]),
              let metadata = InputMetadata(
            version: ProtocolVersion(major: major, minor: minor),
            sessionID: raw.sessionID,
            attachmentID: raw.attachmentID,
            payloadLength: raw.payloadLength,
            sequence: raw.sequence
        ) else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        return WarrenDecodedInputFrame(metadata: metadata, payload: envelope.payload)
    }

    func decodeAtomicStateHeader(_ envelope: ParsedEnvelope) throws -> WarrenDecodedAtomicStateFrame {
        let raw: RawAtomicStateHeader
        do {
            raw = try JSONDecoder().decode(RawAtomicStateHeader.self, from: Data(envelope.headerBytes))
        } catch {
            throw WarrenWireCodecError.invalidHeaderJSON
        }
        guard raw.payloadLength >= 0 else {
            throw WarrenWireCodecError.negativePayloadLength
        }
        guard raw.payloadLength <= maxAtomicStatePayload else {
            throw WarrenWireCodecError.payloadTooLarge(
                actual: raw.payloadLength,
                limit: maxAtomicStatePayload
            )
        }
        guard raw.payloadLength == envelope.payloadLength else {
            throw WarrenWireCodecError.payloadLengthMismatch(
                expected: raw.payloadLength,
                actual: envelope.payloadLength
            )
        }
        guard let header = BinaryAtomicStateFrameHeader(
            sessionID: raw.sessionID,
            epoch: raw.epoch,
            sequence: raw.sequence,
            format: raw.format,
            payloadLength: raw.payloadLength
        ) else {
            throw WarrenWireCodecError.invalidHeaderJSON
        }
        return WarrenDecodedAtomicStateFrame(header: header, payload: envelope.payload)
    }

}
