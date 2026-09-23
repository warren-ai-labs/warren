import Foundation
import WarrenProtocol

public enum WarrenWireCodecError: Error, Equatable, Sendable {
    case headerTooLarge(actual: Int, limit: Int)
    case payloadTooLarge(actual: Int, limit: Int)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case negativePayloadLength
    case invalidHeaderJSON
    /// The frame names an encoding its payload is not in. Refused by the codec
    /// rather than by whatever decodes the payload next, which must not be the
    /// component that discovers it was handed the wrong format.
    case unsupportedFrameFormat(String)
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

extension WarrenWireCodecError: LocalizedError {
    /// A codec failure reaches the user as a disconnect reason, so an error
    /// without a description reports "couldn't be completed (error 1)" — which
    /// is exactly the wrong thing to say about a truncated frame or a payload
    /// over budget, the two failures most likely to be real.
    public var errorDescription: String? {
        switch self {
        case .headerTooLarge(let actual, let limit):
            return "The frame header is too large (\(actual) bytes; limit \(limit))."
        case .payloadTooLarge(let actual, let limit):
            return "The frame payload is too large (\(actual) bytes; limit \(limit))."
        case .payloadLengthMismatch(let expected, let actual):
            return "The frame header declares \(expected) payload bytes but the envelope carries \(actual)."
        case .negativePayloadLength:
            return "The frame header declares a negative payload length."
        case .invalidHeaderJSON:
            return "The frame header is not valid JSON."
        case .unsupportedFrameFormat(let format):
            return "The frame names an unsupported payload format: \(format)."
        case .truncatedFrame:
            return "The frame ended before its declared length."
        case .trailingBytes:
            return "The frame carries bytes beyond its declared length."
        case .invalidMagic:
            return "The frame does not begin with the Warren binary frame magic."
        case .invalidVersion(let received):
            return "The frame uses an unsupported binary wire version (\(received))."
        case .invalidDirection(let expected, let received):
            return "The frame travels \(directionName(received)) but this frame kind is \(directionName(expected))."
        case .invalidDirectionValue(let received):
            return "The frame carries an unknown direction byte (\(received))."
        case .invalidKindValue(let received):
            return "The frame carries an unknown kind byte (\(received))."
        case .kindDirectionMismatch(let kind, let direction):
            return "A \(kindName(kind)) frame cannot travel \(directionName(direction))."
        case .integerOverflow:
            return "The frame declares a length that does not fit."
        }
    }

    private func directionName(_ direction: BinaryFrameDirection) -> String {
        switch direction {
        case .clientToHost: return "client-to-host"
        case .hostToClient: return "host-to-client"
        }
    }

    private func kindName(_ kind: BinaryFrameKind) -> String {
        switch kind {
        case .input: return "input"
        case .output: return "output"
        case .atomicState: return "atomic state"
        case .browserFrame: return "browser frame"
        }
    }
}
