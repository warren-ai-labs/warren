//
//  TerminalAppKitModifierState@AppKit.swift
//  WarrenGhosttyEmbedding
//
//  Created by Warren contributors on 2026/9/3.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    /// The logical modifier flags that AppKit can report for a modifier key.
    ///
    /// AppKit keeps the physical key code when a user remaps a modifier in
    /// System Settings, but reports the remapped key as a logical flag. The
    /// distinction is important for Caps Lock -> Control and similar setups.
    enum TerminalAppKitModifier: CaseIterable, Equatable {
        case shift
        case control
        case option
        case command
        case capsLock

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .shift: return .shift
            case .control: return .control
            case .option: return .option
            case .command: return .command
            case .capsLock: return .capsLock
            }
        }
    }

    struct TerminalAppKitModifierEvent {
        let modifier: TerminalAppKitModifier
        let action: ghostty_input_action_e
    }

    /// Converts AppKit's aggregate `flagsChanged` events into key transitions.
    ///
    /// `NSEvent.modifierFlags` describes the aggregate logical state, not the
    /// state of the physical key identified by `keyCode`. That is sufficient
    /// for ordinary modifier presses, but loses information when two keys map
    /// to the same logical modifier. Remembering the logical modifier assigned
    /// to each pressed physical key lets the matching release remain a release
    /// even while another key keeps the aggregate flag set.
    struct TerminalAppKitModifierState {
        private var previousFlags: NSEvent.ModifierFlags = []
        private var activeModifiers: [UInt16: TerminalAppKitModifier] = [:]
        private var learnedModifiers: [UInt16: TerminalAppKitModifier] = [:]

        mutating func resolve(
            keyCode: UInt16,
            flags: NSEvent.ModifierFlags
        ) -> TerminalAppKitModifierEvent? {
            let previousFlags = self.previousFlags
            self.previousFlags = flags

            // A key that we saw pressed is unambiguously releasing now. Do
            // this before looking at aggregate flags: the destination flag can
            // still be set by another physical key.
            if let modifier = activeModifiers.removeValue(forKey: keyCode) {
                return TerminalAppKitModifierEvent(
                    modifier: modifier,
                    action: GHOSTTY_ACTION_RELEASE
                )
            }

            let changed = changedModifiers(
                from: previousFlags,
                to: flags
            )
            guard let modifier = modifierForPress(
                keyCode: keyCode,
                flags: flags,
                previousFlags: previousFlags,
                changed: changed
            ) else {
                return nil
            }

            learnedModifiers[keyCode] = modifier
            let isPressed = flags.contains(modifier.flag)
            if isPressed {
                activeModifiers[keyCode] = modifier
            }

            return TerminalAppKitModifierEvent(
                modifier: modifier,
                action: isPressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
            )
        }

        mutating func reset() {
            previousFlags = []
            activeModifiers.removeAll(keepingCapacity: true)
            learnedModifiers.removeAll(keepingCapacity: true)
        }

        private func changedModifiers(
            from previousFlags: NSEvent.ModifierFlags,
            to flags: NSEvent.ModifierFlags
        ) -> [TerminalAppKitModifier] {
            TerminalAppKitModifier.allCases.filter { modifier in
                previousFlags.contains(modifier.flag) != flags.contains(modifier.flag)
            }
        }

        private func modifierForPress(
            keyCode: UInt16,
            flags: NSEvent.ModifierFlags,
            previousFlags: NSEvent.ModifierFlags,
            changed: [TerminalAppKitModifier]
        ) -> TerminalAppKitModifier? {
            // A remapped key normally changes exactly one logical flag. This
            // branch is also what handles an unknown physical key code.
            if changed.count == 1 {
                return changed[0]
            }

            // If several flags changed together, prefer the physical mapping
            // when it is one of those changes. This is conservative and avoids
            // assigning an unrelated logical modifier to a real key.
            if let physical = physicalModifier(for: keyCode),
               changed.contains(physical)
            {
                return physical
            }

            // Aggregate flags do not change when a second key is pressed for
            // the same logical modifier. A prior mapping handles remapped
            // keys seen earlier in this focus session; for a normal key the
            // physical mapping is authoritative.
            if let learned = learnedModifiers[keyCode],
               flags.contains(learned.flag) || previousFlags.contains(learned.flag)
            {
                return learned
            }

            guard let physical = physicalModifier(for: keyCode) else {
                return nil
            }

            // A known physical key with a different logical modifier is the
            // common first event for a remap while the destination modifier is
            // already held (for example Caps Lock -> Control). If exactly one
            // logical modifier is active, it is the only evidence available
            // for that remap, so use it. With multiple candidates we fall back
            // to the physical mapping instead of manufacturing an arbitrary
            // binding.
            let active = Set(activeModifiers.values)
            if active.count == 1,
               let only = active.first,
               only != physical,
               !flags.contains(physical.flag),
               !previousFlags.contains(physical.flag)
            {
                return only
            }

            // A normal second-side press leaves the aggregate physical flag
            // set and is identified by its physical key code. If the physical
            // flag is absent, there is no evidence that a known key configured
            // as "No Action" should be delivered to Ghostty.
            guard flags.contains(physical.flag) || previousFlags.contains(physical.flag)
            else { return nil }
            return physical
        }

        private func physicalModifier(for keyCode: UInt16) -> TerminalAppKitModifier? {
            switch keyCode {
            case 0x39: return .capsLock
            case 0x38, 0x3C: return .shift
            case 0x3B, 0x3E: return .control
            case 0x3A, 0x3D: return .option
            case 0x37, 0x36: return .command
            default: return nil
            }
        }
    }
#endif
