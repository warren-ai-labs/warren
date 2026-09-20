import CoreGraphics
import WarrenDesignSystem

/// Room a workspace row has to leave for the accessories on its trailing edge.
///
/// The editor entry and the Task link are drawn in an overlay so their buttons
/// stay outside the row's own Button — a Button nested in another Button's label
/// never receives the click on macOS. An overlay takes no layout space, so the
/// row's content lays itself out across the full width and the accessories are
/// drawn on top of it: the Workspace name and the activity marker disappear
/// underneath them. A Workspace with both an open editor and a Task loses the
/// most room, which is where it shows first.
///
/// The row insets its content by this much instead. The name then truncates
/// against the accessories rather than running below them, and the row still
/// fills the rail, so the whole width stays clickable.
///
/// Arithmetic rather than measurement: both accessories are glyph buttons with
/// explicit frames, so the width is known without a layout pass, and the
/// constants below are the ones the row draws with.
enum WarrenDesktopWorkspaceRowAccessories {
    /// Hit target for the editor entry glyph.
    static let editorEntryWidth: CGFloat = 20
    /// The Task link is wider because it carries the word "Task", not a glyph.
    static let taskLinkWidth: CGFloat = 32

    static func inset(isEditorMarked: Bool, showsTaskLink: Bool) -> CGFloat {
        var inset: CGFloat = 0
        if isEditorMarked {
            inset += editorEntryWidth
        }
        if showsTaskLink {
            inset += taskLinkWidth
        }
        // A row with no accessories keeps its full width; an inset here would
        // truncate names for space nothing occupies.
        guard inset > 0 else { return 0 }
        if isEditorMarked, showsTaskLink {
            inset += WarrenSpacing.xs
        }
        // The overlay's own trailing padding, so the inset reaches where the
        // accessories actually start rather than where their frames do.
        return inset + WarrenSpacing.compact
    }
}
