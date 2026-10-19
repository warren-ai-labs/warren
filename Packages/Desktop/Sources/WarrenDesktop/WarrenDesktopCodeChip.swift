import SwiftUI
import WarrenDesignSystem

/// A small monospaced chip for a literal from a script: `$1`, `WARREN_*`, or a
/// title-template placeholder. One component for both surfaces, so the two do
/// not drift into two greys. An interactive chip is a button and gains a hover
/// border; a caption sits beside it rather than inside it.
struct WarrenDesktopCodeChip: View {
    let text: String
    var isInteractive = false
    var action: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var hovering = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        if isInteractive, let action {
            Button(action: action) {
                chip(tokens: tokens)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        } else {
            chip(tokens: tokens)
        }
    }

    private func chip(tokens: WarrenColorTokens) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(tokens.foreground.opacity(0.83))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                tokens.foreground.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        hovering ? tokens.foreground.opacity(0.20) : tokens.cardBorder,
                        lineWidth: 1
                    )
            }
    }
}
