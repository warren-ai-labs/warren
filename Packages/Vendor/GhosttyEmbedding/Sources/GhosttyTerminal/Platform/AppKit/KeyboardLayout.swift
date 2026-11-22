#if canImport(AppKit) && !canImport(UIKit)
    import Carbon.HIToolbox
    import Foundation

    enum KeyboardLayout {
        static var id: String? {
            guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            else {
                return nil
            }

            guard let rawProperty = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyInputSourceID
            ) else {
                return nil
            }

            let property = unsafeBitCast(rawProperty, to: CFString.self)
            return property as String
        }

        /// Translates a hardware keyCode with no modifiers against the active
        /// keyboard layout. On macOS 13, `NSEvent.characters(byApplyingModifiers: [])`
        /// can return `nil` when an input method is active or for synthetic
        /// events; querying the underlying UCKeyboardLayout preserves Ghostty's
        /// `unshifted_codepoint` for keybind matching (e.g. ⌘C / ⌘V).
        static func unshiftedCodepoint(for keyCode: UInt16) -> UInt32? {
            let candidates: [TISInputSource?] = [
                TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            ]
            for case let source? in candidates {
                guard let rawLayout = TISGetInputSourceProperty(
                    source,
                    kTISPropertyUnicodeKeyLayoutData
                ) else {
                    continue
                }
                let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout)
                    .takeUnretainedValue() as Data
                if let codepoint = translateUnshifted(keyCode: keyCode, layoutData: layoutData) {
                    return codepoint
                }
            }
            return nil
        }

        private static func translateUnshifted(
            keyCode: UInt16,
            layoutData: Data
        ) -> UInt32? {
            layoutData.withUnsafeBytes { buffer in
                guard let layout = buffer.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self)
                else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { return nil }
                let text = String(utf16CodeUnits: chars, count: length)
                return text.unicodeScalars.first?.value
            }
        }
    }
#endif
