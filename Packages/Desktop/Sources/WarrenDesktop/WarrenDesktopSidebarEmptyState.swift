import SwiftUI
import WarrenDesignSystem

/// Why a sidebar section has nothing to show.
///
/// The three cases are unrelated situations that happen to share a shape: an
/// error to recover from, a filter the user set themselves, and a starting
/// point that needs a first project. Rendering them as one line of muted text
/// made them indistinguishable, so each carries its own tone, its own escape
/// hatch, and — for the filter — the count of what is being withheld.
enum WarrenDesktopSidebarEmptyReason: Equatable {
    /// The Host cannot be reached. `detail` is the underlying error when the
    /// transport supplied one.
    case hostUnavailable(isFailed: Bool, detail: String?)

    /// The active-only filter hid every workspace. `hiddenWorkspaceCount` is
    /// what the user would see if the filter were off, and it is the fact that
    /// distinguishes "I hid these" from "there is nothing here".
    case filteredByActiveOnly(hiddenWorkspaceCount: Int)

    /// The Host has no projects at all.
    case noProjects(canAddProject: Bool, hostName: String?)
}

/// One empty state for both sidebar paths.
///
/// The aggregated Host rows and the single-Host rows previously rendered the
/// same situation two different ways: one centered with guidance, the other a
/// single left-aligned muted line. This is the shared presentation, so a new
/// reason cannot diverge between them again.
struct WarrenDesktopSidebarEmptyState: View {
    let reason: WarrenDesktopSidebarEmptyReason
    /// Clears the active-only filter. Only used by `.filteredByActiveOnly`.
    var onShowAll: (() -> Void)?
    /// Retries the Host connection. Only used by `.hostUnavailable`.
    var onRetry: (() -> Void)?
    /// Starts project creation. Only used by `.noProjects` when permitted.
    var onAddProject: (() -> Void)?
    /// Scopes semantic action IDs when several Host empty states are visible.
    var semanticIDPrefix: String = "sidebar.empty"
    /// Places the empty-state copy at the child depth when it sits beneath a
    /// Host heading in the aggregated sidebar.
    var isNestedUnderHost: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @FocusState private var isActionFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            if isStarter {
                // The first-run case gets a mark of its own: it is the one
                // empty state that is a beginning rather than a problem.
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(tokens.treeSecondaryText)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tokens.treeRowHover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tokens.cardBorder, lineWidth: 1)
                    )
                    .padding(.bottom, WarrenSpacing.compact)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(isStarter ? Font.system(size: 13, weight: .medium) : WarrenTypography.navigationItem)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(titleColor(tokens))

            if let detail {
                Text(detail)
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(detailColor(tokens))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action {
                Button(action: action.perform) {
                    HStack(spacing: 5) {
                        if let symbol = action.systemImage {
                            Image(systemName: symbol)
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        Text(action.label)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(WarrenDesktopSidebarEmptyActionStyle(isFocused: isActionFocused))
                .focused($isActionFocused)
                .padding(.top, WarrenSpacing.compact)
                .warrenSemanticElement(
                    id: "\(semanticIDPrefix).\(action.semanticID)",
                    role: .button,
                    label: action.label,
                    action: action.perform
                )
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, WarrenSpacing.medium)
        .padding(.vertical, isStarter ? WarrenSpacing.standard : WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var isWarning: Bool {
        if case .hostUnavailable = reason { return true }
        return false
    }

    /// Whether this is the Host's first run: no projects, and a way to add one.
    private var isStarter: Bool {
        if case .noProjects(let canAddProject, _) = reason { return canAddProject }
        return false
    }

    // MARK: Content

    private var leadingInset: CGFloat {
        isNestedUnderHost
            ? WarrenDesktopSidebarIndent.hostEmptyState
            : WarrenDesktopSidebarIndent.host
    }

    private var title: String {
        switch reason {
        case .hostUnavailable(let isFailed, _):
            isFailed ? "Host unavailable" : "Host disconnected"
        case .filteredByActiveOnly:
            "No active workspaces"
        case .noProjects:
            "No projects yet"
        }
    }

    private var detail: String? {
        switch reason {
        case .hostUnavailable(_, let detail):
            detail
        case .filteredByActiveOnly(let hidden):
            // The count is the whole point: it separates a filter the user set
            // from an empty Host, which no wording can do on its own.
            hidden > 0
                ? "\(hidden) workspace\(hidden == 1 ? "" : "s") hidden by the active filter"
                : "No workspace has a running session"
        case .noProjects(let canAddProject, let hostName):
            if canAddProject {
                // The sidebar takes no folder drops, so the copy names only
                // the path that exists.
                "Add a Git repository to list its worktrees and Sessions here."
            } else if let hostName, !hostName.isEmpty {
                "Add one from the CLI on \(hostName)"
            } else {
                "Add one from the CLI on the host machine"
            }
        }
    }

    private struct Action {
        let label: String
        let semanticID: String
        var systemImage: String? = nil
        let perform: () -> Void
    }

    private var action: Action? {
        switch reason {
        case .hostUnavailable:
            guard let onRetry else { return nil }
            return Action(
                label: "Retry",
                semanticID: "retry",
                systemImage: "arrow.clockwise",
                perform: onRetry
            )
        case .filteredByActiveOnly:
            guard let onShowAll else { return nil }
            return Action(
                label: "Show all workspaces",
                semanticID: "show-all",
                perform: onShowAll
            )
        case .noProjects(let canAddProject, _):
            guard canAddProject, let onAddProject else { return nil }
            return Action(
                label: "Add Project…",
                semanticID: "add-project",
                systemImage: "plus",
                perform: onAddProject
            )
        }
    }

    /// Connection failures use warning color. Only aggregated Host sections
    /// promote ordinary empty-state titles to the project text tier; the
    /// single-Host presentation keeps its legacy muted treatment.
    private func titleColor(_ tokens: WarrenColorTokens) -> Color {
        switch reason {
        case .hostUnavailable:
            tokens.warning
        case .filteredByActiveOnly, .noProjects:
            isNestedUnderHost ? tokens.projectText : tokens.mutedForeground
        }
    }

    private func detailColor(_ tokens: WarrenColorTokens) -> Color {
        isNestedUnderHost
            ? tokens.mutedForeground.opacity(0.72)
            : tokens.mutedForeground
    }

    private var accessibilityLabel: String {
        [title, detail].compactMap { $0 }.joined(separator: ". ")
    }
}

/// The empty state's one action: a small bordered capsule in the tree's own
/// colours, so the way out reads as a control rather than as orange link text
/// that looks like a status.
private struct WarrenDesktopSidebarEmptyActionStyle: ButtonStyle {
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, isFocused: isFocused)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let isFocused: Bool

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.warrenWindowMaterial) private var windowMaterial
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .foregroundStyle(isHovered ? tokens.treeSessionSelectedText : tokens.treeSessionText)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(shape.fill(isHovered || configuration.isPressed ? tokens.treeRowSelected : tokens.treeRowHover))
                .overlay(shape.strokeBorder(isFocused ? tokens.focusRing : tokens.cardBorder, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: isHovered)
        }
    }
}

/// The tree's placeholder while a Host is still connecting and has sent no
/// projects yet: project-shaped rows with Session lines under them, in the
/// sidebar's own metrics.
///
/// Before it, a single-Host sidebar said "No projects" for the second it took
/// to attach, and an aggregated Host showed nothing under its heading. Rows in
/// the tree's shape say what is coming and keep the list from jumping when it
/// lands.
struct WarrenDesktopSidebarSkeleton: View {
    var projectCount = 3
    /// Places the rows beneath a Host heading in the aggregated sidebar.
    var isNestedUnderHost = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    /// Session lines per project, and the width of each title, so the block
    /// reads as a tree of different names rather than a grid.
    private static let sessionCounts = [2, 1, 2]
    private static let projectWidths: [CGFloat] = [0.46, 0.62, 0.38]
    private static let sessionWidths: [CGFloat] = [0.70, 0.52, 0.64, 0.58, 0.74]

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.groupSpacing) {
            ForEach(0..<projectCount, id: \.self) { project in
                VStack(alignment: .leading, spacing: WarrenDesktopSidebarMetrics.groupContentSpacing) {
                    projectRow(project)
                    ForEach(0..<Self.sessionCounts[project % Self.sessionCounts.count], id: \.self) { session in
                        sessionRow(project: project, session: session)
                    }
                }
            }
        }
        .padding(.leading, isNestedUnderHost ? WarrenDesktopSidebarIndent.hostEmptyState : WarrenDesktopSidebarIndent.project)
        .padding(.trailing, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.xxs)
        .warrenSkeletonTint(tokens.treeRowSelected)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading projects")
    }

    private func projectRow(_ index: Int) -> some View {
        let phase = Double(index) * 0.18
        return HStack(spacing: 8) {
            WarrenSkeletonBar(phase: phase)
                .frame(width: 16, height: 16)
            GeometryReader { proxy in
                WarrenSkeletonBar(phase: phase)
                    .frame(width: proxy.size.width * Self.projectWidths[index % Self.projectWidths.count], height: 9)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(height: WarrenDesktopSidebarMetrics.groupRowHeight)
    }

    private func sessionRow(project: Int, session: Int) -> some View {
        let phase = Double(project) * 0.18 + Double(session + 1) * 0.06
        let width = Self.sessionWidths[(project * 2 + session) % Self.sessionWidths.count]
        return HStack(spacing: 8) {
            WarrenSkeletonBar(phase: phase)
                .frame(width: 6, height: 6)
                .clipShape(Circle())
                .frame(width: 16)
            GeometryReader { proxy in
                WarrenSkeletonBar(phase: phase)
                    .frame(width: proxy.size.width * width, height: 7)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, WarrenDesktopSidebarMetrics.rowHorizontalPadding)
        .frame(height: WarrenDesktopSidebarMetrics.worktreeRowHeight)
    }
}

extension WarrenDesktopConnectionState {
    /// Still on its way to attached: the tree it will show has not arrived,
    /// so an empty roster is not yet a fact worth stating.
    var isSettling: Bool {
        self == .connecting || self == .reconnecting
    }
}
