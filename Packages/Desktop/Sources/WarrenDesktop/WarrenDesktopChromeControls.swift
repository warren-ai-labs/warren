import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopChromeButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let action: () -> Void
    var tint: Color? = nil
    /// Shown beside the label in the tooltip, e.g. `"⌥⌘B"`.
    var shortcut: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @FocusState private var isFocused: Bool
    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .fixedSize(horizontal: true, vertical: false)
        .focused($isFocused)
        .foregroundStyle(tint ?? tokens.mutedForeground)
        .warrenTooltip(label, shortcut: shortcut)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

struct WarrenDesktopChromeDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        Rectangle()
            .fill(WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial).chromeDivider)
            .frame(height: WarrenSpacing.hairline)
    }
}
