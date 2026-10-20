import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// The split group's two-stage hover gesture, shared by the group pill, its
/// control shelf and the pane cards below them.
///
/// Light: the pointer rests on the pill and the stacked icons lift apart, so a
/// click picks a pane. Heavy: a longer dwell, or a pull toward the pill's bottom
/// edge, drops the shelf. Both stages share one aimed member, which is why the
/// icon, its shelf row and its pane card always light up together.
@MainActor
final class WarrenDesktopPaneGroupHover: ObservableObject {
    enum Phase: Equatable {
        case rest
        case lifted
        case pulled
    }

    @Published private(set) var phase: Phase = .rest
    /// The member under the pointer (or the keyboard), nil while the title or
    /// nothing is aimed at.
    @Published private(set) var hotTabID: String?
    /// The shelf was opened from the keyboard, so ↑↓ ⏎ ⌫ Esc act on it.
    @Published private(set) var isKeyboardDriven = false

    static let liftDelay = WarrenDesktopHoverIntent.liftDelay
    static let pullDelay = WarrenDesktopHoverIntent.pullDelay
    static let dropDelay = WarrenDesktopHoverIntent.dropDelay
    /// How long a ⌥N focus keeps the pill lifted as a hint.
    static let hintDuration: TimeInterval = 0.6

    private var isPillHovered = false
    private var isShelfHovered = false
    private var liftWork: DispatchWorkItem?
    private var pullWork: DispatchWorkItem?
    private var dropWork: DispatchWorkItem?

    init(phase: Phase = .rest, hotTabID: String? = nil) {
        self.phase = phase
        self.hotTabID = hotTabID
    }

    /// The member the pane area previews; nothing at rest.
    var peekTabID: String? { phase == .rest ? nil : hotTabID }

    var isLifted: Bool { phase != .rest }

    func pillHover(_ inside: Bool) {
        isPillHovered = inside
        if inside {
            dropWork?.cancel()
            // A Tab drag passes over the pill with the button held. Neither
            // stage may start under it, or the drop target would move away.
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            guard phase == .rest else { return }
            schedule(&liftWork, after: Self.liftDelay) { [weak self] in
                self?.lift()
            }
            schedule(&pullWork, after: Self.pullDelay) { [weak self] in
                self?.pull()
            }
        } else {
            liftWork?.cancel()
            pullWork?.cancel()
            scheduleDropIfLeft()
        }
    }

    func shelfHover(_ inside: Bool) {
        isShelfHovered = inside
        if inside {
            dropWork?.cancel()
        } else {
            scheduleDropIfLeft()
        }
    }

    /// Aims at a member, or at the group itself with nil.
    func aim(_ tabID: String?) {
        guard phase != .rest else { return }
        hotTabID = tabID
    }

    /// Opens the shelf at once: the pointer was carried toward the bottom edge.
    func pull() {
        guard phase != .rest || isPillHovered else { return }
        liftWork?.cancel()
        pullWork?.cancel()
        phase = .pulled
    }

    func drop() {
        liftWork?.cancel()
        pullWork?.cancel()
        dropWork?.cancel()
        phase = .rest
        hotTabID = nil
        isKeyboardDriven = false
    }

    /// A drag started from one of the group's members; both stages stand down.
    func dragBegan() {
        drop()
    }

    /// Lifts the pill briefly, the hint a ⌥N focus gives.
    func hint() {
        guard phase == .rest else { return }
        lift()
        schedule(&dropWork, after: Self.hintDuration) { [weak self] in
            guard let self, !self.isPillHovered, !self.isShelfHovered else { return }
            self.drop()
        }
    }

    func openFromKeyboard(aiming tabID: String?) {
        liftWork?.cancel()
        pullWork?.cancel()
        dropWork?.cancel()
        phase = .pulled
        isKeyboardDriven = true
        hotTabID = tabID
    }

    /// Steps the keyboard's aim through the members, wrapping at both ends.
    func moveKeyboardAim(in tabIDs: [String], by delta: Int) {
        guard !tabIDs.isEmpty else { return }
        let index = hotTabID.flatMap(tabIDs.firstIndex(of:)) ?? (delta > 0 ? -1 : 0)
        let next = ((index + delta) % tabIDs.count + tabIDs.count) % tabIDs.count
        hotTabID = tabIDs[next]
    }

    private func lift() {
        guard phase == .rest else { return }
        phase = .lifted
        hotTabID = nil
    }

