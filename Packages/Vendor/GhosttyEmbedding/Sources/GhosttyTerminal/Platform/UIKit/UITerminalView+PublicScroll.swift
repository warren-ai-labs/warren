//
//  UITerminalView+PublicScroll.swift
//  WarrenGhosttyEmbedding
//
//  Public viewport jumps for hosts with their own key bar. Paging keys on a
//  phone bar (pgup/pgdn) write CSI 5~/6~ to the PTY, which agent TUIs ignore —
//  what a mobile host actually wants is to move the *viewport* through
//  scrollback, and libghostty already ships that as the scroll_to_top /
//  scroll_to_bottom keybind actions. This forwards to the surface's binding
//  action path so the jump behaves exactly like a bound key on desktop.
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    public extension UITerminalView {
        /// Jump the viewport to the top of scrollback.
        func scrollToTop() {
            surface?.performBindingAction("scroll_to_top")
        }

        /// Jump the viewport back to the live prompt at the bottom.
        func scrollToBottom() {
            surface?.performBindingAction("scroll_to_bottom")
        }
    }
#endif
