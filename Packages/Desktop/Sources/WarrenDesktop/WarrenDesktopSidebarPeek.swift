import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// Which sidebar a card is drawing.
enum WarrenDesktopSidebarPresentation: Equatable, Sendable {
    /// The real column beside the content. Collapsing removes it.
    case docked
    /// The floating copy laid over the content while the sidebar is collapsed.
    case peek
}

/// The one attention dot the collapsed sidebar button can carry.
///
/// The dot is a request, not a heartbeat: a failure and the actionable tier
/// draw, while `working` and `ready` never do. Otherwise the dot would be lit
/// almost always and stop meaning anything. The Session the person is already
/// looking at is excluded first, by `unattended`.
enum WarrenDesktopSidebarAttention {
    /// Diameter from the collapsed design.
    static let dotSize: CGFloat = 7

    /// The Sessions the person is not already looking at: every Session
    /// except the current Tab's. The dot and the approval tray both start from
    /// this population, so the tray never lists a request the dot ignores.
    static func unattended(
        _ sessions: [WarrenDesktopSession],
        selectedTabID: String?
    ) -> [WarrenDesktopSession] {
        sessions.filter { $0.tabID != selectedTabID }
    }

    /// The unattended Sessions an Agent has stopped for until a person
    /// answers. The mark is the same `activityMark` the sidebar dot draws.
    static func waiting(
        _ sessions: [WarrenDesktopSession],
        selectedTabID: String?
    ) -> [WarrenDesktopSession] {
        unattended(sessions, selectedTabID: selectedTabID)
            .filter { $0.activityMark?.isWaitingOnPerson == true }
    }

    /// The highest-priority badge among `marks`, or `nil` when nothing needs a
    /// person. `WarrenActivityMark` orders failures above every request, so a
    /// plain `max()` is the priority rule.
    static func mark(among marks: [WarrenActivityMark?]) -> WarrenActivityMark? {
        marks
            .compactMap { $0 }
            .filter(draws)
            .max()
    }

    /// Whether a mark draws the badge at all.
    static func draws(_ mark: WarrenActivityMark) -> Bool {
        mark.tier == .actionable
    }
}

/// Schedules the one delayed action the peek gesture is waiting on.
///
/// The controller replaces any pending action when a new region is entered, so
/// at most one timer is ever live. The protocol exists so the timing state
/// machine can be tested without sleeping.
@MainActor
protocol WarrenDesktopSidebarPeekClock: AnyObject {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void)
    func cancelPending()
}

/// The production clock: one cancellable `Task` per pending action.
@MainActor
final class WarrenDesktopSidebarPeekTaskClock: WarrenDesktopSidebarPeekClock {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancelPending() {
        task?.cancel()
        task = nil
    }
}

/// When the collapsed sidebar floats open, and when it goes away again.
///
/// The whole gesture lives here — the dwell before a reveal, the grace period
/// before a hide, the Esc suppression — so the views only report where the
/// pointer is and the keyboard asked for what. A peek is only possible while
/// the sidebar is collapsed and the window holds the keyboard.
@MainActor
final class WarrenDesktopSidebarPeekController: ObservableObject {
    /// Where the pointer is, as far as the gesture cares.
    enum Region: Hashable {
        case sidebarButton
        case edge
        case panel
    }

    struct Delays: Equatable {
        /// Dwell before hovering the button or brushing the edge reveals.
        var reveal: Duration = .milliseconds(250)
        /// Grace after the pointer leaves before the panel hides.
        var hide: Duration = .milliseconds(300)
    }

    @Published private(set) var isPeeking = false

    private let clock: WarrenDesktopSidebarPeekClock
    private let delays: Delays
    private var isCollapsed = false
    private var isWindowKey = true
    private var regions: Set<Region> = []
    /// An Esc dismissal holds until the pointer leaves every region, so the
    /// reveal does not immediately re-arm under a pointer that never moved.
    private var isDismissedUntilPointerLeaves = false

    init(
        clock: WarrenDesktopSidebarPeekClock = WarrenDesktopSidebarPeekTaskClock(),
        delays: Delays = Delays()
    ) {
        self.clock = clock
        self.delays = delays
    }