    private func scheduleDropIfLeft() {
        guard !isKeyboardDriven else { return }
        schedule(&dropWork, after: Self.dropDelay) { [weak self] in
            guard let self, !self.isPillHovered, !self.isShelfHovered else { return }
            self.drop()
        }
    }

    private func schedule(
        _ slot: inout DispatchWorkItem?,
        after delay: TimeInterval,
        _ body: @escaping @MainActor () -> Void
    ) {
        slot?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        slot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private struct WarrenDesktopPaneGroupHoverKey: EnvironmentKey {
    static let defaultValue: WarrenDesktopPaneGroupHover? = nil
}

extension EnvironmentValues {
    /// The window's group hover, read by the pane cards to preview the aimed
    /// member.
    var warrenPaneGroupHover: WarrenDesktopPaneGroupHover? {
        get { self[WarrenDesktopPaneGroupHoverKey.self] }
        set { self[WarrenDesktopPaneGroupHoverKey.self] = newValue }
    }
}

/// Everything the group pill and its shelf draw, resolved once by the bar.
struct WarrenDesktopPaneGroupPresentation {
    struct Member: Identifiable {
        let tab: ClientTab
        let title: String
        let mark: WarrenActivityMark?
        /// What the Session is doing, one line.
        let activity: String
        let icon: WarrenDesktopAppIcon
        /// The pane's place in the layout, in unit coordinates.
        let unitFrame: CGRect

        var id: String { tab.id }
        var needsPerson: Bool { mark?.tier == .actionable }
    }

    let scopeKey: String
    let title: String
    /// Where the group lives, e.g. "warren · feat/workbench-cards".
    let context: String
    let members: [Member]
    /// The member focus lands on: the selected Tab when it is a member,
    /// otherwise the pane the layout last had active.
    let currentTabID: String?
    let containsSelection: Bool
    /// Whether "Split" can add a pane.
    let canSplit: Bool

    var tabIDs: [String] { members.map(\.id) }
    var needsPerson: Bool { members.contains(where: \.needsPerson) }

    func member(_ tabID: String?) -> Member? {
        tabID.flatMap { id in members.first { $0.id == id } }
    }
}

/// What a group's controls ask the window to do.
struct WarrenDesktopPaneGroupActions {
    /// Focus one member's pane.
    let selectMember: (String) -> Void
    /// Switch to the group without changing which of its panes has focus.
    let selectGroup: () -> Void
    /// Show one pane alone until it is restored; the group stays.
    let toggleZoom: (String) -> Void
    let isZoomed: (String) -> Bool
    let closeMember: (String) -> Void
    let split: () -> Void
    let ungroup: () -> Void
    /// A Tab dropped on the pill joins the group.
    let merge: (String) -> Void
    let splitDrop: (String, String, SplitDropTarget) -> Void
    let contextMenu: (ClientTab) -> [WarrenDesktopContextMenuAction]
}

/// A split group in the top bar: one fixed-width pill holding the members'
/// stacked icons, the group's name and its pane count.
struct WarrenDesktopPaneGroupPill: View {
    let group: WarrenDesktopPaneGroupPresentation
    let actions: WarrenDesktopPaneGroupActions
    @ObservedObject var hover: WarrenDesktopPaneGroupHover

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var keyMonitor: Any?
    /// The window this pill is mounted in, so the app-wide key monitor only
    /// answers keys aimed at it.
    @State private var hostWindow = WarrenDesktopPaneGroupWindowBox()

    private typealias Metrics = WarrenLayoutMetrics

    private var lifted: Bool { hover.isLifted }
    private var pulled: Bool { hover.phase == .pulled }

    private var liftAnimation: Animation? {
        WarrenDesktopHoverIntent.animation(reduceMotion: reduceMotion)
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let surface = group.containsSelection ? tokens.selectedTabPillFill : tokens.workbenchCardFill
        HStack(spacing: 0) {
            fan(tokens: tokens, surface: surface)
                .zIndex(3)
            titleArea(tokens: tokens)
                .padding(.leading, 7)
            Text("\(group.members.count)")
                .font(.system(size: 11))
                .foregroundStyle(tokens.treeQuietText)
                .padding(.leading, 4)
                .opacity(lifted ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(width: Metrics.tabGroupPillWidth, height: Metrics.tabPillHeight, alignment: .leading)
        .background(
            group.containsSelection
                ? tokens.selectedTabPillFill
                : (isHovered ? tokens.fillHover : .clear),
            in: RoundedRectangle(cornerRadius: Metrics.tabPillRadius, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            if group.needsPerson {
                Circle()
                    .fill(tokens.highlight)
                    .frame(width: 6, height: 6)
                    // The ring is the pill's own fill, so it does not show as
                    // a darker halo on the selected pill.
                    .background(Circle().fill(surface).padding(-1.5))
                    .padding(.top, 2)
                    .padding(.trailing, 3)
                    .opacity(lifted ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            // The grip says the pill can still be pulled down.
            RoundedRectangle(cornerRadius: 1)
                .fill(tokens.treeQuietText)
                .frame(width: 16, height: 2)
                .offset(y: 1)
                .opacity(lifted && !pulled ? 0.8 : 0)
                .allowsHitTesting(false)
        }
        .animation(liftAnimation, value: hover.phase)
        .animation(liftAnimation, value: hover.hotTabID)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hover.pillHover(true)
                // Carrying the pointer to the bottom edge is the pull.
                if lifted, point.y > Metrics.tabPillHeight - 5 {
                    hover.pull()
                }
            case .ended:
                hover.pillHover(false)
            }
        }
        .dropDestination(for: String.self) { tabIDs, _ in
            guard let tabID = tabIDs.first, !group.tabIDs.contains(tabID) else { return false }
            actions.merge(tabID)
            return true
        }
        .background(WarrenDesktopPaneGroupWindowProbe(box: hostWindow))
        .focusable()
        .focused($isFocused)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        .warrenSemanticElement(
            id: "tabgroup.\(group.scopeKey)",
            role: .group,
            label: "Split group \(group.title)",
            value: "\(group.members.count) panes",
            isSelected: group.containsSelection,
            action: actions.selectGroup
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split group \(group.title), \(group.members.count) panes")
    }

    // MARK: - Fan

    private func fan(tokens: WarrenColorTokens, surface: Color) -> some View {
        let count = group.members.count
        let restWidth = Metrics.tabGroupIconSize + CGFloat(max(count - 1, 0)) * Metrics.tabGroupIconRestPitch
        return ZStack(alignment: .topLeading) {
            ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                fanIcon(member, index: index, tokens: tokens, surface: surface)
                    .zIndex(Double(count - index) + (member.id == hover.hotTabID ? 10 : 0))
            }
        }
        .frame(width: restWidth, height: Metrics.tabGroupIconSize, alignment: .topLeading)
    }

    private func fanIcon(
        _ member: WarrenDesktopPaneGroupPresentation.Member,
        index: Int,
        tokens: WarrenColorTokens,
        surface: Color
    ) -> some View {
        let isHot = lifted && member.id == hover.hotTabID
        let isCurrent = member.id == group.currentTabID
        let pitch = lifted ? Metrics.tabGroupIconLiftedPitch : Metrics.tabGroupIconRestPitch
        let rise: CGFloat = reduceMotion || !lifted
            ? 0
            : (isHot ? Metrics.tabGroupIconHotLift : Metrics.tabGroupIconLift)
        let size = Metrics.tabGroupIconSize
        return WarrenDesktopSessionKindBadge(icon: member.icon, size: size)
            .background(
                // At rest a ring of the pill's surface separates each icon
                // from the one it is tucked behind.
                RoundedRectangle(cornerRadius: 4 + 1.5, style: .continuous)
                    .fill(surface)
                    .padding(-1.5)
                    .opacity(lifted ? 0 : 1)
            )
            .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: 5, y: 4)
            .overlay(alignment: .bottomTrailing) {
                if let mark = member.mark, mark.isDrawn, lifted || member.needsPerson {
                    Circle()
                        .fill(WarrenDesktopStatusDot.color(for: mark, tokens: tokens))
                        .frame(width: 7, height: 7)
                        .background(Circle().fill(surface).padding(-1.5))
                        .offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .bottom) {
                // The focused member's underline, shown while lifted.
                RoundedRectangle(cornerRadius: 1)
                    .fill(tokens.foreground.opacity(0.85))
                    .frame(width: size - 6, height: 2)
                    .offset(y: 6)
                    .opacity(lifted && isCurrent ? 1 : 0)
            }
            .overlay {
                WarrenDesktopTabDragHandle(
                    tabID: member.id,
                    isEnabled: member.tab.sessionID != nil,
                    onSelect: { select(member.id) },
                    onSplitDrop: actions.splitDrop,
                    onDragStarted: { hover.dragBegan() }
                )
            }
            .scaleEffect(isHot && !reduceMotion ? Metrics.tabGroupIconHotScale : 1)
            .offset(x: CGFloat(index) * pitch, y: -rise)
            .onHover { inside in
                if inside { hover.aim(member.id) }
            }
            .warrenContextMenu(actions.contextMenu(member.tab))
            .help(member.title)
            .accessibilityElement()
            .accessibilityLabel("Pane \(member.title)")
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(member.id) }
            .warrenSemanticElement(
                id: "tabgroup.\(group.scopeKey).member.\(member.id)",
                role: .button,
                label: "Pane \(member.title)",
                isSelected: isCurrent,
                action: { select(member.id) }
            )
    }

    // MARK: - Title

    private func titleArea(tokens: WarrenColorTokens) -> some View {
        let spread = CGFloat(max(group.members.count - 1, 0)) * Metrics.tabGroupIconLiftedPitch
        let memberTitle = group.member(hover.hotTabID ?? group.currentTabID)?.title ?? group.title
        let color = group.containsSelection ? tokens.foreground.opacity(0.95) : tokens.mutedForeground
        // The titles size to their own text; the clear container is what
        // takes the pill's remaining width. Laying the text out directly
        // would make the longer, hover-only member title a minimum width and
        // push the pane count past the fixed-width pill.
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                // Fades only when the title does not fit, like a sidebar row's
                // name, rather than through a fixed mask that dimmed the end
                // of every title. The trailing padding stands in for the
                // lifted title's offset, so the fade still measures it.
                WarrenDesktopFadingLine {
                    ZStack(alignment: .leading) {
                        Text(group.title)
                            .opacity(lifted ? 0 : 1)
                            .offset(x: lifted ? spread : 0)
                        Text(memberTitle)
                            .opacity(lifted ? 1 : 0)
                            .offset(x: spread)
                    }
                    .padding(.trailing, lifted ? spread : 0)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                }
            }
            .clipped()
            .contentShape(.rect)
            .onHover { inside in
                if inside { hover.aim(nil) }
            }
            .onTapGesture {
                hover.drop()
                actions.selectGroup()
            }
    }

    private func select(_ tabID: String) {
        hover.drop()
        actions.selectMember(tabID)
    }

    // MARK: - Keyboard

    /// ⌥1–⌥9 focus the group's Nth pane from anywhere in the window; with the
    /// pill focused, ↓ opens the shelf and the shelf takes ↑↓ ⏎ ⌫ Esc.
    ///
    /// Only keys that name an existing member are taken, so every other ⌥ chord
    /// still reaches the terminal. The monitor is app-wide, so it also lets
    /// through every key aimed at another window (Settings, a sheet) or at
    /// this window while it is not key, and leaves ⌥-digits to a focused text
    /// control (the command palette, a search field, the composer), where
    /// they type characters.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleKey(event) } ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = hostWindow.window,
              event.window === window,
              window.isKeyWindow else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers == .option,
           !(window.firstResponder is NSText),
           let number = WarrenDesktopPaneGroupKeys.memberNumber(keyCode: event.keyCode),
           number <= group.members.count {
            actions.selectMember(group.members[number - 1].id)
            hover.hint()
            return true
        }
        guard modifiers.isEmpty || modifiers == .numericPad else { return false }
        if hover.isKeyboardDriven, hover.phase == .pulled {
            switch event.keyCode {
            case WarrenDesktopPaneGroupKeys.down:
                hover.moveKeyboardAim(in: group.tabIDs, by: 1)
            case WarrenDesktopPaneGroupKeys.up:
                hover.moveKeyboardAim(in: group.tabIDs, by: -1)
            case WarrenDesktopPaneGroupKeys.returnKey, WarrenDesktopPaneGroupKeys.enter:
                if let tabID = hover.hotTabID { select(tabID) }
            case WarrenDesktopPaneGroupKeys.delete:
                if let tabID = hover.hotTabID {
                    hover.drop()
                    actions.closeMember(tabID)
                }
            case WarrenDesktopPaneGroupKeys.escape:
                hover.drop()
            default:
                return false
            }
            return true
        }
        if isFocused, event.keyCode == WarrenDesktopPaneGroupKeys.down {
            hover.openFromKeyboard(aiming: group.currentTabID ?? group.tabIDs.first)
            return true
        }
        return false
    }
}

/// A weak reference to the pill's window, held in `@State` so the key
/// monitor's closure reads the current value without capturing the view.
final class WarrenDesktopPaneGroupWindowBox {
    weak var window: NSWindow?
}

/// Reports the window it is mounted in to a `WarrenDesktopPaneGroupWindowBox`.
private struct WarrenDesktopPaneGroupWindowProbe: NSViewRepresentable {
    let box: WarrenDesktopPaneGroupWindowBox

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.box = box
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.box = box
        box.window = view.window
    }

    final class ProbeView: NSView {
        var box: WarrenDesktopPaneGroupWindowBox?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

enum WarrenDesktopPaneGroupKeys {
    static let up: UInt16 = 126
    static let down: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53

    /// Key codes of the top-row digits 1–9, which stay put whatever ⌥ turns
    /// them into on the active layout.
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func memberNumber(keyCode: UInt16) -> Int? {
        digitKeyCodes.firstIndex(of: keyCode).map { $0 + 1 }
    }
}

/// The control shelf the group pill drops: one row per pane, then Split and
/// Ungroup.
struct WarrenDesktopPaneGroupShelf: View {
    let group: WarrenDesktopPaneGroupPresentation
    let actions: WarrenDesktopPaneGroupActions
    @ObservedObject var hover: WarrenDesktopPaneGroupHover

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: "\(group.members.count) PANES") {
                if !group.context.isEmpty {
                    Text(group.context)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                WarrenDesktopPaneGroupShelfRow(
                    member: member,
                    number: index + 1,
                    isHot: member.id == hover.hotTabID,
                    isCurrent: member.id == group.currentTabID,
                    isZoomed: actions.isZoomed(member.id),
                    hover: hover,
                    actions: actions,
                    scopeKey: group.scopeKey,
                    layoutFrames: group.members.map(\.unitFrame)
                )
            }

            WarrenDesktopMenuDivider()

            HStack(spacing: 2) {
                footerButton(
                    title: "Split",
                    id: "split",
                    isEnabled: group.canSplit,
                    tokens: tokens,
                    action: actions.split
                ) {
                    WarrenDesktopViewBoxGlyph(
                        shape: WarrenDesktopViewBoxShape { path in
                            path.addRoundedRect(
                                in: CGRect(x: 1.5, y: 2.5, width: 13, height: 11),
                                cornerSize: CGSize(width: 2, height: 2)
                            )
                            path.move(to: CGPoint(x: 8, y: 2.5))
                            path.addLine(to: CGPoint(x: 8, y: 13.5))
                        },
                        size: 13,
                        lineWidth: 1.4
                    )
                }
                footerButton(
                    title: "Ungroup",
                    id: "ungroup",
                    isEnabled: true,
                    tokens: tokens,
                    action: actions.ungroup
                ) {
                    WarrenDesktopViewBoxGlyph(
                        shape: WarrenDesktopViewBoxShape { path in
                            path.addRoundedRect(
                                in: CGRect(x: 1.5, y: 2.5, width: 5.5, height: 11),
                                cornerSize: CGSize(width: 1.5, height: 1.5)
                            )
                            path.addRoundedRect(
                                in: CGRect(x: 9, y: 2.5, width: 5.5, height: 11),
                                cornerSize: CGSize(width: 1.5, height: 1.5)
                            )
                        },
                        size: 13,
                        lineWidth: 1.4
                    )
                }
            }
            .padding(.horizontal, 0)
            .padding(.bottom, 0)
        }
        .warrenMenuSurface(width: WarrenLayoutMetrics.tabGroupShelfWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panes in this group")
    }

    private func footerButton<Icon: View>(
        title: String,
        id: String,
        isEnabled: Bool,
        tokens: WarrenColorTokens,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let run = {
            hover.drop()
            action()
        }
        return Button(action: run) {
            HStack(spacing: 6) {
                icon()
                Text(title)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopPaneGroupShelfButtonStyle(cornerRadius: WarrenDesktopMenuMetrics.rowRadius))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .warrenSemanticElement(
            id: "tabgroup.\(group.scopeKey).\(id)",
            role: .button,
            label: title,
            isEnabled: isEnabled,
            action: run
        )
    }
}

private struct WarrenDesktopPaneGroupShelfRow: View {
    let member: WarrenDesktopPaneGroupPresentation.Member
    let number: Int
    let isHot: Bool
    let isCurrent: Bool
    let isZoomed: Bool
    @ObservedObject var hover: WarrenDesktopPaneGroupHover
    let actions: WarrenDesktopPaneGroupActions
    let scopeKey: String
    let layoutFrames: [CGRect]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 10) {
            WarrenDesktopPanePositionGlyph(
                unitFrame: member.unitFrame,
                tokens: tokens,
                allUnitFrames: layoutFrames
            )
            WarrenDesktopSessionKindBadge(icon: member.icon, size: 18)
                .overlay(alignment: .bottomTrailing) {
                    if let mark = member.mark, mark.isDrawn {
                        Circle()
                            .fill(WarrenDesktopStatusDot.color(for: mark, tokens: tokens))
                            .frame(width: 8, height: 8)
                            .background(Circle().fill(tokens.popoverSurface).padding(-2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(member.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? tokens.foreground : tokens.foreground.opacity(0.86))
                    .frame(height: 17)
                if !member.activity.isEmpty {
                    Text(member.activity)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                WarrenDesktopTabDragHandle(
                    tabID: member.id,
                    isEnabled: member.tab.sessionID != nil,
                    onSelect: select,
                    onSplitDrop: actions.splitDrop,
                    onDragStarted: { hover.dragBegan() }
                )
            }

            if isHot {
                HStack(spacing: 2) {
                    actionButton(
                        help: isZoomed ? "Restore Pane" : "Maximize Pane",
                        id: "maximize",
                        tokens: tokens,
                        action: { actions.toggleZoom(member.id) }
                    ) {
                        WarrenDesktopViewBoxGlyph(
                            shape: WarrenDesktopViewBoxShape { path in
                                path.move(to: CGPoint(x: 9.5, y: 2.5))
                                path.addLine(to: CGPoint(x: 13.5, y: 2.5))
                                path.addLine(to: CGPoint(x: 13.5, y: 6.5))
                                path.move(to: CGPoint(x: 6.5, y: 13.5))
                                path.addLine(to: CGPoint(x: 2.5, y: 13.5))
                                path.addLine(to: CGPoint(x: 2.5, y: 9.5))
                                path.move(to: CGPoint(x: 13.5, y: 2.5))
                                path.addLine(to: CGPoint(x: 9, y: 7))
                                path.move(to: CGPoint(x: 2.5, y: 13.5))
                                path.addLine(to: CGPoint(x: 7, y: 9))
                            },
                            size: 12,
                            lineWidth: 1.5,
                            lineCap: .round
                        )
                    }
                    actionButton(
                        help: "Close Pane",
                        id: "close",
                        tokens: tokens,
                        action: {
                            hover.drop()
                            actions.closeMember(member.id)
                        }
                    ) {
                        WarrenDesktopViewBoxGlyph(
                            shape: WarrenDesktopViewBoxShape { path in
                                path.move(to: CGPoint(x: 4, y: 4))
                                path.addLine(to: CGPoint(x: 12, y: 12))
                                path.move(to: CGPoint(x: 12, y: 4))
                                path.addLine(to: CGPoint(x: 4, y: 12))
                            },
                            size: 11,
                            lineWidth: 1.7,
                            lineCap: .round
                        )
                    }
                }
            } else if number <= 9 {
                Text("⌥\(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.treeQuietText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isHot ? tokens.fillHover : (isCurrent ? tokens.fillSelected : .clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { inside in
            if inside { hover.aim(member.id) }
        }
        .warrenContextMenu(actions.contextMenu(member.tab))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(member.title)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .warrenSemanticElement(
            id: "tabgroup.\(scopeKey).row.\(member.id)",
            role: .button,
            label: "Pane \(member.title)",
            value: member.activity,
            isSelected: isCurrent,
            action: select
        )
    }

    private func select() {
        hover.drop()
        actions.selectMember(member.id)
    }

    private func actionButton<Icon: View>(
        help: String,
        id: String,
        tokens: WarrenColorTokens,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopPaneGroupShelfButtonStyle(cornerRadius: 6))
        .warrenTooltip(help)
        .accessibilityLabel(help)
        .warrenSemanticElement(
            id: "tabgroup.\(scopeKey).row.\(member.id).\(id)",
            role: .button,
            label: help,
            action: action
        )
    }
}

/// The shelf's quiet buttons: muted glyph and label, a hover wash.
private struct WarrenDesktopPaneGroupShelfButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        WarrenDesktopPaneGroupShelfButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius
        )
    }
}

private struct WarrenDesktopPaneGroupShelfButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        configuration.label
            .foregroundStyle(isHovered && isEnabled ? tokens.foreground : tokens.mutedForeground)
            .background(
                isHovered && isEnabled ? tokens.fillSelected : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .onHover { isHovered = $0 }
    }
}

/// A pane's place in its layout, as a miniature of the whole arrangement with
/// that pane lit.
struct WarrenDesktopPanePositionGlyph: View {
    let unitFrame: CGRect
    let tokens: WarrenColorTokens
    /// Every pane of the layout, so the miniature draws the whole grid.
    var allUnitFrames: [CGRect] = []

    var body: some View {
        Canvas { context, size in
            let frames = allUnitFrames.isEmpty ? [unitFrame] : allUnitFrames
            for frame in frames {
                let rect = CGRect(
                    x: frame.minX * size.width,
                    y: frame.minY * size.height,
                    width: frame.width * size.width,
                    height: frame.height * size.height
                ).insetBy(dx: 0.75, dy: 0.75)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(
                    path,
                    with: .color(frame == unitFrame ? tokens.foreground.opacity(0.8) : tokens.foreground.opacity(0.12))
                )
            }
        }
        .frame(width: 18, height: 13)
        .accessibilityHidden(true)
    }
}

extension SplitLayoutTree {
    /// Every pane's frame as a share of the whole layout, keyed by Tab.
    func unitFrames() -> [String: CGRect] {
        let side: CGFloat = 1000
        let placement = placement(in: CGSize(width: side, height: side), dividerThickness: 0)
        var frames: [String: CGRect] = [:]
        for pane in placement.panes {
            frames[pane.item.tabID] = CGRect(
                x: pane.frame.minX / side,
                y: pane.frame.minY / side,
                width: pane.frame.width / side,
                height: pane.frame.height / side
            )
        }
        return frames
    }
}

/// Previews the aimed group member on its pane card: the card lights up and
/// its siblings dim.
private struct WarrenDesktopPanePeekModifier: ViewModifier {
    let tabID: String
    @ObservedObject var hover: WarrenDesktopPaneGroupHover

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let peek = hover.peekTabID
        let isPeeked = peek == tabID
        let shape = RoundedRectangle(cornerRadius: WarrenLayoutMetrics.cardRadius, style: .continuous)
        content
            .opacity(peek == nil || isPeeked ? 1 : 0.55)
            .overlay {
                if isPeeked {
                    shape
                        .strokeBorder(tokens.mutedForeground, lineWidth: 1)
                        .background(
                            shape
                                .stroke(tokens.foreground.opacity(0.06), lineWidth: 6)
                        )
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: peek)
    }
}

extension View {
    /// Lights this pane when its group member is aimed at in the top bar.
    @ViewBuilder
    func warrenPanePeek(tabID: String, hover: WarrenDesktopPaneGroupHover?) -> some View {
        if let hover {
            modifier(WarrenDesktopPanePeekModifier(tabID: tabID, hover: hover))
        } else {
            self
        }
    }
}

/// Places the shelf under the group pill, with the invisible bridge between
/// them that keeps a pointer moving down from dropping the shelf.
struct WarrenDesktopPaneGroupShelfLayer: View {
    let group: WarrenDesktopPaneGroupPresentation
    let actions: WarrenDesktopPaneGroupActions
    @ObservedObject var hover: WarrenDesktopPaneGroupHover

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From the pill's bottom edge to the shelf: the rest of the bar, then the
    /// shelf's own gap below it.
    private static let bridgeHeight = (WarrenLayoutMetrics.tabBarHeight - WarrenLayoutMetrics.tabPillHeight) / 2
        + WarrenLayoutMetrics.tabGroupShelfGap

    var body: some View {
        ZStack(alignment: .topLeading) {
            if hover.phase == .pulled {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(width: WarrenLayoutMetrics.tabGroupPillWidth, height: Self.bridgeHeight)
                        .contentShape(.rect)
                    WarrenDesktopPaneGroupShelf(group: group, actions: actions, hover: hover)
                }
                .onHover { hover.shelfHover($0) }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .offset(y: -6))
                )
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.22, dampingFraction: 0.7),
            value: hover.phase == .pulled
        )
        .fixedSize()
        .offset(y: WarrenLayoutMetrics.tabPillHeight)
    }
}
