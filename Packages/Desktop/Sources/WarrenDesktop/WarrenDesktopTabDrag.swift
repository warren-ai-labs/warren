import AppKit
import SwiftUI

/// One pane and one of its drop zones, resolved from a pointer position.
struct WarrenDesktopSplitTarget: Equatable, Sendable {
    let paneID: String
    let target: SplitDropTarget
}

/// Shared state for an in-flight tab drag.
///
/// SwiftUI's own `.draggable` / `.dropDestination` pair is not a reliable way
/// to deliver a drop over the AppKit terminal: the sidebar abandoned it for a
/// native `NSDraggingSession` in `WarrenDesktopSidebarDragOverlay`, whose
/// comment records the same failure ("the drag works even when AppKit cannot
/// find a SwiftUI-backed drop destination"). Tabs use the same model, so the
/// drag source — not AppKit — resolves the pane under the pointer and performs
/// the split from `draggingSession(_:endedAt:)`.
@MainActor
final class WarrenDesktopTabDrag: ObservableObject {
    /// The pane and zone the pointer is currently over, or nil.
    @Published private(set) var splitTarget: WarrenDesktopSplitTarget?

    func setSplitTarget(_ target: WarrenDesktopSplitTarget?) {
        guard splitTarget != target else { return }
        splitTarget = target
    }
}

private struct WarrenDesktopTabDragKey: EnvironmentKey {
    static let defaultValue: WarrenDesktopTabDrag? = nil
}

extension EnvironmentValues {
    var warrenTabDrag: WarrenDesktopTabDrag? {
        get { self[WarrenDesktopTabDragKey.self] }
        set { self[WarrenDesktopTabDragKey.self] = newValue }
    }
}

/// Maps a point inside a pane's drop area to one of the five tab targets.
///
/// Pure geometry, so the mapping is asserted directly instead of inferred from
/// a rendered overlay. A pane that cannot split still accepts the centre
/// target, which is how the existing UI expresses replace-in-place.
enum WarrenDesktopPaneDropResolver {
    static func target(
        in size: CGSize,
        at point: CGPoint,
        canSplit: Bool
    ) -> SplitDropTarget {
        guard canSplit else { return .center }
        let rects = WarrenDesktopSplitDropZones.rects(in: size)
        if rects.top.contains(point) { return .top }
        if rects.bottom.contains(point) { return .bottom }
        if rects.left.contains(point) { return .left }
        if rects.right.contains(point) { return .right }
        return .center
    }
}

/// Marks a pane's drop area for the tab drag session.
///
/// This view takes no mouse hit and draws nothing. It exists only so the native
/// drag source can map a screen point back to a pane without a SwiftUI
/// preference round trip. Returning nil from `hitTest` keeps every click,
/// selection drag, and terminal mouse report on the AppKit surface below.
final class WarrenDesktopPaneDropMarkerView: NSView {
    var paneID: String = ""
    var canSplit: Bool = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WarrenDesktopPaneDropMarker: NSViewRepresentable {
    let paneID: String
    let canSplit: Bool

    func makeNSView(context: Context) -> WarrenDesktopPaneDropMarkerView {
        let view = WarrenDesktopPaneDropMarkerView()
        view.paneID = paneID
        view.canSplit = canSplit
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopPaneDropMarkerView, context: Context) {
        nsView.paneID = paneID
        nsView.canSplit = canSplit
    }
}

/// The drag source layered over a tab's title.
///
/// A left press is intercepted only while the tab can be dragged; every other
/// hit path (hover, the context menu, the close control, the terminal) is left
/// alone. A press that never crosses the movement threshold is forwarded to
/// `onSelect`, so selection keeps working after the Button stops receiving the
/// title press.
struct WarrenDesktopTabDragHandle: NSViewRepresentable {
    let tabID: String
    let isEnabled: Bool
    let onSelect: () -> Void
    let onSplitDrop: (String, String, SplitDropTarget) -> Void

    @Environment(\.warrenTabDrag) private var drag

