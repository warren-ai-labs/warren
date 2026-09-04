import Foundation
import WarrenDomain

public struct ResizeRequest: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let size: TerminalSize

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID, size: TerminalSize) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.size = size
    }
}

public struct FocusRequest: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let focused: Bool

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID, focused: Bool) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.focused = focused
    }
}

public struct ControlRequest: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
    }
}

public struct ReleaseControlRequest: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let leaseID: ControlLeaseID?

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID, leaseID: ControlLeaseID? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.leaseID = leaseID
    }
}

public struct DetachRequest: Codable, Hashable, Sendable {
    public let version: ProtocolVersion
    public let sessionID: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let reason: String?

    public init(version: ProtocolVersion = .current, sessionID: TerminalSessionID,
                attachmentID: TerminalAttachmentID, reason: String? = nil) {
        self.version = version
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.reason = reason
    }
}

public enum ClientControlMessage: Codable, Hashable, Sendable {
    case resize(ResizeRequest)
    case focus(FocusRequest)
    case requestControl(ControlRequest)
    case releaseControl(ReleaseControlRequest)
    case detach(DetachRequest)

    public var version: ProtocolVersion {
        switch self {
        case .resize(let value): return value.version
        case .focus(let value): return value.version
        case .requestControl(let value): return value.version
        case .releaseControl(let value): return value.version
        case .detach(let value): return value.version
        }
    }

    private enum CodingKeys: String, CodingKey { case type, payload }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resize(let value):
            try container.encode("resize", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .focus(let value):
            try container.encode("focus", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .requestControl(let value):
            try container.encode("request_control", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .releaseControl(let value):
            try container.encode("release_control", forKey: .type)
            try container.encode(value, forKey: .payload)
        case .detach(let value):
            try container.encode("detach", forKey: .type)
            try container.encode(value, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "resize": self = .resize(try container.decode(ResizeRequest.self, forKey: .payload))
        case "focus": self = .focus(try container.decode(FocusRequest.self, forKey: .payload))
        case "request_control": self = .requestControl(try container.decode(ControlRequest.self, forKey: .payload))
        case "release_control": self = .releaseControl(try container.decode(ReleaseControlRequest.self, forKey: .payload))
        case "detach": self = .detach(try container.decode(DetachRequest.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "Unknown client control message type.")
        }
    }
}
