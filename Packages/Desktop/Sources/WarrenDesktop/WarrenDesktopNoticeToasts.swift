import SwiftUI
import WarrenDesignSystem

/// New notices, shown for a moment over the sidebar's foot.
///
/// Errors and system messages used to land only in the notice center, which
/// opens from a menu, so an "Update failed" arrived without anything in the
/// window lighting up. Here each arrival rises as a toast. They stack, newest
/// in front, and fan out under the pointer. Info, warnings and successes
/// retire on their own; an error stays until it is dismissed or opened,
/// because it is the one a person has to read. Dismissing a toast leaves the
/// notice unread in the center; opening one opens the center.
struct WarrenDesktopNoticeToastStack: View {
    let notices: [WarrenDesktopNotice]
    let isMuted: Bool
    let onOpen: () -> Void

    static let lifetime: TimeInterval = 5
    /// Extra time a toast gets when its timer fires under the pointer.
    static let hoverGrace: TimeInterval = 1.5
    static let toastHeight: CGFloat = 52
    static let fanGap: CGFloat = 8
    /// How far each toast behind the front one peeks out while stacked.
    static let stackStep: CGFloat = 8
    /// Toasts kept at once; older ones still wait in the notice center.
    static let limit = 4

    @State private var toastIDs: [WarrenDesktopNotice.ID] = []
    @State private var knownIDs: Set<WarrenDesktopNotice.ID> = []
    @State private var isPrimed = false
    @State private var isHovered = false
    @State private var retireTasks: [WarrenDesktopNotice.ID: Task<Void, Never>] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toasts = toastIDs.compactMap { id in notices.first { $0.id == id } }
        ZStack(alignment: .bottom) {
            ForEach(Array(toasts.enumerated()), id: \.element.id) { index, notice in
                WarrenDesktopNoticeToast(
                    notice: notice,
                    onOpen: open,
                    onDismiss: { retire(notice.id) }
                )
                .frame(height: Self.toastHeight)
                .scaleEffect(scale(at: index), anchor: .bottom)
                .offset(y: offset(at: index))
                .opacity(opacity(at: index))
                .zIndex(Double(toasts.count - index))
                .allowsHitTesting(isHovered || index == 0)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 16)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                )
            }
        }
        .frame(height: height(for: toasts.count), alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(motion) { isHovered = inside }
        }
        .animation(motion, value: toastIDs)
        .onAppear(perform: prime)
        .onChange(of: notices) { reconcile($0) }
        .onDisappear {
            retireTasks.values.forEach { $0.cancel() }
            retireTasks = [:]
        }
    }

    private var motion: Animation? {
        WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)
    }

    private func height(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        if isHovered {
            return CGFloat(count) * Self.toastHeight + CGFloat(count - 1) * Self.fanGap
        }
        return Self.toastHeight + CGFloat(min(count - 1, 2)) * Self.stackStep
    }

    private func offset(at index: Int) -> CGFloat {
        isHovered
            ? -CGFloat(index) * (Self.toastHeight + Self.fanGap)
            : -CGFloat(min(index, 2)) * Self.stackStep
    }

    private func scale(at index: Int) -> CGFloat {
        isHovered ? 1 : 1 - CGFloat(min(index, 2)) * 0.05
    }

    private func opacity(at index: Int) -> Double {
        if isHovered { return 1 }
        return index < 3 ? 1 - Double(index) * 0.18 : 0
    }

    /// What is already in the center when the window appears is not news.
    private func prime() {
        guard !isPrimed else { return }
        isPrimed = true
        knownIDs = Set(notices.map(\.id))
    }

    private func reconcile(_ current: [WarrenDesktopNotice]) {
        // A notice read or removed in the center takes its toast with it.
        let stale = toastIDs.filter { id in
            current.first { $0.id == id }?.isUnread != true
        }
        stale.forEach(cancelRetire)
        var next = toastIDs.filter { !stale.contains($0) }

        // `current` is newest first, and so is the stack.
        let arrivals = current.filter { !knownIDs.contains($0.id) && $0.isUnread }
        knownIDs = Set(current.map(\.id))
        if !isMuted {
            for notice in arrivals.reversed() {
                next.insert(notice.id, at: 0)
                if notice.kind != .error {
                    armRetire(notice.id, after: Self.lifetime)
                }
            }
        }
        if next.count > Self.limit {
            next.suffix(from: Self.limit).forEach(cancelRetire)
            next = Array(next.prefix(Self.limit))
        }
        if next != toastIDs { toastIDs = next }
    }

    private func armRetire(_ id: WarrenDesktopNotice.ID, after delay: TimeInterval) {
        retireTasks[id]?.cancel()
        retireTasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Never pull a toast out from under the pointer.
            if isHovered {
                armRetire(id, after: Self.hoverGrace)
            } else {
                retire(id)
            }
        }
    }

    private func cancelRetire(_ id: WarrenDesktopNotice.ID) {
        retireTasks[id]?.cancel()
        retireTasks[id] = nil
    }

    private func retire(_ id: WarrenDesktopNotice.ID) {
        cancelRetire(id)
        toastIDs.removeAll { $0 == id }
    }

    private func open() {
        toastIDs.forEach(cancelRetire)
        toastIDs = []
        isHovered = false
        onOpen()
    }
}

private struct WarrenDesktopNoticeToast: View {
    let notice: WarrenDesktopNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    WarrenNoticeToneIcon(kind: notice.kind, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                        Text(notice.message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notice.title). \(notice.message)")
            .accessibilityHint("Open notifications")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WarrenChromeButtonStyle())
            .foregroundStyle(tokens.mutedForeground)
            .warrenTooltip("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(notice.kind == .error ? tokens.destructive.opacity(0.45) : tokens.border, lineWidth: 1)
        )
        .shadow(color: tokens.elevationShadow, radius: 13, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}
