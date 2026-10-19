import SwiftUI

public extension View {
    /// Uses the shared semantic background and foreground values.
    func warrenSurface() -> some View {
        modifier(WarrenSurfaceModifier())
    }
}

private struct WarrenSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content
            .background(tokens.background)
            .foregroundStyle(tokens.foreground)
    }
}
