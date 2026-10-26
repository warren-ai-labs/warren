import Foundation

/// Why a Session's runtime ended, as the Host recorded it.
///
/// The reason is the Host's account of the end, not a statement about what a
/// client can still offer: a Session can be `processExited` with a transcript to
/// resume or with nothing left at all.
public enum WarrenDesktopEndReason: String, Hashable, Sendable, CaseIterable {
    /// The user closed or killed the Session.
    case userClosed
    /// The program the Session ran exited.
    case processExited
    /// The runtime could no longer find the Session, typically because the Host
    /// restarted onto a fresh runtime.
    case runtimeMissing
    /// An ended Session with no recorded reason, which is every record written
    /// before Hosts kept one.
    case unknown

    public init(wire value: String?) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self = WarrenDesktopEndReason(rawValue: trimmed) ?? .unknown
    }

    /// Whether an ended Session with this reason keeps its Tab.
    ///
    /// Only the ends the user did not ask for keep it: those leave a Session the
    /// person was still using, and the Host still has its record and its last
    /// output. A Session the user closed is gone on purpose, and a legacy record
    /// with no reason cannot claim to be worth reopening.
    public var keepsStoppedTab: Bool {
        switch self {
        case .processExited, .runtimeMissing: true
        case .userClosed, .unknown: false
        }
    }

    /// The one line a stopped Tab says about how its Session ended.
    public var detail: String {
        switch self {
        case .runtimeMissing: "The runtime is gone, so this Session stopped."
        case .processExited: "The program exited, so this Session stopped."
        case .userClosed: "You closed this Session."
        case .unknown: "This Session stopped."
        }
    }
}

/// The single action a stopped Tab offers, or none when there is nothing left to
/// continue.
public enum WarrenDesktopStoppedAction: Hashable, Sendable {
    /// Continue the Agent conversation this Session was bound to, in a new
    /// Session.
    case resume
    /// Start the same shell or custom command again in the same directory.
    case restart

    public var label: String {
        switch self {
        case .resume: "Resume"
        case .restart: "Restart"
        }
    }

    /// The one thing the action cannot do, said before it is tried.
    public var explanation: String {
        switch self {
        case .resume: "Continue this conversation in a new Tab"
        case .restart: "Start this command again in the same directory"
        }
    }
}

/// The wire fields the stopped-Tab rule reads. Both Desktop rosters (the active
/// endpoint's projection and the multi-host sidebar) build these, so they cannot
/// disagree about which stopped Sessions stay visible.
public struct WarrenDesktopStoppedSessionInput: Hashable, Sendable {
    public let sessionID: String
    public let lifecycle: String
    public let kind: String
    public let runtimeKind: String?
    public let endReason: String?
    /// The ended Session this Session continued, when it is a resume.
    public let resumedFrom: String?

    public init(
        sessionID: String,
        lifecycle: String,
        kind: String,
        runtimeKind: String? = nil,
        endReason: String? = nil,
        resumedFrom: String? = nil
    ) {
        self.sessionID = sessionID
        self.lifecycle = lifecycle
        self.kind = kind
        self.runtimeKind = runtimeKind
        self.endReason = endReason
        self.resumedFrom = resumedFrom
    }
}

/// One stopped Session whose Tab offers Resume, as Resume All sees it.
public struct WarrenDesktopResumeCandidate: Hashable, Sendable {
    public let sessionID: String
    /// The provider conversation the Session is bound to.
    public let conversationID: String
    public let createdAt: Date?

    public init(sessionID: String, conversationID: String, createdAt: Date? = nil) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.createdAt = createdAt
    }
}

/// Which ended Sessions the Tab list keeps. This is one rule with one test, not
/// a condition repeated wherever a Tab is built.
public enum WarrenDesktopStoppedSessionRoster {
    /// Providers whose conversation the Host can continue on the command line.
    /// Kept in step with the Host's own resume targets: offering Resume for a
    /// provider the Host refuses would only produce an error.
    public static let resumableProviders: Set<String> = ["claude", "codex", "opencode", "pi"]

    /// The Session IDs an ended roster keeps as stopped Tabs.
    ///
    /// A stopped Tab is dropped as soon as a running Session continues it: the
    /// conversation moved, and showing the old Tab beside its own continuation
    /// would offer Resume for a conversation already open.
    public static func stoppedSessionIDs(_ sessions: [WarrenDesktopStoppedSessionInput]) -> Set<String> {
        let resumedAway = Set(
            sessions
                .filter { $0.lifecycle == "running" }
                .compactMap { normalized($0.resumedFrom) }
        )
        var stopped: Set<String> = []
        for session in sessions where session.lifecycle == "ended" {
            guard WarrenDesktopEndReason(wire: session.endReason).keepsStoppedTab else { continue }
            // A browser renders a live page and an ACP Session renders a
            // conversation; neither has a terminal output to show after the
            // runtime is gone, so a stopped Tab would be an empty pane.
            let kind = normalized(session.kind) ?? ""
            let runtimeKind = normalized(session.runtimeKind) ?? ""
            guard kind != "browser", runtimeKind != "acp" else { continue }
            guard !resumedAway.contains(session.sessionID) else { continue }
            stopped.insert(session.sessionID)
        }
        return stopped
    }

    /// The action a stopped Session offers, given what it was and whether it has
    /// a provider conversation.
    public static func action(
        kind: String,
        agentProvider: String?,
        agentSessionID: String?
    ) -> WarrenDesktopStoppedAction? {
        let provider = normalized(agentProvider) ?? normalized(kind) ?? ""
        let conversation = normalized(agentSessionID)
        if conversation != nil, resumableProviders.contains(provider) {
            return .resume
        }
        // A dedicated Agent Session with no conversation recorded has nothing to
        // continue, and re-running the provider would silently start a new one.
        switch provider {
        case "shell", "custom":
            return .restart
        default:
            return nil
        }
    }

    /// The Sessions Resume All continues besides `current`.
    ///
    /// One per conversation, the newest stopped record of it: a conversation
    /// resumed before and stopped again leaves two stopped Tabs, and the Host
    /// lets only one running Session own a conversation, so resuming both would
    /// only fail. The current Session's own conversation is left out, because
    /// the banner's Resume already covers it. The order follows the input.
    public static func resumeAllTargets(
        _ candidates: [WarrenDesktopResumeCandidate],
        besides current: String
    ) -> [String] {
        let currentConversation = candidates
            .first { $0.sessionID == current }
            .flatMap { normalized($0.conversationID) }
        var newest: [String: WarrenDesktopResumeCandidate] = [:]
        for candidate in candidates where candidate.sessionID != current {
            guard let conversation = normalized(candidate.conversationID),
                  conversation != currentConversation else { continue }
            if let kept = newest[conversation],
               (kept.createdAt ?? .distantPast) >= (candidate.createdAt ?? .distantPast) {
                continue
            }
            newest[conversation] = candidate
        }
        let chosen = Set(newest.values.map(\.sessionID))
        return candidates.map(\.sessionID).filter(chosen.contains)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
