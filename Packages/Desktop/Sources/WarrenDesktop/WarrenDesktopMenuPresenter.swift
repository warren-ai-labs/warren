import AppKit
import SwiftUI
import WarrenDesignSystem

/// The window's one floating menu, presented by any view that wants to show
/// a context menu or a menu-button drop-down.
///
/// The Workbench draws its own menus so they can share the spec's surface,
/// rows and keyboard model; a native `NSMenu` cannot. A view reports the
/// actions and where to hang them, and the window root renders them above
/// everything else.
@MainActor
final class WarrenDesktopMenuCenter: ObservableObject {
    enum Content {
        /// A list of actions, drawn row by row.
        case actions([WarrenDesktopContextMenuAction])
        /// A panel: a switch list, an editor, a notice list, whose own view
        /// owns its content and sits on the shared surface.
        ///
        /// This is the panel as it was when it opened. A panel presented
        /// through `warrenMenuPanel` also republishes itself on every update
        /// of the view that opened it (`WarrenDesktopMenuPanelContentKey`),
        /// and the layer draws that live copy instead, so a panel never shows
        /// state frozen at the moment it opened.
        case panel(AnyView)
    }

    struct Request: Identifiable {
        let id = UUID()
        let content: Content
        let anchor: CGPoint
        let title: String?
        let width: CGFloat
        let edge: WarrenDesktopMenuEdge
        /// A hover card: drawn without the click-catching scrim and never
        /// hit-tested, so the views under it keep the pointer. A scrim there
        /// takes the hover from the row that opened the card, which closes the
        /// card and, in the sidebar, collapses every resting shell row.
        var isPassive = false
    }

    @Published var request: Request?

    func present(
        _ actions: [WarrenDesktopContextMenuAction],
        at anchor: CGPoint,
        title: String? = nil
    ) {
        guard actions.contains(where: \.isActionable) else { return }
        request = Request(
            content: .actions(actions),
            anchor: anchor,
            title: title,
            width: WarrenDesktopMenuMetrics.menuWidth,
            edge: .auto
        )
    }

    @discardableResult
    func presentPanel(
        _ panel: AnyView,
        at anchor: CGPoint,
        width: CGFloat,
        title: String? = nil,
        edge: WarrenDesktopMenuEdge = .auto,
        isPassive: Bool = false
    ) -> UUID {
        let request = Request(
            content: .panel(panel),
            anchor: anchor,
            title: title,
            width: width,
            edge: edge,
            isPassive: isPassive
        )
        self.request = request
        return request.id
    }

    func dismiss() {
        request = nil
    }
}

extension WarrenDesktopContextMenuAction {
    /// A separator never carries an action, and an empty nested menu is not
    /// worth opening either.
    var isActionable: Bool {
        switch self {
        case .divider: false
        case .button: true
        case .check: true
        case .menu(_, let actions): actions.contains(where: \.isActionable)
        }
    }
}

private struct WarrenDesktopMenuCenterKey: EnvironmentKey {
    static let defaultValue: WarrenDesktopMenuCenter? = nil
}

extension EnvironmentValues {
    var warrenMenuCenter: WarrenDesktopMenuCenter? {
        get { self[WarrenDesktopMenuCenterKey.self] }
        set { self[WarrenDesktopMenuCenterKey.self] = newValue }
    }
}

public extension View {
    /// Presents `actions` as the Workbench's own context menu on right-click.
    func warrenContextMenu(_ actions: [WarrenDesktopContextMenuAction]) -> AnyView {
        AnyView(modifier(WarrenDesktopContextMenuModifier(actions: actions)))
    }

    /// Presents `actions` from a menu button, hanging under its leading edge.
    func warrenMenuButton(
        _ actions: [WarrenDesktopContextMenuAction],
        title: String? = nil
    ) -> AnyView {
        AnyView(modifier(WarrenDesktopMenuButtonModifier(actions: actions, title: title)))
    }

