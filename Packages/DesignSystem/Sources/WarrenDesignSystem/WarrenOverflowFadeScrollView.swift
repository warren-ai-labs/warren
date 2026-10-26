#if os(macOS)
import AppKit
import SwiftUI

private struct WarrenScrollEdges: Equatable {
    var canScrollTop = false
    var canScrollBottom = false
    var canScrollLeft = false
    var canScrollRight = false
}

/// A scroll view whose native coordinator reports edge visibility without
/// feeding measured geometry back into SwiftUI layout.
public struct WarrenOverflowFadeScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let fadeLength: CGFloat
    private let surface: Color
    private let showsEdgeChevrons: Bool
    private let suspendsHitTestingWhileScrolling: Bool
    private let content: () -> Content
    private let contentID = "warren-overflow-content"

    /// Held by reference so a change re-renders only the fades and chevrons
    /// that observe it. As plain view state, every edge crossing re-ran this
    /// body and so `content`, rebuilding every row of a long list at the
    /// moment a scroll left the top.
    @State private var edgeModel = WarrenScrollEdgeModel()
    @State private var activity = WarrenScrollActivity()

    public init(
        _ axes: Axis.Set = .vertical,
        fadeLength: CGFloat = 24,
        surface: Color,
        showsEdgeChevrons: Bool = false,
        suspendsHitTestingWhileScrolling: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axes = axes
        self.fadeLength = fadeLength
        self.surface = surface
        self.showsEdgeChevrons = showsEdgeChevrons
        self.suspendsHitTestingWhileScrolling = suspendsHitTestingWhileScrolling
        self.content = content
    }

    public var body: some View {
        let model = edgeModel
        let activity = activity
        let suspends = suspendsHitTestingWhileScrolling
        ScrollViewReader { proxy in
            ScrollView(axes, showsIndicators: false) {
                WarrenScrollHitGate(
                    activity: activity,
                    isEnabled: suspends,
                    content: content()
                        .id(contentID)
                        .background {
                            WarrenScrollEdgeObserver(
                                onChange: { newEdges in
                                    guard model.edges != newEdges else { return }
                                    model.edges = newEdges
                                },
                                onScrollingChange: suspends ? { activity.isScrolling = $0 } : nil
                            )
                        }
                )
            }
            // A fade painted in the surface color only works over an opaque
            // surface. On glass the region behind is the window's coat, so the
            // content itself fades out instead.
            .mask {
                WarrenScrollEdgeMask(model: model, axes: axes, fadeLength: fadeLength)
            }
            .overlay {
                WarrenScrollEdgeIndicators(
                    model: model,
                    axes: axes,
                    fadeLength: fadeLength,
                    surface: surface,
                    showsEdgeChevrons: showsEdgeChevrons,
                    onScroll: { anchor in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(contentID, anchor: anchor)
                        }
                    }
                )
            }
        }
    }
}

@MainActor
private final class WarrenScrollEdgeModel: ObservableObject {
    @Published var edges = WarrenScrollEdges()
}

/// Whether the content is moving under the pointer right now.
@MainActor
private final class WarrenScrollActivity: ObservableObject {
    @Published var isScrolling = false
}

/// Takes the content out of hit testing while it scrolls.
///
/// Content moving under a still pointer makes AppKit ask, every frame, which
/// view is under the pointer for its cursor, and SwiftUI ask again for its
/// hover state. Both walk every responder in the content, so a long sidebar
/// spent most of each 120 Hz frame answering. Hover is the only thing lost:
/// wheel events go to the scroll view, which stays hit-testable, and a click
/// restores the content before it is delivered.
///
/// `content` is built by the scroll view's body, which a change here does not
/// re-run, so flipping the gate re-renders this modifier and nothing inside it.
private struct WarrenScrollHitGate<Gated: View>: View {
    @ObservedObject var activity: WarrenScrollActivity
    let isEnabled: Bool
    let content: Gated

    var body: some View {
        content.allowsHitTesting(!(isEnabled && activity.isScrolling))
    }
}

