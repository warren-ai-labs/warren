import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

// The Projects section in three bands, and a project's worktrees in two.
//
// Pinned projects come first, then every project with an open Session, then
// one folded row for the rest. A project changes band only when it gains its
// first Session, a minute after it closes its last, or when it is selected
// from the folded row (see `WarrenDesktopProjectHold`), never on a status
// change, and the active band is ordered by when each project became active,
// so rows do not move while someone reads them. Inside a project, worktrees with Sessions keep
// their order and every other worktree folds into one row at the end.
//
// Both the current-Host tree and the multi-Host tree draw from these, so the
// two cannot disagree about which band a project is in.

/// A section's projects split into its bands.
struct WarrenDesktopProjectBands<Item> {
    var pinned: [Item] = []
    var active: [Item] = []
    /// Most recently active first.
    var inactive: [Item] = []

    /// The projects drawn as full rows.
    var listed: [Item] { pinned + active }
    /// Every project, in band order, for a rail that draws them all.
    var all: [Item] { pinned + active + inactive }

    /// `activeSince` orders the active band; it defaults to the Host's stamp,
    /// and a held project supplies the one it is held with.
    init(
        _ items: [Item],
        project: (Item) -> Project,
        isActive: (Item) -> Bool,
        lastActiveAt: (Item) -> Date?,
        activeSince: ((Item) -> Date?)? = nil
    ) {
        var active: [(offset: Int, item: Item)] = []
        var inactive: [(offset: Int, item: Item, last: Date?)] = []
        for (offset, item) in items.enumerated() {
            if project(item).pinned {
                pinned.append(item)
            } else if isActive(item) {
                active.append((offset, item))
            } else {
                inactive.append((offset, item, lastActiveAt(item)))
            }
        }
        // A Host that predates the stamp leaves every project unstamped; they
        // then keep the Host's order behind the stamped ones.
        self.active = active.sorted { lhs, rhs in
            let left = activeSince?(lhs.item) ?? project(lhs.item).activeSince ?? .distantFuture
            let right = activeSince?(rhs.item) ?? project(rhs.item).activeSince ?? .distantFuture
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.item)
        self.inactive = inactive.sorted { lhs, rhs in
            let left = lhs.last ?? .distantPast
            let right = rhs.last ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.item)
    }
}

/// Projects held in the active band without an open Session.
///
/// A project that closes its last Session stays where it was for a minute, so
/// closing one Session to open another does not send its row away and back.
/// Selecting an inactive project lifts it into the band the same way, at the
/// band's end, where its row has the actions that start work in it.
///
/// A hold outlasts its minute while its project holds the selection, so a row
/// someone is looking at is never folded away, and while the pointer is over
/// the rail, so no row moves under the pointer reading it. The hold is
/// Desktop-local: the Host's `activeSince` still says only whether a Session
/// runs. Keys are the tree's own project keys, so the multi-Host tree can scope
/// them by Host.
struct WarrenDesktopProjectHold: Equatable {
    static let interval: TimeInterval = 60

    struct Entry: Equatable {
        /// Where the project sorts in the active band.
        var activeSince: Date?
        var expiresAt: Date
    }

    private(set) var entries: [String: Entry] = [:]

    func contains(_ key: String) -> Bool { entries[key] != nil }

    func activeSince(_ key: String) -> Date? { entries[key]?.activeSince }

    /// The earliest moment a hold can end.
    var nextExpiry: Date? { entries.values.map(\.expiresAt).min() }

    /// Follows one change of which projects are active.
    ///
    /// A project that stopped being active is held with the stamp it had, so
    /// it keeps its place; one that became active again needs no hold; one
    /// that is gone is forgotten.
    mutating func update(from previous: Snapshot, to current: Snapshot, now: Date) {
        for (key, stamp) in previous.active
        where current.active[key] == nil && current.existing.contains(key) {
            entries[key] = Entry(activeSince: stamp, expiresAt: now.addingTimeInterval(Self.interval))
        }
        for key in entries.keys
        where current.active[key] != nil || !current.existing.contains(key) {
            entries[key] = nil
        }
    }

