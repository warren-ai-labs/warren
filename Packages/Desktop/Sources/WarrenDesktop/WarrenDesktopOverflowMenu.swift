import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopOverflowButton: View {
    let isPresented: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromeButton(
            systemImage: "ellipsis",
            label: "More workspace actions",
            hint: "Show additional workspace actions",
            action: action,
            tint: isPresented ? tokens.foreground : nil
        )
    }
}

struct WarrenDesktopOverflowPopover: View {
    let controls: [WarrenDesktopWorkspaceTabTrailingControl]
    let detail: (WarrenDesktopWorkspaceTabTrailingControl) -> String?
    let onSelect: (WarrenDesktopWorkspaceTabTrailingControl) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromePopoverSurface(
            title: "More",
            width: 300,
            onDismiss: onDismiss,
            titleFont: WarrenTypography.body,
            role: .menu
        ) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                ForEach(controls, id: \.self) { control in
                    Button {
                        onSelect(control)
                    } label: {
                        HStack(spacing: WarrenSpacing.compact) {
                            Image(systemName: control.systemImage)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(tokens.mutedForeground)
                                .frame(width: 22, height: 22)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(control.title)
                                    .font(WarrenTypography.body)
                                    .foregroundStyle(tokens.foreground)
                                    .lineLimit(1)
                                if let detail = detail(control) {
                                    Text(detail)
                                        .font(WarrenTypography.popoverMeta)
                                        .foregroundStyle(tokens.mutedForeground)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.xs)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WarrenInteractiveRowStyle(cornerRadius: WarrenRadius.small))
                    .accessibilityLabel(control.title)
                    .accessibilityHint(control.accessibilityHint)
                }
            }
            .padding(.vertical, WarrenSpacing.xs)
        }
    }
}
