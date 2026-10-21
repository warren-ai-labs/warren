import Foundation
import WarrenDomain

/// Keeps the newest value while exposing at most one pending wake-up.
struct WarrenLatestValueSignal<Value: Sendable>: Sendable {
    private var latestValue: Value?
    private var signalPending = false

    mutating func offer(_ value: Value) -> Bool {
        latestValue = value
        guard !signalPending else { return false }
        signalPending = true
        return true
    }

    mutating func take() -> Value? {
        let value = latestValue
        latestValue = nil
        signalPending = false
        return value
    }

    mutating func reset() {
        latestValue = nil
        signalPending = false
    }
}

/// A completed Agent turn detected from the remote roster.
///
/// The remote model publishes this transport-neutral event. Platform clients
/// decide whether and how to present it (for example, with a sound).
struct WarrenAgentCompletionEvent: Equatable, Sendable {
    let sessionID: TerminalSessionID
    let turnID: UInt64
}

/// Converts the latest Agent turn from each roster snapshot into exactly one
/// notification per successful completion. A first snapshot and a transcript
/// reset are baselines, never historical notifications.
///
/// A Host that restarts reports its Sessions before it has replayed their
/// transcripts, so a Session can first appear without a turn and only gain a
/// terminal turn in a later snapshot. That first observation is restored
/// Host state, not a completion: it rings only when the Session was unknown
/// at the time of the snapshot, or when an already observed turn transitions
/// to a terminal status.
struct WarrenAgentCompletionTracker {
    private var initialized = false
    private var turns: [TerminalSessionID: RemoteRoster.AgentTurn] = [:]
    private var knownSessionIDs: Set<TerminalSessionID> = []

    mutating func observe(
        sessions: Set<TerminalSessionID>,
        turns nextTurns: [TerminalSessionID: RemoteRoster.AgentTurn]
    ) -> [TerminalSessionID] {
        let previouslyKnownSessionIDs = knownSessionIDs
        knownSessionIDs.formUnion(sessions)

        guard initialized else {
            initialized = true
            turns = nextTurns
            return []
        }

        var completed: [TerminalSessionID] = []
        for (sessionID, turn) in nextTurns {
            guard turn.status == "completed" else { continue }
            guard let previous = turns[sessionID] else {
                // A Session the client has never seen is a live completion
                // whose start the snapshot missed. A Session first observed
                // without a turn is still restoring Host Agent state.
                if !previouslyKnownSessionIDs.contains(sessionID) {
                    completed.append(sessionID)
                }
                continue
            }
            // Turn ids restart when a transcript projection is rebound. Do
            // not ring for the new snapshot's old terminal state.
            guard turn.id >= previous.id else { continue }
            if turn.id > previous.id || previous.status != "completed" {
                completed.append(sessionID)
            }
        }
        turns = nextTurns
        return completed
    }
}

/// Keeps at most one unsent terminal viewport. A window drag can produce more
/// resize callbacks than the daemon can process; intermediate dimensions have
/// no value once a newer one exists.
struct WarrenResizeRequestBuffer: Sendable {
    private(set) var pending: TerminalSize?
    private(set) var lastSent: TerminalSize?

    /// Returns true when the caller needs to start a drain task.
    mutating func offer(_ size: TerminalSize) -> Bool {
        guard size != lastSent || pending != nil else { return false }
        let shouldStart = pending == nil
        pending = size
        return shouldStart
    }

    mutating func take() -> TerminalSize? {
        guard let pending else { return nil }
        self.pending = nil
        guard pending != lastSent else { return nil }
        return pending
    }

    mutating func markSent(_ size: TerminalSize) {
        lastSent = size
    }

    mutating func reset() {
        pending = nil
        lastSent = nil
    }
}

struct TerminalOutputAnchor: Equatable, Sendable {
    let epoch: UInt64
    let sequence: UInt64
}