    /// Which projects a tree lists, and the Host's stamp on each active one.
    struct Snapshot: Equatable {
        var active: [String: Date?] = [:]
        var existing: Set<String> = []
    }

    /// Lifts a selected inactive project into the active band, behind every
    /// project already there. A project already held keeps its place.
    mutating func lift(_ key: String, now: Date) {
        guard entries[key] == nil else { return }
        entries[key] = Entry(activeSince: now, expiresAt: now.addingTimeInterval(Self.interval))
    }

    /// Ends the holds whose minute is up, except the ones in `kept`. Reports
    /// whether any ended.
    @discardableResult
    mutating func expire(now: Date, keeping kept: Set<String>) -> Bool {
        let ended = entries.filter { $0.value.expiresAt <= now && !kept.contains($0.key) }.keys
        for key in ended { entries[key] = nil }
        return !ended.isEmpty
    }
}

/// What the hold's clock waits on: the next expiry, and the two things that
/// postpone it. Any change restarts the wait.
struct WarrenDesktopProjectHoldClock: Equatable {
    var nextExpiry: Date?
    var pointerInsideSidebar: Bool
    var kept: Set<String>

    /// Sleeps until the next hold can end, then ends what may. Returns without
    /// ending anything while the pointer is over the rail.
    @MainActor
    func run(_ expire: @MainActor (Date, Set<String>) -> Void) async {
        guard let nextExpiry, !pointerInsideSidebar else { return }
        let delay = nextExpiry.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        expire(Date(), kept)
    }
}

/// A project's worktrees split into the ones it lists and the ones folded
/// into its idle row.
///
/// In each list a `main` or `master` worktree comes first, so the default
/// branch is always found in the same place.
struct WarrenDesktopWorkspaceSplit: Equatable {
    /// The default branch, then the Host's order.
    var live: [Workspace]
    /// The default branch, then most recently active first.
    var idle: [Workspace]

    init(_ workspaces: [Workspace], isLive: (Workspace) -> Bool) {
        live = Self.defaultBranchFirst(workspaces.filter(isLive))
        idle = Self.defaultBranchFirst(workspaces
            .enumerated()
            .filter { !isLive($0.element) }
            .sorted { lhs, rhs in
                let left = lhs.element.lastActiveAt ?? .distantPast
                let right = rhs.element.lastActiveAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element))
    }

    static func isDefaultBranch(_ workspace: Workspace) -> Bool {
        let branch = workspace.branch ?? workspace.name
        return branch == "main" || branch == "master"
    }

    /// Moves the default-branch worktrees to the front, keeping every other
    /// order as it was.
    private static func defaultBranchFirst(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.filter(isDefaultBranch) + workspaces.filter { !isDefaultBranch($0) }
    }

    /// Whether the idle row is drawn. A project with no Session and one
    /// worktree is just its own row: a lone idle `main` under it says nothing
    /// the project row does not.
    var showsIdleRow: Bool {
        !idle.isEmpty && !(live.isEmpty && idle.count == 1)
    }

    /// Whether the project has anything to draw beneath its own row.
    var hasRows: Bool { !live.isEmpty || showsIdleRow }
}

/// A branch name read by its leaf: the prefix up to the last `/` is dimmed,
/// and a long leaf is cut in the middle so both of its ends stay.
enum WarrenDesktopBranchName {
    static let maximumLeafLength = 26
    static let keptHead = 13
    static let keptTail = 11

    static func parts(_ name: String) -> (prefix: String, leaf: String) {
        var (prefix, leaf) = wholeParts(name)
        if leaf.count > maximumLeafLength {
            leaf = String(leaf.prefix(keptHead)) + "…" + String(leaf.suffix(keptTail))
        }
        return (prefix, leaf)
    }

    /// The prefix and the leaf before the leaf is cut.
    static func wholeParts(_ name: String) -> (prefix: String, leaf: String) {
        // A Task's worktree reads `project · branch`; that is a label, not a
        // branch, so nothing in it is a prefix.
        guard !name.contains(" · "), let slash = name.lastIndex(of: "/") else {
            return ("", name)
        }
        return (String(name[...slash]), String(name[name.index(after: slash)...]))
    }

