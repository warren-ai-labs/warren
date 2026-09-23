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
    /// The text Ghostty should encode a committed `insertText` string with, or
    /// `nil` when the commit must be encoded from the physical key instead.
    ///
    /// AppKit commits Ctrl-key input through `insertText` as a raw C0 byte.
    /// Ghostty's encoder reads a single UTF-8 byte as the character to convert
    /// into a C0 sequence, so an already-encoded byte falls out of its ctrl
    /// table and degrades into a fixterms CSI-u sequence instead of `0x03`.
    /// Dropping the text makes Ghostty fall back to the physical keycode plus
    /// the Control modifier, which is what it expects on every platform.
    static func keyEncodingText(_ text: String) -> String? {
        guard !isSingleASCIIControlCharacter(text) else { return nil }
        return text
    }

    /// True only when the whole string is one ASCII control scalar, matching
    /// Ghostty's `isControlUtf8`. A control byte followed by more text is not a
    /// pure control commit, so it must not be dropped.
    static func isSingleASCIIControlCharacter(_ text: String) -> Bool {
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else {
            return false
        }
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
