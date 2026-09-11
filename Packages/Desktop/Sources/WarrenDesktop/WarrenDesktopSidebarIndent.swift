import WarrenDesignSystem

/// Where each sidebar row sits in the navigation tree.
///
/// `WarrenLayoutMetrics` owns the indent formula; this owns the depth each row
/// kind occupies, because that is navigation structure rather than geometry.
/// Keeping both in one place is what makes the gradient stay monotonic when a
/// new row kind is added.
///
/// Rows whose selection background is inset by `WarrenSpacing.compact` need
/// their content padding reduced by that inset, so the resolved text origin
/// still lands on the tier. The `.row`-suffixed values do that subtraction.
enum WarrenDesktopSidebarIndent {
    /// Section labels (`TERMINALS`, `PROJECTS`) anchor the tree.
    static let section = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// A Host heading is a lightweight group label, so it shares depth 1 with
    /// the projects beneath it instead of claiming its own level. That keeps a
    /// multi-Host workspace at the same depth as a single-Host one.
    static let host = WarrenLayoutMetrics.sidebarLeadingInset(depth: 1)

    /// Projects, tasks, and terminal groups are the first resource tier.
    static let project = WarrenLayoutMetrics.sidebarLeadingInset(depth: 1)
        - WarrenSpacing.compact
    static let task = project
    static let terminalGroup = project

    /// Workspaces nest inside a project or a task.
    static let workspace = WarrenLayoutMetrics.sidebarLeadingInset(depth: 2)
        - WarrenSpacing.compact
}
