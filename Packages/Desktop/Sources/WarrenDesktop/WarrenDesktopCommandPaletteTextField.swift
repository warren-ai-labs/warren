import AppKit
import SwiftUI

enum WarrenDesktopCommandPaletteTextCommand: Equatable {
    case move(WarrenDesktopCommandPaletteSelection.Movement)
    case submit
    case cancel

    static func command(for selector: Selector) -> Self? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            .move(.previous)
        case #selector(NSResponder.moveDown(_:)):
            .move(.next)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.moveToBeginningOfLine(_:)):
            .move(.first)
        case #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.moveToEndOfLine(_:)):
            .move(.last)
        case #selector(NSResponder.insertNewline(_:)):
            .submit
        case #selector(NSResponder.cancelOperation(_:)):
            .cancel
        default:
            nil
        }
    }
}

/// AppKit owns key interpretation for its field editor. Handling movement in
/// the NSTextField delegate keeps arrows, Home/End, Return, Escape, and IME
/// composition reliable on every supported macOS version.
struct WarrenDesktopCommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (WarrenDesktopCommandPaletteSelection.Movement) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WarrenDesktopCommandPaletteNativeTextField {
        let textField = WarrenDesktopCommandPaletteNativeTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13, weight: .light)
        textField.textColor = .labelColor
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(
        _ nsView: WarrenDesktopCommandPaletteNativeTextField,
        context: Context
    ) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WarrenDesktopCommandPaletteTextField

        init(parent: WarrenDesktopCommandPaletteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let command = WarrenDesktopCommandPaletteTextCommand.command(
                for: commandSelector
            ) else { return false }
            switch command {
            case .move(let movement):
                parent.onMove(movement)
            case .submit:
                guard !textView.hasMarkedText() else { return false }
                parent.onSubmit()
            case .cancel:
                parent.onCancel()
            }
            return true
        }
    }
}

final class WarrenDesktopCommandPaletteNativeTextField: NSTextField {
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