    /// The sidebar's collapsed state. Expanding retires any peek.
    func setCollapsed(_ isCollapsed: Bool) {
        guard self.isCollapsed != isCollapsed else { return }
        self.isCollapsed = isCollapsed
        if isCollapsed {
            armRevealIfPointerInside()
        } else {
            hide()
        }
    }

    /// Whether this window holds the keyboard. A background window must not pop
    /// its sidebar open when the pointer crosses it.
    func setWindowKey(_ isWindowKey: Bool) {
        guard self.isWindowKey != isWindowKey else { return }
        self.isWindowKey = isWindowKey
        if isWindowKey {
            armRevealIfPointerInside()
        } else {
            hide()
        }
    }

    /// Reports the pointer entering or leaving one of the gesture's regions.
    func setPointer(_ region: Region, isInside: Bool) {
        let wasInside = !regions.isEmpty
        if isInside {
            regions.insert(region)
        } else {
            regions.remove(region)
        }
        let isInsideAny = !regions.isEmpty
        clock.cancelPending()
        if isInsideAny {
            if !wasInside { isDismissedUntilPointerLeaves = false }
            armRevealIfEligible()
        } else {
            isDismissedUntilPointerLeaves = false
            guard isPeeking else { return }
            clock.schedule(after: delays.hide) { [weak self] in
                self?.hideIfPointerStillOutside()
            }
        }
    }

    /// `⌃⌘S`: reveal now, with no dwell.
    func show() {
        clock.cancelPending()
        guard isEligible else { return }
        isDismissedUntilPointerLeaves = false
        isPeeking = true
    }

    /// `Esc`, or picking a Session: hide now. A selection does not suppress,
    /// because the pointer is expected to leave with the row it clicked.
    func dismiss(suppressingUntilPointerLeaves: Bool = false) {
        clock.cancelPending()
        if suppressingUntilPointerLeaves, !regions.isEmpty {
            isDismissedUntilPointerLeaves = true
        }
        isPeeking = false
    }

    /// The peek only exists over a collapsed sidebar in the key window.
    private var isEligible: Bool {
        isCollapsed && isWindowKey
    }

    private func armRevealIfPointerInside() {
        guard !regions.isEmpty else { return }
        armRevealIfEligible()
    }

    private func armRevealIfEligible() {
        guard isEligible, !isPeeking, !isDismissedUntilPointerLeaves else { return }
        clock.schedule(after: delays.reveal) { [weak self] in
            self?.revealIfEligible()
        }
    }

    private func revealIfEligible() {
        guard isEligible, !regions.isEmpty, !isDismissedUntilPointerLeaves else { return }
        isPeeking = true
    }

    private func hideIfPointerStillOutside() {
        guard regions.isEmpty else { return }
        isPeeking = false
    }

    private func hide() {
        clock.cancelPending()
        isDismissedUntilPointerLeaves = false
        isPeeking = false
    }
}

/// The collapsed sidebar button's attention dot.
///
/// The hue comes from the same `WarrenActivityMark` palette as the sidebar's
/// own status dots, so the dot and the row it stands for cannot disagree. The
/// ring separates it from the glyph underneath on either chrome surface.
struct WarrenDesktopSidebarAttentionDot: View {
    let mark: WarrenActivityMark

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let size = WarrenDesktopSidebarAttention.dotSize
        Circle()
            .fill(mark.color(tokens))
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(tokens.windowBackdrop, lineWidth: 2)
            }
            .offset(x: 3, y: -3)
            .accessibilityHidden(true)
    }
}

/// The invisible strip along the window's leading edge that reveals the
/// collapsed sidebar. It is only the pointer target; the controller owns the
/// dwell, so the edge and the button feel the same.
struct WarrenDesktopSidebarPeekEdge: View {
    static let width: CGFloat = 6

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

extension WarrenDesktopAction {
    /// Whether this action means the person picked something in the sidebar,
    /// which is the peek's cue to get out of the way.
    var dismissesSidebarPeek: Bool {
        switch self {
        case .openSession, .selectWorkspace, .selectProject:
            true
        default:
            false
        }
    }
}

extension WarrenDesktopCommand {
    /// Posted by the View menu (`⌃⌘S`) to reveal the collapsed sidebar
    /// without waiting out the hover dwell.
    public static let peekSidebar = Notification.Name("WarrenDesktopCommand.peekSidebar")
}