    /// Presents `panel` when tapped, on the shared surface. Use this for a
    /// drop-down whose content is switches, an editor or another list rather
    /// than plain rows.
    func warrenMenuPanel<Panel: View>(
        width: CGFloat,
        title: String? = nil,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> AnyView {
        AnyView(modifier(WarrenDesktopMenuPanelButtonModifier(width: width, title: title, panel: panel)))
    }

    /// Presents `panel` while `isPresented` is true, hung from this view. Use
    /// this for a panel a notification or a command opens programmatically,
    /// where there is no click on the anchor itself. A hover card passes
    /// `isPassive` so it never takes the pointer from the view it describes.
    func warrenMenuPanel<Panel: View>(
        isPresented: Binding<Bool>,
        width: CGFloat,
        edge: WarrenDesktopMenuEdge = .auto,
        isPassive: Bool = false,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> AnyView {
        AnyView(modifier(WarrenDesktopMenuPanelBindingModifier(
            isPresented: isPresented,
            width: width,
            edge: edge,
            isPassive: isPassive,
            panel: panel
        )))
    }
}

struct WarrenDesktopMenuPanelBindingModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let edge: WarrenDesktopMenuEdge
    var isPassive = false
    let panel: () -> Panel

    @Environment(\.warrenMenuCenter) private var center: WarrenDesktopMenuCenter?
    @State private var presentedID: UUID?
    @State private var frameReader = WarrenDesktopFrameReader()

    func body(content: Content) -> some View {
        content
            .preference(
                key: WarrenDesktopMenuPanelContentKey.self,
                value: WarrenDesktopMenuPanelContentKey.live(presentedID, in: center, panel: panel)
            )
            .background {
                // The anchor is read when the panel opens, as the tap-opened
                // modifiers read theirs. Tracking the frame instead ran a
                // callback and a state write on every frame a scroll moved the
                // view, and every sidebar Session row carries one of these.
                GeometryReader { geo in
                    let _ = frameReader.read = { geo.frame(in: .global) }
                    Color.clear
                }
            }
            .onChange(of: isPresented) { presented in
                guard let center else { return }
                if presented {
                    presentedID = center.presentPanel(
                        AnyView(panel()),
                        at: anchorPoint(for: frameReader.read?() ?? .zero),
                        width: width,
                        edge: edge,
                        isPassive: isPassive
                    )
                } else if center.request != nil {
                    center.dismiss()
                }
            }
            .onChange(of: center?.request?.id) { id in
                if id == nil, isPresented { isPresented = false }
            }
    }

    private func anchorPoint(for frame: CGRect) -> CGPoint {
        switch edge {
        case .above:
            CGPoint(x: frame.minX, y: frame.minY - WarrenDesktopMenuMetrics.anchorGap)
        case .below, .auto:
            CGPoint(x: frame.minX, y: frame.maxY + WarrenDesktopMenuMetrics.anchorGap)
        }
    }
}

/// Reads a view's current frame on demand. It publishes nothing, so pointing
/// it at the latest geometry during an update invalidates no view.
@MainActor
final class WarrenDesktopFrameReader {
    var read: (() -> CGRect)?
}

struct WarrenDesktopMenuPanelButtonModifier<Panel: View>: ViewModifier {
    let width: CGFloat
    let title: String?
    let panel: () -> Panel

    @Environment(\.warrenMenuCenter) private var center: WarrenDesktopMenuCenter?
    @State private var presentedID: UUID?

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let frame = geo.frame(in: .global)
                        presentedID = center?.presentPanel(
                            AnyView(panel()),
                            at: CGPoint(
                                x: frame.minX,
                                y: frame.maxY + WarrenDesktopMenuMetrics.anchorGap
                            ),
                            width: width,
                            title: title
                        )
                    }
            }
        }
        .preference(
            key: WarrenDesktopMenuPanelContentKey.self,
            value: WarrenDesktopMenuPanelContentKey.live(presentedID, in: center, panel: panel)
        )
    }
}

/// The open panel as its presenter draws it now.
///
/// A panel's content is a closure over its presenter's state: the notices it
/// lists, the value a picker has selected. Evaluating it once, when the panel
/// opens, froze that state, so marking a notice read or picking a value
/// changed nothing on screen until the panel was opened again. The presenter
/// instead republishes the panel under the request's id on every update while
/// that request is the open one, and the menu overlay draws the latest copy.
struct WarrenDesktopMenuPanelContentKey: PreferenceKey {
    static var defaultValue: [UUID: AnyView] { [:] }

    static func reduce(value: inout [UUID: AnyView], nextValue: () -> [UUID: AnyView]) {
        value.merge(nextValue()) { _, next in next }
    }

    /// The live panel for `id`, or nothing once another request (or none)
    /// has replaced it, so a closed panel stops being rebuilt.
    @MainActor
    static func live<Panel: View>(
        _ id: UUID?,
        in center: WarrenDesktopMenuCenter?,
        panel: () -> Panel
    ) -> [UUID: AnyView] {
        guard let id, center?.request?.id == id else { return [:] }
        return [id: AnyView(panel())]
    }
}

extension View {
    /// Hosts the window's floating menu. Apply once, at the window root.
    func warrenMenuOverlay(_ center: WarrenDesktopMenuCenter) -> some View {
        modifier(WarrenDesktopMenuOverlayModifier(center: center))
    }
}

