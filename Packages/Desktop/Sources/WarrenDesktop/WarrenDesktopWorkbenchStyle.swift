import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// The Workbench's shared look: a dark window backdrop with rounded cards on
/// it, and a sidebar tree whose rows share one set of measurements.
///
/// Every row in the tree draws through the pieces here, so a project, a task,
/// a worktree and a Session stay on one grid and one palette.
enum WarrenDesktopSidebarMetrics {
    /// Inset of the tree from the sidebar card's edges.
    static let contentHorizontalInset: CGFloat = 8
    static let contentVerticalInset: CGFloat = 10
    /// Between one section (Tasks, Projects) and the next.
    static let sectionSpacing: CGFloat = 18
    /// Between a section heading and its first group.
    static let sectionHeaderSpacing: CGFloat = 8
    /// Between two groups of one section, on each side of the hairline that
    /// divides them.
    static let groupSpacing: CGFloat = 10
    /// Above and below a folded group, so two folded neighbours sit 2pt apart.
    static let foldedGroupInset: CGFloat = 1
    /// Between a group row and its first worktree.
    static let groupContentSpacing: CGFloat = 4
    /// Between two worktrees of one group.
    static let worktreeSpacing: CGFloat = 6
    /// Between a worktree row and its Sessions, and between two Sessions.
    static let sessionSpacing: CGFloat = 1

    static let sectionHeaderHeight: CGFloat = 20
    static let groupRowHeight: CGFloat = 30
    static let worktreeRowHeight: CGFloat = 24
    /// A worktree with no Session, listed under its project's idle row.
    static let idleWorktreeRowHeight: CGFloat = 22
    /// The row that folds a section's inactive projects away.
    static let inactiveProjectsRowHeight: CGFloat = 28
    /// One inactive project in that row's list.
    static let inactiveProjectRowHeight: CGFloat = 26
    static let inactiveProjectIconSize: CGFloat = 14
    static let inactiveProjectIconOpacity: Double = 0.75
    /// Between the inactive-projects row and its list.
    static let inactiveProjectListSpacing: CGFloat = 2
    /// Inner horizontal padding every row shares, so all leading icons sit on
    /// one column.
    static let rowHorizontalPadding: CGFloat = 8
    static let rowRadius: CGFloat = 6

    static let groupIconSize: CGFloat = 18
    static let groupIconSpacing: CGFloat = 8
    static let worktreeIconSize: CGFloat = 11
    static let worktreeIconSpacing: CGFloat = 6

    static let sessionIconSize: CGFloat = 18
    static let sessionIconSpacing: CGFloat = 10
    static let sessionVerticalPadding: CGFloat = 6
    /// A Session row's second line, the same height whether it is drawing the
    /// activity now or the last one.
    static let sessionActivityLineHeight: CGFloat = 15
    /// Every Session row is two lines, so a Workspace's Sessions keep one
    /// rhythm down the rail whether they are working, resting, or new.
    static let sessionRowHeight: CGFloat = sessionVerticalPadding * 2
        + sessionIconSize + sessionLineSpacing + sessionActivityLineHeight
    static let sessionRadius: CGFloat = 8
    static let sessionLineSpacing: CGFloat = 2
    static let sessionDotSize: CGFloat = 8
    static let sessionDotOffset: CGFloat = 3
    /// How much of an overflowing line fades out at its trailing end.
    static let sessionLineFadeWidth: CGFloat = 28

    static let foldDotSize: CGFloat = 6
    static let foldDotSpacing: CGFloat = 4
    static let maximumFoldDots = 6
    static let chevronSize: CGFloat = 10

    static let headerTrafficRowHeight: CGFloat = 30
    static let headerHostRowHeight: CGFloat = 44
    static let hostTileSize: CGFloat = 26
    static let footerHeight: CGFloat = 40
}

