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
            tint: isPresented ? tokens.foreground : nil,
            edgeSpaced: true
        )
    }
}

struct WarrenDesktopOverflowPopover: View {
    let controls: [WarrenDesktopWorkspaceTabTrailingControl]
    let detail: (WarrenDesktopWorkspaceTabTrailingControl) -> String?
    let supportsSecondary: (WarrenDesktopWorkspaceTabTrailingControl) -> Bool
    let secondaryContent: (WarrenDesktopWorkspaceTabTrailingControl, @escaping () -> Void) -> AnyView?
    let onSelect: (WarrenDesktopWorkspaceTabTrailingControl) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedControl: WarrenDesktopWorkspaceTabTrailingControl?

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenDesktopChromePopoverSurface(
            title: selectedControl?.title ?? "More",
            width: surfaceWidth,
            onDismiss: onDismiss,
            titleFont: WarrenTypography.body,
            role: .menu
        ) {
            if let selectedControl,
               let content = secondaryContent(selectedControl, returnToMenu) {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: returnToMenu) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(tokens.mutedForeground)
                            .contentShape(.rect)
                    }
                    .buttonStyle(WarrenInteractiveRowStyle(cornerRadius: WarrenRadius.small))
                    .padding(.horizontal, WarrenSpacing.xs)
                    .padding(.top, WarrenSpacing.xs)
                    .accessibilityLabel("Back to More")

                    content
                }
            } else {
                listView(tokens: tokens)
            }
        }
        .onChange(of: controls) { _, current in
            if let selectedControl,
               !current.contains(selectedControl) {
                self.selectedControl = nil
            }
        }
    }

    private var surfaceWidth: CGFloat {
        guard let selectedControl else { return 248 }
        switch selectedControl {
        case .notifications:
            return 360
        case .web:
            return WarrenLayoutMetrics.webPopoverWidth
        default:
            return 260
        }
    }

    private func listView(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            ForEach(controls, id: \.self) { control in
                Button {
                    if supportsSecondary(control) {
                        selectedControl = control
                    } else {
                        onSelect(control)
                    }
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
                        if supportsSecondary(control) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tokens.mutedForeground)
                                .accessibilityHidden(true)
                        }
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

    private func returnToMenu() {
        selectedControl = nil
    }
}
