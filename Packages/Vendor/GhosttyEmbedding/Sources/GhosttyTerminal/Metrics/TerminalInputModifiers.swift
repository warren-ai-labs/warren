//
//  TerminalInputModifiers.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
    import IOKit
#endif

public struct TerminalInputModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalInputModifiers(rawValue: 1 << 0)
    public static let ctrl = TerminalInputModifiers(rawValue: 1 << 1)
    public static let alt = TerminalInputModifiers(rawValue: 1 << 2)
    public static let super_ = TerminalInputModifiers(rawValue: 1 << 3)
    public static let caps = TerminalInputModifiers(rawValue: 1 << 4)
    public static let num = TerminalInputModifiers(rawValue: 1 << 5)
    public static let shiftRight = TerminalInputModifiers(rawValue: 1 << 6)
    public static let ctrlRight = TerminalInputModifiers(rawValue: 1 << 7)
    public static let altRight = TerminalInputModifiers(rawValue: 1 << 8)
    public static let superRight = TerminalInputModifiers(rawValue: 1 << 9)

    public var ghosttyMods: ghostty_input_mods_e {
        ghostty_input_mods_e(rawValue)
    }

    #if canImport(UIKit)
        public init(from flags: UIKeyModifierFlags) {
            var mods = TerminalInputModifiers()
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.control) { mods.insert(.ctrl) }
            if flags.contains(.alternate) { mods.insert(.alt) }
            if flags.contains(.command) { mods.insert(.super_) }
            if flags.contains(.alphaShift) { mods.insert(.caps) }
            if flags.contains(.numericPad) { mods.insert(.num) }
            self = mods
        }

    #elseif canImport(AppKit)
        /// Derives Ghostty modifier flags from AppKit's aggregate flags and
        /// the device-dependent right-side masks in `IOKit/hidsystem/IOLLEvent.h`.
        ///
        /// Each right-side bit is gated on its aggregate logical flag so that
        /// callers stripping `.control` / `.command` (for `consumed_mods` or
        /// translation events) never leak orphaned `*_RIGHT` bits when a user
        /// holds a right-side or remapped modifier (e.g. Caps Lock -> Right Control).
        public init(from flags: NSEvent.ModifierFlags) {
            var mods = TerminalInputModifiers()
            let raw = flags.rawValue
            if flags.contains(.shift) {
                mods.insert(.shift)
                if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods.insert(.shiftRight) }
            }
            if flags.contains(.control) {
                mods.insert(.ctrl)
                if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods.insert(.ctrlRight) }
            }
            if flags.contains(.option) {
                mods.insert(.alt)
                if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods.insert(.altRight) }
            }
            if flags.contains(.command) {
                mods.insert(.super_)
                if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods.insert(.superRight) }
            }
            if flags.contains(.capsLock) { mods.insert(.caps) }
            if flags.contains(.numericPad) { mods.insert(.num) }
            self = mods
        }
    #endif
}
