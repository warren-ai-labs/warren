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
/// Only the Session leaf indents, because it has no such signal left — it is a
/// name with a marker, exactly like the workspace above it. Its one step plus
/// `sessionGuide` is what says "contained by".
///
/// Rows whose selection background is inset by `WarrenSpacing.compact` need
/// their content padding reduced by that inset, so the resolved text origin
/// still lands on the tier. The `.row`-suffixed values do that subtraction.
enum WarrenDesktopSidebarIndent {
    /// Section labels (`TERMINALS`, `PROJECTS`) anchor the tree.
    static let section = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// A Host heading is a lightweight group label, so it shares depth 0 with
    /// the projects beneath it instead of claiming its own level. That keeps a
    /// multi-Host workspace at the same depth as a single-Host one; its
    /// disclosure chevron is what separates it from the section label.
    static let host = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// Projects, tasks, and terminal groups are the first resource tier.
    static let project = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)
        - WarrenSpacing.compact
    static let task = project
    static let terminalGroup = project

    /// Workspaces nest inside a project or a task, and say so by weight and
    /// glyph rather than by position. See the type's note.
    static let workspace = project

    /// Breathing room between the rail and the Session leaves it ties.
    ///
    /// A bare indent step left the leaf icon about one point past the rail,
    /// which read as touching. One small spacing step keeps the rail legible as
    /// a separate structure without spending meaningful width on a 260pt rail.
    static let sessionGuideGap = WarrenSpacing.xxs

    /// Terminal Sessions are the leaves of the tree, shown by the rich
    /// workspace presentation.
    static let session = WarrenLayoutMetrics.sidebarLeadingInset(depth: 1)
        - WarrenSpacing.compact
        + sessionGuideGap

    /// The x of the rail that ties Session leaves to the workspace that owns
    /// them.
    ///
    /// It sits on the depth-0 content leading edge — the edge section labels,
    /// Host titles, and the project and workspace glyph slots all start from —
    /// rather than on the workspace glyph's center. Anchoring it on the glyph
    /// left only three points between the rail and the leaf icon, so the elbow
    /// had no room to read as a branch. Moving the rail into the gutter
    /// lengthens that elbow to a full indent step and lines the rail up with
    /// the column every other row already starts on.
    ///
    /// This is an absolute position in the rail, not a row inset, so it does
    /// not subtract the selection inset the way the `.row` values do.
    ///
    /// The guide is a stroked path, so this is the line's center and not the
    /// leading edge a filled rectangle would need. The drawing that reads it
    /// lives in `WarrenDesktopSessionTreeGuide`.
    static let sessionGuide = WarrenLayoutMetrics.sidebarLeadingInset(depth: 0)

    /// Empty-state copy is content beneath a Host heading, so align it with
    /// the workspace row's leading content edge rather than an arbitrary
    /// visual offset. Workspace rows add the outer row inset back at layout.
    static let hostEmptyState = workspace + WarrenSpacing.compact
}
