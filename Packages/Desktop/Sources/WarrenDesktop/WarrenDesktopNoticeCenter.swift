import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopNoticeButton: View {
    let unreadCount: Int
    let isPresented: Bool
    let isMuted: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let bellColor = isMuted
            ? tokens.mutedForeground
            : (isPresented
                ? tokens.foreground
                : (unreadCount > 0 ? tokens.highlight.opacity(0.78) : tokens.mutedForeground))
        Button(action: action) {
            Image(systemName: isMuted ? "bell.slash" : "bell")
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .regular))
                .foregroundStyle(bellColor)
                .accessibilityHidden(true)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(WarrenChromeButtonStyle(isFocused: isFocused))
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .fixedSize(horizontal: true, vertical: false)
        .focused($isFocused)
        .foregroundStyle(bellColor)
        .accessibilityLabel("Notifications")
        .accessibilityValue(
            isMuted
                ? "Muted"
                : (unreadCount > 0 ? "\(unreadCount) unread" : "No unread notifications")
        )
        .accessibilityHint("Show system messages and errors")
    }
}

struct WarrenDesktopNoticeTitleActions: View {
    let unreadCount: Int
    @Binding var isMuted: Bool
    let onMarkAllRead: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            Button("Mark all read", action: onMarkAllRead)
            .buttonStyle(.plain)
            .font(WarrenTypography.popoverMeta)
            .foregroundStyle(
                unreadCount > 0
                    ? tokens.mutedForeground
                    : tokens.mutedForeground.opacity(0.45)
            )
            .disabled(unreadCount == 0)
            .accessibilityLabel("Mark all notifications as read")
            .accessibilityHint("Mark every unread notification as read")

            Button(isMuted ? "Unmute all" : "Mute all") {
                isMuted.toggle()
            }
            .buttonStyle(.plain)
            .font(WarrenTypography.popoverMeta)
            .foregroundStyle(tokens.mutedForeground)
            .accessibilityLabel(isMuted ? "Unmute all notifications" : "Mute all notifications")
        }
    }
}

struct WarrenDesktopNoticePopover: View {
    let notices: [WarrenDesktopNotice]
    let onRead: (WarrenDesktopNotice.ID) -> Void
    let onDismissNotice: (WarrenDesktopNotice.ID) -> Void
    @Binding var isMuted: Bool
    let onMarkAllRead: () -> Void
    let onDismiss: () -> Void

    @State private var selectedID: WarrenDesktopNotice.ID?

    private var selectedNotice: WarrenDesktopNotice? {
        guard let selectedID else { return nil }
        return notices.first { $0.id == selectedID }
    }

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: selectedNotice == nil ? "Notifications" : "Notification details",
            width: 360,
            onDismiss: onDismiss,
            titleTrailing: AnyView(
                WarrenDesktopNoticeTitleActions(
                    unreadCount: notices.filter(\.isUnread).count,
                    isMuted: $isMuted,
                    onMarkAllRead: onMarkAllRead
                )
            )
        ) {
            WarrenDesktopNoticeContent(
                notices: notices,
                selectedID: $selectedID,
                onRead: onRead,
                onDismissNotice: onDismissNotice,
                onDismiss: onDismiss
            )
        }
        .onChange(of: notices) { _, current in
            if let selectedID, !current.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }
}

/// Content shared by the standalone notice popover and More's inline detail
/// view. The outer surface owns the title, border and close affordance.
struct WarrenDesktopNoticeContent: View {
    let notices: [WarrenDesktopNotice]
    @Binding var selectedID: WarrenDesktopNotice.ID?
    let onRead: (WarrenDesktopNotice.ID) -> Void
    let onDismissNotice: (WarrenDesktopNotice.ID) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var selectedNotice: WarrenDesktopNotice? {
        guard let selectedID else { return nil }
        return notices.first { $0.id == selectedID }
    }

    @ViewBuilder
    var body: some View {
        if let selectedNotice {
            detailView(selectedNotice)
        } else {
            listView
        }
    }

    private var listView: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Group {
            if notices.isEmpty {
                VStack(spacing: WarrenSpacing.compact) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(tokens.mutedForeground)
                    Text("No notifications")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                    Text("Errors and system messages will appear here.")
                        .font(WarrenTypography.popoverMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(WarrenSpacing.large)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notices) { notice in
                            Button {
                                onRead(notice.id)
                                selectedID = notice.id
                            } label: {
                                HStack(alignment: .top, spacing: WarrenSpacing.compact) {
                                    WarrenNoticeToneIcon(kind: notice.kind)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.xs) {
                                            Text(notice.title)
                                                .font(WarrenTypography.popoverItem)
                                                .foregroundStyle(tokens.foreground)
                                                .lineLimit(1)
                                            if notice.isUnread {
                                                Circle()
                                                    .fill(tokens.info)
                                                    .frame(width: 6, height: 6)
                                                    .accessibilityHidden(true)
                                            }
                                            Spacer(minLength: 0)
                                            Text(relativeDate(notice.createdAt))
                                                .font(WarrenTypography.popoverMeta)
                                                .foregroundStyle(tokens.mutedForeground)
                                        }
                                        Text(notice.message)
                                            .font(WarrenTypography.popoverMeta)
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, WarrenSpacing.standard)
                                .padding(.vertical, WarrenSpacing.compact)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(notice.title)
                            .accessibilityValue(notice.isUnread ? "Unread" : "Read")
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
    }

    private func detailView(_ notice: WarrenDesktopNotice) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            HStack(spacing: WarrenSpacing.compact) {
                Button {
                    selectedID = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Back to notifications")
                WarrenNoticeToneIcon(kind: notice.kind)
                Text(relativeDate(notice.createdAt))
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
            }
            Text(notice.title)
                .font(WarrenTypography.popoverTitle)
                .foregroundStyle(tokens.foreground)
            Text(notice.message)
                .font(WarrenTypography.popoverItem)
                .foregroundStyle(tokens.foreground)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(notice.detail)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Dismiss") {
                    onDismissNotice(notice.id)
                    selectedID = nil
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.popoverMeta))
                Spacer(minLength: 0)
                Button("Done") { onDismiss() }
                    .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.popoverMeta))
            }
        }
        .padding(WarrenSpacing.standard)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// More needs an independent selection state because the parent overflow menu
/// does not otherwise own notice-detail navigation.
struct WarrenDesktopNoticeInlineContent: View {
    let notices: [WarrenDesktopNotice]
    let onRead: (WarrenDesktopNotice.ID) -> Void
    let onDismissNotice: (WarrenDesktopNotice.ID) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: WarrenDesktopNotice.ID?

    var body: some View {
        WarrenDesktopNoticeContent(
            notices: notices,
            selectedID: $selectedID,
            onRead: onRead,
            onDismissNotice: onDismissNotice,
            onDismiss: onDismiss
        )
        .onChange(of: notices) { _, current in
            if let selectedID, !current.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
    }
}

private struct WarrenNoticeToneIcon: View {
    let kind: WarrenDesktopNotice.Kind

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Image(systemName: iconName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(toneColor(tokens))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var iconName: String {
        switch kind {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private func toneColor(_ tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .error: tokens.destructive
        case .warning: tokens.warning
        case .info: tokens.info
        case .success: tokens.success
        }
    }
}
