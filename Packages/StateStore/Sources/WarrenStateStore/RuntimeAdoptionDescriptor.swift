/// The information a Host can use to find an already-running runtime session.
///
/// This is intentionally an opaque adapter descriptor.  The state store does
/// not know which concrete runtime adapter owns the process.
public struct RuntimeAdoptionDescriptor: Codable, Hashable, Sendable {
    public let runtime: String
    public let identifier: String
    public let metadata: [String: String]

    public init(
        runtime: String,
        identifier: String,
        metadata: [String: String] = [:]
    ) {
        self.runtime = runtime
        self.identifier = identifier
        self.metadata = metadata
    }

}