extension WarrenColorTokens {
    /// The fill of every card on the window backdrop: the sidebar, the pane
    /// cards and the top row's capsules.
    ///
    /// Opaque under both materials. Glass clears the region fills so the
    /// window's coat shows through, which under cards left nothing but a
    /// hairline between a card and the gutter beside it, and the whole window
    /// read as one flat sheet. The cards stay the terminal's own ground; the
    /// coat shows in the gutters.
    var workbenchCardFill: Color { background }
    /// Group names: projects and tasks. The loudest label in
    /// the tree, because a group is the name a person gave it.
    var treeGroupText: Color { foreground }
    /// A Session's title, the loudest line in the tree after a selection.
    var treeSessionText: Color { foreground.opacity(0.84) }
    var treeSessionSelectedText: Color { foreground.opacity(0.96) }
    /// Worktree names and a Session's activity line.
    var treeSecondaryText: Color { sidebarLeafText }
    /// The high point of a working row's activity line.
    ///
    /// Only the shimmer uses it: light moving across the line has to be visible
    /// on it, and this stays below the title so a working row never outranks
    /// the name of the thing it is working on.
    var treeActivityHighlightText: Color { sidebarTextBase.opacity(0.95) }
    /// Section headings, task IDs and other quiet labels.
    var treeQuietText: Color { sidebarSectionText }
    var treeChevron: Color { sidebarSectionText.opacity(0.75) }
    /// Below the quiet tier: a dimmed branch prefix under a quiet name, and
    /// the age beside an idle row.
    var treeFaintText: Color { sidebarSectionText.opacity(0.66) }
    var treeGroupIcon: Color { foreground.opacity(0.62) }
    var treeRowHover: Color { foreground.opacity(0.05) }
    var treeRowSelected: Color { foreground.opacity(0.08) }
    /// The selected Tab's pill. Opaque, so a badge's ring can match it.
    var selectedTabPillFill: Color {
        material == .glass ? foreground.opacity(0.10) : sidebarSelectedPill
    }
    private var sidebarSelectedPill: Color { muted }
}

/// Group names, and the branch names of the worktrees under them. A group is a
/// name a person chose, so it is proportional and bold; a worktree is a git
/// branch, so it is monospaced and regular.
enum WarrenDesktopTreeTypography {
    static let groupName = Font.system(size: 13.5, weight: .semibold)
    static let branchName = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    /// "N idle worktrees" and "N inactive projects".
    static let foldedCount = Font.system(size: 12, weight: .regular)
    static let foldedCountNumber = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let inactiveProjectName = Font.system(size: 12.5, weight: .regular)
    /// The last-activity age at the end of an idle row.
    static let age = Font.system(size: 11, weight: .regular).monospacedDigit()
}

/// The room around one group of a section: a hairline with a gap on each side
/// of it frames a group that is open, while a run of folded groups packs into
/// a compact list.
///
/// A folded group is its one 30pt row with 1pt above and below, so two folded
/// neighbours sit 2pt apart with no hairline. Wherever an open group meets a
/// neighbour, the hairline and its gaps divide them. The first group of a
/// section draws no hairline.
struct WarrenDesktopTreeGroupSeparator: ViewModifier {
    let isFirst: Bool
    var isFolded = false
    var followsFolded = false
    var isLast = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                if isFolded && followsFolded {
                    Color.clear
                        .frame(height: 2 * WarrenDesktopSidebarMetrics.foldedGroupInset)
                        .accessibilityHidden(true)
                } else {
                    Rectangle()
                        .fill(tokens.cardBorder)
                        .frame(height: 1)
                        .padding(.vertical, WarrenDesktopSidebarMetrics.groupSpacing)
                        .accessibilityHidden(true)
                }
            } else if isFolded {
                Color.clear
                    .frame(height: WarrenDesktopSidebarMetrics.foldedGroupInset)
                    .accessibilityHidden(true)
            }
            content
            if isLast && isFolded {
                Color.clear
                    .frame(height: WarrenDesktopSidebarMetrics.foldedGroupInset)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func warrenTreeGroupSeparator(
        isFirst: Bool,
        isFolded: Bool = false,
        followsFolded: Bool = false,
        isLast: Bool = false
    ) -> some View {
        modifier(WarrenDesktopTreeGroupSeparator(
            isFirst: isFirst,
            isFolded: isFolded,
            followsFolded: followsFolded,
            isLast: isLast
        ))
    }

    /// The separator for `item` among a section's `items`.
    ///
    /// `isFollowed` says another group comes after `items`, as the
    /// inactive-projects row follows the projects above it.
    func warrenTreeGroupSeparator<Item: Identifiable>(
        of item: Item,
        in items: [Item],
        isFollowed: Bool = false,
        isFolded: (Item) -> Bool
    ) -> some View {
        let neighbours = WarrenDesktopTreeGroupNeighbours(of: item, in: items, isFolded: isFolded)
        return warrenTreeGroupSeparator(
            isFirst: neighbours.isFirst,
            isFolded: isFolded(item),
            followsFolded: neighbours.followsFolded,
            isLast: neighbours.isLast && !isFollowed
        )
    }
}

