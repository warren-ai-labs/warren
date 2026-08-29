import Foundation

/// A UUID whose phantom tag prevents identifiers from different domain entities
/// being mixed accidentally.
public struct DomainID<Tag: Sendable>: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.init(rawValue: rawValue)
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    /// A stable, human-sized prefix for local paths and labels. The canonical
    /// identity remains the complete UUID; this value is never persisted as a
    /// second identifier.
    public var shortDescription: String {
        String(description.prefix(8))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID string for a domain identifier."
            )
        }
        self.init(rawValue: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

public enum HostIDTag: Sendable {}
public enum TaskIDTag: Sendable {}
public enum ProjectIDTag: Sendable {}
public enum WorkspaceIDTag: Sendable {}
public enum TerminalGroupIDTag: Sendable {}
public enum TerminalSessionIDTag: Sendable {}
public enum TerminalAttachmentIDTag: Sendable {}
public enum ClientIDTag: Sendable {}
public enum ClientWindowIDTag: Sendable {}
public enum ControlLeaseIDTag: Sendable {}

public typealias HostID = DomainID<HostIDTag>
public typealias TaskID = DomainID<TaskIDTag>
public typealias ProjectID = DomainID<ProjectIDTag>
public typealias WorkspaceID = DomainID<WorkspaceIDTag>
public typealias TerminalGroupID = DomainID<TerminalGroupIDTag>
public typealias TerminalSessionID = DomainID<TerminalSessionIDTag>
public typealias TerminalAttachmentID = DomainID<TerminalAttachmentIDTag>
public typealias ClientID = DomainID<ClientIDTag>
public typealias ClientWindowID = DomainID<ClientWindowIDTag>
public typealias ControlLeaseID = DomainID<ControlLeaseIDTag>
