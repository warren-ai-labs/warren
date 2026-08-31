//
//  TerminalInputText.swift
//  WarrenGhosttyEmbedding
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/NSEvent+Extension.swift
//  Keep the AppKit text filtering here aligned with Ghostty's native
//  `ghosttyCharacters` behavior so future upstream syncs stay mechanical.

import Foundation

enum TerminalInputText {
    /// True when the first scalar is an ASCII control character (C0 or DEL).
    /// AppKit can report Ctrl-key input through `insertText`; those bytes must
    /// instead be encoded from the physical key and its modifiers by Ghostty.
    static func startsWithASCIIControlCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    static func filteredFunctionKeyText(_ text: String?) -> String? {
        guard let text else { return nil }
        if isUIKitNamedFunctionKey(text) {
            return nil
        }
        guard text.count == 1, let scalar = text.unicodeScalars.first else {
            return text
        }

        if isPrivateUseFunctionKey(scalar) {
            return nil
        }

        return text
    }

    static func lineCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}
