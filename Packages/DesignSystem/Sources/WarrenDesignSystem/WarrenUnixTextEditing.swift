import AppKit
import SwiftUI

/// Installs the shared Unix/readline editing vocabulary for AppKit text
/// fields. The monitor only handles an NSTextView field editor, so terminal
/// surfaces and other key responders keep their native event path.
public struct WarrenUnixTextEditingBridge: NSViewRepresentable {
    public init() {}

    @MainActor
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    public func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    @MainActor
    public func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    public final class Coordinator {
        private var monitor: Any?

        @MainActor
        fileprivate func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                WarrenUnixTextEditing.handle(event) ? nil : event
            }
        }

        isolated deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

public extension View {
    /// Enables command/control editing shortcuts for all native inputs below
    /// the modified view.
    func warrenUnixTextEditing() -> some View {
        background(WarrenUnixTextEditingBridge())
    }
}

enum WarrenUnixTextEditing {
    @MainActor
    static func handle(_ event: NSEvent) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isFieldEditor,
              textView.isEditable,
              textView.window != nil else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = event.keyCode

        if modifiers == .command, (key == "a" || keyCode == 0) {
            textView.selectAll(nil)
            return true
        }
        guard modifiers == .control else { return false }

        let mappedKey = keyForCode(keyCode)
        switch mappedKey.isEmpty ? key : mappedKey {
        case "a": textView.moveToBeginningOfLine(nil)
        case "e": textView.moveToEndOfLine(nil)
        case "f": textView.moveRight(nil)
        case "b": textView.moveLeft(nil)
        case "k": textView.deleteToEndOfLine(nil)
        case "u": textView.deleteToBeginningOfLine(nil)
        case "w": textView.deleteWordBackward(nil)
        default: return false
        }
        return true
    }

    private static func keyForCode(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "a"
        case 14: "e"
        case 3: "f"
        case 11: "b"
        case 40: "k"
        case 32: "u"
        case 13: "w"
        default: ""
        }
    }
}
