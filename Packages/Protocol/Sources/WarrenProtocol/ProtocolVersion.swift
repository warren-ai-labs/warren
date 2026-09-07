/// The version carried by every DENB metadata envelope.
public struct ProtocolVersion: Codable, Hashable, Sendable, Comparable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// Protocol 4 is the canonical control protocol. It is a clean break:
    /// DENB input is mandatory, session subscriptions have one lifecycle, and
    /// older clients cannot safely downgrade to the removed contract.
    public static let current = ProtocolVersion(major: 4, minor: 0)

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// Whether this local version can decode an incoming version. Protocol 4
    /// is a clean-break contract: even a minor-version drift is rejected
    /// until both sides are upgraded together.
    public func canDecode(_ incoming: ProtocolVersion) -> Bool {
        self == incoming
    }

}
