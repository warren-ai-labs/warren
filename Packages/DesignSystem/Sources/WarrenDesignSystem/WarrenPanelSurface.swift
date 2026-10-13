import SwiftUI

/// The two surfaces the workbench is built from.
///
/// `navigation` is the floating layer — the sidebar panel, the tab capsule,
/// the button capsule. On glass it is a lighter pane of the window's own coat
/// with a lit top edge; opaque it is the sidebar surface. `content` is a pane
/// card: nearly solid in both materials, because terminal text must never sit
/// on a moving wallpaper.
public enum WarrenPanelKind: Sendable {
    case navigation
    case content
}

public extension View {
    /// Paints a workbench panel behind the view and clips it to the panel's
    /// rounded shape.
    func warrenPanel(
        _ kind: WarrenPanelKind,
        cornerRadius: CGFloat = WarrenRadius.panel,
        isFocused: Bool = false
    ) -> some View {
        modifier(WarrenPanelModifier(kind: kind, cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

private struct WarrenPanelModifier: ViewModifier {
    let kind: WarrenPanelKind
    let cornerRadius: CGFloat
    let isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var material

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isLight = colorScheme == .light
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content
            .clipShape(shape)
            .background(fill(tokens: tokens, isLight: isLight), in: shape)
            .overlay(
                shape.strokeBorder(edge(isLight: isLight), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if material == .glass, kind == .navigation {
                    // The lit top edge is what reads as glass rather than as a
                    // tinted rectangle; it is drawn once, inside the stroke.
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(isLight ? 0.55 : 0.22), .clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity(isLight: isLight)),
                radius: kind == .content ? 14 : 10,
                y: kind == .content ? 6 : 4
            )
    }

    private func fill(tokens: WarrenColorTokens, isLight: Bool) -> Color {
        switch (kind, material) {
        case (.navigation, .glass):
            return Color.white.opacity(isLight ? 0.45 : 0.07)
        case (.navigation, .opaque):
            return tokens.sidebarSurface
        case (.content, .glass):
            return tokens.background.opacity(0.92)
        case (.content, .opaque):
            return tokens.background
        }
    }

    private func edge(isLight: Bool) -> Color {
        let base = isLight ? Color.black : Color.white
        if isFocused { return base.opacity(isLight ? 0.18 : 0.16) }
        return base.opacity(isLight ? 0.08 : 0.07)
    }

    private func shadowOpacity(isLight: Bool) -> Double {
        let base = isLight ? 0.06 : 0.22
        return isFocused ? base * 1.5 : base
    }
}
