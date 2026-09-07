import Foundation
import WarrenProtocol

/// A PTY output frame. The header is kept separate from its bytes so a client
/// can validate the recovery position before handing bytes to a renderer.
public struct BinaryOutputFrame: Hashable, Sendable {
    public let header: BinaryOutputFrameHeader
    public let payload: Data

    public init(header: BinaryOutputFrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public var hasValidPayloadLength: Bool {
        payload.count == header.payloadLength
    }
}