struct WarrenDesktopMenuButtonModifier: ViewModifier {
    let actions: [WarrenDesktopContextMenuAction]
    let title: String?

    @Environment(\.warrenMenuCenter) private var center: WarrenDesktopMenuCenter?

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let frame = geo.frame(in: .global)
                        center?.present(
                            actions,
                            at: CGPoint(
                                x: frame.minX,
                                y: frame.maxY + WarrenDesktopMenuMetrics.anchorGap
                            ),
                            title: title
                        )
                    }
            }
        }
    }
}

struct WarrenDesktopContextMenuModifier: ViewModifier {
    let actions: [WarrenDesktopContextMenuAction]

    @Environment(\.warrenMenuCenter) private var center: WarrenDesktopMenuCenter?

    func body(content: Content) -> some View {
        content.overlay {
            if !actions.isEmpty, let center {
                GeometryReader { geo in
                    WarrenDesktopRightClickCatcher { local in
                        let origin = geo.frame(in: .global).origin
                        center.present(
                            actions,
                            at: CGPoint(x: origin.x + local.x, y: origin.y + local.y)
                        )
                    }
                }
                .allowsHitTesting(true)
            }
        }
    }
}

struct WarrenDesktopMenuOverlayModifier: ViewModifier {
    @ObservedObject var center: WarrenDesktopMenuCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(WarrenDesktopMenuPanelContentKey.self) { livePanels in
            // The transition belongs on the layer, the view that is inserted
            // and removed; on a view inside it nothing ever runs. The animation
            // is keyed here because the presenters set the request bare.
            ZStack {
                if let request = center.request {
                    WarrenDesktopMenuLayer(request: request, livePanel: livePanels[request.id]) {
                        center.dismiss()
                    }
                    .id(request.id)
                    // The spec's pop: it grows out of the edge it hangs from,
                    // so a panel rising from the sidebar's foot travels up
                    // rather than dropping in from above.
                    .transition(WarrenDesktopPopMotion.transition(
                        edge: request.edge == .above ? .bottom : .top,
                        reduceMotion: reduceMotion
                    ))
                }
            }
            .animation(
                WarrenDesktopPopMotion.animation(reduceMotion: reduceMotion),
                value: center.request?.id
            )
        }
    }
}

/// Where a panel hangs relative to its anchor.
public enum WarrenDesktopMenuEdge: Sendable {
    /// Below when there is room, otherwise above.
    case auto
    /// Always below the anchor.
    case below
    /// Always above the anchor: a panel rising from the window's foot.
    case above
}

/// Catches a right-click without taking left clicks or hover from the view
/// underneath: it never hit-tests, it only watches the window's events and
/// keeps the ones inside its own frame.
struct WarrenDesktopRightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopWatching()
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?

        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                let point = self.isFlipped
                    ? local
                    : CGPoint(x: local.x, y: self.bounds.height - local.y)
                guard self.bounds.contains(local) else { return event }
                self.onRightClick?(point)
                return nil
            }
        }

        func stopWatching() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// The window-level layer: a click-catching scrim and the menu itself,
/// clamped to the window and flipped up when it would run off the bottom.
struct WarrenDesktopMenuLayer: View {
    let request: WarrenDesktopMenuCenter.Request
    /// The panel as its presenter draws it now; see
    /// `WarrenDesktopMenuPanelContentKey`.
    var livePanel: AnyView? = nil
    let onDismiss: () -> Void

    @State private var size: CGSize = .zero

    private static let edge: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let placed = placement(in: geo.size)
            ZStack(alignment: .topLeading) {
                if !request.isPassive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                        .ignoresSafeArea()
                }

