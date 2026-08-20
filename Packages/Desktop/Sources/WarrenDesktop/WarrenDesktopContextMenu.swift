import SwiftUI

/// The shared native context-menu action model. Every sidebar and tab menu
/// declares its actions here so labels, ordering, separators and destructive
/// state stay identical across clients instead of being re-invented per row.
enum WarrenDesktopContextMenuAction {
    case button(title: String, destructive: Bool = false, action: () -> Void)
    case divider
    case menu(title: String, actions: [WarrenDesktopContextMenuAction])
}

/// Renders a context-menu action model into native AppKit menu content.
/// Nested menus keep the same model, so move targets and other grouped
/// actions cannot diverge from the flat action order.
@MainActor
struct WarrenDesktopContextMenuView: View {
    let actions: [WarrenDesktopContextMenuAction]

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            switch action {
            case .button(let title, let destructive, let action):
                Button(title, role: destructive ? .destructive : nil, action: action)
            case .divider:
                Divider()
            case .menu(let title, let nestedActions):
                Menu(title) {
                    WarrenDesktopContextMenuView(actions: nestedActions)
                }
            }
        }
    }
}

@MainActor
func WarrenDesktopContextMenu(_ actions: [WarrenDesktopContextMenuAction]) -> some View {
    WarrenDesktopContextMenuView(actions: actions)
}