    static func text(_ name: String, leaf leafColor: Color, prefix prefixColor: Color) -> Text {
        let parts = parts(name)
        let leaf = Text(parts.leaf).foregroundColor(leafColor)
        guard !parts.prefix.isEmpty else { return leaf }
        return Text(parts.prefix).foregroundColor(prefixColor) + leaf
    }
}

/// A branch name that is cut at most once.
///
/// When the whole name does not fit, the prefix goes first, since the leaf is
/// the part someone recognizes, and a quiet `…/` stands for it; only when the
/// leaf alone still does not fit does its end fade, as every name in the tree
/// does.
struct WarrenDesktopBranchNameLabel: View {
    let name: String
    let leafColor: Color
    let prefixColor: Color
    var font: Font = WarrenDesktopTreeTypography.branchName
    var wideFont: Font = WarrenDesktopTreeTypography.branchNameWide

    var body: some View {
        let whole = WarrenDesktopBranchName.wholeParts(name)
        // A name that does not fit fades at its end, before whatever the
        // row keeps at its trailing edge, rather than losing its prefix.
        ViewThatFits(in: .horizontal) {
            line(prefix: whole.prefix, leaf: whole.leaf)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            WarrenDesktopFadingLine {
                line(prefix: whole.prefix, leaf: whole.leaf)
            }
        }
    }

    private func line(prefix: String, leaf: String) -> Text {
        let leafText = WarrenDesktopTreeTypography.scriptText(leaf, latin: font, wide: wideFont)
            .foregroundColor(leafColor)
        guard !prefix.isEmpty else { return leafText }
        return WarrenDesktopTreeTypography.scriptText(prefix, latin: font, wide: wideFont)
            .foregroundColor(prefixColor) + leafText
    }
}

/// How long ago something was last active, in the sidebar's one form: `now`,
/// `5m`, `2h`, `3d`, `2w`, and then a date once it is older than five weeks.
/// Every sidebar age shares this so a project, a workspace, and a Session
/// never disagree about how to say "when".
/// A row's activity age, kept current while the row is on screen. The label
/// is relative to now, so read once in `body` it went stale: a row said
/// "now" until something else redrew the sidebar.
struct WarrenDesktopActivityAgeText: View {
    let date: Date
    let color: Color

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(WarrenDesktopActivityAge.label(since: date, now: context.date))
                .font(WarrenDesktopTreeTypography.age)
                .foregroundStyle(color)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

enum WarrenDesktopActivityAge {
    static func label(since date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minute: Double = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<week: return "\(Int(seconds / day))d"
        case ..<(6 * week): return "\(Int(seconds / week))w"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return (sameYear ? Self.monthDay : Self.monthDayYear).string(from: date)
        }
    }

    /// The date form the age falls back to past five weeks: `Oct 3`, with the
    /// year only when it is not this year. Pinned to English so the month
    /// abbreviation does not change with the system locale.
    nonisolated(unsafe) private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    nonisolated(unsafe) private static let monthDayYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// The age as assistive technology reads it: whole words, and "just now"
    /// rather than "now ago".
    static func spokenLabel(since date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minute: Double = 60
        let hour = 60 * minute
        let day = 24 * hour
        let week = 7 * day
        func ago(_ value: Double, _ unit: String) -> String {
            let count = Int(value)
            return "\(count) \(unit)\(count == 1 ? "" : "s") ago"
        }
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour: return ago(seconds / minute, "minute")
        case ..<day: return ago(seconds / hour, "hour")
        case ..<week: return ago(seconds / day, "day")
        case ..<(6 * week): return ago(seconds / week, "week")
        default: return "on \(label(since: date, now: now, calendar: calendar))"
        }
    }

    /// The age a project shows: its most recently active worktree.
    static func lastActiveAt(of workspaces: [Workspace]) -> Date? {
        workspaces.compactMap(\.lastActiveAt).max()
    }
}

