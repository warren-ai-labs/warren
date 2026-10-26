import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Bridges the Desktop's domain status onto the shared activity mark.
///
/// The Design System is a leaf package, so it cannot see `AgentStatus`; iOS
/// reaches the same table through its own wire model. Keeping the mapping here
/// leaves one ladder for all three clients while each keeps its own model.
extension WarrenActivityMark {
    static func resolve(
        _ status: AgentStatus?,
        acknowledged: AgentActivityState? = nil
    ) -> WarrenActivityMark? {
        guard let status else { return nil }
        return resolve(
            lifecycle: WarrenAgentLifecycle(status.activity),
            attention: status.attention.map { WarrenAgentAttentionKind($0.kind) },
            acknowledged: acknowledged.map(WarrenAgentLifecycle.init)
        )
    }

    /// The domain lifecycle this mark reduces to, for a caller that has to name
    /// a Session's state in the Host's own vocabulary. See `lifecycle` for why
    /// the reduction is lossy.
    var activityState: AgentActivityState {
        switch lifecycle {
        case .failed: .failed
        case .blocked: .blocked
        case .working: .working
        case .ready: .ready
        case .exited: .exited
        }
    }

    /// The palette entry for this mark.
    ///
    /// Delegates to `WarrenDesktopStatusDot.color(for:tokens:)`, the one
    /// Desktop dot palette, so the tray, the command palette, the peek, the
    /// Host header and the tree's own dots cannot drift onto different hues
    /// for the same state.
    func color(_ tokens: WarrenColorTokens) -> Color {
        WarrenDesktopStatusDot.color(for: self, tokens: tokens)
    }
}

extension WarrenAgentLifecycle {
    init(_ state: AgentActivityState) {
        switch state {
        case .working: self = .working
        case .blocked: self = .blocked
        case .failed: self = .failed
        case .ready: self = .ready
        case .exited: self = .exited
        }
    }
}

extension WarrenAgentAttentionKind {
    init(_ kind: AgentAttentionKind) {
        switch kind {
        case .input: self = .input
        case .approval: self = .approval
        }
    }
}

extension WarrenDesktopSession {
    /// What this Session's row should draw.
    ///
    /// `nil` for a plain shell — the Host observes no Agent state for it, so the
    /// trailing slot stays empty — and `nil` for a completion this person has
    /// already seen here.
    var activityMark: WarrenActivityMark? {
        WarrenActivityMark.resolve(
            agentStatus,
            acknowledged: acknowledgedActivity
        )
    }

    /// The mark before acknowledgment, for a caller deciding whether there is
    /// anything to acknowledge. Reading `activityMark` cannot answer that: it is
    /// already `nil` once the notice has been retired.
    var unacknowledgedActivityMark: WarrenActivityMark? {
        WarrenActivityMark.resolve(agentStatus)
    }

    /// The mark the row's icon dot draws. An Agent Session keeps its own mark;
    /// a plain shell reports its OSC 133 state instead: green while a command is
    /// running, red after a command failed. A shell that never emitted a marker
    /// reports nothing, so no state is invented for it.
    public var rowStatusMark: WarrenActivityMark? {
        if isAgentSession { return activityMark }
        guard let shell = shellState else { return activityMark }
        if shell.isRunningCommand { return .working }
        if shell.didFail { return .failed }
        return nil
    }
}
