import SwiftUI
import WarrenDesignSystem

/// Top-right workspace controls share one app-owned popover contract. A
/// control only reports which popover it wants; the window root owns
/// presentation, dismissal and outside clicks.
enum WarrenDesktopChromePopover: Equatable {
    case web
    case endpoint
    case externalIDE
    case notices
    case overflow
}

/// Shared surface for every top-right chrome popover: same radius, border,
/// elevation, header typography and close affordance.
struct WarrenDesktopChromePopoverSurface<Content: View>: View {
    let title: String
    let width: CGFloat
    let onDismiss: () -> Void
    let titleFont: Font
    let role: WarrenPresentationRole
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        width: CGFloat,
        onDismiss: @escaping () -> Void,
        titleFont: Font = WarrenTypography.popoverTitle,
        role: WarrenPresentationRole = .popover,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.width = width
        self.onDismiss = onDismiss
        self.titleFont = titleFont
        self.role = role
        self.content = content()
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(WarrenTypography.popoverMeta)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.vertical, WarrenSpacing.compact)

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            content
        }
        .frame(width: width, alignment: .leading)
        .warrenPresentationSurface(role: role, cornerRadius: WarrenRadius.base)
        .onExitCommand(perform: onDismiss)
    }
}

struct WarrenDesktopEndpointPopover: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: "Execution Server",
            width: 260,
            onDismiss: onDismiss
        ) {
            WarrenDesktopEndpointPopoverContent(
                connectionState: connectionState,
                endpoints: endpoints,
                selectedID: selectedID,
                onSelect: onSelect,
                onDismiss: onDismiss
            )
        }
    }
}

/// The list portion is shared by the direct endpoint popover and the inline
/// More detail view. Keeping the list separate avoids stacking a full panel
/// inside another panel when a hidden action is opened from More.
struct WarrenDesktopEndpointPopoverContent: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                WarrenStatusIndicator(
                    color: statusColor(presentation.tone, tokens: tokens),
                    isActive: presentation.isActive,
                    size: 8,
                    accessibilityLabel: presentation.label
                )
                Text(presentation.label)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.vertical, WarrenSpacing.compact)

            ForEach(endpoints) { endpoint in
                Button {
                    onSelect(endpoint.id)
                    onDismiss()
                } label: {
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(systemName: endpoint.id == selectedID ? "checkmark.circle.fill" : "circle")
                            .font(WarrenTypography.popoverMeta)
                            .foregroundStyle(
                                endpoint.id == selectedID
                                    ? tokens.highlight
                                    : tokens.mutedForeground
                            )
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.label)
                                .font(WarrenTypography.popoverItem)
                                .foregroundStyle(tokens.foreground)
                            if let detail = endpoint.detail {
                                Text(detail)
                                    .font(WarrenTypography.popoverMeta)
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(endpoint.label)
                .accessibilityValue(endpoint.id == selectedID ? "Selected" : "")
            }
        }
    }

    private func statusColor(
        _ tone: WarrenDesktopConnectionTone,
        tokens: WarrenColorTokens
    ) -> Color {
        switch tone {
        case .success: tokens.success
        case .info: tokens.info
        case .warning: tokens.warning
        case .destructive: tokens.destructive
        }
    }
}

struct WarrenDesktopExternalIDEPopover: View {
    let options: [WarrenDesktopExternalIDEOption]
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onDismiss: () -> Void

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: "Open in IDE",
            width: 260,
            onDismiss: onDismiss
        ) {
            WarrenDesktopExternalIDEPopoverContent(
                options: options,
                onOpen: onOpen,
                onDismiss: onDismiss
            )
        }
    }
}

struct WarrenDesktopExternalIDEPopoverContent: View {
    let options: [WarrenDesktopExternalIDEOption]
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WarrenDesktopExternalIDEMenuPresentation.items(from: options)) { item in
                Button {
                    onOpen(item.option)
                    onDismiss()
                } label: {
                    HStack(spacing: WarrenSpacing.compact) {
                        iconView(item.icon, tokens: tokens)
                        Text(item.title)
                            .font(WarrenTypography.popoverItem)
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(.rect)
                    .opacity(item.isEnabled ? 1 : 0.42)
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityHint(item.isEnabled ? "" : "Unavailable")
            }
        }
    }

    @ViewBuilder
    private func iconView(_ icon: NSImage?, tokens: WarrenColorTokens) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
        } else {
            Image(systemName: "app")
                .font(.system(size: WarrenLayoutMetrics.externalIDEIconSize, weight: .light))
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
                .foregroundStyle(tokens.mutedForeground)
        }
    }
}