private struct WarrenScrollEdgeMask: View {
    @ObservedObject var model: WarrenScrollEdgeModel
    let axes: Axis.Set
    let fadeLength: CGFloat

    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        if windowMaterial == .glass {
            let edges = model.edges
            let top = axes.contains(.vertical) && edges.canScrollTop
            let bottom = axes.contains(.vertical) && edges.canScrollBottom
            let leading = axes.contains(.horizontal) && edges.canScrollLeft
            let trailing = axes.contains(.horizontal) && edges.canScrollRight
            VStack(spacing: 0) {
                LinearGradient(colors: [top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: axes.contains(.vertical) ? fadeLength : 0)
                Color.black
                LinearGradient(colors: [.black, bottom ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: axes.contains(.vertical) ? fadeLength : 0)
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: axes.contains(.horizontal) ? fadeLength : 0)
                    Color.black
                    LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: axes.contains(.horizontal) ? fadeLength : 0)
                }
            }
        } else {
            Color.black
        }
    }
}

/// The surface-colored fades and the horizontal chevrons, drawn over the
/// scroll view from the observed edges.
private struct WarrenScrollEdgeIndicators: View {
    @ObservedObject var model: WarrenScrollEdgeModel
    let axes: Axis.Set
    let fadeLength: CGFloat
    let surface: Color
    let showsEdgeChevrons: Bool
    let onScroll: (UnitPoint) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private enum Edge { case top, bottom, leading, trailing }

    var body: some View {
        let edges = model.edges
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                fade(edge: .top)
                    .opacity(axes.contains(.vertical) && edges.canScrollTop ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                fade(edge: .bottom)
                    .opacity(axes.contains(.vertical) && edges.canScrollBottom ? 1 : 0)
            }
            .overlay(alignment: .leading) {
                fade(edge: .leading)
                    .opacity(horizontalIndicatorVisible(edges.canScrollLeft) ? 1 : 0)
            }
            .overlay(alignment: .trailing) {
                fade(edge: .trailing)
                    .opacity(horizontalIndicatorVisible(edges.canScrollRight) ? 1 : 0)
            }
            .overlay(alignment: .leading) {
                chevron(edge: .leading) { onScroll(.leading) }
                    .opacity(horizontalIndicatorVisible(edges.canScrollLeft) ? 1 : 0)
                    .allowsHitTesting(horizontalIndicatorVisible(edges.canScrollLeft))
                    .accessibilityHidden(!horizontalIndicatorVisible(edges.canScrollLeft))
            }
            .overlay(alignment: .trailing) {
                chevron(edge: .trailing) { onScroll(.trailing) }
                    .opacity(horizontalIndicatorVisible(edges.canScrollRight) ? 1 : 0)
                    .allowsHitTesting(horizontalIndicatorVisible(edges.canScrollRight))
                    .accessibilityHidden(!horizontalIndicatorVisible(edges.canScrollRight))
            }
    }

    private func horizontalIndicatorVisible(_ canScroll: Bool) -> Bool {
        showsEdgeChevrons && axes.contains(.horizontal) && canScroll
    }

    private var fadesByMask: Bool { windowMaterial == .glass }

    @ViewBuilder
    private func fade(edge: Edge) -> some View {
        if fadesByMask {
            EmptyView()
        } else {
            surfaceFade(edge: edge)
        }
    }

    @ViewBuilder
    private func surfaceFade(edge: Edge) -> some View {
        switch edge {
        case .top:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: fadeLength)
                .allowsHitTesting(false)
        case .bottom:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .bottom, endPoint: .top)
                .frame(height: fadeLength)
                .allowsHitTesting(false)
        case .leading:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeLength)
                .allowsHitTesting(false)
        case .trailing:
            LinearGradient(colors: [surface, surface.opacity(0)], startPoint: .trailing, endPoint: .leading)
                .frame(width: fadeLength)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func chevron(edge: Edge, action: @escaping () -> Void) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: edge == .trailing ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tokens.foreground)
                .frame(width: 22, height: 22)
                .background(tokens.muted.opacity(0.85), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(tokens.border.opacity(0.8), lineWidth: WarrenSpacing.hairline)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityLabel(edge == .trailing ? "Scroll tabs forward" : "Scroll tabs backward")
        .help(edge == .trailing ? "More tabs" : "Earlier tabs")
    }
}

