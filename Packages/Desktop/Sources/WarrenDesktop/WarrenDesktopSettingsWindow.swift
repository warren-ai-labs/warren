import AppKit
import SwiftUI
import WarrenDesignSystem

/// Presents the settings page in its own window.
///
/// The page keeps living in the root view's hierarchy, so its bindings and
/// callbacks stay the ones the app already wired; this only moves where it is
/// drawn. A separate window is what lets the user change a terminal font or the
/// translucency while watching the real terminal, which an in-window overlay
/// covered up.
@MainActor
struct WarrenDesktopSettingsWindowPresenter: NSViewRepresentable {
    let isPresented: Bool
    /// Bumped every time the page is asked for, so requesting it while its
    /// window is already open brings that window forward.
    let activation: Int
    let content: AnyView
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.update(
            isPresented: isPresented,
            activation: activation,
            content: content
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var onClose: () -> Void = {}
        private var window: NSWindow?
        private var hosting: NSHostingView<AnyView>?
        private var lastActivation = Int.min

        /// The window the presenter owns, once it has been asked to present.
        var presentedWindow: NSWindow? { window }

        func update(isPresented: Bool, activation: Int, content: AnyView) {
            guard isPresented else {
                window?.orderOut(nil)
                return
            }
            let window = window ?? makeWindow(content: content)
            hosting?.rootView = Self.root(content)
            if !window.isVisible || activation != lastActivation {
                window.makeKeyAndOrderFront(nil)
            }
            lastActivation = activation
        }

        private func makeWindow(content: AnyView) -> NSWindow {
            let hosting = NSHostingView(rootView: Self.root(content))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentView = hosting
            // Wide enough that a page column never drops below the width its
            // two-column rows and the Usage cards are laid out for.
            window.minSize = NSSize(width: 820, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameAutosaveName("warren.settings") {
                window.center()
            }
            self.hosting = hosting
            self.window = window
            return window
        }

        private static func root(_ content: AnyView) -> AnyView {
            AnyView(WarrenDesktopSettingsWindowRoot(content: content))
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}

/// The settings window's own root.
///
/// A second `NSHostingView` inherits nothing from the main window's hierarchy,
/// so the menu surface and tooltip host the main root installs never reached
/// this window: every picker and menu button here found no menu center and a
/// click on it did nothing. The window gets its own, which also keeps its
/// menus drawn inside it rather than in the main window.
private struct WarrenDesktopSettingsWindowRoot: View {
    let content: AnyView

    @StateObject private var menuCenter = WarrenDesktopMenuCenter()

    var body: some View {
        content
            .environment(\.warrenMenuCenter, menuCenter)
            .warrenMenuOverlay(menuCenter)
            .warrenTooltipHost()
    }
}
