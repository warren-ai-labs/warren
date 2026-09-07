import Foundation
import WarrenDomain

/// Stable metadata for one Client-to-Host terminal input payload.
///
/// `InputMetadata` describes bytes; it never owns them. The payload is carried
/// by the binary envelope and `payloadLength` must equal that envelope's payload
/// length. `sequence` is an optional client emission ordinal only. Protocol 4
/// encodes `version` as the same string used by the JSON control handshake so
/// Go, Swift, and Web DENB decoders share one header shape.
public struct InputMetadata: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let payloadLength: Int
    public let sequence: UInt64?

    /// Protocol 4.0 does not provide input ACK/deduplication semantics.
    public static let supportsIdempotentSequence = false

    public init?(
        version: ProtocolVersion = .current,
        sessionID: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        payloadLength: Int,
        sequence: UInt64? = nil
    ) {
        guard payloadLength >= 0 else { return nil }
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.payloadLength = payloadLength
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID
        case attachmentID
        case payloadLength
        case sequence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("\(version.major).\(version.minor)", forKey: .version)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(payloadLength, forKey: .payloadLength)
        try container.encodeIfPresent(sequence, forKey: .sequence)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVersion = try container.decode(String.self, forKey: .version)
        let parts = rawVersion.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let major = UInt16(parts[0]),
              let minor = UInt16(parts[1]) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "version must be a major.minor string."
            )
        }
        let version = ProtocolVersion(major: major, minor: minor)
        let sessionID = try container.decode(TerminalSessionID.self, forKey: .sessionID)
        let attachmentID = try container.decode(TerminalAttachmentID.self, forKey: .attachmentID)
        let payloadLength = try container.decode(Int.self, forKey: .payloadLength)
        let sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        guard let value = Self(
            version: version,
            sessionID: sessionID,
            attachmentID: attachmentID,
            payloadLength: payloadLength,
            sequence: sequence
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadLength,
                in: container,
                debugDescription: "payloadLength must be non-negative."
            )
        }
        self = value
    }
}
