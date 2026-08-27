import Foundation
import WarrenDomain
import WarrenProtocol

extension WarrenWireCodec {
    struct ParsedEnvelope: Sendable {
        let direction: BinaryFrameDirection
        let kind: BinaryFrameKind
        let headerBytes: Data
        let payload: Data
        let payloadLength: Int
    }

    struct RawOutputHeader: Decodable {
        let sessionID: TerminalSessionID
        let epoch: UInt64
        let sequence: UInt64
        let payloadLength: Int
    }

    struct RawInputHeader: Decodable {
        let version: ProtocolVersion
        let sessionID: TerminalSessionID
        let attachmentID: TerminalAttachmentID
        let payloadLength: Int
        let sequence: UInt64?
    }

    struct RawAtomicStateHeader: Decodable {
        let sessionID: TerminalSessionID
        let epoch: UInt64
        let sequence: UInt64
        let format: String
        let payloadLength: Int
    }

    func parseEnvelope(_ bytes: [UInt8]) throws -> ParsedEnvelope {
        guard bytes.count >= Self.binaryPrefixLength else {
            throw WarrenWireCodecError.truncatedFrame
        }
        guard Array(bytes.prefix(Self.binaryMagic.count)) == Self.binaryMagic else {
            throw WarrenWireCodecError.invalidMagic
        }
        let versionOffset = Self.binaryMagic.count
        guard bytes[versionOffset] == Self.binaryVersion else {
            throw WarrenWireCodecError.invalidVersion(received: bytes[versionOffset])
        }

        let directionRaw = bytes[versionOffset + 1]
        guard let direction = BinaryFrameDirection(rawValue: directionRaw) else {
            throw WarrenWireCodecError.invalidDirectionValue(received: directionRaw)
        }
        let kindRaw = bytes[versionOffset + 2]
        guard let kind = BinaryFrameKind(rawValue: kindRaw) else {
            throw WarrenWireCodecError.invalidKindValue(received: kindRaw)
        }
        guard kind.direction == direction else {
            throw WarrenWireCodecError.kindDirectionMismatch(kind: kind, direction: direction)
        }

        let headerLength = try checkedLength(readUInt32(bytes, at: versionOffset + 3))
        let payloadLength = try checkedLength(readUInt32(bytes, at: versionOffset + 7))
        guard headerLength <= maxHeader else {
            throw WarrenWireCodecError.headerTooLarge(actual: headerLength, limit: maxHeader)
        }
        let payloadLimit = kind == .atomicState ? maxAtomicStatePayload : maxPayload
        guard payloadLength <= payloadLimit else {
            throw WarrenWireCodecError.payloadTooLarge(actual: payloadLength, limit: payloadLimit)
        }

        let (payloadOffset, headerOverflow) = Self.binaryPrefixLength.addingReportingOverflow(headerLength)
        guard !headerOverflow else { throw WarrenWireCodecError.integerOverflow }
        guard bytes.count >= payloadOffset else {
            throw WarrenWireCodecError.truncatedFrame
        }
        let (expectedLength, payloadOverflow) = payloadOffset.addingReportingOverflow(payloadLength)
        guard !payloadOverflow else { throw WarrenWireCodecError.integerOverflow }
        guard bytes.count >= expectedLength else {
            throw WarrenWireCodecError.truncatedFrame
        }
        guard bytes.count == expectedLength else {
            throw WarrenWireCodecError.trailingBytes
        }

        return ParsedEnvelope(
            direction: direction,
            kind: kind,
            headerBytes: Data(bytes[Self.binaryPrefixLength..<payloadOffset]),
            payload: Data(bytes[payloadOffset..<expectedLength]),
            payloadLength: payloadLength
        )
    }

    private func checkedLength(_ value: UInt32) throws -> Int {
        guard let length = Int(exactly: value) else {
            throw WarrenWireCodecError.integerOverflow
        }
        return length
    }

    func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    static var binaryPrefixLength: Int {
        binaryMagic.count + 1 + 1 + 1 + MemoryLayout<UInt32>.size + MemoryLayout<UInt32>.size
    }
}
