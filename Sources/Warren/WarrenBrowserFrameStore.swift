import Foundation
import WarrenDomain
import Combine

/// One decoded screencast frame of a Warren Browser Session.
///
/// The Host sends an encoded still image (RFC 0022). Warren never re-encodes it:
/// the viewer draws the bytes exactly as received, so a frame that fails to
/// decode is dropped rather than substituted.
public struct WarrenBrowserFrame: Equatable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64
    public let format: String
    public let payload: Data

    public init(epoch: UInt64, sequence: UInt64, format: String, payload: Data) {
        self.epoch = epoch
        self.sequence = sequence
        self.format = format
        self.payload = payload
    }
}

/// Holds the newest screencast frame of every Warren Browser Session.
///
/// This is deliberately a separate store from the terminal surface manager: a
/// browser Session has no PTY, so no VT parser, snapshot, or recovery anchor may
/// ever see these bytes. Only the viewer reads them.
public final class WarrenBrowserFrameStore: ObservableObject {
    /// The newest frame per Session ID. Older frames are replaced, never queued:
    /// a viewer that is behind should show the latest page, not replay history.
    @Published public private(set) var frames: [TerminalSessionID: WarrenBrowserFrame] = [:]

    public init() {}

    public func frame(for sessionID: TerminalSessionID) -> WarrenBrowserFrame? {
        frames[sessionID]
    }

    public func install(sessionID: TerminalSessionID, frame: WarrenBrowserFrame) {
        guard let existing = frames[sessionID] else {
            frames[sessionID] = frame
            return
        }
        // A restarted Chromium restarts its frame counter, so a lower sequence
        // is only stale when the epoch is unchanged.
        guard frame.epoch >= existing.epoch, frame.sequence >= existing.sequence else { return }
        frames[sessionID] = frame
    }

    public func clear(sessionID: TerminalSessionID) {
        frames.removeValue(forKey: sessionID)
    }

    public func reset() {
        frames.removeAll()
    }
}
