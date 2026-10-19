import SwiftUI

public extension View {
    /// Rolls a changing figure digit by digit instead of swapping it, so a
    /// count, a percentage or a cost reads as moving rather than as replaced.
    /// Before macOS 14 the figure simply swaps; under Reduce Motion it
    /// crossfades.
    func warrenNumericTransition<Value: Equatable>(value: Value) -> some View {
        modifier(WarrenNumericTransitionModifier(value: value))
    }
}

private struct WarrenNumericTransitionModifier<Value: Equatable>: ViewModifier {
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(
                    reduceMotion
                        ? .easeOut(duration: WarrenMotion.stateChangeDuration)
                        : .spring(response: 0.32, dampingFraction: 0.9),
                    value: value
                )
        } else {
            content
        }
    }
}
