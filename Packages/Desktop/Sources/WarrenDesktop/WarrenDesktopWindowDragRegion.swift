#if os(macOS)
import AppKit
import SwiftUI

/// A leaf-only macOS window drag surface.
///
/// Superset marks only empty chrome fillers as draggable. Keeping this as a
/// dedicated view makes it impossible for a terminal, tab, or button subtree
/// to inherit window-drag behavior.
struct WarrenDesktopWindowDragRegion: NSViewRepresentable {
    private let identifier: String?

    init(identifier: String? = nil) {
        self.identifier = identifier
    }

    func makeNSView(context: Context) -> WarrenDesktopWindowDragView {
        let view = WarrenDesktopWindowDragView()
        applyIdentifier(to: view)
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopWindowDragView, context: Context) {
        applyIdentifier(to: nsView)
    }

    private func applyIdentifier(to view: WarrenDesktopWindowDragView) {
        view.identifier = identifier.map(NSUserInterfaceItemIdentifier.init(rawValue:))
    }
}

final class WarrenDesktopWindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {}

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            guard let window else { return }
            WarrenDesktopTitleBarDoubleClick.perform(
                WarrenDesktopTitleBarDoubleClick.current(),
                on: window
            )
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// What a double-click on empty chrome does: whatever System Settings ›
/// Desktop & Dock says a title bar double-click does, so Warren's
/// borderless chrome behaves like every titled window beside it. It used to
/// always enter Spaces full screen, which no title bar on the system does.
enum WarrenDesktopTitleBarDoubleClick: Equatable {
    case zoom
    case minimize
    case ignore

    /// Reads the global preference. "Fill" (macOS 15) and "Maximize" both
    /// mean the zoom; an unset preference is the system default, zoom.
    static func current(defaults: UserDefaults = .standard) -> Self {
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        return action(for: global?["AppleActionOnDoubleClick"] as? String)
    }

    static func action(for value: String?) -> Self {
        switch value {
        case "Minimize": .minimize
        case "None": .ignore
        default: .zoom
        }
    }

    @MainActor
    static func perform(_ action: Self, on window: NSWindow) {
        switch action {
        case .minimize:
            window.miniaturize(nil)
        case .ignore:
            break
        case .zoom:
            zoom(window)
        }
    }

    /// `NSWindow.zoom(_:)` needs a title bar to find its standard frame, and
    /// this window is borderless, so the toggle is done by hand: fill the
    /// screen's visible frame, and a second double-click puts back the frame
    /// the window had.
    @MainActor
    private static func zoom(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        if window.frame.equalTo(visible), let restored = restoredFrames[window.windowNumber] {
            restoredFrames[window.windowNumber] = nil
            window.setFrame(restored, display: true, animate: true)
        } else {
            restoredFrames[window.windowNumber] = window.frame
            window.setFrame(visible, display: true, animate: true)
        }
    }

    @MainActor
    private static var restoredFrames: [Int: NSRect] = [:]
}
#endif