private struct WarrenScrollEdgeObserver: NSViewRepresentable {
    let onChange: (WarrenScrollEdges) -> Void
    var onScrollingChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> WarrenScrollEdgeObserverView {
        let view = WarrenScrollEdgeObserverView()
        view.onChange = onChange
        view.onScrollingChange = onScrollingChange
        return view
    }

    func updateNSView(_ nsView: WarrenScrollEdgeObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.onScrollingChange = onScrollingChange
        nsView.reconcileScrollView()
    }
}

private final class WarrenScrollEdgeObserverView: NSView {
    var onChange: ((WarrenScrollEdges) -> Void)?
    /// Reports when the clip view starts and stops moving. A wheel scroll has
    /// no end event, so the end is the moment movement has paused this long.
    var onScrollingChange: ((Bool) -> Void)?
    static let scrollSettleInterval: TimeInterval = 0.15

    private weak var observedScrollView: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var lastEdges: WarrenScrollEdges?
    private var publicationScheduled = false
    private var isScrolling = false
    private var lastScrollMovement: TimeInterval = 0
    private var settleScheduled = false
    private var clickMonitor: Any?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeObservations()
            observedScrollView = nil
            endScrolling()
            return
        }
        reconcileScrollView()
    }

    override func layout() {
        super.layout()
        schedulePublication()
    }

    func reconcileScrollView() {
        let scrollView = enclosingScrollView
        guard observedScrollView !== scrollView else {
            schedulePublication()
            return
        }

        removeObservations()
        observedScrollView = scrollView
        guard let scrollView else { return }

        scrollView.contentView.postsBoundsChangedNotifications = true
        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
        }
        let center = NotificationCenter.default
        observations.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteScrollMovement()
                self?.schedulePublication()
            }
        })
        if let documentView = scrollView.documentView {
            observations.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.schedulePublication()
                }
            })
        }
        schedulePublication()
    }

    private func schedulePublication() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            publicationScheduled = false
            publishEdges()
        }
    }

    private func publishEdges() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let epsilon: CGFloat = 1
        let visible = documentView.visibleRect
        let document = documentView.bounds
        let edges = WarrenScrollEdges(
            canScrollTop: visible.minY > document.minY + epsilon,
            canScrollBottom: visible.maxY < document.maxY - epsilon,
            canScrollLeft: visible.minX > document.minX + epsilon,
            canScrollRight: visible.maxX < document.maxX - epsilon
        )
        guard edges != lastEdges else { return }
        lastEdges = edges
        onChange?(edges)
    }

    private func noteScrollMovement() {
        guard onScrollingChange != nil else { return }
        lastScrollMovement = ProcessInfo.processInfo.systemUptime
        if !isScrolling {
            isScrolling = true
            onScrollingChange?(true)
            installClickMonitor()
        }
        scheduleSettleCheck(after: Self.scrollSettleInterval)
    }

    private func scheduleSettleCheck(after delay: TimeInterval) {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            settleScheduled = false
            guard isScrolling else { return }
            let idle = ProcessInfo.processInfo.systemUptime - lastScrollMovement
            if idle >= Self.scrollSettleInterval {
                endScrolling()
            } else {
                scheduleSettleCheck(after: Self.scrollSettleInterval - idle)
            }
        }
    }

    private func endScrolling() {
        removeClickMonitor()
        guard isScrolling else { return }
        isScrolling = false
        onScrollingChange?(false)
    }

    /// A click while the content still moves — one that stops a momentum
    /// scroll, say — must land on the row under it. The monitor runs before
    /// the click is dispatched; the gate is lifted and the window laid out
    /// at once, so the click's own hit test already sees the content.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return }
                self.endScrolling()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    private func removeObservations() {
        let center = NotificationCenter.default
        observations.forEach(center.removeObserver)
        observations.removeAll()
    }
}

#endif
