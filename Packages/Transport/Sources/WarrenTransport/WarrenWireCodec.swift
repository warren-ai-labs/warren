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

/// Encodes control JSON and the bounded binary terminal envelope.
public struct WarrenWireCodec: Sendable {
    public static let binaryMagic: [UInt8] = [0x44, 0x45, 0x4E, 0x42] // DENB
    public static let binaryVersion: UInt8 = 1
    public static let defaultMaxControl = 64 * 1024
    public static let defaultMaxHeader = 16 * 1024
    public static let defaultMaxPayload = 8 * 1024 * 1024
    public static let defaultMaxAtomicStatePayload = 64 * 1024 * 1024

    public let maxControl: Int
    public let maxHeader: Int
    public let maxPayload: Int
    public let maxAtomicStatePayload: Int

    public init(
        maxControl: Int = WarrenWireCodec.defaultMaxControl,
        maxHeader: Int = WarrenWireCodec.defaultMaxHeader,
        maxPayload: Int = WarrenWireCodec.defaultMaxPayload,
        maxAtomicStatePayload: Int = WarrenWireCodec.defaultMaxAtomicStatePayload
    ) {
        self.maxControl = max(0, maxControl)
        self.maxHeader = max(0, maxHeader)
        self.maxPayload = max(0, maxPayload)
        self.maxAtomicStatePayload = max(0, maxAtomicStatePayload)
    }

    public func encodeControl(_ message: ClientControlMessage) throws -> [UInt8] {
        try encodeControlValue(message)
    }

    public func encodeControl(_ message: ServerControlMessage) throws -> [UInt8] {
        try encodeControlValue(message)
    }

    public func decodeServerControl(_ bytes: [UInt8]) throws -> ServerControlMessage {
        try decodeControlValue(bytes, as: ServerControlMessage.self)
    }

    public func decodeClientControl(_ bytes: [UInt8]) throws -> ClientControlMessage {
        try decodeControlValue(bytes, as: ClientControlMessage.self)
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

    private func encodeControlValue<Value: Encodable>(_ value: Value) throws -> [UInt8] {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw WarrenWireCodecError.invalidControlJSON
        }
        guard data.count <= maxControl else {
            throw WarrenWireCodecError.controlTooLarge(actual: data.count, limit: maxControl)
        }
        return Array(data)
    }

    private func decodeControlValue<Value: Decodable>(
        _ bytes: [UInt8],
        as type: Value.Type
    ) throws -> Value {
        guard bytes.count <= maxControl else {
            throw WarrenWireCodecError.controlTooLarge(actual: bytes.count, limit: maxControl)
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw WarrenWireCodecError.invalidUTF8
        }
        do {
            return try JSONDecoder().decode(type, from: Data(bytes))
        } catch {
            throw WarrenWireCodecError.invalidControlJSON
        }
    }
}
