import SwiftUI
#if os(macOS)
import AppKit

/// One tooltip for the whole window.
///
/// AppKit's tooltip (`.help`) makes every control wait about a second on its
/// own, so sweeping along a row of icon buttons means waiting again at each
/// one. Here the first tooltip waits the same dwell as the hover detail card;
/// while it is up, or for a moment after it goes, the next control answers at
/// once and the single bubble glides across to it.
@MainActor
public final class WarrenTooltipCenter: ObservableObject {
    public struct Tip: Equatable {
        public let id: String
        public let text: String
        public let shortcut: String?
        /// The control's frame in `WarrenTooltipCenter.coordinateSpace`.
        public let anchor: CGRect
    }

    public static let coordinateSpace = "warren.tooltip"
    /// The first tooltip's dwell, shared with the hover detail card.
    public static let showDelay: TimeInterval = 0.45
    /// How long after a tooltip goes the next control still answers at once.
    public static let warmWindow: TimeInterval = 0.3
    /// Grace between leaving one control and entering its neighbour, so the
    /// bubble glides instead of blinking out and back.
    static let leaveGrace: TimeInterval = 0.06

    @Published public private(set) var tip: Tip?
    /// Whether the current tip arrived by moving from another control.
    @Published public private(set) var glides = false

    private var showTask: Task<Void, Never>?
    /// The control whose dwell `showTask` is timing.
    private var pendingID: String?
    private var hideTask: Task<Void, Never>?
    private var warmUntil = Date.distantPast
    private var eventMonitor: Any?

    public init() {}

    func enter(_ next: Tip) {
        showTask?.cancel()
        hideTask?.cancel()
        pendingID = nil
        if tip != nil || Date() < warmUntil {
            glides = tip != nil
            tip = next
            return
        }
        pendingID = next.id
        showTask = after(Self.showDelay) { center in
            center.pendingID = nil
            center.glides = false
            center.tip = next
        }
    }

    func leave(_ id: String) {
        // Leaving one control must not cancel a neighbour's dwell, which can
        // start before this exit arrives.
        if pendingID == id {
            showTask?.cancel()
            pendingID = nil
        }
        guard tip?.id == id else { return }
        hideTask?.cancel()
        hideTask = after(Self.leaveGrace) { center in
            center.tip = nil
            center.warmUntil = Date().addingTimeInterval(Self.warmWindow)
        }
    }

    private func after(
        _ delay: TimeInterval,
        _ body: @escaping @MainActor (WarrenTooltipCenter) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            body(self)
        }
    }

    /// A click or a keystroke ends the tooltip outright, without the warm
    /// window: the person has moved on from reading.
    func dismiss() {
        showTask?.cancel()
        pendingID = nil
        hideTask?.cancel()
        warmUntil = .distantPast
        if tip != nil { tip = nil }
    }

    func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        dismiss()
    }
}

private struct WarrenTooltipCenterKey: EnvironmentKey {
    static let defaultValue: WarrenTooltipCenter? = nil
}

public extension EnvironmentValues {
    /// The window's tooltip owner, or nil where no host was installed; there
    /// `warrenTooltip` falls back to the system tooltip.
    var warrenTooltipCenter: WarrenTooltipCenter? {
        get { self[WarrenTooltipCenterKey.self] }
        set { self[WarrenTooltipCenterKey.self] = newValue }
    }
}

public extension View {
    /// Names the control in the window's shared tooltip, with its shortcut
    /// when it has one (`"⌘K"`). Use it on chrome controls whose only label is
    /// a glyph. The accessibility label stays the control's own.
    func warrenTooltip(_ text: String, shortcut: String? = nil) -> some View {
        modifier(WarrenTooltipModifier(text: text, shortcut: shortcut))
    }

    /// Installs the shared tooltip for everything inside. Apply it once, at
    /// the root of a window.
    func warrenTooltipHost() -> some View {
        modifier(WarrenTooltipHostModifier())
    }
}

/// Holds the control's last laid-out frame without making the control
/// re-render each time it moves.
@MainActor
private final class WarrenTooltipAnchor {
    var frame: CGRect = .zero
}

private struct WarrenTooltipModifier: ViewModifier {
    let text: String
    let shortcut: String?

    @Environment(\.warrenTooltipCenter) private var center
    @State private var id = UUID().uuidString
    @State private var anchor = WarrenTooltipAnchor()

    func body(content: Content) -> some View {
        if let center {
            content
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named(WarrenTooltipCenter.coordinateSpace))
                        Color.clear
                            .onAppear { anchor.frame = frame }
                            .onChange(of: frame) { anchor.frame = $0 }
                    }
                }
                .onHover { inside in
                    if inside {
                        center.enter(.init(id: id, text: text, shortcut: shortcut, anchor: anchor.frame))
                    } else {
                        center.leave(id)
                    }
                }
                .onDisappear { center.leave(id) }
        } else {
            content.help(shortcut.map { "\(text) (\($0))" } ?? text)
        }
    }
}

private struct WarrenTooltipHostModifier: ViewModifier {
    @StateObject private var center = WarrenTooltipCenter()

    func body(content: Content) -> some View {
        content
            .environment(\.warrenTooltipCenter, center)
            .overlay { WarrenTooltipLayer(center: center) }
            .coordinateSpace(name: WarrenTooltipCenter.coordinateSpace)
            .onAppear { center.startMonitoring() }
            .onDisappear { center.stopMonitoring() }
    }
}

private struct WarrenTooltipLayer: View {
    @ObservedObject var center: WarrenTooltipCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero

    /// Gap between the control and the bubble, and the bubble's minimum
    /// distance from the window edge.
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let tip = center.tip {
                WarrenTooltipBubble(text: tip.text, shortcut: tip.shortcut)
                    .background {
                        GeometryReader { bubble in
                            Color.clear
                                .onAppear { size = bubble.size }
                                .onChange(of: bubble.size) { size = $0 }
                        }
                    }
                    // Hidden for the one pass before its size is known, so it
                    // never flashes at the wrong place.
                    .opacity(size == .zero ? 0 : 1)
                    .position(Self.position(for: tip.anchor, size: size, in: proxy.size))
                    .animation(
                        center.glides && !reduceMotion ? WarrenMotion.selection(reduceMotion: false) : nil,
                        value: tip.anchor
                    )
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: WarrenMotion.stateChangeDuration), value: center.tip == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Centred under the control, above it when there is no room below, and
    /// kept inside the window.
    static func position(for anchor: CGRect, size: CGSize, in container: CGSize) -> CGPoint {
        let halfWidth = size.width / 2
        let x = min(
            max(anchor.midX, halfWidth + margin),
            max(halfWidth + margin, container.width - halfWidth - margin)
        )
        let halfHeight = size.height / 2
        let below = anchor.maxY + gap + halfHeight
        let y = below + halfHeight <= container.height - margin
            ? below
            : anchor.minY - gap - halfHeight
        // A control taller than the room around it (a full-height pane edge)
        // still keeps the bubble on screen.
        let clampedY = min(
            max(y, halfHeight + margin),
            max(halfHeight + margin, container.height - halfHeight - margin)
        )
        return CGPoint(x: x, y: clampedY)
    }
}

private struct WarrenTooltipBubble: View {
    let text: String
    let shortcut: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tokens.foreground)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        )
        .shadow(color: tokens.elevationShadow, radius: 11, y: 6)
    }
}
#endif
