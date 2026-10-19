import WarrenDesignSystem

/// Where each sidebar row sits in the navigation tree.
///
/// `WarrenLayoutMetrics` owns the indent formula; this owns the depth each row
/// kind occupies, because that is navigation structure rather than geometry.
/// Keeping both in one place is what makes the gradient stay monotonic when a
/// new row kind is added.
///
/// Indentation is the scarcest thing in the rail, so a tier only spends a step
/// when nothing cheaper will separate it.
///
/// Section labels, Host headings, projects, and workspaces therefore all sit at
/// depth 0. What tells them apart costs no width: a section label is uppercase
/// and recedes to `sidebarSectionText`; a Host heading carries a disclosure
/// chevron; a project is `medium` weight with a filled avatar; a workspace is
/// `regular` weight, one brightness tier down, with a 5pt glyph. Four signals,
/// none of them position.
///
/// Session leaves share that edge too. A leaf carries its own signals: a type
/// icon with a status dot, the brightest title in the tree, and a second line
/// for what it is doing.
///
/// Rows whose selection background is inset by `WarrenSpacing.compact` need
/// their content padding reduced by that inset, so the resolved text origin
/// still lands on the tier. The `.row`-suffixed values do that subtraction.
enum WarrenDesktopSidebarIndent {
    /// Section labels (`TERMINALS`, `PROJECTS`) anchor the tree.
    static let section = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// A Host heading is a lightweight group label that claims no level: it
    /// lines up with the section labels and the rows it governs at
    /// `WarrenDesktopSidebarMetrics.rowHorizontalPadding`, and its disclosure
    /// chevron is what separates it from a section label. This constant is the
    /// base a Host's empty-state copy is positioned from.
    static let host = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// Projects and tasks are the first resource tier.
    static let project = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)
        - WarrenSpacing.compact
    static let task = project

    /// Workspaces nest inside a project or a task, and say so by weight and
    /// glyph rather than by position. See the type's note.
    static let workspace = project

    /// Terminal Sessions are the leaves of the tree. They share the
    /// workspace's edge: three tiers of indent left too little width for a
    /// title, and the leaf already reads as a child by its type icon and its
    /// second line.
    static let session = workspace

    /// Empty-state copy is content beneath a Host heading, so align it with
    /// the workspace row's leading content edge rather than an arbitrary
    /// visual offset. Workspace rows add the outer row inset back at layout.
    static let hostEmptyState = workspace + WarrenSpacing.compact
}
