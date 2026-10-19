import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Payload format shared between the sidebar drag overlay and the drop
/// handlers in `WarrenDesktopSidebarRows`.
enum WarrenSidebarDragPayload {
    static let projectPrefix = "project:"
    static let workspacePrefix = "workspace:"

    static func project(_ id: ProjectID) -> String {
        projectPrefix + id.description
    }

    static func workspace(_ id: WorkspaceID) -> String {
        workspacePrefix + id.description
    }
}

/// Named coordinate space shared by the row frame preferences and the drag
/// overlay. Rows report frames in this space; the overlay covers the same
/// bounds, so AppKit-local points convert directly to those frames.
enum WarrenSidebarRowsDragCoordinateSpace {
    static let name = "WarrenSidebarRowsDrag"
}

struct WarrenSidebarRowDragFrame: Equatable, Sendable {
    let info: WarrenSidebarRowDragInfo
    let frame: CGRect
}

struct WarrenSidebarRowDragFramesKey: PreferenceKey {
    static let defaultValue: [String: WarrenSidebarRowDragFrame] = [:]

    static func reduce(
        value: inout [String: WarrenSidebarRowDragFrame],
        nextValue: () -> [String: WarrenSidebarRowDragFrame]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum WarrenSidebarDragGesture {
    static let threshold: CGFloat = 5

    static func hasExceededThreshold(from origin: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) >= threshold
    }
}

enum WarrenSidebarDragAutoCollapse: Equatable, Sendable {
    case allProjects
    case projectsExcept(ProjectID)
}

enum WarrenSidebarDragPresentation {
    static func autoCollapse(
        for info: WarrenSidebarRowDragInfo
    ) -> WarrenSidebarDragAutoCollapse {
        switch info.kind {
        case .project:
            return .allProjects
        case .workspace(_, let projectID):
            return .projectsExcept(projectID)
        }
    }

    static func isExpanded(
        _ projectID: ProjectID,
        persistedCollapses: Set<ProjectID>,
        autoCollapse: WarrenSidebarDragAutoCollapse?
    ) -> Bool {
        guard !persistedCollapses.contains(projectID) else { return false }
        switch autoCollapse {
        case nil:
            return true
        case .allProjects:
            return false
        case .projectsExcept(let sourceProjectID):
            return projectID == sourceProjectID
        }
    }
}

/// Metadata for one sidebar row. Workspace rows carry their containing
/// project so a drop can be validated without cross-view lookups.
struct WarrenSidebarRowDragInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case project(ProjectID)
        case workspace(WorkspaceID, projectID: ProjectID)
    }

    let id: String
    let kind: Kind
    let name: String
    let isLastOfList: Bool

    var projectID: ProjectID {
        switch kind {
        case .project(let projectID):
            return projectID
        case .workspace(_, let projectID):
            return projectID
        }
    }

    var isProjectRow: Bool {
        if case .project = kind { return true }
        return false
    }
}

/// Tracks the Command modifier and the active drag session. The Command state
/// never reaches SwiftUI, so holding Command cannot change layout.
@MainActor
final class WarrenDesktopSidebarDragSession {
    private(set) var commandHeld = false
    private(set) var isActive = false

    private var flagsMonitor: Any?
    private var clients: [UUID: (Bool) -> Void] = [:]

    func addClient(id: UUID, onMeasurementNeededChanged: @escaping (Bool) -> Void) {
        clients[id] = onMeasurementNeededChanged
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let nextCommandHeld = event.modifierFlags.contains(.command)
            guard commandHeld != nextCommandHeld else { return event }
            commandHeld = nextCommandHeld
            notifyMeasurementNeeded()
            return event
        }
    }

    func removeClient(id: UUID) {
        clients[id] = nil
        guard clients.isEmpty, let flagsMonitor else { return }
        NSEvent.removeMonitor(flagsMonitor)
        self.flagsMonitor = nil
        commandHeld = false
        isActive = false
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        notifyMeasurementNeeded()
    }

    private func notifyMeasurementNeeded() {
        let isNeeded = commandHeld || isActive
        clients.values.forEach { $0(isNeeded) }
    }
}

