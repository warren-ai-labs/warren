/// The direction carried by a binary envelope.
///
/// A direction is part of the wire contract rather than an assumption made by
/// the transport. This lets a Host reject a client frame sent on the wrong
/// endpoint and lets a Client reject an input frame received from a Host.
public enum BinaryFrameDirection: UInt8, Codable, Hashable, Sendable {
    case clientToHost = 1
    case hostToClient = 2
}

/// The payload kind carried by a binary envelope.
///
/// Protocol version 1 has one kind in each direction. Keeping the kind
/// explicit makes adding another binary message later a versioned protocol
/// decision instead of silently reusing terminal bytes.
public enum BinaryFrameKind: UInt8, Codable, Hashable, Sendable {
    case input = 1
    case output = 2
    case atomicState = 3

    public var direction: BinaryFrameDirection {
        switch self {
        case .input: return .clientToHost
        case .output, .atomicState: return .hostToClient
        }
    }
}
