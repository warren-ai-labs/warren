import SwiftUI

public enum WarrenSemanticAction: String, Codable, Hashable, Sendable {
    case press
}

@MainActor
public final class WarrenSemanticRecorder {
    private var nodes: [WarrenSemanticNode] = []
    private var actions: [String: () -> Void] = [:]

    public init() {}

    public func snapshot() -> WarrenSemanticSnapshot {
        WarrenSemanticSnapshot(
            capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            nodes: nodes
        )
    }

    public func perform(_ action: WarrenSemanticAction, on id: String) throws {
        guard action == .press, let handler = actions[id] else {
            throw WarrenSemanticRecorderError.actionUnavailable(id: id, action: action)
        }
        handler()
    }

    func replace(_ values: [WarrenSemanticNode]) {
        nodes = values
    }

    func registerAction(id: String, action: @escaping () -> Void) {
        actions[id] = action
    }

    func removeAction(id: String) {
        actions[id] = nil
    }
}

public enum WarrenSemanticRecorderError: Error, Equatable {
    case actionUnavailable(id: String, action: WarrenSemanticAction)
}

private struct WarrenSemanticRecorderKey: EnvironmentKey {
    static let defaultValue: WarrenSemanticRecorder? = nil
}

public extension EnvironmentValues {
    var warrenSemanticRecorder: WarrenSemanticRecorder? {
        get { self[WarrenSemanticRecorderKey.self] }
        set { self[WarrenSemanticRecorderKey.self] = newValue }
    }
}

private struct WarrenSemanticPreferenceKey: PreferenceKey {
    static let defaultValue: [WarrenSemanticNode] = []

    static func reduce(
        value: inout [WarrenSemanticNode],
        nextValue: () -> [WarrenSemanticNode]
    ) {
        value.append(contentsOf: nextValue())
    }
}

/// Holds the action a node currently performs.
///
/// The recorder is handed a stable closure that reads through this box instead
/// of the node's own closure, because a closure captures the state it was
/// created with. A control whose behavior depends on state — a toggle, most
/// plainly — would otherwise keep performing the direction it was born with:
/// the node's recorded `value` would say the editor is open while pressing it
/// still tried to open it. `onChange` is not enough here; it delivers the
/// closure from the update that observed the change, which is the stale one.
@MainActor
private final class WarrenSemanticActionBox {
    var action: (() -> Void)?
}

private struct WarrenSemanticElementModifier: ViewModifier {
    @Environment(\.warrenSemanticRecorder) private var recorder
    @State private var actionBox = WarrenSemanticActionBox()

    let id: String
    let role: WarrenSemanticRole
    let label: String
    let value: String?
    let isEnabled: Bool
    let isSelected: Bool
    let isFocused: Bool
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        let currentAction = refreshedAction()
        let identifiedContent = content.accessibilityIdentifier(id)
        if let recorder {
            identifiedContent
                .overlay {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(WarrenSemanticCoordinateSpace.name))
                        Color.clear.preference(
                            key: WarrenSemanticPreferenceKey.self,
                            value: [
                                WarrenSemanticNode(
                                    id: id,
                                    role: role,
                                    label: label,
                                    value: value,
                                    isEnabled: isEnabled,
                                    isSelected: isSelected,
                                    isFocused: isFocused,
                                    frame: WarrenSemanticRect(
                                        x: frame.origin.x,
                                        y: frame.origin.y,
                                        width: frame.size.width,
                                        height: frame.size.height
                                    )
                                ),
                            ]
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onAppear {
                    if let currentAction {
                        recorder.registerAction(id: id, action: currentAction)
                    }
                }
                .onDisappear {
                    recorder.removeAction(id: id)
                }
        } else {
            identifiedContent
        }
    }

    /// Points the box at this update's closure and returns the stable trampoline
    /// to register, or `nil` for a node that performs nothing.
    ///
    /// Assigning here is a write during a view update, which is safe because the
    /// box publishes nothing and so invalidates nothing. It is the only place
    /// that sees the closure belonging to the state the node is reporting.
    private func refreshedAction() -> (() -> Void)? {
        actionBox.action = action
        guard action != nil else { return nil }
        let box = actionBox
        return { box.action?() }
    }
}

private enum WarrenSemanticCoordinateSpace {
    static let name = "WarrenSemanticRoot"
}

private struct WarrenSemanticObservationRootModifier: ViewModifier {
    let recorder: WarrenSemanticRecorder?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let recorder {
            content
                .coordinateSpace(name: WarrenSemanticCoordinateSpace.name)
                .onPreferenceChange(WarrenSemanticPreferenceKey.self) { values in
                    recorder.replace(values)
                }
        } else {
            content
        }
    }
}

public extension View {
    func warrenSemanticElement(
        id: String,
        role: WarrenSemanticRole,
        label: String,
        value: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        isFocused: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(
            WarrenSemanticElementModifier(
                id: id,
                role: role,
                label: label,
                value: value,
                isEnabled: isEnabled,
                isSelected: isSelected,
                isFocused: isFocused,
                action: action
            )
        )
    }

    func warrenSemanticObservationRoot(
        recorder: WarrenSemanticRecorder?
    ) -> some View {
        modifier(WarrenSemanticObservationRootModifier(recorder: recorder))
    }
}
