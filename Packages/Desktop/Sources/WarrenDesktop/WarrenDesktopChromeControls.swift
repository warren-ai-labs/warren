import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopChromeButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let action: () -> Void
    var tint: Color? = nil
    // Kept source-compatible with older callers while every action now uses
    // the same fixed slot. Equal slots keep icon baselines and gaps stable
    // across SF Symbols with different intrinsic widths.
    var edgeSpaced: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
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
