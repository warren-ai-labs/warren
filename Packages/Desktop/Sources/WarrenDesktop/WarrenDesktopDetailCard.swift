import AppKit
import SwiftUI
import WarrenDesignSystem

/// A read-only detail card on the shared floating surface.
///
/// Every Session hover uses it through `warrenDetailHover`: the sidebar's
/// shell and Agent rows and the tab bar's pane title. The label column and
/// the value faces live here rather than in any caller.
struct WarrenDesktopDetailCard: View {
    struct Row: Identifiable {
        /// How a value is set, after the sidebar's own rules: a command or a
        /// path is code and stays monospaced, a branch takes the branch face,
        /// and anything else is read as text.
        enum Style {
            case code
            case branch
            case text
        }

        let label: String
        let value: String
        var style: Style = .code

        var id: String { label }
    }

    /// The design's card width, inside the floating surface's own inset.
    static let width: CGFloat = 300

    let rows: [Row]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(WarrenTypography.hoverCardLabel)
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 62, alignment: .leading)
                    Text(row.value)
                        .font(Self.valueFont(row.style))
                        .foregroundStyle(tokens.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private static func valueFont(_ style: Row.Style) -> Font {
        switch style {
        case .code: WarrenTypography.monoSmall
        case .branch: WarrenDesktopTreeTypography.branchName
        case .text: WarrenTypography.hoverCardLabel
        }
    }
}

extension View {
    /// The one hover surface for a Session, wherever it shows: a shell or an
    /// Agent row in the sidebar and a pane's title in the tab bar all rest
    /// here, so they share one card and one placement.
    ///
    /// `rows` is read when the card opens, so a row that changes while the
    /// pointer rests is current; a card with no rows is not shown. A click,
    /// a key or a scroll ends the card and keeps it away until the pointer
    /// leaves, so opening a Session never pops its card over it.
    func warrenDetailHover(
        delay: TimeInterval = WarrenTooltipCenter.showDelay,
        rows: @escaping () -> [WarrenDesktopDetailCard.Row]
    ) -> some View {
        modifier(WarrenDesktopDetailHover(delay: delay, rows: rows))
    }
}

private struct WarrenDesktopDetailHover: ViewModifier {
    let delay: TimeInterval
    let rows: () -> [WarrenDesktopDetailCard.Row]

    @State private var isPresented = false
    @State private var dwell: Task<Void, Never>?
    /// Set by a click or key while the pointer is inside; cleared on exit.
    @State private var isSuppressed = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover(perform: hover)
            .onDisappear(perform: end)
            .warrenMenuPanel(
                isPresented: $isPresented,
                width: WarrenDesktopDetailCard.width,
                isPassive: true
            ) {
                WarrenDesktopDetailCard(rows: rows())
            }
    }

    private func hover(_ isInside: Bool) {
        guard isInside else {
            end()
            return
        }
        isSuppressed = false
        watchForInput()
        schedule()
    }

    private func schedule() {
        dwell?.cancel()
        dwell = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isSuppressed, !rows().isEmpty else { return }
            isPresented = true
        }
    }

    /// The person acted on the row instead of reading it.
    private func watchForInput() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { event in
            isSuppressed = true
            dwell?.cancel()
            dwell = nil
            isPresented = false
            return event
        }
    }

    private func end() {
        dwell?.cancel()
        dwell = nil
        isPresented = false
        isSuppressed = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
