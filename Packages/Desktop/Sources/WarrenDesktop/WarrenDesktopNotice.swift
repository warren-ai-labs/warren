import Foundation

/// A bounded, client-local system message. Notices deliberately do not own
/// transport or Host state; they are presentation history for the current
/// desktop process.
public struct WarrenDesktopNotice: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case error
        case warning
        case info
        case success
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let message: String
    public let detail: String
    public let createdAt: Date
    public var isUnread: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind = .info,
        title: String,
        message: String,
        detail: String? = nil,
        createdAt: Date = Date(),
        isUnread: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.detail = detail ?? message
        self.createdAt = createdAt
        self.isUnread = isUnread
    }
}
