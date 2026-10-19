import Foundation
import WarrenDesignSystem
import WarrenDomain

/// One request an Agent is stopped on, as a system notification carries it.
public struct WarrenDesktopAttentionAlert: Equatable, Sendable {
    public let sessionID: TerminalSessionID
    /// Which request this is. A new request on the same Session gets a new
    /// key, so it alerts again; the same request seen twice does not.
    public let key: String
    public let title: String
    /// "project · branch".
    public let location: String
    /// What the Agent is asking, then the command or file it is about.
    public let body: String
    /// The decision to answer from the notification, when this client holds
    /// one with both a way to allow and a way to reject.
    public let quickAnswer: QuickAnswer?

    public struct QuickAnswer: Equatable, Sendable {
        public let decisionID: String
        public let allowOptionID: String
        public let allowLabel: String
        public let rejectOptionID: String
        public let rejectLabel: String
    }
}

/// The Sessions on this Host an Agent has stopped for, for the Dock badge and
/// for system notifications.
///
/// It reads the same population and rows as the approval tray, with one
/// difference: the current Tab counts too. The tray leaves it out because the
/// person is looking at it; an alert exists for when they are not.
public enum WarrenDesktopAttentionAlerts {
    public static func alerts(
        projection: WarrenDesktopProjection,
        decisions: [TerminalSessionID: WarrenDesktopPendingDecision]
    ) -> [WarrenDesktopAttentionAlert] {
        let waiting = projection.sessions.filter { $0.activityMark?.isWaitingOnPerson == true }
        let sessionsByID = Dictionary(waiting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = WarrenDesktopApprovalTray.entries(
            waiting: waiting,
            decisions: decisions,
            title: { session in
                let workspace = session.workspaceID.flatMap { projection.workspace(id: $0) }
                return WarrenDesktopTabTitle
                    .sessionTitle(for: session, worktreeRoot: workspace?.path ?? "")
                    .title
            },
            location: { session in
                guard let workspace = session.workspaceID.flatMap({ projection.workspace(id: $0) }) else {
                    return ""
                }
                let project = projection.projectGroup(id: workspace.projectID)?.project.name
                let branch = workspace.branch?.isEmpty == false ? workspace.branch : workspace.name
                return [project, branch].compactMap { $0 }.joined(separator: " \u{00B7} ")
            }
        )
        return rows.map { row in
            let requestID = row.decision?.id
                ?? sessionsByID[row.id]?.agentStatus?.attention?.requestID
                ?? ""
            return WarrenDesktopAttentionAlert(
                sessionID: row.id,
                key: "\(row.id.description)|\(requestID)|\(row.mark.rawValue)",
                title: row.title,
                location: row.location,
                body: [row.ask, row.detail].compactMap { $0 }.joined(separator: "\n"),
                quickAnswer: row.decision.flatMap(quickAnswer)
            )
        }
    }

    /// Allow is the first option that is not a rejection, which is the one the
    /// Conversation's dock lists first; reject is the first rejection. A
    /// decision without both is answered in the window.
    static func quickAnswer(_ decision: WarrenDesktopPendingDecision) -> WarrenDesktopAttentionAlert.QuickAnswer? {
        guard let allow = decision.options.first(where: { !$0.isReject }),
              let reject = decision.options.first(where: \.isReject) else { return nil }
        return .init(
            decisionID: decision.id,
            allowOptionID: allow.id,
            allowLabel: allow.label,
            rejectOptionID: reject.id,
            rejectLabel: reject.label
        )
    }
}

/// Which alerts are new since the last update, and which are gone.
///
/// A request alerts once, when it first appears. When it is answered here, on
/// another client, or the Agent moves on, its notification is withdrawn so
/// Notification Center never holds a question nobody is asking.
public struct WarrenDesktopAttentionAlertTracker: Sendable {
    private var delivered: [TerminalSessionID: String] = [:]

    public init() {}

    public mutating func update(
        _ alerts: [WarrenDesktopAttentionAlert]
    ) -> (post: [WarrenDesktopAttentionAlert], withdraw: [TerminalSessionID]) {
        let current = Dictionary(alerts.map { ($0.sessionID, $0.key) }, uniquingKeysWith: { first, _ in first })
        let post = alerts.filter { delivered[$0.sessionID] != $0.key }
        // A replaced request reuses its Session's notification, so only a
        // Session with nothing left to ask is withdrawn.
        let withdraw = delivered.keys.filter { current[$0] == nil }
        delivered = current
        return (post, withdraw.sorted { $0.description < $1.description })
    }
}
