//
//  AppTerminalView+Input.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit
    import UniformTypeIdentifiers

    extension AppTerminalView {
        /// Whether the general pasteboard holds an image with no text form
        /// (e.g. a fresh screenshot). `paste_from_clipboard` can only write
        /// text into the pty, so such a paste must instead reach the running
        /// TUI as a Ctrl+V keystroke — agents like Claude Code respond to it
        /// by reading the image straight off the system clipboard.
        private var pasteboardHoldsImageOnly: Bool {
            let pasteboard = NSPasteboard.general
            guard pasteboard.string(forType: .string) == nil else { return false }
            return pasteboard.canReadItem(
                withDataConformingToTypes: [UTType.image.identifier]
            )
        }

        override open func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override open func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown else { return false }
            guard window?.firstResponder === self else { return false }
            guard let surface else { return false }

            // Cmd+V with an image-only clipboard: ghostty's `super+v` binding
            // would consume the key and paste nothing (no text to write).
            // Hand the paste to the TUI as Ctrl+V before the binding eats it.
            if event.charactersIgnoringModifiers == "v",
               event.modifierFlags.contains(.command),
               event.modifierFlags.isDisjoint(with: [.shift, .option, .control]),
               pasteboardHoldsImageOnly
            {
                surface.submitCtrlV()
                return true
            }

            if keyIsBinding(event, on: surface) {
                keyDown(with: event)
                return true
            }

            let equivalent: String
            switch event.charactersIgnoringModifiers {
            case "\r":
                guard event.modifierFlags.contains(.control) else {
                    return false
                }
                equivalent = "\r"

            case "/":
                guard event.modifierFlags.contains(.control),
                      event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
                else {
                    return false
                }
                equivalent = "_"

            default:
                if event.timestamp == 0 {
                    return false
                }

                if !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control)
                {
                    lastPerformKeyEvent = nil
                    return false
                }

                if let lastPerformKeyEvent,
                   lastPerformKeyEvent == event.timestamp
                {
                    self.lastPerformKeyEvent = nil
                    equivalent = event.characters ?? ""
                    break
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            guard let translatedEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) else {
                return false
            }

            keyDown(with: translatedEvent)
            return true
        }

        override open func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override open func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override open func doCommand(by selector: Selector) {
            if let lastPerformKeyEvent,
               let current = NSApp.currentEvent,
               lastPerformKeyEvent == current.timestamp
            {
                NSApp.sendEvent(current)
                return
            }

            if TerminalKeyEventHandler.shouldReplayInterpretedCommand(selector) {
                inputHandler?.recordInterpretedCommand(selector)
            }
        }

        @IBAction open func copy(_: Any?) {
            _ = copySelectedTextToPasteboard()
        }

        @IBAction func paste(_: Any?) {
            if pasteboardHoldsImageOnly {
                TerminalDebugLog.log(
                    .input,
                    "paste image-only clipboard, forwarding ctrl+v to tui"
                )
                surface?.submitCtrlV()
                return
            }
            if let text = NSPasteboard.general.string(forType: .string) {
                TerminalDebugLog.log(
                    .input,
                    "paste binding bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
                )
            }
            _ = surface?.performBindingAction("paste_from_clipboard")
        }

        @IBAction override open func selectAll(_: Any?) {
            _ = surface?.performBindingAction("select_all")
        }

        internal func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        /// Let the click that activates the window also reach the grid.
        ///
        /// Warren derives terminal focus from SwiftUI intent, and the surface
        /// manager's focus path refuses to act on a window that is not yet key.
        /// Without this the first click on an inactive window is consumed by
        /// activation alone: it neither selects the pane it landed in nor
        /// reaches the program running there, so the user has to click twice.
        override open func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override open func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            pointerSelectionStartPoint = CGPoint(x: x, y: y)
            pendingSelectionMenuPoint = nil
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override open func mouseUp(with event: NSEvent) {
            stopSelectionAutoscroll()
            lastDragPoint = nil
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
            finishPointerSelection(at: CGPoint(x: x, y: y))
        }

        override open func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            if let menuPoint = selectionMenuPoint(at: CGPoint(x: x, y: y)) {
                pendingSelectionMenuPoint = menuPoint
                return
            }
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override open func rightMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            if pendingSelectionMenuPoint != nil {
                pendingSelectionMenuPoint = nil
                showSelectionCopyMenu(with: event)
                return
            }
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override open func menu(for event: NSEvent) -> NSMenu? {
            let (x, y) = mousePoint(from: event)
            guard selectionMenuPoint(at: CGPoint(x: x, y: y)) != nil else {
                return super.menu(for: event)
            }
            return selectionContextMenu()
        }

        override open func otherMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override open func otherMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override open func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        /// The tracking area asks for enter and exit as well as moves, so
        /// answer both. An enter that is not reported leaves Ghostty acting on
        /// wherever the pointer last was, which after a pane switch is a cell
        /// in a different surface.
        override open func mouseEntered(with event: NSEvent) {
            mouseMoved(with: event)
        }

        /// Tell Ghostty the pointer is gone rather than leaving it parked on
        /// the last cell it saw. Without this the cell stays hovered after the
        /// pointer has moved to another pane: a hyperlink under it keeps its
        /// underline, and a mouse-mode program keeps its highlight.
        ///
        /// A negative position is how "outside the grid" is expressed; there is
        /// no separate exit entry point in the surface API.
        override open func mouseExited(with event: NSEvent) {
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: -1, y: -1, mods: mods.ghosttyMods)
        }

        override open func mouseDragged(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let point = CGPoint(x: x, y: y)
            updatePointerSelectionRect(to: point)
            lastDragPoint = point
            updateSelectionAutoscroll(for: point, mods: event.modifierFlags)
            mouseMoved(with: event)
        }

        override open func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override open func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override open func scrollWheel(with event: NSEvent) {
            // Position first: a mouse-mode program reads the scroll against the
            // cell the pointer is over, and scrolling does not require the
            // pointer to have moved within this view beforehand. Without this
            // the first scroll after the pointer arrives by any path other than
            // a tracked move is attributed to a stale cell.
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            let scrollMods = TerminalScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY,
                mods: scrollMods.rawValue
            )
        }

        /// Scrolls the viewport while a selection drag is held past the top or
        /// bottom edge, so a selection can reach beyond one screen of output.
        ///
        /// AppKit stops delivering `mouseDragged` as soon as the pointer stops
        /// moving, and a drag held just outside the view is exactly that: the
        /// pointer is stationary and the selection would sit still at the edge.
        /// The timer re-sends the held position on each tick and asks Ghostty to
        /// scroll, which extends the selection in the direction of the drag.
        private func updateSelectionAutoscroll(
            for point: CGPoint,
            mods: NSEvent.ModifierFlags
        ) {
            // Only a selection drag autoscrolls. A drag reported while no
            // selection is in flight belongs to a mouse-mode program, which
            // does its own scrolling.
            guard pointerSelectionStartPoint != nil else {
                stopSelectionAutoscroll()
                return
            }
            let overshoot = Self.autoscrollOvershoot(for: point, in: bounds)
            guard overshoot != 0 else {
                stopSelectionAutoscroll()
                return
            }
            guard selectionAutoscrollTimer == nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.performSelectionAutoscrollTick(mods: mods)
                }
            }
            // The tracking loop AppKit runs during a drag uses its own mode, so
            // a timer added to the default mode alone would never fire until
            // the drag ended.
            RunLoop.main.add(timer, forMode: .common)
            selectionAutoscrollTimer = timer
        }

        private func performSelectionAutoscrollTick(mods: NSEvent.ModifierFlags) {
            guard let point = lastDragPoint,
                  pointerSelectionStartPoint != nil else {
                stopSelectionAutoscroll()
                return
            }
            let overshoot = Self.autoscrollOvershoot(for: point, in: bounds)
            guard overshoot != 0 else {
                stopSelectionAutoscroll()
                return
            }
            let inputMods = TerminalInputModifiers(from: mods)
            // Re-send the held position so the selection's far end tracks the
            // rows that scrolling brings into view.
            surface?.sendMousePos(x: point.x, y: point.y, mods: inputMods.ghosttyMods)
            surface?.sendMouseScroll(
                x: 0,
                y: overshoot,
                mods: TerminalScrollModifiers(precision: false).rawValue
            )
        }

        func stopSelectionAutoscroll() {
            selectionAutoscrollTimer?.invalidate()
            selectionAutoscrollTimer = nil
        }

        /// Rows to scroll per tick for a drag point, signed so that a drag above
        /// the view scrolls toward earlier output. Zero while the point is
        /// inside. Capped so a drag far past the edge stays controllable rather
        /// than flinging through the scrollback.
        static func autoscrollOvershoot(for point: CGPoint, in bounds: CGRect) -> Double {
            let maximumRows = 5.0
            // Ghostty's y axis grows downward from the top of the view, so a
            // negative y is above it.
            if point.y < 0 {
                return min(ceil(-point.y / 10), maximumRows)
            }
            if point.y > bounds.height {
                return -min(ceil((point.y - bounds.height) / 10), maximumRows)
            }
            return 0
        }

        private func updatePointerSelectionRect(to point: CGPoint) {
            guard let start = pointerSelectionStartPoint else { return }
            lastPointerSelectionRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(start.x - point.x),
                height: abs(start.y - point.y)
            ).insetBy(dx: -2, dy: -2)
        }

        private func finishPointerSelection(at point: CGPoint) {
            defer { pointerSelectionStartPoint = nil }
            guard let start = pointerSelectionStartPoint else { return }
            let dragDistance = hypot(point.x - start.x, point.y - start.y)
            if dragDistance < 2 {
                lastPointerSelectionRect = nil
            } else {
                updatePointerSelectionRect(to: point)
            }
        }

        private func showSelectionCopyMenu(with event: NSEvent) {
            let menu = selectionContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        private func keyIsBinding(
            _ event: NSEvent,
            on surface: TerminalSurface
        ) -> Bool {
            guard let rawSurface = surface.rawValue else {
                return false
            }

            var keyEvent = event.buildKeyInput(action: GHOSTTY_ACTION_PRESS)
            var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
            let text = event.characters ?? ""
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(rawSurface, keyEvent, &bindingFlags)
            }
        }
    }
#endif