                Group {
                    switch request.content {
                    case .actions(let actions):
                        WarrenDesktopActionMenu(
                            actions: actions,
                            title: request.title,
                            onDismiss: onDismiss
                        )
                    case .panel(let opened):
                        (livePanel ?? opened)
                            .warrenMenuSurface(width: request.width)
                            // A panel's content rarely holds focus (the
                            // terminal keeps it), so its own Escape handling
                            // never fires; the layer closes it instead.
                            .background {
                                if !request.isPassive {
                                    WarrenDesktopEscapeMonitor(onEscape: onDismiss)
                                }
                            }
                    }
                }
                // Taller than the window, a menu scrolls inside it rather
                // than running off its bottom.
                .environment(\.warrenMenuMaxHeight, maxHeight(in: geo.size))
                .fixedSize()
                .background {
                    GeometryReader { menuGeo in
                        Color.clear.preference(key: WarrenDesktopMenuSizeKey.self, value: menuGeo.size)
                    }
                }
                .offset(x: placed.x, y: placed.y)
                .allowsHitTesting(!request.isPassive)
            }
            .onPreferenceChange(WarrenDesktopMenuSizeKey.self) { size = $0 }
        }
        .ignoresSafeArea()
    }

    /// The room on the side the panel hangs to, so a panel rising from the
    /// sidebar's foot (the notice center) or hanging from the top bar
    /// scrolls before it would cover its own anchor or leave the window.
    private func maxHeight(in available: CGSize) -> CGFloat {
        let window = available.height - 2 * Self.edge
        let room: CGFloat
        switch request.edge {
        case .above:
            room = request.anchor.y - Self.edge
        case .below:
            room = available.height - Self.edge - request.anchor.y
        case .auto:
            room = window
        }
        return max(min(160, window), min(room, window))
    }

    private func placement(in available: CGSize) -> CGPoint {
        let width = size.width > 0 ? size.width : request.width
        let height = size.height
        let x = min(max(Self.edge, request.anchor.x), max(Self.edge, available.width - Self.edge - width))
        var y: CGFloat
        switch request.edge {
        case .below:
            y = request.anchor.y
        case .above:
            y = request.anchor.y - height
        case .auto:
            y = request.anchor.y
            if y + height > available.height - Self.edge {
                let above = request.anchor.y - height
                y = above >= Self.edge ? above : max(Self.edge, available.height - Self.edge - height)
            }
        }
        y = min(max(Self.edge, y), max(Self.edge, available.height - Self.edge - height))
        return CGPoint(x: x, y: y)
    }
}

struct WarrenDesktopMenuSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        // Only the menu reports a size; a sibling that reports nothing must
        // not overwrite it with the default, or a panel that rises above its
        // anchor is placed as if it had no height and runs off the window.
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// One page of actions, with nested menus shown as a drill-in page: the spec
/// uses a flyout for a short, simple list, but a page keeps a deep context
/// menu on screen and in one place.
struct WarrenDesktopActionMenu: View {
    let actions: [WarrenDesktopContextMenuAction]
    var title: String? = nil
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var page: Page?
    @State private var hot: Int = -1

    private struct Page {
        let title: String
        let actions: [WarrenDesktopContextMenuAction]
    }

    private enum Entry {
        case divider
        case button(String, Bool, Bool, () -> Void)
        case check(String, Bool, () -> Void)
        case menu(String, [WarrenDesktopContextMenuAction])

        var isSelectable: Bool {
            switch self {
            case .divider: return false
            case .button(_, _, let isEnabled, _): return isEnabled
            default: return true
            }
        }

        var opensPage: Bool {
            if case .menu = self { return true }
            return false
        }

        var isCheck: Bool {
            if case .check = self { return true }
            return false
        }
    }

    private var entries: [Entry] {
        Self.entries(of: page?.actions ?? actions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let page {
                returnRow(page.title)
                WarrenDesktopMenuDivider()
            } else if let title {
                WarrenDesktopMenuGroupHeader(title: title)
            }
            rows
        }
        .warrenMenuSurface(width: WarrenDesktopMenuMetrics.menuWidth)
        .overlay { WarrenDesktopKeyCatcher(onKey: handle) }
        .onExitCommand {
            if page != nil { page = nil } else { onDismiss() }
        }
    }

