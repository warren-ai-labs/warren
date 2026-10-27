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
    /// Inset of the tree from the sidebar card's edges. The top inset is the
    /// gap under the tab bar's hairline.
    static let contentHorizontalInset: CGFloat = 8
    static let contentVerticalInset: CGFloat = 10
    /// The tree's gaps, each wider than the one inside it: 0 between
    /// Sessions, 6 between worktrees (0 between two with no Session), 14
    /// between groups. No hairline divides groups; the gap does.
    ///
    /// Between Tasks and the Host sections, where both are listed.
    static let sectionSpacing: CGFloat = 28
    /// Between a section heading and its first group.
    static let sectionHeaderSpacing: CGFloat = 6
    /// Between two groups of one list, and from the last project to the
    /// inactive-projects row.
    static let groupSpacing: CGFloat = 20
    /// Above and below a folded group, so two folded neighbours sit 2pt apart.
    static let foldedGroupInset: CGFloat = 1
    /// Between a group row and its first worktree: the rows' heights carry it.
    static let groupContentSpacing: CGFloat = 0
    /// Between two worktrees of one group when either lists Sessions. Two
    /// worktrees with none pack with no gap, so a group of idle branches
    /// reads as one short list rather than a column of islands.
    static let worktreeSpacing: CGFloat = 10
    /// Between one-line summary rows (a folded worktree, an empty one, the
    /// idle row), which read together as one list.
    static let summarySpacing: CGFloat = 2
    /// A one-line summary row's height.
    static let summaryRowHeight: CGFloat = 22
    /// Between a worktree row and its Sessions, and between two Sessions:
    /// the rows' own padding is the gap.
    static let sessionSpacing: CGFloat = 0

    static let sectionHeaderHeight: CGFloat = 20
    /// The Projects / Tasks tab bar, and the gap under its hairline.
    static let tabBarHeight: CGFloat = 30
    static let groupRowHeight: CGFloat = 30
    static let worktreeRowHeight: CGFloat = 24
    /// A worktree with no Session, listed under its project's idle row.
    static let idleWorktreeRowHeight: CGFloat = 22
    /// The row that folds a section's inactive projects away, and each row
    /// of its list.
    static let inactiveProjectsRowHeight: CGFloat = 26
    static let inactiveProjectRowHeight: CGFloat = 26
    static let inactiveProjectIconSize: CGFloat = 14
    static let inactiveProjectIconOpacity: Double = 1
    /// How far each avatar in the inactive row's stack tucks under the one
    /// before it, and how many it shows.
    static let inactiveStackOverlap: CGFloat = 4
    static let inactiveStackCount = 3
    /// Between the inactive-projects row and its list.
    static let inactiveProjectListSpacing: CGFloat = 0
    /// Inner horizontal padding every row shares, so all leading icons sit on
    /// one column.
    static let rowHorizontalPadding: CGFloat = 8
    static let rowRadius: CGFloat = 7
    /// Every row's leading icon sits centred in this column, and its text
    /// starts the same gap after it: at 34pt into the row, at every level.
    static let iconColumnWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8

    static let groupIconSize: CGFloat = 18
    static let groupIconSpacing: CGFloat = iconTextSpacing
    static let worktreeIconSize: CGFloat = 12
    /// A Task worktree's project tile, in the icon column.
    static let worktreeProjectTileSize: CGFloat = 12
    static let worktreeProjectTileRadius: CGFloat = 3.5
    static let worktreeIconSpacing: CGFloat = iconTextSpacing

    static let sessionIconSize: CGFloat = 16
    static let sessionIconSpacing: CGFloat = iconTextSpacing
    static let sessionVerticalPadding: CGFloat = 6
    /// A Session row's second line, the same height whether it is drawing the
    /// activity now or the last one.
    static let sessionActivityLineHeight: CGFloat = 15
    /// An Agent Session is always two lines and a shell always one, so rows
    /// keep their height whatever their state; state changes only colour.
    static let sessionRowHeight: CGFloat = sessionVerticalPadding * 2
        + sessionIconSize + sessionLineSpacing + sessionActivityLineHeight
    static let shellRowHeight: CGFloat = sessionVerticalPadding * 2 + sessionIconSize
    static let sessionRadius: CGFloat = 7
    static let sessionLineSpacing: CGFloat = 1
    static let sessionDotSize: CGFloat = 8
    static let sessionDotOffset: CGFloat = 3
    /// How much of an overflowing line fades out at its trailing end.
    static let sessionLineFadeWidth: CGFloat = 24

    static let foldDotSize: CGFloat = 6
    static let foldDotSpacing: CGFloat = 3
    static let maximumFoldDots = 6
    /// The trailing chevron's column. Every foldable row draws its chevron in
    /// this width, so fold summaries and chevrons line up down the tree.
    static let chevronSize: CGFloat = 14

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
    /// Group names: projects and tasks, the loudest label in the tree,
    /// because a group is the name a person gave it.
    var treeGroupText: Color { sidebarInk.t1 }
    /// A live Session's title: working, waiting on a person, failed, or done
    /// and not yet looked at.
    var treeSessionText: Color { sidebarInk.t2 }
    /// A resting Session's title, a step down from a live one so the rows
    /// that want something stand out of a long list.
    var treeSessionRestingText: Color { sidebarInk.t3 }
    var treeSessionSelectedText: Color { sidebarInk.t1 }
    /// Branch names, a live second line, labels a step under a title.
    var treeSecondaryText: Color { sidebarInk.t4 }
    /// The high point of a working row's activity line, the live title's ink,
    /// so light moving across the line is visible without outranking it.
    var treeActivityHighlightText: Color { sidebarInk.t2 }
    /// Labels that name rather than say: the idle and inactive rows' words.
    var treeQuietText: Color { sidebarInk.t4 }
    var treeChevron: Color { sidebarInk.t5 }
    /// The quietest tier: times, counts, a branch's prefix, glyphs, a
    /// resting Session's second line.
    var treeFaintText: Color { sidebarInk.t5 }
    /// A branch name sits a step under the Session lines it heads: the rows
    /// carry the content, the branch only says which checkout they are in.
    var treeBranchText: Color { sidebarInk.branch }
    /// The branch's `release/…/` prefix, one more step down.
    var treeBranchPrefixText: Color { sidebarInk.branch.opacity(0.7) }
    var treeGroupIcon: Color { sidebarInk.t5 }
    var treeRowHover: Color { sidebarInk.hover }
    var treeRowSelected: Color { sidebarInk.selected }
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
    static let groupNameSize: CGFloat = 13.5
    /// Chinese characters fill their em box, so at the Latin size a Chinese
    /// run reads a step larger than an English one beside it. Every mixed
    /// line in the tree draws its wide runs half a point down.
    static let groupNameWideSize: CGFloat = 13
    static let groupName = Font.system(size: groupNameSize, weight: .semibold)
    static let groupNameWide = Font.system(size: groupNameWideSize, weight: .semibold)
    /// A Session's title, the group name's size in regular weight.
    static let sessionTitle = Font.system(size: 13, weight: .regular)
    static let sessionTitleWide = Font.system(size: 12.5, weight: .regular)
    /// A branch name: a git ref, so monospaced. Its Chinese runs keep the
    /// proportional face, a step down, since a monospaced CJK run is uneven.
    static let branchName = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let branchNameWide = Font.system(size: 10.5, weight: .regular)
    /// The project a Task's worktree belongs to, ahead of its branch.
    static let worktreeProjectName = Font.system(size: 12, weight: .medium)
    /// "N idle worktrees" and "N inactive projects": the words in SF Pro,
    /// the count in SF Mono.
    static let foldedCount = Font.system(size: 11.5, weight: .regular)
    static let foldedCountNumber = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let inactiveProjectName = Font.system(size: 12.5, weight: .regular)
    /// Times and counts: SF Mono, so a column of them lines up.
    static let age = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let count = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    /// The Projects / Tasks tabs, and the count after each.
    static let tabTitle = Font.system(size: 13, weight: .medium)
    static let tabTitleSelected = Font.system(size: 13, weight: .semibold)
    static let tabCount = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// The `⌘T` hint on the Task worktree a new Session opens in.
    static let keyHint = Font.system(size: 10, weight: .medium, design: .monospaced)
    /// A section heading where one remains: the multi-Host "Projects · Hosts".
    static let sectionTitle = Font.system(size: 11.5, weight: .semibold)
    static let sectionCount = Font.system(size: 11, weight: .medium).monospacedDigit()

    /// A project or task name drawn script by script, so a Chinese name and an
    /// English one share one optical size on their rows.
    static func groupNameText(_ name: String) -> Text {
        scriptText(name, latin: groupName, wide: groupNameWide)
    }

    /// `text` drawn script by script in `latin` and `wide`, so a Chinese run
    /// and a Latin one share one optical size.
    static func scriptText(_ text: String, latin: Font, wide: Font) -> Text {
        var result: Text?
        for run in scriptRuns(text) {
            let part = Text(run.text).font(run.isWide ? wide : latin)
            result = result.map { $0 + part } ?? part
        }
        return result ?? Text(text).font(latin)
    }

    /// A Session's title, script by script.
    static func sessionTitleText(_ title: String) -> Text {
        scriptText(title, latin: sessionTitle, wide: sessionTitleWide)
    }

    /// The name cut into runs of one script, in order, so each run can take
    /// its own font.
    static func scriptRuns(_ name: String) -> [(text: String, isWide: Bool)] {
        var runs: [(text: String, isWide: Bool)] = []
        for character in name {
            let isWide = character.unicodeScalars.contains(where: isWideScript)
            if var last = runs.last, last.isWide == isWide {
                last.text.append(character)
                runs[runs.count - 1] = last
            } else {
                runs.append((String(character), isWide))
            }
        }
        return runs
    }

    /// Whether a scalar is drawn on a full square rather than a narrow Latin
    /// advance: the CJK ideographs, kana, Hangul, and their punctuation and
    /// fullwidth forms.
    static func isWideScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x2FDF, 0x2FF0...0x2FFF,
             0x3000...0x303F, 0x3041...0x30FF, 0x3100...0x312F,
             0x3130...0x318F, 0x31A0...0x31BF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFF:
            true
        default:
            false
        }
    }
}