/// Where one group sits among its section's groups, for its separator.
struct WarrenDesktopTreeGroupNeighbours {
    let isFirst: Bool
    let followsFolded: Bool
    let isLast: Bool

    init<Item: Identifiable>(of item: Item, in items: [Item], isFolded: (Item) -> Bool) {
        let index = items.firstIndex { $0.id == item.id }
        isFirst = index == nil || index == items.startIndex
        if let index, index > items.startIndex {
            followsFolded = isFolded(items[items.index(before: index)])
        } else {
            followsFolded = false
        }
        isLast = index == nil || index == items.index(before: items.endIndex)
    }
}

/// The disclosure chevron at the trailing edge of every foldable row: pointing
/// down while open, turned a quarter to the left while folded.
struct WarrenDesktopTreeChevron: View {
    let isExpanded: Bool
    var color: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color ?? tokens.treeChevron)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .animation(
                WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion),
                value: isExpanded
            )
            .frame(
                width: WarrenDesktopSidebarMetrics.chevronSize,
                height: WarrenDesktopSidebarMetrics.chevronSize
            )
            .accessibilityHidden(true)
    }
}

/// One dot per Session with a state, drawn by a folded row so those states
/// stay in sight. Status lives in the dot's colour and nothing else; an idle
/// Session draws nothing and holds no room.
struct WarrenDesktopTreeFoldDots: View {
    let marks: [WarrenActivityMark?]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: WarrenDesktopSidebarMetrics.foldDotSpacing) {
            ForEach(Array(visibleMarks.enumerated()), id: \.offset) { _, mark in
                WarrenDesktopStatusDot(
                    mark: mark,
                    size: WarrenDesktopSidebarMetrics.foldDotSize,
                    ring: nil,
                    tokens: tokens
                )
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var visibleMarks: [WarrenActivityMark] {
        Self.visibleMarks(of: marks)
    }

    /// The marks a folded row draws: only Sessions with a state, capped so
    /// the dots still read as individual Sessions.
    static func visibleMarks(of marks: [WarrenActivityMark?]) -> [WarrenActivityMark] {
        Array(
            marks.compactMap { $0?.isDrawn == true ? $0 : nil }
                .prefix(WarrenDesktopSidebarMetrics.maximumFoldDots)
        )
    }

    /// Whether a folded row with these marks draws any dot.
    static func drawsAny(_ marks: [WarrenActivityMark?]) -> Bool {
        marks.contains { $0?.isDrawn == true }
    }
}

/// A Session's status as one dot.
///
/// A Session with no drawn state is idle and draws nothing, ring included.
struct WarrenDesktopStatusDot: View {
    let mark: WarrenActivityMark?
    let size: CGFloat
    /// The surface the dot sits on, drawn as a ring around it so the dot reads
    /// as attached to an icon's corner. `nil` draws no ring.
    let ring: Color?
    let tokens: WarrenColorTokens
    /// A translucent wash over the ring, for a dot on a hovered or selected
    /// row whose fill is itself a wash over the surface.
    var ringTint: Color? = nil

    var body: some View {
        if let drawn = mark.flatMap({ $0.isDrawn ? $0 : nil }) {
            ZStack {
                if let ring {
                    Circle()
                        .fill(ring)
                        .frame(width: size + 4, height: size + 4)
                    if let ringTint {
                        Circle()
                            .fill(ringTint)
                            .frame(width: size + 4, height: size + 4)
                    }
                }
                // The shared indicator, so `working` pulses here exactly as it
                // does through `WarrenActivityMarkView`: one quiet,
                // compositor-driven ring, and only for the live tier. Its slot
                // is wider than the dot; the frame below keeps the layout at
                // the dot's own size and lets the ring overflow.
                WarrenStatusIndicator(
                    color: Self.color(for: drawn, tokens: tokens),
                    isActive: drawn.isAnimated,
                    size: size,
                    intensity: .quiet,
                    accessibilityLabel: drawn.accessibilityLabel
                )
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// The Desktop's one dot palette: green while an Agent works, Ember orange
    /// when it wants a person, red on failure, blue once it is done.
    ///
    /// `WarrenActivityMark.color` forwards here, so every surface that draws a
    /// mark — tree, tabs, tray, palette, peek — agrees on the hue.
    nonisolated static func color(for mark: WarrenActivityMark, tokens: WarrenColorTokens) -> Color {
        switch mark {
        case .failed: tokens.destructive
        case .approvalNeeded, .inputNeeded, .attentionUnspecified: tokens.highlight
        case .working: tokens.success
        case .ready: tokens.info
        case .exited: tokens.treeQuietText
        }
    }
}

/// Whether a Host answers, as the dot on its tile's corner.
///
/// One rule for every Host tile: green while reachable, red when it is not,
/// the info hue while a connection is being made. A Host nothing has probed
/// yet has no value here and draws no dot.
enum WarrenDesktopHostReachability: Equatable, Sendable {
    case reachable
    case connecting
    case unreachable

    init(_ state: WarrenDesktopConnectionState) {
        switch state {
        case .attached: self = .reachable
        case .connecting, .reconnecting: self = .connecting
        case .disconnected, .failed: self = .unreachable
        }
    }

    init(isOnline: Bool) {
        self = isOnline ? .reachable : .unreachable
    }

    func color(_ tokens: WarrenColorTokens) -> Color {
        switch self {
        case .reachable: tokens.success
        case .connecting: tokens.info
        case .unreachable: tokens.destructive
        }
    }
}

/// A Host's lettered tile: the name's lowercase initial in the monospaced
/// face on a neutral square, with its reachability on the corner.
///
/// The sidebar's Host row and the collapsed rail's Host button draw this one
/// view, so the Host reads the same whether the sidebar is open or not. A
/// project wears a filled colour square with a bold capital, so the two
/// never read as one another.
struct WarrenDesktopHostInitialTile: View {
    let name: String
    let size: CGFloat
    /// `nil` draws no dot.
    let reachability: WarrenDesktopHostReachability?
    /// The surface under the tile, drawn as a ring around the dot.
    var surface: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    static func initial(of name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).lowercased()
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let dotSize: CGFloat = size >= 24 ? 8 : 6
        Text(Self.initial(of: name))
            .font(.system(size: (size * 0.55).rounded(), weight: .medium, design: .monospaced))
            .foregroundStyle(tokens.foreground.opacity(0.8))
            .frame(width: size, height: size)
            .background(
                tokens.foreground.opacity(0.07),
                in: RoundedRectangle(cornerRadius: (size * 0.27).rounded(), style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                if let reachability {
                    Circle()
                        .fill(reachability.color(tokens))
                        .frame(width: dotSize, height: dotSize)
                        .padding(dotSize >= 8 ? 2 : 1.5)
                        .background(surface ?? tokens.workbenchCardFill, in: Circle())
                        .offset(x: dotSize / 2, y: dotSize / 2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A project's lettered avatar in a stable identity colour.
///
/// The tile is a wash of that colour with the letter in it. A Session's app
/// icon is a solid tile with a white mark, so solid reads as a program and
/// the tinted tile as the container it lives in.
struct WarrenDesktopProjectAvatar: View {
    let name: String
    let identity: String
    var size: CGFloat = WarrenDesktopSidebarMetrics.groupIconSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let tint = Self.tint(for: identity, in: tokens)
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(colorScheme == .dark ? 0.18 : 0.14),
                in: RoundedRectangle(cornerRadius: size * 5 / 18, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// The identity palette indexed by a stable hash of the project's ID, so a
    /// project keeps its colour across launches and reorderings.
    static func tint(for identity: String, in tokens: WarrenColorTokens) -> Color {
        let palette = tokens.hostSectionTints
        guard !palette.isEmpty else { return tokens.muted }
        return palette[stableIndex(for: identity, count: palette.count)]
    }

    static func stableIndex(for identity: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

/// A Session's app icon: its brand's mark in white on a tile of the brand's
/// colour, the badge every Session wears in the tree, on its Tab, and in its
/// pane header.
///
/// Every badge is the same tile whatever it holds, so a row of mixed Agents
/// and programs reads as one row of app icons.
struct WarrenDesktopSessionKindBadge: View {
    let icon: WarrenDesktopAppIcon
    var size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize

    init(icon: WarrenDesktopAppIcon, size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize) {
        self.icon = icon
        self.size = size
    }

    init(kind: TerminalSessionKind, size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize) {
        self.init(icon: WarrenDesktopAppIcon(kind: kind), size: size)
    }

    init(session: WarrenDesktopSession, size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize) {
        self.init(icon: WarrenDesktopAppIcon.resolve(session), size: size)
    }

    /// The mark's share of the tile. Simple Icons and LobeHub marks both fill
    /// their 24pt canvas edge to edge, so one ratio sizes them alike.
    static let glyphRatio: CGFloat = 0.62
    static let cornerRatio: CGFloat = 0.27

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
        shape
            .fill(icon.tileColor)
            .overlay { glyph }
            // Keeps a near-black tile's edge on the dark card.
            .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        let side = size * Self.glyphRatio
        if let name = icon.resourceName,
           let image = WarrenPresetIconCache.shared.image(named: name, template: icon.drawsWhiteGlyph) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
                .frame(width: side, height: side)
        } else if case .browser = icon {
            Image(systemName: "globe")
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(Color.white)
        } else {
            Text(String(icon.displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(Color.white)
        }
    }
}

/// A rounded card on the window backdrop.
struct WarrenDesktopCardModifier: ViewModifier {
    var isFocused = false
    var fill: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(
            cornerRadius: WarrenLayoutMetrics.cardRadius,
            style: .continuous
        )
        content
            .background(fill ?? tokens.workbenchCardFill)
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(
                        isFocused ? tokens.cardBorderFocused : tokens.cardBorder,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func warrenCard(isFocused: Bool = false, fill: Color? = nil) -> some View {
        modifier(WarrenDesktopCardModifier(isFocused: isFocused, fill: fill))
    }
}

/// A capsule of small controls in the top row: the Tabs, or the panels and "+"
/// buttons.
struct WarrenDesktopChromeCapsule<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(
            cornerRadius: WarrenLayoutMetrics.tabCapsuleRadius,
            style: .continuous
        )
        content
            .padding(WarrenLayoutMetrics.tabCapsulePadding)
            .frame(height: WarrenLayoutMetrics.tabBarHeight)
            .background(tokens.workbenchCardFill, in: shape)
            .overlay {
                shape
                    .strokeBorder(tokens.cardBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
