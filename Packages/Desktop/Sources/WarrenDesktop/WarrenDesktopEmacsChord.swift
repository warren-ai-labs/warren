import AppKit

public enum EmacsSplitAction: Equatable, Sendable {
    /// C-x 2: Split window below (horizontal divider, top & bottom)
    case splitBelow
    /// C-x 3: Split window right (vertical divider, left & right)
    case splitRight
    /// C-x 0: Delete current window (close split pane)
    case closePane
    /// C-x 1: Delete other windows (maximize current pane)
    case maximize
    /// C-x o: Other window (cycle focus to next pane)
    case otherPane
}

@MainActor
public final class EmacsSplitChordMonitor {
    public static let shared = EmacsSplitChordMonitor()

    public var onAction: ((EmacsSplitAction) -> Bool)?
    public private(set) var inChord = false
    public var onChordStateChanged: ((Bool) -> Void)?
    /// Whether a terminal surface currently owns keyboard focus.
    ///
    /// Injected because the terminal view class lives below this package. When
    /// no answer is supplied the monitor falls back to the responder inspection
    /// in `shouldHandle`, which keeps the chord working in fixtures and tests
    /// that drive it without a live surface.
    public var isTerminalFocused: (() -> Bool)?

    private var chordTimer: Timer?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    public func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        cancelChord()
    }

    public func handle(event: NSEvent) -> NSEvent? {
        // The monitor is installed at the application level, but the chord is
        // a terminal command. Let AppKit text controls keep ownership of
        // their native C-x editing command (command palette, Settings, and
        // search fields), and cancel a pending chord when focus moves there.
        guard shouldHandle(event: event) else {
            cancelChord()
            return event
        }

        if inChord {
            cancelChord()
            guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
                return event
            }
            switch chars {
            case "2":
                if onAction?(.splitBelow) == true { return nil }
            case "3":
                if onAction?(.splitRight) == true { return nil }
            case "0":
                if onAction?(.closePane) == true { return nil }
            case "1":
                if onAction?(.maximize) == true { return nil }
            case "o":
                if onAction?(.otherPane) == true { return nil }
            case "g" where event.modifierFlags.contains(.control):
                // C-g cancels chord without emitting
                return nil
            case "x" where event.modifierFlags.contains(.control):
                // C-x C-x emits Ctrl+X
                return event
            default:
                break
            }
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.control] && event.charactersIgnoringModifiers == "x" {
            inChord = true
            onChordStateChanged?(true)
            chordTimer?.invalidate()
            chordTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancelChord()
                }
            }
            return nil
        }

        return event
    }

    /// C-x is a terminal command, so the chord belongs to the terminal only.
    ///
    /// This used to name the controls that had to keep their own C-x editing
    /// command — text views and text fields — and let everything else through.
    /// That list cannot be complete: the embedded editor is a WKWebView, so
    /// code-server's own Cut was swallowed here and the keystroke started a
    /// chord instead. Asking whether the terminal has focus inverts the test, so
    /// a surface that is not a terminal keeps its keys without having to be
    /// enumerated first.
    private func shouldHandle(event: NSEvent) -> Bool {
        if let isTerminalFocused {
            return isTerminalFocused()
        }
        guard let responder = NSApp.keyWindow?.firstResponder else { return true }
        if responder is NSTextView || responder is NSTextField {
            return false
        }
        return true
    }

    public func cancelChord() {
        guard inChord else { return }
        inChord = false
        chordTimer?.invalidate()
        chordTimer = nil
        onChordStateChanged?(false)
    }
}
