import Foundation

/// What the user is told about the connection, as opposed to what the transport
/// is doing. `WarrenRemoteConnectionState` flaps on every sub-second network
/// hiccup; a banner that flaps with it trains the user to distrust it.
public enum WarrenConnectionPresentation: String, Equatable, Sendable {
    /// Usable. Say nothing.
    case live
    /// Retrying, but not yet worth mentioning. The status dot breathes; copy
    /// and content stay exactly as they were.
    case settling
    /// Confirmed loss. Show the reason and when the Host was last seen.
    case interrupted
}

/// How long a transport may be unusable before the user hears about it. It has
/// to outlast a *successful* reconnect, or the banner flashes for the last
/// moments of a recovery that was already working. Measured against a Relay
/// behind a 160ms RTT link with jitter, replacing the socket end to end
/// (backoff, TCP, WS upgrade, auth, welcome) took 0.85s–1.28s, so a 1.2s budget
/// flashed on half the attempts.
///
/// Mirrors `connectionSettleGraceMs` in `Web/src/connection.js`.
public let warrenConnectionSettleGrace: TimeInterval = 3.0

/// Maps transport events onto `WarrenConnectionPresentation`: degrade slowly,
/// recover instantly.
///
/// A value type with an explicit clock, so the rules can be tested without
/// waiting on timers. The owner calls `refresh(at:)` once the grace period is
/// up — nothing here schedules work.
public struct WarrenConnectionPresenter: Equatable, Sendable {
    public private(set) var presentation: WarrenConnectionPresentation
    /// Why the connection is interrupted, ready for display. Empty while live.
    public private(set) var detail: String
    /// When the current unsettled stretch began; nil once live again.
    public private(set) var unsettledSince: Date?

    private let grace: TimeInterval

    public init(grace: TimeInterval = warrenConnectionSettleGrace) {
        self.grace = grace
        // A cold start is settling, not interrupted: the first connect attempt
        // must not paint "Offline" before it has had a chance to succeed.
        self.presentation = .settling
        self.detail = ""
        self.unsettledSince = nil
    }

    /// The transport can carry traffic. Recovery is immediate and unconditional.
    @discardableResult
    public mutating func markLive() -> Bool {
        let changed = presentation != .live || !detail.isEmpty || unsettledSince != nil
        presentation = .live
        detail = ""
        unsettledSince = nil
        return changed
    }

    /// The transport is connecting, reconnecting or probing. Starts the grace
    /// period; a flap that resolves inside it is never shown.
    @discardableResult
    public mutating func markUnsettled(detail: String = "", at now: Date) -> Bool {
        let previous = self
        switch presentation {
        case .interrupted:
            // Already told the user, with a reason. Staying interrupted until the
            // transport is demonstrably live keeps the notice from blinking while
            // the backoff retries, and keeps a generic "Reconnecting…" from
            // overwriting a specific reason like "unauthorized".
            return false
        case .settling:
            // Keep the original deadline. Re-arming on every retry would let a
            // fast reconnect loop postpone the notice forever.
            if unsettledSince == nil { unsettledSince = now }
        case .live:
            presentation = .settling
            unsettledSince = now
        }
        if !detail.isEmpty { self.detail = detail }
        return self != previous
    }

    /// A known absence rather than a flap: skip the grace period. Relay only
    /// reports `host_offline` after waiting ~15s for the Host to come back, so
    /// waiting another 1.2s tells the user nothing.
    @discardableResult
    public mutating func markLost(detail: String, at now: Date) -> Bool {
        let previous = self
        presentation = .interrupted
        if !detail.isEmpty { self.detail = detail }
        if unsettledSince == nil { unsettledSince = now }
        return self != previous
    }

    /// Promotes a settling connection to `interrupted` once the grace period
    /// has elapsed. Call from a timer; safe to call at any time.
    @discardableResult
    public mutating func refresh(at now: Date) -> Bool {
        guard presentation == .settling, let since = unsettledSince else { return false }
        guard now.timeIntervalSince(since) >= grace else { return false }
        presentation = .interrupted
        return true
    }

    /// Seconds until `refresh(at:)` would change anything, or nil when there is
    /// nothing pending.
    public func timeUntilInterrupted(from now: Date) -> TimeInterval? {
        guard presentation == .settling, let since = unsettledSince else { return nil }
        return max(0, grace - now.timeIntervalSince(since))
    }
}

/// Which transport states are worth a grace period rather than a notice.
public extension WarrenRemoteConnectionState {
    var isUsableForPresentation: Bool { self == .connected }
}

/// "3 minutes ago". Deliberately coarse: the point is whether the Host went
/// away moments ago or this morning.
public func warrenRelativeTimeLabel(_ interval: TimeInterval) -> String {
    let seconds = Int((max(0, interval)).rounded())
    if seconds < 45 { return "just now" }
    let units: [(limit: Int, size: Int, name: String)] = [
        (60, 1, "second"),
        (3_600, 60, "minute"),
        (86_400, 3_600, "hour"),
        (.max, 86_400, "day"),
    ]
    let unit = units.first { seconds < $0.limit } ?? units[units.count - 1]
    let value = max(1, Int((Double(seconds) / Double(unit.size)).rounded()))
    return "\(value) \(unit.name)\(value == 1 ? "" : "s") ago"
}

/// Go stamps RFC 3339 with fractional seconds only when the value has them, and
/// `ISO8601DateFormatter` accepts exactly one of the two shapes per instance.
public func warrenParseRelayTimestamp(_ value: String) -> Date? {
    // Built per call rather than cached: this runs on a disconnect path, and a
    // shared formatter is not Sendable.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

/// How long a connection attempt may present as authenticating before the copy
/// admits what it is actually doing. Relay holds a client socket while it waits
/// for an absent Host, so past this point the delay is the Host being away
/// rather than authentication being slow.
///
/// It has to land *inside* `warrenConnectionSettleGrace`, and earlier than the
/// attempt that preceded it: the grace is already counting down from the socket
/// that died, so a copy arriving after the promotion would only ever be read as
/// "interrupted · <whatever the transport last said>".
///
/// Mirrors `hostWaitCopyDelayMs` in `Web/src/connection.js`.
public let warrenHostWaitCopyDelay: TimeInterval = 1.0

/// Copy for a connection that authenticated but has not been handed a Host yet.
/// Naming the machine is the point: "Waiting for Mac…" tells the user which
/// device to go wake, and it is the one thing a cold first load can say.
///
/// Mirrors `waitingForHostMessage` in `Web/src/connection.js`; the two clients
/// must say the same thing about the same Relay wait.
public func warrenWaitingForHostMessage(hostName: String?) -> String {
    let trimmed = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Waiting for the Host…" : "Waiting for \(trimmed)…"
}

/// Relay reports an absent Host only after waiting for it to come back, and
/// says when it was last seen. "Mac is offline · last seen 3 minutes ago" tells
/// the user whether to go wake their machine; "host offline" does not.
///
/// Mirrors `hostOfflineDetail` in `Web/src/connection.js`; the two clients must
/// say the same thing about the same Relay frame.
public func warrenHostOfflineDetail(
    hostName: String?,
    lastSeenAt: Date?,
    now: Date = Date()
) -> String {
    let trimmed = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmed.isEmpty ? "Host" : trimmed
    guard let lastSeenAt else { return "\(name) is offline" }
    return "\(name) is offline · last seen \(warrenRelativeTimeLabel(now.timeIntervalSince(lastSeenAt)))"
}
