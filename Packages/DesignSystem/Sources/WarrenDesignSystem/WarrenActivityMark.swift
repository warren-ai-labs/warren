import SwiftUI

/// The Host's lifecycle half of an Agent status, as a client-neutral value.
///
/// Mirrors `AgentActivityState` in the domain and `WarrenRemoteAgentActivity` on
/// the wire. The Design System deliberately does not depend on either: it is a
/// leaf package shared by the Desktop and iOS clients, which carry two different
/// models for the same Host fact.
public enum WarrenAgentLifecycle: String, CaseIterable, Hashable, Sendable {
    case working
    case blocked
    case failed
    case ready
    case exited
}

/// What an Agent is waiting for a person to supply.
///
/// `unnamed` is a real state rather than a decoding failure: a client can
/// receive an attention payload whose `kind` it does not recognize, and the
/// request is still real even when Warren cannot say what it is. The Desktop's
/// domain model has no such case and never produces it; the wire models both
/// clients share do.
public enum WarrenAgentAttentionKind: String, CaseIterable, Hashable, Sendable {
    case input
    case approval
    case unnamed
}

/// How loudly a mark should read, and therefore which channel carries it.
///
/// The encoding rule this type exists to enforce: **motion says whether work is
/// progressing and color says what a state asks of a person.** A mark that only
/// reports progress takes the working hue and pulses; a mark that wants someone
/// takes the attention hue and holds still; the rest stay quiet.
///
/// The rule is a response to a measured collision. Both halves of an Agent
/// status used to be folded into one hue ramp, but their orderings are nearly
/// opposite: the lifecycle's most common value is `ready` — an idle Agent, which
/// needs nothing — while the rarest attention payload is the one that needs an
/// answer this second. Keeping motion and color as separate channels is what
/// stops "running, leave it alone" from reading as "halted, waiting on you".
public enum WarrenActivityMarkTier: Int, Comparable, CaseIterable, Sendable {
    /// Nothing is being asked and nothing is moving.
    case idle
    /// Progressing on its own. Motion carries this tier; a person is not needed.
    case live
    /// A person has to answer before the work continues. Every mark in this tier
    /// is drawn in the attention hue, so a row that wants something is visible
    /// without reading a single word.
    case actionable

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One Agent status as the thing a client actually draws.
///
/// The case order is the priority order, so a rollup over a Workspace's Sessions
/// is `max()`. It matches the ladder in `DESIGN.md` §8.2 —
/// `failed > attention/blocked > working > ready > exited` — with the attention
/// tier split by what is being asked, which the Host has always reported and no
/// client used to distinguish.
public enum WarrenActivityMark: Int, Comparable, CaseIterable, Sendable {
    case exited
    case ready
    case working
    /// A `blocked` lifecycle with no attention payload to explain it.
    ///
    /// The live Host always sends the two together, because `blocked` is only
    /// ever set by marking attention. This case exists for the snapshot that
    /// arrives without one — an older Host, or a partial update — and it is
    /// deliberately not folded into `inputNeeded`: naming a request Warren
    /// cannot see would put a wrong word on the row.
    case attentionUnspecified
    case inputNeeded
    case approvalNeeded
    case failed

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Folds a Host status into the mark to draw.
    ///
    /// Returns `nil` for a Session with no Agent bound: a plain shell reports no
    /// activity Warren can observe, and inventing a mark for it would claim
    /// knowledge of a process the Host does not track.
    ///
    /// An attention payload outranks the lifecycle value it arrives with, so a
    /// stale `ready` or `working` snapshot still reads as actionable until the
    /// Host clears the request. A `failed` lifecycle outranks attention, because
    /// a turn that already ended badly is the more specific fact.
    /// `acknowledged` is the lifecycle this person has already seen for this
    /// Session on this device. It suppresses only an acknowledgeable mark, and
    /// self-invalidates: the moment the Host reports a different lifecycle, the
    /// acknowledgment no longer matches and the mark returns.
    public static func resolve(
        lifecycle: WarrenAgentLifecycle?,
        attention: WarrenAgentAttentionKind?,
        acknowledged: WarrenAgentLifecycle? = nil
    ) -> WarrenActivityMark? {
        guard let mark = resolveIgnoringAcknowledgment(
            lifecycle: lifecycle,
            attention: attention
        ) else { return nil }
        if mark.isAcknowledgeable, acknowledged == mark.lifecycle { return nil }
        return mark
    }

    private static func resolveIgnoringAcknowledgment(
        lifecycle: WarrenAgentLifecycle?,
        attention: WarrenAgentAttentionKind?
    ) -> WarrenActivityMark? {
        if lifecycle == .failed { return .failed }
        switch attention {
        case .approval: return .approvalNeeded
        case .input: return .inputNeeded
        case .unnamed: return .attentionUnspecified
        case .none: break
        }
        switch lifecycle {
        case .blocked: return .attentionUnspecified
        case .working: return .working
        case .ready: return .ready
        case .exited: return .exited
        // Handled above; repeated so a new lifecycle case fails the build here.
        case .failed: return .failed
        case .none: return nil
        }
    }

