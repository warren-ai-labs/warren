import Foundation
import WarrenProtocol

/// The decoded binary message kind is explicit at the transport boundary.
/// Host code consumes `.input`; Client code consumes `.output`.
public enum WarrenDecodedBinaryMessage: Hashable, Sendable {
    case input(WarrenDecodedInputFrame)
    case output(WarrenDecodedOutputFrame)
    case atomicState(WarrenDecodedAtomicStateFrame)

    public var direction: BinaryFrameDirection {
        switch self {
        case .input: return .clientToHost
        case .output, .atomicState: return .hostToClient
        }
    }

    public var kind: BinaryFrameKind {
        switch self {
        case .input: return .input
        case .output: return .output
        case .atomicState: return .atomicState
        }
    }
}

/// A Host-readable client input frame. Input bytes are intentionally kept
/// separate from control JSON and are never decoded as text.
public struct WarrenDecodedInputFrame: Hashable, Sendable {
    public let metadata: InputMetadata
    public let payload: Data

    public init(metadata: InputMetadata, payload: Data) {
        self.metadata = metadata
        self.payload = payload
    }
}

/// A Client-readable Host PTY output frame.
public struct WarrenDecodedOutputFrame: Hashable, Sendable {
    public let header: BinaryOutputFrameHeader
    public let payload: Data

    public init(header: BinaryOutputFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

/// A Client-readable opaque terminal-emulator snapshot.
public struct WarrenDecodedAtomicStateFrame: Hashable, Sendable {
    public let header: BinaryAtomicStateFrameHeader
    public let payload: Data

    public init(header: BinaryAtomicStateFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

/// Encodes the bounded DENB terminal envelope.
public struct WarrenWireCodec: Sendable {
    public static let binaryMagic: [UInt8] = [0x44, 0x45, 0x4E, 0x42] // DENB
    public static let binaryVersion: UInt8 = 1
    public static let defaultMaxHeader = 16 * 1024
    public static let defaultMaxPayload = 8 * 1024 * 1024
    public static let defaultMaxAtomicStatePayload = 64 * 1024 * 1024

    public let maxHeader: Int
    public let maxPayload: Int
    public let maxAtomicStatePayload: Int

    /// The largest complete DENB envelope accepted by this codec. URLSession
    /// uses this value as its binary WebSocket message budget so the transport
    /// still admits a legal atomic-state snapshot without leaving a generous
    /// 128 MiB allocation window.
    public var maximumEnvelopeBytes: Int {
        let payloadLimit = max(maxPayload, maxAtomicStatePayload)
        let (headerAndPrefix, headerOverflow) = Self.binaryPrefixLength.addingReportingOverflow(maxHeader)
        let (total, payloadOverflow) = headerAndPrefix.addingReportingOverflow(payloadLimit)
        guard !headerOverflow, !payloadOverflow else { return Int.max }
        return total
    }

    public init(
        maxHeader: Int = WarrenWireCodec.defaultMaxHeader,
        maxPayload: Int = WarrenWireCodec.defaultMaxPayload,
        maxAtomicStatePayload: Int = WarrenWireCodec.defaultMaxAtomicStatePayload
    ) {
        self.maxHeader = max(0, maxHeader)
        self.maxPayload = max(0, maxPayload)
        self.maxAtomicStatePayload = max(0, maxAtomicStatePayload)
    }

    /// Decodes either binary kind for a dispatcher that owns both directions.
    public func decodeFrame(_ bytes: [UInt8]) throws -> WarrenDecodedBinaryMessage {
        let envelope = try parseEnvelope(bytes)
        switch envelope.kind {
        case .input:
            return .input(try decodeInputHeader(envelope))
        case .output:
            return .output(try decodeOutputHeader(envelope))
        case .atomicState:
            return .atomicState(try decodeAtomicStateHeader(envelope))
        }
    }

}
