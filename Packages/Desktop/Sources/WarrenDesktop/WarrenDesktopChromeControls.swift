import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopChromeButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let action: () -> Void
    var tint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .focused($isFocused)
        .foregroundStyle(tint ?? tokens.mutedForeground)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}

struct WarrenDesktopOfflineBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Text("Offline")
            .font(WarrenTypography.navigationMeta)
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.vertical, WarrenSpacing.xs)
            .background(tokens.muted)
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .accessibilityLabel("Offline")
    }
}

struct WarrenDesktopChromeDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(WarrenColorTokens.resolved(for: colorScheme).chromeDivider)
            .frame(height: WarrenSpacing.hairline)
    }
}
