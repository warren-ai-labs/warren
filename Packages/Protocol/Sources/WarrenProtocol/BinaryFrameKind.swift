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
    /// One screencast frame for a Warren Browser Session (RFC 0022).
    ///
    /// Its own kind for the same reason `atomicState` is one: the payload is an
    /// encoded still image, and feeding it to a VT output parser would corrupt
    /// the terminal. A browser Session has no PTY, so there is no terminal
    /// stream for these bytes to be confused with — but a client that
    /// subscribes to a Session without checking its kind would otherwise try.
    case browserFrame = 4

    public var direction: BinaryFrameDirection {
        switch self {
        case .input: return .clientToHost
        case .output, .atomicState, .browserFrame: return .hostToClient
        }
    }
}
