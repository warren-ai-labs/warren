import Combine
import Foundation

/// The single dismissal policy for app-owned presentation surfaces. A
/// coordinator owns one stack per window so Escape and outside clicks always
/// target the topmost surface instead of every mounted overlay guessing.
public struct WarrenPresentationStack: Equatable, Sendable {
    public private(set) var roles: [WarrenPresentationRole] = []

    public init() {}

    public var top: WarrenPresentationRole? {
        roles.last
    }

    public var isEmpty: Bool {
        roles.isEmpty
    }

    public mutating func push(_ role: WarrenPresentationRole) {
        roles.append(role)
    }

    @discardableResult
    public mutating func popTop() -> WarrenPresentationRole? {
        roles.popLast()
    }

    public func allowsBackdropDismiss(
        role: WarrenPresentationRole,
        hasEdits: Bool
    ) -> Bool {
        switch role {
        case .modal:
            false
        case .sheet:
            !hasEdits
        case .commandSurface, .popover, .menu, .status, .inline:
            true
        }
    }

    public func allowsEscapeDismiss(role: WarrenPresentationRole) -> Bool {
        switch role {
        case .modal, .sheet, .commandSurface, .popover, .menu:
            true
        case .status, .inline:
            false
        }
    }
}

/// Observable wrapper used by window roots to own one presentation stack.
/// Views present and dismiss roles through this object instead of mutating
/// raw state, which keeps the topmost-surface and dismissal policy in one
/// place per window.
@MainActor
public final class WarrenPresentationCoordinator: ObservableObject {
    @Published public private(set) var stack = WarrenPresentationStack()

    public init() {}

    public var top: WarrenPresentationRole? {
        stack.top
    }

    public func present(_ role: WarrenPresentationRole) {
        stack.push(role)
    }

    @discardableResult
    public func dismissTop() -> WarrenPresentationRole? {
        stack.popTop()
    }

    public func allowsBackdropDismiss(
        role: WarrenPresentationRole,
        hasEdits: Bool
    ) -> Bool {
        stack.allowsBackdropDismiss(role: role, hasEdits: hasEdits)
    }

    public func allowsEscapeDismiss(role: WarrenPresentationRole) -> Bool {
        stack.allowsEscapeDismiss(role: role)
    }
}