/// The room around one group of a section: a gap frames a group that is open,
/// while a run of folded groups packs into a compact list.
///
/// A folded group is its one 30pt row with 1pt above and below, so two folded
/// neighbours sit 2pt apart. Wherever an open group meets a neighbour, the
/// 14pt gap divides them; no hairline is drawn, since a line between every
/// project cut the list into cells. The first group of a section has no gap.
struct WarrenDesktopTreeGroupSeparator: ViewModifier {
    let isFirst: Bool
    var isFolded = false
    var followsFolded = false
    var isLast = false

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Groups are 20 apart; folded groups in a run pack 2 apart and
            // read as one list.
            if !isFirst {
                Color.clear
                    .frame(height: isFolded && followsFolded
                        ? WarrenDesktopSidebarMetrics.summarySpacing
                        : WarrenDesktopSidebarMetrics.groupSpacing)
                    .accessibilityHidden(true)
            }
            content
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
/// What a folded row keeps of the rows it hides: one dot per Session with a
/// state (at most six), then how many Sessions there are.
struct WarrenDesktopFoldSummary: View {
    let marks: [WarrenActivityMark?]
    let count: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    static let spacing: CGFloat = 6

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: Self.spacing) {
            if WarrenDesktopTreeFoldDots.drawsAny(marks) {
                WarrenDesktopTreeFoldDots(marks: marks)
            }
            if count > 0 {
                Text("\(count)")
                    .font(WarrenDesktopTreeTypography.count)
                    .foregroundStyle(tokens.treeFaintText)
                    .frame(minWidth: 10, alignment: .trailing)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// The summary's drawn width, so a row can leave room for it.
    static func width(marks: [WarrenActivityMark?], count: Int) -> CGFloat {
        let dots = CGFloat(WarrenDesktopTreeFoldDots.visibleMarks(of: marks).count)
        let dotsWidth = dots > 0
            ? dots * WarrenDesktopSidebarMetrics.foldDotSize
                + (dots - 1) * WarrenDesktopSidebarMetrics.foldDotSpacing
            : 0
        let countWidth = count > 0
            ? max(10, WarrenDesktopSessionSecondLineLayout.textWidth("\(count)", fontSize: 10.5, monospaced: true))
            : 0
        let gap = dotsWidth > 0 && countWidth > 0 ? spacing : 0
        return dotsWidth + gap + countWidth
    }
}

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
    /// The corner, 5/18 of the size unless a row's design gives its own.
    var cornerRadius: CGFloat? = nil
    /// Whether the tile carries the name's initial. A tile too small to read
    /// it is a solid swatch of the project's colour instead.
    var showsInitial = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let tint = Self.tint(for: identity, in: tokens)
        Text(showsInitial ? String(name.prefix(1)).uppercased() : "")
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(showsInitial ? (colorScheme == .dark ? 0.18 : 0.14) : 0.55),
                in: RoundedRectangle(cornerRadius: cornerRadius ?? size * 5 / 18, style: .continuous)
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
public struct WarrenDesktopSessionKindBadge: View {
    let icon: WarrenDesktopAppIcon
    var size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize
    @Environment(\.displayScale) private var displayScale

    init(icon: WarrenDesktopAppIcon, size: CGFloat = WarrenDesktopSidebarMetrics.sessionIconSize) {
        self.icon = icon
        self.size = size
    }

    public init(kind: TerminalSessionKind, size: CGFloat) {
        self.init(icon: WarrenDesktopAppIcon(kind: kind), size: size)
    }

    public init(session: WarrenDesktopSession, size: CGFloat) {
        self.init(icon: WarrenDesktopAppIcon.resolve(session), size: size)
    }

    /// The mark's share of the tile. Simple Icons and LobeHub marks both fill
    /// their 24pt canvas edge to edge, so one ratio sizes them alike.
    static let glyphRatio: CGFloat = 0.62
    static let cornerRatio: CGFloat = 0.27

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
        shape
            .fill(icon.tileColor)
            .overlay { glyph }
            // Keeps a near-black tile's edge on the dark card. One device
            // pixel: 0.5pt is a pixel on Retina but a blurred half pixel at 1x.
            .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1 / displayScale) }
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

/// A name that fades its last 28pt when it does not fit, the tree's one way
/// of cutting a name or a title. A name that fits takes only its own width,
/// so whatever follows it on the row stays beside it.
struct WarrenDesktopFadingName: View {
    let text: Text

    var body: some View {
        ViewThatFits(in: .horizontal) {
            text
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            WarrenDesktopFadingLine { text }
        }
    }
}

/// The Task mark: a flag. It leads a Task's row, and marks a Projects
/// worktree that belongs to a Task.
struct WarrenDesktopTaskGlyph: View {
    var size: CGFloat = 11
    var color: Color

    var body: some View {
        Image(systemName: "flag")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