    /// Whether looking at the Session is enough to retire this mark.
    ///
    /// `ready` is news exactly once — a turn just finished — and stops being news
    /// once the person has seen it, so it is acknowledgeable.
    ///
    /// `exited` is the opposite kind of fact: a Session that ended stays ended,
    /// so it is never news and never draws. An unanswered request is not
    /// acknowledgeable either, because glancing at a row does not answer it, and
    /// a failure does not un-fail because it was visited.
    public var isAcknowledgeable: Bool { self == .ready }

    /// The lifecycle value this mark reduces to.
    ///
    /// Lossy on purpose: all three attention marks reduce to `blocked`, which is
    /// the lifecycle the Host reports alongside every attention payload. This is
    /// what a client speaks when it has to name a Session's state in the Host's
    /// own vocabulary — a dismiss intent, or the `is:` search filter people
    /// already type. A client that needs to know *what* is being asked keeps the
    /// mark.
    public var lifecycle: WarrenAgentLifecycle {
        switch self {
        case .failed: .failed
        case .approvalNeeded, .inputNeeded, .attentionUnspecified: .blocked
        case .working: .working
        case .ready: .ready
        case .exited: .exited
        }
    }

    public var tier: WarrenActivityMarkTier {
        switch self {
        case .exited, .ready: .idle
        case .working: .live
        case .attentionUnspecified, .inputNeeded, .approvalNeeded, .failed: .actionable
        }
    }

    /// Whether the mark animates.
    ///
    /// Motion means one thing: work is progressing. `blocked` used to pulse as
    /// well, which left the pulse carrying no information — it marked "not
    /// ready, failed, or exited" rather than any single fact — and left a
    /// halted Session animating indefinitely while it waited for a person.
    public var isAnimated: Bool {
        tier == .live
    }

    /// Whether the mark is worth a dot at all.
    ///
    /// An ended Session is a permanent state rather than an event, so it draws
    /// nothing. Every Session that ever ended would otherwise carry a grey dot
    /// forever, which is exactly the background noise this encoding removes.
    public var isDrawn: Bool { self != .exited }

    /// The short state word a row shows beside the mark.
    public var statusWord: String {
        switch self {
        case .approvalNeeded: "Approval needed"
        case .inputNeeded: "Input needed"
        case .attentionUnspecified: "Needs attention"
        case .failed: "Failed"
        case .working: "Working"
        // "Done", not "Idle": this mark is drawn only while it is news, and the
        // news is that a turn finished. Calling it Idle described a state rather
        // than the event that put it on screen.
        case .ready: "Done"
        case .exited: "Exited"
        }
    }

    /// The label assistive technology and the hover tooltip receive. Unlike
    /// `statusWord` it names its subject, because it is read without the row's
    /// surrounding context.
    public var accessibilityLabel: String {
        switch self {
        case .approvalNeeded: "Agent needs approval"
        case .inputNeeded: "Agent needs input"
        case .attentionUnspecified: "Session needs attention"
        case .failed: "Session failed"
        case .working: "Agent working"
        case .ready: "Agent finished"
        case .exited: "Session exited"
        }
    }
}

/// Geometry for an activity mark, derived from the dot a surface already uses so
/// the two never drift apart.
public struct WarrenActivityMarkMetrics: Sendable {
    public let dotSize: CGFloat

    public init(dotSize: CGFloat) {
        self.dotSize = dotSize
    }

    /// The slot the dot sits in. It is wider than the dot so a row's trailing
    /// edge does not shift when a Session enters or leaves a state.
    public var slotSize: CGFloat { dotSize * 1.6 }
}

/// Draws one `WarrenActivityMark`.
///
/// Color stays with the caller: the Desktop and iOS clients own separate
/// palettes, and unifying them is a larger decision than this encoding. What is
/// shared is the part that carries meaning — the hue, and whether the mark moves.
///
/// Every mark is a plain dot. Shape was tried as the channel for the states that
/// want a person and it read worse at the size a row actually uses, so the tier
/// is carried by color and motion alone, and the kind of a request lives in the
/// `statusWord` a row shows and in the `accessibilityLabel` assistive technology
/// receives. `tier` still orders the marks even though nothing draws it.
public struct WarrenActivityMarkView: View {
    private let mark: WarrenActivityMark
    private let color: Color
    private let metrics: WarrenActivityMarkMetrics

    public init(
        mark: WarrenActivityMark,
        color: Color,
        dotSize: CGFloat = 7
    ) {
        self.mark = mark
        self.color = color
        self.metrics = WarrenActivityMarkMetrics(dotSize: dotSize)
    }

    public var body: some View {
        Group {
            if mark.isDrawn {
                WarrenStatusIndicator(
                    color: color,
                    isActive: mark.isAnimated,
                    size: metrics.dotSize,
                    intensity: .quiet,
                    accessibilityLabel: mark.accessibilityLabel
                )
            }
        }
        .frame(width: metrics.slotSize, height: metrics.slotSize)
    }
}
