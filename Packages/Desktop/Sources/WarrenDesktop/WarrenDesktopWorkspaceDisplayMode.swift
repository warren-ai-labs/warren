import CoreGraphics
import WarrenDesignSystem

/// Controls how workspace children are presented in the desktop sidebar.
///
/// Compact mode keeps the existing one-line workspace rows. Rich mode keeps
/// those rows as the parent and adds one child row for every live Terminal
/// Session, so the Session becomes the leaf of the navigation tree instead of
/// living only inside a Tab strip.
public enum WarrenDesktopWorkspaceDisplayMode: String, CaseIterable, Hashable, Sendable {
    case compact
    case rich

    public var isRich: Bool { self == .rich }

    /// Whether the sidebar tree enumerates every live Session as a leaf.
    ///
    /// The tree and the pane bar split the job of listing a scope's Sessions:
    /// exactly one of them owns that list at a time, and which one is the only
    /// thing this mode changes. Both sides read the answer from here so neither
    /// has to invert the other's flag.
    public var sidebarListsSessions: Bool { isRich }

    /// Whether the pane bar has to enumerate Sessions because the tree does not.
    public var paneBarListsEverySession: Bool { !sidebarListsSessions }

    public var toggleLabel: String {
        isRich ? "Hide Sessions in the navigation tree" : "Show Sessions in the navigation tree"
    }

    public var toggleHint: String {
        isRich
            ? "List each workspace without its running Sessions"
            : "List every running Session under the workspace that owns it"
    }

    /// The control says what it does to the tree, not what a Session is.
    ///
    /// A speech bubble names a conversation, which is only true of Agent
    /// Sessions and says nothing about the tree gaining a level. An indented
    /// list is what the toggle actually produces, and it stays accurate for a
    /// plain shell leaf.
    public var systemImage: String {
        isRich ? "list.bullet.indent" : "list.bullet"
    }

    /// Vertical separation between one project's subtree and the next.
    ///
    /// A uniform row gap makes a deep tree read as one undifferentiated list.
    /// Separating the groups is what lets the eye find a project without
    /// reading labels, and rich mode needs more of it because each group is
    /// taller.
    public var projectGroupSpacing: CGFloat {
        isRich ? WarrenSpacing.medium : WarrenSpacing.compact
    }

    /// Separation between a workspace row and the Session rows it owns.
    ///
    /// The leaves belong to the workspace above them, so they stay tighter to
    /// it than one project group is to the next. Without this the workspace and
    /// its first Session read as two unrelated siblings.
    public var sessionGroupSpacing: CGFloat {
        isRich ? WarrenSpacing.xs : WarrenSpacing.xxs
    }

    /// Row height for the tree's resource rows.
    ///
    /// Rich mode carries one more tier and a status marker per leaf, so its
    /// rows get vertical room the compact list does not need. This is the one
    /// place the two modes are allowed to disagree about rhythm; every row kind
    /// reads it so a project, a workspace, and a Session stay on one grid.
    public var rowHeight: CGFloat {
        isRich
            ? WarrenLayoutMetrics.sidebarWorkspaceRowHeight + WarrenSpacing.xs
            : WarrenLayoutMetrics.sidebarWorkspaceRowHeight
    }
}
