import Foundation
import WarrenDesignSystem
import WarrenDomain

/// What this person has already seen, per Session, on this device.
///
/// `ready` is a completion notice rather than a property of a Session: a turn
/// finishing is news exactly once. The Host reports it as a steady lifecycle
/// value, so it stayed on screen forever — and because every idle Agent reports
/// it, the loudest thing in the sidebar was the one state that needs nothing.
/// Remembering what was read turns it back into a notice.
///
/// Device-local by design, in the same tier as Tab order. Which completions
/// *this* person read at *this* screen is not something the Host can know, and
/// two clients legitimately disagree: reading it on the Mac does not read it on
/// the phone.
public struct WarrenDesktopActivityAcknowledgments: Equatable, Sendable {
    private var bySessionID: [TerminalSessionID: AgentActivityState]

    public init(_ bySessionID: [TerminalSessionID: AgentActivityState] = [:]) {
        self.bySessionID = bySessionID
    }

    public var isEmpty: Bool { bySessionID.isEmpty }

    public subscript(sessionID: TerminalSessionID) -> AgentActivityState? {
        bySessionID[sessionID]
    }

    /// Records that this person has seen the Session in its current state.
    ///
    /// Only an acknowledgeable mark is recorded. Selecting a row that is waiting
    /// on an approval must not retire the request — looking is not answering —
    /// and a failure does not un-fail because it was visited.
    public mutating func acknowledge(_ session: WarrenDesktopSession) -> Bool {
        guard let mark = session.unacknowledgedActivityMark, mark.isAcknowledgeable else {
            return false
        }
        let state = mark.activityState
        guard bySessionID[session.id] != state else { return false }
        bySessionID[session.id] = state
        return true
    }

    /// Drops an acknowledgment the Host has moved past.
    ///
    /// This is what keeps a second completion from being swallowed by the first
    /// one's acknowledgment: `ready → (seen) → working → ready` has to light up
    /// again, because the Agent did something new in between.
    public mutating func invalidate(
        sessionID: TerminalSessionID,
        currentActivity: AgentActivityState?
    ) -> Bool {
        guard let recorded = bySessionID[sessionID], recorded != currentActivity else {
            return false
        }
        bySessionID.removeValue(forKey: sessionID)
        return true
    }

    /// Forgets Sessions the Host no longer lists, so a long-lived install does
    /// not accumulate acknowledgments for Sessions that ended weeks ago.
    public mutating func retain(sessionIDs: Set<TerminalSessionID>) {
        bySessionID = bySessionID.filter { sessionIDs.contains($0.key) }
    }

    public var storageRecords: [String: String] {
        Dictionary(uniqueKeysWithValues: bySessionID.map {
            ($0.key.description, $0.value.rawValue)
        })
    }

    public init(storageRecords: [String: String]) {
        bySessionID = Dictionary(uniqueKeysWithValues: storageRecords.compactMap { key, value in
            guard let id = TerminalSessionID(uuidString: key),
                  let state = AgentActivityState(rawValue: value) else {
                return nil
            }
            return (id, state)
        })
    }
}

/// Device-local persistence for `WarrenDesktopActivityAcknowledgments`.
///
/// Scoped per endpoint, like Tab order, because Session IDs belong to one Host.
/// Persisting is what the "does not expire" rule actually requires: the roster
/// arriving after a relaunch carries no transition history, so without this a
/// weekend's worth of finished work would either all be new or all be silent
/// depending on which way the client guessed.
public enum WarrenDesktopActivityAcknowledgmentStore {
    private static let storageKey = "warren.desktop.activityAcknowledgments"

    private static func key(scope: String) -> String {
        "\(storageKey).\(scope)"
    }

    public static func restore(
        scope: String,
        defaults: UserDefaults = .standard
    ) -> WarrenDesktopActivityAcknowledgments {
        guard let data = defaults.data(forKey: key(scope: scope)),
              let records = try? JSONDecoder().decode([String: String].self, from: data) else {
            return WarrenDesktopActivityAcknowledgments()
        }
        return WarrenDesktopActivityAcknowledgments(storageRecords: records)
    }

    public static func save(
        _ acknowledgments: WarrenDesktopActivityAcknowledgments,
        scope: String,
        defaults: UserDefaults = .standard
    ) {
        let records = acknowledgments.storageRecords
        guard !records.isEmpty,
              let data = try? JSONEncoder().encode(records) else {
            defaults.removeObject(forKey: key(scope: scope))
            return
        }
        defaults.set(data, forKey: key(scope: scope))
    }
}
