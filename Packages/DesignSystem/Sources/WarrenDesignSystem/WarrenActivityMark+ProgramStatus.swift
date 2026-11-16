import Foundation

/// The lifecycle half of an OSC 7501 program status, as a client-neutral value.
///
/// Mirrors the Host's `ProgramStatusState`. The Design System deliberately does
/// not depend on the wire models: it is a leaf package shared by the Desktop and
/// iOS clients, which carry two different models for the same Host fact.
public enum WarrenProgramLifecycle: String, CaseIterable, Hashable, Sendable {
    case idle
    case working
    case done
    case blocked
    case error
    /// A state a later protocol revision added. It draws nothing, because a
    /// state Warren cannot name must not be guessed into one it can.
    case unknown
}

/// What a blocked program waits for. `unnamed` covers `auth`, a kind a later
/// revision adds, and no kind at all: the request is real even when Warren
/// cannot say what it is.
public enum WarrenProgramBlockedKind: String, CaseIterable, Hashable, Sendable {
    case permission
    case question
    case unnamed

    public init(protocolKind: String?) {
        switch protocolKind?.lowercased() {
        case "permission": self = .permission
        case "question": self = .question
        default: self = .unnamed
        }
    }
}

extension WarrenActivityMark {
    /// Folds an OSC 7501 program status into the one activity encoding.
    ///
    /// A program's state is drawn with the same marks as an Agent's, so a row
    /// says what it asks of a person the same way whatever reported it.
    ///
    /// `idle` draws nothing: it is the resting state of every shell. `done`
    /// draws the finished mark and keeps it until a new report replaces it,
    /// which is what lets a finished build be found later. A program report
    /// carries no record of having been read, so unlike an Agent's completion
    /// it is not acknowledged away by looking at the Session.
    public static func resolve(
        program lifecycle: WarrenProgramLifecycle?,
        blockedKind: WarrenProgramBlockedKind? = nil
    ) -> WarrenActivityMark? {
        switch lifecycle {
        case .working:
            return .working
        case .blocked:
            switch blockedKind {
            case .permission: return .approvalNeeded
            case .question: return .inputNeeded
            case .unnamed, .none: return .attentionUnspecified
            }
        case .error:
            return .failed
        case .done:
            return .ready
        case .idle, .unknown, .none:
            return nil
        }
    }

    /// The label assistive technology receives for a mark a program reported.
    /// It names the program, because nothing bound it to an Agent.
    public var programAccessibilityLabel: String {
        switch self {
        case .approvalNeeded: "Program needs approval"
        case .inputNeeded: "Program needs input"
        case .attentionUnspecified: "Program needs attention"
        case .failed: "Program failed"
        case .working: "Program working"
        case .ready: "Program finished"
        case .exited: "Session exited"
        }
    }
}
