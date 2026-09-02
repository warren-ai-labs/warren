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
    private let content: () -> Content
    private let contentID = "warren-overflow-content"

    @State private var edges = WarrenScrollEdges()
    @Environment(\.colorScheme) private var colorScheme

    public init(
        _ axes: Axis.Set = .vertical,
        fadeLength: CGFloat = 24,
        surface: Color,
        showsEdgeChevrons: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.axes = axes
        self.fadeLength = fadeLength
        self.surface = surface
        self.showsEdgeChevrons = showsEdgeChevrons
        self.content = content
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axes, showsIndicators: false) {
                content()
                    .id(contentID)
                    .background {
                        WarrenScrollEdgeObserver { newEdges in
                            guard edges != newEdges else { return }
                            edges = newEdges
                        }
                    }
            }
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
                chevron(edge: .leading) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(contentID, anchor: .leading)
                    }
                }
                .opacity(horizontalIndicatorVisible(edges.canScrollLeft) ? 1 : 0)
                .allowsHitTesting(horizontalIndicatorVisible(edges.canScrollLeft))
                .accessibilityHidden(!horizontalIndicatorVisible(edges.canScrollLeft))
            }
            .overlay(alignment: .trailing) {
                chevron(edge: .trailing) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(contentID, anchor: .trailing)
                    }
                }
                .opacity(horizontalIndicatorVisible(edges.canScrollRight) ? 1 : 0)
                .allowsHitTesting(horizontalIndicatorVisible(edges.canScrollRight))
                .accessibilityHidden(!horizontalIndicatorVisible(edges.canScrollRight))
            }
        }
    }

    private enum Edge { case top, bottom, leading, trailing }

    private func horizontalIndicatorVisible(_ canScroll: Bool) -> Bool {
        showsEdgeChevrons && axes.contains(.horizontal) && canScroll
    }

    @ViewBuilder
    private func fade(edge: Edge) -> some View {
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
                        .stroke(tokens.border.opacity(0.8), lineWidth: WarrenSpacing.hairline)
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

    func makeNSView(context: Context) -> WarrenScrollEdgeObserverView {
        let view = WarrenScrollEdgeObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WarrenScrollEdgeObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.reconcileScrollView()
    }
}

private final class WarrenScrollEdgeObserverView: NSView {
    var onChange: ((WarrenScrollEdges) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var lastEdges: WarrenScrollEdges?
    private var publicationScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeObservations()
            observedScrollView = nil
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
            Task { @MainActor [weak self] in
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

    private func removeObservations() {
        let center = NotificationCenter.default
        observations.forEach(center.removeObserver)
        observations.removeAll()
    }
}

#endif
