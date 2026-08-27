/// The version carried by every control message.
public struct ProtocolVersion: Codable, Hashable, Sendable, Comparable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// Protocol 2 is the minimum supported control protocol. Terminal
    /// recovery is atomic in this version, so older clients cannot safely
    /// downgrade to the replay-only contract.
    public static let current = ProtocolVersion(major: 2, minor: 0)

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// Whether this local version can decode an incoming version.
    public func canDecode(_ incoming: ProtocolVersion) -> Bool {
        major == incoming.major && minor >= incoming.minor
    }

    @available(*, deprecated, message: "Use canDecode(_:) to make direction explicit.")
    public func isCompatible(with incoming: ProtocolVersion) -> Bool {
        canDecode(incoming)
    }
}

/// Features negotiated independently from the message version.
public struct ProtocolCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let binaryOutput = Self(rawValue: 1 << 0)
    public static let input = Self(rawValue: 1 << 1)
    public static let resize = Self(rawValue: 1 << 2)
    public static let focus = Self(rawValue: 1 << 3)
    public static let control = Self(rawValue: 1 << 4)
    public static let recovery = Self(rawValue: 1 << 5)
    public static let title = Self(rawValue: 1 << 6)
    public static let core: Self = [.binaryOutput, .input, .resize, .focus, .control, .recovery]
}
