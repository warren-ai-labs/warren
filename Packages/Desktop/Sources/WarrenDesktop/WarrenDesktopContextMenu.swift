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
    case button(title: String, destructive: Bool = false, action: () -> Void)
    /// A single-choice row: the checkmark sits in its own leading column so
    /// every name in the list stays aligned.
    case check(title: String, isOn: Bool, action: () -> Void)
    case divider
    case menu(title: String, actions: [WarrenDesktopContextMenuAction])
}
