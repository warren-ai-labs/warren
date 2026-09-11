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
    @FocusState private var isActionFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            Text(title)
                .font(WarrenTypography.navigationItem)
                .foregroundStyle(titleColor(tokens))
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(detailColor(tokens))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action {
                Button(action: action.perform) {
                    Text(action.label)
                        .font(WarrenTypography.navigationMeta)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.highlight)
                .focused($isActionFocused)
                .padding(.top, WarrenSpacing.xxs)
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
        .padding(.vertical, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
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
            "No projects"
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
                "Add a project or drop a Git repository folder"
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
        let perform: () -> Void
    }

    private var action: Action? {
        switch reason {
        case .hostUnavailable:
            guard let onRetry else { return nil }
            return Action(
                label: "Retry",
                semanticID: "retry",
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