/// A transparent AppKit surface covering the sidebar rows. It only intercepts
/// a left mouse press while Command is held and the press lands on a row. A
/// native drag starts only after the pointer crosses the movement threshold.
/// The session's own `movedTo`/`endedAt`
/// callbacks drive the drop highlight and resolve the final row, so the drag
/// works even when AppKit cannot find a SwiftUI-backed drop destination.
struct WarrenDesktopSidebarDragOverlay: NSViewRepresentable {
    let session: WarrenDesktopSidebarDragSession
    let rows: [String: WarrenSidebarRowDragFrame]
    let onDropProject: (String, ProjectID?) -> Bool
    let onDropWorkspace: (String, WorkspaceID?, ProjectID?) -> Bool
    let onDragAutoCollapseChanged: (WarrenSidebarDragAutoCollapse?) -> Void
    let onDragSourceChanged: (String?) -> Void
    let onMeasurementNeededChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WarrenDesktopSidebarDragOverlayView {
        let view = WarrenDesktopSidebarDragOverlayView(session: session)
        view.rows = rows
        view.onDropProject = onDropProject
        view.onDropWorkspace = onDropWorkspace
        view.onDragAutoCollapseChanged = onDragAutoCollapseChanged
        view.onDragSourceChanged = onDragSourceChanged
        view.onMeasurementNeededChanged = onMeasurementNeededChanged
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopSidebarDragOverlayView, context: Context) {
        nsView.rows = rows
        nsView.onDropProject = onDropProject
        nsView.onDropWorkspace = onDropWorkspace
        nsView.onDragAutoCollapseChanged = onDragAutoCollapseChanged
        nsView.onDragSourceChanged = onDragSourceChanged
        nsView.onMeasurementNeededChanged = onMeasurementNeededChanged
    }
}

final class WarrenDesktopSidebarDragOverlayView: NSView, NSDraggingSource {
    var rows: [String: WarrenSidebarRowDragFrame] = [:] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onDropProject: ((String, ProjectID?) -> Bool)?
    var onDropWorkspace: ((String, WorkspaceID?, ProjectID?) -> Bool)?
    var onDragAutoCollapseChanged: ((WarrenSidebarDragAutoCollapse?) -> Void)?
    var onDragSourceChanged: ((String?) -> Void)?
    var onMeasurementNeededChanged: ((Bool) -> Void)?

    private let session: WarrenDesktopSidebarDragSession
    private var highlightRect: NSRect?
    private var attachedToWindow = false
    private var pendingRow: WarrenSidebarRowDragFrame?
    private var mouseDownPoint: NSPoint?
    private var currentPayload: String?
    private var currentDragInfo: WarrenSidebarRowDragInfo?
    private var dragGeneration: UInt64 = 0
    private var didRequestAutoCollapse = false
    private var escapePressed = false
    private var escapeMonitor: Any?
    private var suppressClickUntil: Date?
    private let clientID = UUID()

    init(session: WarrenDesktopSidebarDragSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard session.commandHeld else { return }
        for row in rows.values {
            let rect = bounds.intersection(row.frame)
            guard !rect.isEmpty, !rect.isNull else { continue }
            addCursorRect(rect, cursor: .openHand)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !attachedToWindow {
            attachedToWindow = true
            session.addClient(id: clientID) { [weak self] isNeeded in
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
                self.onMeasurementNeededChanged?(isNeeded)
            }
        } else if window == nil, attachedToWindow {
            finishDrag(suppressClick: false)
            attachedToWindow = false
            session.removeClient(id: clientID)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            finishDrag(suppressClick: false)
            if attachedToWindow {
                session.removeClient(id: clientID)
            }
        }
    }

    // MARK: - Event interception

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = point
        guard bounds.contains(local) else { return nil }
        if session.isActive {
            return self
        }
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown,
              event.modifierFlags.contains(.command),
              rowFrame(at: local) != nil
        else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.modifierFlags.contains(.command),
              let row = rowFrame(at: point) else {
            super.mouseDown(with: event)
            return
        }
        suppressClickUntil = nil
        pendingRow = row
        mouseDownPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let row = pendingRow, let origin = mouseDownPoint else {
            super.mouseDragged(with: event)
            return
        }
        guard event.modifierFlags.contains(.command) else {
            finishDrag(suppressClick: false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard WarrenSidebarDragGesture.hasExceededThreshold(from: origin, to: point) else {
            return
        }
        beginNativeDrag(row: row, event: event)
    }

    private func beginNativeDrag(row: WarrenSidebarRowDragFrame, event: NSEvent) {
        let payload = Self.payload(for: row.info)
        dragGeneration &+= 1
        pendingRow = nil
        mouseDownPoint = nil
        onDragSourceChanged?(row.info.id)
        let item = NSDraggingItem(
            pasteboardWriter: NSString(string: payload)
        )
        item.setDraggingFrame(row.frame, contents: snapshotRow(row.frame))
        currentPayload = payload
        currentDragInfo = row.info
        escapePressed = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.escapePressed = true
            }
            return event
        }
        session.setActive(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingRow != nil {
            finishDrag(suppressClick: false)
            return
        }
        if let deadline = suppressClickUntil, Date() < deadline {
            // A drag that ends without a system drop target can re-deliver the
            // mouseUp as a plain click; swallow only that immediate event.
            suppressClickUntil = nil
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if !escapePressed, let payload = currentPayload, let window {
            let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            let zone = dropZone(at: local, payload: payload)
            _ = performDrop(payload, zone: zone)
        }
        finishDrag(suppressClick: true)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let currentDragInfo else { return }
        let autoCollapse = WarrenSidebarDragPresentation.autoCollapse(
            for: currentDragInfo
        )
        let generation = dragGeneration
        // Tree reflow must happen after AppKit establishes the native drag
        // session. Reflowing synchronously before this callback can invert
        // the SwiftUI view-tree and AppKit drag-session lock order.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.dragGeneration == generation,
                  self.session.isActive,
                  self.currentDragInfo == currentDragInfo,
                  !self.didRequestAutoCollapse
            else { return }
            self.didRequestAutoCollapse = true
            self.onDragAutoCollapseChanged?(autoCollapse)
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let payload = currentPayload, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        updateHighlight(payload: payload, at: local)
    }

    // MARK: - Drop zones

    private enum DropZone: Equatable {
        case beforeWorkspace(rowID: String, y: CGFloat)
        case beforeProject(rowID: String, y: CGFloat)
        case endOfWorkspaces(projectID: ProjectID, y: CGFloat)
        case endOfProjects(y: CGFloat)

        var insertionY: CGFloat {
            switch self {
            case .beforeWorkspace(_, let y),
                 .beforeProject(_, let y),
                 .endOfWorkspaces(_, let y),
                 .endOfProjects(let y):
                return y
            }
        }
    }

    private func rowFrame(at point: NSPoint) -> WarrenSidebarRowDragFrame? {
        rows.values.first { $0.frame.contains(point) }
    }

    private func dropZone(at point: NSPoint, payload: String) -> DropZone? {
        let ordered = rows.values.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        guard point.y >= first.frame.minY, point.y <= last.frame.maxY else { return nil }

        let isWorkspacePayload = payload.hasPrefix(WarrenSidebarDragPayload.workspacePrefix)
        var candidates: [DropZone] = []
        for row in ordered {
            if isWorkspacePayload {
                guard !row.info.isProjectRow else { continue }
                candidates.append(.beforeWorkspace(rowID: row.info.id, y: row.frame.minY))
                if row.info.isLastOfList {
                    candidates.append(
                        .endOfWorkspaces(projectID: row.info.projectID, y: row.frame.maxY)
                    )
                }
            } else {
                guard row.info.isProjectRow else { continue }
                candidates.append(.beforeProject(rowID: row.info.id, y: row.frame.minY))
                if row.info.isLastOfList {
                    candidates.append(.endOfProjects(y: row.frame.maxY))
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min {
            abs($0.insertionY - point.y) < abs($1.insertionY - point.y)
        }
    }

    private func performDrop(_ payload: String, zone: DropZone?) -> Bool {
        guard let zone else { return false }
        if payload.hasPrefix(WarrenSidebarDragPayload.projectPrefix) {
            let sourceID = String(payload.dropFirst(WarrenSidebarDragPayload.projectPrefix.count))
            guard ProjectID(uuidString: sourceID) != nil else { return false }
            switch zone {
            case .beforeProject(let rowID, _):
                guard let projectID = ProjectID(uuidString: rowID) else { return false }
                return onDropProject?(payload, projectID) ?? false
            case .endOfProjects:
                return onDropProject?(payload, nil) ?? false
            case .beforeWorkspace, .endOfWorkspaces:
                return false
            }
        } else {
            let sourceID = String(payload.dropFirst(WarrenSidebarDragPayload.workspacePrefix.count))
            guard WorkspaceID(uuidString: sourceID) != nil else { return false }
            switch zone {
            case .beforeWorkspace(let rowID, _):
                guard let target = WorkspaceID(uuidString: rowID) else {
                    return false
                }
                return onDropWorkspace?(payload, target, nil) ?? false
            case .endOfWorkspaces(let projectID, _):
                return onDropWorkspace?(payload, nil, projectID) ?? false
            case .beforeProject, .endOfProjects:
                return false
            }
        }
    }

    private func updateHighlight(payload: String, at point: NSPoint) {
        let zone = dropZone(at: point, payload: payload)
        let rect = zone.map { insertionRect(for: $0) }
        if highlightRect != rect {
            highlightRect = rect
            needsDisplay = true
        }
    }

    private func clearHighlight() {
        guard highlightRect != nil else { return }
        highlightRect = nil
        needsDisplay = true
    }

    private func finishDrag(suppressClick: Bool) {
        dragGeneration &+= 1
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        pendingRow = nil
        mouseDownPoint = nil
        currentPayload = nil
        currentDragInfo = nil
        escapePressed = false
        if suppressClick {
            suppressClickUntil = Date().addingTimeInterval(0.5)
        }
        if didRequestAutoCollapse {
            didRequestAutoCollapse = false
            let notify = onDragAutoCollapseChanged
            DispatchQueue.main.async {
                notify?(nil)
            }
        }
        onDragSourceChanged?(nil)
        session.setActive(false)
        clearHighlight()
    }

    private func insertionRect(for zone: DropZone) -> NSRect {
        let lineHeight: CGFloat = 2.5
        return NSRect(
            x: WarrenSpacing.compact,
            y: zone.insertionY - lineHeight / 2,
            width: max(0, bounds.width - WarrenSpacing.compact * 2),
            height: lineHeight
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let highlightRect else { return }
        let path = NSBezierPath(
            roundedRect: highlightRect,
            xRadius: highlightRect.height / 2,
            yRadius: highlightRect.height / 2
        )
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    // MARK: - Helpers

    private static func payload(for info: WarrenSidebarRowDragInfo) -> String {
        switch info.kind {
        case .project(let projectID):
            return WarrenSidebarDragPayload.project(projectID)
        case .workspace(let workspaceID, _):
            return WarrenSidebarDragPayload.workspace(workspaceID)
        }
    }

    /// Captures the row exactly as it is rendered on screen, so the drag
    /// preview matches the sidebar UI instead of showing a synthetic chip.
    private func snapshotRow(_ rowFrame: NSRect) -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let windowRect = convert(rowFrame, to: nil)
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
