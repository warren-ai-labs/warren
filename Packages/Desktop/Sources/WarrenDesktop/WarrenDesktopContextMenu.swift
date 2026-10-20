import Foundation

/// The shared context-menu action model. Every sidebar, Task, Tab, pane and
/// Inspector menu declares its actions here so labels, ordering, separators
/// and destructive state stay identical across clients instead of being
/// re-invented per row.
///
/// The Workbench renders this model itself, on the shared menu surface, so
/// the model carries no view types: a right-click, a menu button and a
/// check list all read from the same list.
public enum WarrenDesktopContextMenuAction {
    /// `isEnabled` is how a row states a reason the action cannot run right
    /// now. The row stays in the menu, muted and unselectable: removing it
    /// would make the menu's shape depend on state the user cannot see, and a
    /// missing item reads as a bug while a dim one reads as a rule.
    case button(title: String, destructive: Bool = false, isEnabled: Bool = true, action: () -> Void)
    /// A single-choice row: the checkmark sits in its own leading column so
    /// every name in the list stays aligned.
    case check(title: String, isOn: Bool, action: () -> Void)
    case divider
    case menu(title: String, actions: [WarrenDesktopContextMenuAction])
}
