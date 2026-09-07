import WarrenProtocol

public enum WarrenWireCodecError: Error, Equatable, Sendable {
    case headerTooLarge(actual: Int, limit: Int)
    case payloadTooLarge(actual: Int, limit: Int)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case negativePayloadLength
    case invalidHeaderJSON
    case truncatedFrame
    case trailingBytes
    case invalidMagic
    case invalidVersion(received: UInt8)
    case invalidDirection(expected: BinaryFrameDirection, received: BinaryFrameDirection)
    case invalidDirectionValue(received: UInt8)
    case invalidKindValue(received: UInt8)
    case kindDirectionMismatch(kind: BinaryFrameKind, direction: BinaryFrameDirection)
    case integerOverflow
}
