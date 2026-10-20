import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopNoticeTitleActions: View {
    let unreadCount: Int
    @Binding var isMuted: Bool
    let onMarkAllRead: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: WarrenSpacing.xs) {
            Button("Mark All Read", action: onMarkAllRead)
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

            Button(isMuted ? "Unmute All" : "Mute All") {
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: WarrenDesktopNotice.ID?

    private var selectedNotice: WarrenDesktopNotice? {
        guard let selectedID else { return nil }
        return notices.first { $0.id == selectedID }
    }

    /// Bare content: the window's menu layer owns the surface, so the panel
    /// does not draw one of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedNotice == nil {
                WarrenDesktopMenuGroupHeader(title: "NOTIFICATIONS") {
                    WarrenDesktopNoticeTitleActions(
                        unreadCount: notices.filter(\.isUnread).count,
                        isMuted: $isMuted,
                        onMarkAllRead: onMarkAllRead
                    )
                }
            } else {
                WarrenDesktopMenuBackRow(
                    title: "Notification",
                    backLabel: "Back to notifications",
                    onBack: { selectedID = nil }
                )
                WarrenDesktopMenuDivider()
            }

            WarrenDesktopNoticeContent(
                notices: notices,
                selectedID: $selectedID,
                onRead: onRead,
                onDismissNotice: onDismissNotice,
                onDismiss: onDismiss
            )
        }
        .onChange(of: notices) { current in
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial

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
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
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
                                HStack(alignment: .top, spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                                    WarrenNoticeToneIcon(kind: notice.kind)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.xs) {
                                            Text(notice.title)
                                                .font(.system(size: 13))
                                                .foregroundStyle(palette.rowText)
                                                .lineLimit(1)
                                            if notice.isUnread {
                                                Circle()
                                                    .fill(tokens.info)
                                                    .frame(width: 6, height: 6)
                                                    .accessibilityHidden(true)
                                            }
                                            Spacer(minLength: 0)
                                            Text(relativeDate(notice.createdAt))
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(palette.meta)
                                        }
                                        Text(notice.message)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(palette.meta)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                                .padding(.vertical, 8)
                                .contentShape(.rect)
                            }
                            .buttonStyle(WarrenDesktopMenuRowStyle())
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
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        return VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            // The surrounding page's back row already leads home, so the
            // detail opens on the notice's tone and age alone.
            HStack(spacing: WarrenSpacing.compact) {
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

/// A notice's tone: a filled disc in the tone's colour with a small glyph
/// knocked out of it. The toast, the list and the detail all draw this one
/// mark, so a notice looks the same wherever it is met.
struct WarrenNoticeToneIcon: View {
    let kind: WarrenDesktopNotice.Kind
    var size: CGFloat = WarrenDesktopMenuMetrics.iconSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Image(systemName: Self.glyph(of: kind))
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(tokens.background)
            .frame(width: size, height: size)
            .background(Self.tone(of: kind, tokens: tokens), in: Circle())
            .accessibilityHidden(true)
    }

    static func glyph(of kind: WarrenDesktopNotice.Kind) -> String {
        switch kind {
        case .error: "exclamationmark"
        case .warning: "exclamationmark"
        case .info: "info"
        case .success: "checkmark"
        }
    }

    static func tone(of kind: WarrenDesktopNotice.Kind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .error: tokens.destructive
        case .warning: tokens.warning
        case .info: tokens.info
        case .success: tokens.success
        }
    }
}

/// The bell: the way into the notice center.
///
/// It sits at the sidebar's bottom-left corner, and in the top bar's trailing
/// capsule while the sidebar is hidden, so it is always on screen. A dot on its shoulder says something is unread; muting
/// swaps the glyph for the struck-through bell so the state reads without
/// opening the panel. A notice that arrives while unmuted swings the bell
/// once, which is the only motion it makes.
struct WarrenDesktopNoticeBell: View {
    let notices: [WarrenDesktopNotice]
    @Binding var isPresented: Bool
    let onRead: (WarrenDesktopNotice.ID) -> Void
    let onDismissNotice: (WarrenDesktopNotice.ID) -> Void
    let onMarkAllRead: () -> Void
    /// Which way the notice center opens: up from the sidebar's foot, down
    /// from the top bar.
    var panelEdge: WarrenDesktopMenuEdge = .below

    @AppStorage(WarrenPreferenceKey.noticeMuted)
    private var isMuted = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.warrenMenuCenter) private var menuCenter: WarrenDesktopMenuCenter?
    @State private var swing: Double = 0

    static let panelWidth: CGFloat = 360

    private var unreadCount: Int {
        notices.filter(\.isUnread).count
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let label = accessibilityLabel
        Button(action: toggle) {
            Image(systemName: isMuted ? "bell.slash" : "bell")
                .font(.system(size: 13, weight: .regular))
                .rotationEffect(.degrees(swing), anchor: .top)
                .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Circle()
                            .fill(isMuted ? tokens.mutedForeground : tokens.info)
                            .frame(width: 6, height: 6)
                            .padding(1.5)
                            .background(Circle().fill(tokens.workbenchCardFill))
                            .offset(x: -6, y: 5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .frame(width: 28, height: WarrenLayoutMetrics.tabPillHeight)
        .background(
            isPresented ? tokens.selectedTabPillFill : .clear,
            in: RoundedRectangle(cornerRadius: WarrenLayoutMetrics.tabPillRadius, style: .continuous)
        )
        .foregroundStyle(isPresented ? tokens.foreground : tokens.mutedForeground)
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: unreadCount > 0)
        .warrenTooltip(isMuted ? "Notifications (muted)" : "Notifications")
        .accessibilityLabel(label)
        .accessibilityHint("Show notifications")
        .warrenSemanticElement(
            id: "notifications.bell",
            role: .button,
            label: label,
            value: "\(unreadCount)",
            isSelected: isPresented,
            action: toggle
        )
        .warrenMenuPanel(
            isPresented: $isPresented,
            width: Self.panelWidth,
            edge: panelEdge
        ) {
            WarrenDesktopNoticePopover(
                notices: notices,
                onRead: onRead,
                onDismissNotice: onDismissNotice,
                isMuted: $isMuted,
                onMarkAllRead: onMarkAllRead,
                onDismiss: dismiss
            )
        }
        .onChange(of: unreadCount) { [oldCount = unreadCount] newCount in
            guard newCount > oldCount, !isMuted, !reduceMotion else { return }
            ring()
        }
    }

    private var accessibilityLabel: String {
        let base = isMuted ? "Notifications, muted" : "Notifications"
        switch unreadCount {
        case 0: return base
        case 1: return "\(base), 1 unread"
        default: return "\(base), \(unreadCount) unread"
        }
    }

    private func toggle() {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            isPresented.toggle()
        }
    }

    private func dismiss() {
        isPresented = false
        menuCenter?.dismiss()
    }

    /// One damped swing about the bell's crown: out, back past centre, rest.
    private func ring() {
        let step = Animation.easeInOut(duration: 0.09)
        withAnimation(step) { swing = 14 }
        withAnimation(step.delay(0.09)) { swing = -10 }
        withAnimation(step.delay(0.18)) { swing = 5 }
        withAnimation(.easeOut(duration: 0.12).delay(0.27)) { swing = 0 }
    }
}