    private func returnRow(_ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).secondaryGlyph)
                .frame(width: WarrenDesktopMenuMetrics.actionSize, height: WarrenDesktopMenuMetrics.actionSize)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).rowText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .frame(height: WarrenDesktopMenuMetrics.rowHeight)
        .contentShape(.rect)
        .onTapGesture { page = nil }
    }

    private var rows: some View {
        let entries = self.entries
        // A page that holds any single-choice row keeps the check column on
        // every row, so the names in a mixed menu share one text edge.
        let unchecked: Bool? = entries.contains(where: \.isCheck) ? false : nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                switch entry {
                case .divider:
                    WarrenDesktopMenuDivider()
                case .button(let title, let destructive, let isEnabled, let action):
                    row(
                        title: title,
                        isChecked: unchecked,
                        opensPage: false,
                        danger: destructive,
                        isEnabled: isEnabled,
                        index: index
                    ) {
                        action()
                        onDismiss()
                    }
                case .check(let title, let isOn, let action):
                    row(title: title, isChecked: isOn, opensPage: false, danger: false, index: index) {
                        action()
                        onDismiss()
                    }
                case .menu(let title, _):
                    row(title: title, isChecked: unchecked, opensPage: true, danger: false, index: index) {
                        open(index)
                    }
                }
            }
        }
    }

    private func row(
        title: String,
        isChecked: Bool? = nil,
        opensPage: Bool,
        danger: Bool,
        isEnabled: Bool = true,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        return Button(action: action) {
            HStack(spacing: WarrenDesktopMenuMetrics.checkSpacing) {
                if let isChecked {
                    WarrenDesktopMenuCheckColumn(isChecked: isChecked)
                }
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(rowText(danger: danger, isEnabled: isEnabled, palette: palette))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if opensPage {
                    WarrenDesktopMenuChevron()
                }
            }
            .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: WarrenDesktopMenuMetrics.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle(danger: danger, forceHover: isEnabled && hot == index))
        // A muted row never takes the highlight: it cannot be run, so it must
        // not look like the row a Return would choose.
        .disabled(!isEnabled)
        .onHover { inside in
            guard isEnabled else { return }
            hot = inside ? index : (hot == index ? -1 : hot)
        }
    }

    private func rowText(danger: Bool, isEnabled: Bool, palette: WarrenDesktopMenuPalette) -> Color {
        guard isEnabled else { return palette.meta }
        return danger ? palette.dangerText : palette.rowText
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: // down
            move(1)
        case 126: // up
            move(-1)
        case 115: // home
            hot = firstSelectable(from: -1, step: 1)
        case 119: // end
            hot = firstSelectable(from: entries.count, step: -1)
        case 36, 76: // return
            guard hot >= 0 else { return true }
            activate(hot)
        case 124: // right
            guard hot >= 0, entries[hot].opensPage else { return true }
            open(hot)
        case 123: // left
            if page != nil { page = nil; hot = -1 }
        case 53: // escape
            if page != nil { page = nil; hot = -1 } else { onDismiss() }
        default:
            return false
        }
        return true
    }

    private func move(_ step: Int) {
        guard let next = nextSelectable(after: hot, step: step) else { return }
        hot = next
    }

    private func nextSelectable(after index: Int, step: Int) -> Int? {
        var current = index
        for _ in 0..<entries.count {
            current += step
            if current < 0 { current = entries.count - 1 }
            if current >= entries.count { current = 0 }
            if entries[current].isSelectable { return current }
        }
        return nil
    }

    private func firstSelectable(from index: Int, step: Int) -> Int {
        nextSelectable(after: index, step: step) ?? -1
    }

    private func activate(_ index: Int) {
        guard index >= 0, index < entries.count else { return }
        switch entries[index] {
        case .divider:
            break
        case .button(_, _, let isEnabled, let action):
            guard isEnabled else { return }
            action()
            onDismiss()
        case .check(_, _, let action):
            action()
            onDismiss()
        case .menu:
            open(index)
        }
    }

    private func open(_ index: Int) {
        guard index >= 0, index < entries.count,
              case .menu(let title, let nested) = entries[index] else { return }
        page = Page(title: title, actions: nested)
        hot = -1
    }

    /// Collapses runs of separators and drops the ones at the ends.
    private static func entries(of actions: [WarrenDesktopContextMenuAction]) -> [Entry] {
        var entries: [Entry] = []
        var pendingDivider = false
        for action in actions {
            switch action {
            case .divider:
                pendingDivider = !entries.isEmpty
            case .button(let title, let destructive, let isEnabled, let run):
                if pendingDivider { entries.append(.divider) }
                pendingDivider = false
                entries.append(.button(title, destructive, isEnabled, run))
            case .check(let title, let isOn, let run):
                if pendingDivider { entries.append(.divider) }
                pendingDivider = false
                entries.append(.check(title, isOn, run))
            case .menu(let title, let nested):
                guard nested.contains(where: \.isActionable) else { continue }
                if pendingDivider { entries.append(.divider) }
                pendingDivider = false
                entries.append(.menu(title, nested))
            }
        }
        return entries
    }
}

/// Takes first responder so a menu can be driven from the keyboard, which
/// SwiftUI cannot do on macOS 13 without an AppKit shim.
struct WarrenDesktopKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func keyDown(with event: NSEvent) {
            guard onKey?(event) == true else {
                super.keyDown(with: event)
                return
            }
        }
    }
}

/// Closes a panel on Escape wherever the key focus is, while the panel is on
/// screen. A local monitor sees the key before the terminal does, and the
/// key is consumed so it does not also reach the shell.
struct WarrenDesktopEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEscape = onEscape
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopWatching()
    }

    final class MonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      event.keyCode == 53,
                      event.window === self.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
                    return event
                }
                self.onEscape?()
                return nil
            }
        }

        func stopWatching() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