/// A row that stands for a folded list: "7 idle worktrees", "9 inactive
/// projects". It has no icon, so its text starts where the icons above it do.
struct WarrenDesktopFoldedCountRow: View {
    let count: Int
    let singular: String
    let plural: String
    let height: CGFloat
    let isExpanded: Bool
    let semanticID: String
    let isEnabled: Bool
    /// Drawn as a worktree among worktrees: the branch glyph in the icon
    /// column, so the row reads as more of the project above it rather than a
    /// heading for the next one.
    var isWorktreeLevel = false
    /// Projects whose avatars lead the row, overlapping, as the inactive row
    /// shows the first few of the projects it holds.
    var stackedProjects: [Project] = []
    /// A row that leads elsewhere rather than folding: a forward chevron that
    /// never turns, after the Task glyph.
    var leadsToTasks = false
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isHovered = false

    private var noun: String { count == 1 ? singular : plural }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Button(action: onToggle) {
            HStack(spacing: WarrenDesktopSidebarMetrics.iconTextSpacing) {
                if leadsToTasks {
                    WarrenDesktopTaskGlyph(size: 11, color: tokens.treeFaintText)
                        .frame(width: WarrenDesktopSidebarMetrics.iconColumnWidth)
                        .accessibilityHidden(true)
                } else if isWorktreeLevel {
                    WarrenDesktopViewBoxGlyph.worktreeBranch(size: WarrenDesktopSidebarMetrics.worktreeIconSize)
                        .foregroundStyle(tokens.treeFaintText)
                        .frame(width: WarrenDesktopSidebarMetrics.iconColumnWidth)
                        .accessibilityHidden(true)
                }
                if !stackedProjects.isEmpty {
                    HStack(spacing: -WarrenDesktopSidebarMetrics.inactiveStackOverlap) {
                        ForEach(stackedProjects.prefix(WarrenDesktopSidebarMetrics.inactiveStackCount)) { project in
                            WarrenDesktopProjectAvatar(
                                name: project.name,
                                identity: project.id.description,
                                size: WarrenDesktopSidebarMetrics.inactiveProjectIconSize,
                                cornerRadius: 4,
                                showsInitial: false
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(tokens.workbenchCardFill)
                                    .padding(-1.5)
                            )
                        }
                    }
                    .accessibilityHidden(true)
                }
                (Text("\(count)")
                    .font(WarrenDesktopTreeTypography.foldedCountNumber)
                    + Text(" \(noun)")
                    .font(WarrenDesktopTreeTypography.foldedCount))
                    .foregroundColor(tokens.treeQuietText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                WarrenDesktopTreeChevron(isExpanded: isExpanded)
            }
            .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(
                isHovered ? tokens.treeRowHover : .clear,
                in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(count) \(noun)")
        .accessibilityValue(leadsToTasks ? "Show in Tasks" : (isExpanded ? "Expanded" : "Collapsed"))
        .warrenSemanticElement(
            id: semanticID,
            role: .button,
            label: "\(count) \(noun)",
            value: leadsToTasks ? "Show in Tasks" : (isExpanded ? "Expanded" : "Collapsed"),
            isEnabled: isEnabled,
            action: { if isEnabled { onToggle() } }
        )
    }
}

/// A worktree with no Session, listed under its project's idle row: shorter
/// and dimmer than a live worktree, with its last activity at the end.
struct WarrenDesktopIdleWorktreeRow: View {
    let workspace: Workspace
    /// The name shown, which a Task copy prefixes with its project.
    var displayName: String? = nil
    let semanticScope: String
    let isSelected: Bool
    let isEnabled: Bool
    var isMutationDisabled = false
    let contextMenuActions: [WarrenDesktopContextMenuAction]
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isHovered = false

    private var name: String {
        let value = displayName ?? workspace.name
        return value.isEmpty ? "Workspace" : value
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let ageDate = workspace.lastActiveAt
        let spokenAge = WarrenDesktopActivityAge.spokenLabel(since: ageDate)
        Button(action: onSelect) {
            HStack(spacing: WarrenDesktopSidebarMetrics.iconTextSpacing) {
                // The idle row above already draws the branch glyph; its list
                // keeps the column empty so the names line up under its words.
                Color.clear
                    .frame(width: WarrenDesktopSidebarMetrics.iconColumnWidth, height: 1)
                WarrenDesktopBranchNameLabel(
                    name: name,
                    leafColor: tokens.treeBranchText,
                    prefixColor: tokens.treeBranchPrefixText
                )
                Spacer(minLength: 6)
                if let ageDate {
                    WarrenDesktopActivityAgeText(date: ageDate, color: tokens.treeFaintText)
                }
            }
            .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: WarrenDesktopSidebarMetrics.idleWorktreeRowHeight, alignment: .leading)
            .background(
                isSelected ? tokens.treeRowSelected : (isHovered ? tokens.treeRowHover : .clear),
                in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isEnabled { onDoubleClick() }
        })
        .onHover { isHovered = $0 }
        .warrenContextMenu(isEnabled && !isMutationDisabled ? contextMenuActions : [])
        // The cut name is whole on hover.
        .help(name)
        .accessibilityLabel("Workspace \(name)")
        .accessibilityValue(spokenAge.isEmpty ? "No sessions" : "No sessions · last active \(spokenAge)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "workspace.\(semanticScope).\(workspace.id.description)",
            role: .button,
            label: "Workspace \(name)",
            value: spokenAge.isEmpty ? "No sessions" : "No sessions · last active \(spokenAge)",
            isEnabled: isEnabled,
            isSelected: isSelected,
            action: { if isEnabled { onSelect() } }
        )
    }
}

/// A project with no open Session, in the folded list at the end of the
/// section: a smaller, faded avatar, a quieter name, and its last activity.
struct WarrenDesktopInactiveProjectRow: View {
    let project: Project
    let lastActiveAt: Date?
    let semanticID: String
    let isSelected: Bool
    let isEnabled: Bool
    var isMutationDisabled = false
    let contextMenuActions: [WarrenDesktopContextMenuAction]
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let spokenAge = WarrenDesktopActivityAge.spokenLabel(since: lastActiveAt)
        Button(action: onSelect) {
            HStack(spacing: WarrenDesktopSidebarMetrics.groupIconSpacing) {
                WarrenDesktopProjectAvatar(
                    name: project.name,
                    identity: project.id.description,
                    size: WarrenDesktopSidebarMetrics.inactiveProjectIconSize
                )
                .opacity(WarrenDesktopSidebarMetrics.inactiveProjectIconOpacity)
                // The avatar keeps the 18pt column, so names line up with the
                // full project rows above.
                .frame(width: WarrenDesktopSidebarMetrics.groupIconSize)
                Text(project.name)
                    .font(WarrenDesktopTreeTypography.inactiveProjectName)
                    .foregroundStyle(isHovered ? tokens.treeSessionText : tokens.treeSessionRestingText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let lastActiveAt {
                    WarrenDesktopActivityAgeText(date: lastActiveAt, color: tokens.treeFaintText)
                }
            }
            .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: WarrenDesktopSidebarMetrics.inactiveProjectRowHeight, alignment: .leading)
            .background(
                isSelected ? tokens.treeRowSelected : (isHovered ? tokens.treeRowHover : .clear),
                in: RoundedRectangle(cornerRadius: WarrenDesktopSidebarMetrics.rowRadius, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .warrenContextMenu(isEnabled && !isMutationDisabled ? contextMenuActions : [])
        .help(project.name)
        .accessibilityLabel("Project \(project.name)")
        .accessibilityValue(spokenAge.isEmpty ? "No open sessions" : "No open sessions · last active \(spokenAge)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: semanticID,
            role: .button,
            label: "Project \(project.name)",
            value: spokenAge.isEmpty ? "No open sessions" : "No open sessions · last active \(spokenAge)",
            isEnabled: isEnabled,
            isSelected: isSelected,
            action: { if isEnabled { onSelect() } }
        )
    }
}