    func makeNSView(context: Context) -> WarrenDesktopTabDragHandleView {
        let view = WarrenDesktopTabDragHandleView()
        view.tabID = tabID
        view.isEnabled = isEnabled
        view.drag = drag
        view.onSelect = onSelect
        view.onSplitDrop = onSplitDrop
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopTabDragHandleView, context: Context) {
        nsView.tabID = tabID
        nsView.isEnabled = isEnabled
        nsView.drag = drag
        nsView.onSelect = onSelect
        nsView.onSplitDrop = onSplitDrop
    }
}

final class WarrenDesktopTabDragHandleView: NSView, NSDraggingSource {
    var tabID: String = ""
    var isEnabled: Bool = true
    weak var drag: WarrenDesktopTabDrag?
    var onSelect: (() -> Void)?
    var onSplitDrop: ((String, String, SplitDropTarget) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    private var escapePressed = false
    private var escapeMonitor: Any?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only a left press is ours. Returning nil for everything else leaves the
    /// tab's hover, context menu, close control, and the terminal below with
    /// their existing hit paths.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, bounds.contains(point) else { return nil }
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard WarrenSidebarDragGesture.hasExceededThreshold(from: origin, to: point) else {
            return
        }
        beginDrag(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didStartDrag else { return }
        onSelect?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishDrag()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            finishDrag()
        }
    }

    // MARK: - Drag

    private func beginDrag(event: NSEvent) {
        didStartDrag = true
        mouseDownPoint = nil
        escapePressed = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.escapePressed = true
            }
            return event
        }
        let item = NSDraggingItem(pasteboardWriter: NSString(string: tabID))
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        drag?.setSplitTarget(resolve(screenPoint))
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        performDrop(at: screenPoint)
        finishDrag()
    }

    /// Resolves and reports the drop for a drag that ended at `screenPoint`.
    ///
    /// Kept separate from the session callback so the pane/zone resolution and
    /// the callback wiring are asserted directly, without a real drag session.
    /// Escape cancels the drag and must never split.
    func performDrop(at screenPoint: NSPoint) {
        guard !escapePressed, let target = resolve(screenPoint) else { return }
        onSplitDrop?(target.paneID, tabID, target.target)
    }

    private func finishDrag() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        escapePressed = false
        didStartDrag = false
        mouseDownPoint = nil
        drag?.setSplitTarget(nil)
    }

    // MARK: - Resolution

    /// Maps a screen point to the pane drop area under it, if any.
    func resolve(_ screenPoint: NSPoint) -> WarrenDesktopSplitTarget? {
        guard let window, let content = window.contentView else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard let marker = deepestMarker(in: content, containing: windowPoint) else {
            return nil
        }
        let local = marker.convert(windowPoint, from: nil)
        guard marker.bounds.contains(local) else { return nil }
        // `WarrenDesktopSplitDropZones` is expressed from the top-left corner,
        // which is only the view's own origin when the view is flipped.
        let topLeft = CGPoint(
            x: local.x,
            y: marker.isFlipped ? local.y : marker.bounds.height - local.y
        )
        return WarrenDesktopSplitTarget(
            paneID: marker.paneID,
            target: WarrenDesktopPaneDropResolver.target(
                in: marker.bounds.size,
                at: topLeft,
                canSplit: marker.canSplit
            )
        )
    }

    private func deepestMarker(
        in view: NSView,
        containing point: NSPoint
    ) -> WarrenDesktopPaneDropMarkerView? {
        var best: (marker: WarrenDesktopPaneDropMarkerView, area: CGFloat)?
        func walk(_ current: NSView) {
            if let marker = current as? WarrenDesktopPaneDropMarkerView,
               !marker.paneID.isEmpty {
                let frame = marker.convert(marker.bounds, to: view)
                if frame.contains(point) {
                    let area = frame.width * frame.height
                    if best == nil || area < best!.area {
                        best = (marker, area)
                    }
                }
            }
            for subview in current.subviews {
                walk(subview)
            }
        }
        walk(view)
        return best?.marker
    }

    /// Captures the title exactly as it is rendered, so the drag preview is the
    /// tab the user grabbed instead of a synthetic chip.
    private func snapshot() -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let windowRect = convert(bounds, to: nil)
        let viewRect = contentView.convert(windowRect, from: nil)
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: viewRect) else {
            return nil
        }
        contentView.cacheDisplay(in: viewRect, to: rep)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
