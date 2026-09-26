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
    /// Color is the reinforcing channel, never the distinguishing one: on the
    /// light palette `warning` and `amber` are the same value, so `working` and a
    /// blocked Session were the same color until the actionable tier took on its
    /// own shape. The hues here only have to agree with the shape, not carry it.
    func color(_ tokens: WarrenColorTokens) -> Color {
        switch self {
        case .failed: tokens.destructive
        case .approvalNeeded, .inputNeeded, .attentionUnspecified: tokens.warning
        case .working: tokens.amber
        case .ready: tokens.success
        case .exited: tokens.mutedForeground
        }
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
}
