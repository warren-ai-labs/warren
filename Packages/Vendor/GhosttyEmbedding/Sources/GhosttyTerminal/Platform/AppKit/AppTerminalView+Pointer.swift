//
//  AppTerminalView+Pointer.swift
//  WarrenGhosttyEmbedding
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    @MainActor
    extension AppTerminalView {
        /// Applies a shape Ghostty asked for.
        ///
        /// The shape is published through cursor rects rather than
        /// `NSCursor.set()`. AppKit owns the pointer while it is inside a
        /// rect, so a neighbouring view that also wants a cursor — a split
        /// divider abutting this surface — cannot win by being the last one to
        /// call `set()`, and the pointer is restored on exit without this view
        /// having to observe the exit at all.
        func applyMouseShape(_ shape: TerminalMouseShape) {
            guard terminalMouseShape != shape else { return }
            terminalMouseShape = shape
            // Apply it now if the pointer is already inside. AppKit asks for the
            // shape through `cursorUpdate` when the pointer crosses the
            // boundary, which has already happened by the time a program asks
            // for a different one.
            guard pointerIsInside else { return }
            Self.cursor(for: shape).set()
        }

        /// Hides the pointer while the user types, and restores it on the next
        /// move.
        ///
        /// `setHiddenUntilMouseMoves` rather than `NSCursor.hide()`: hiding is
        /// reference counted, and the terminal has no event that reliably
        /// balances every hide (a surface can be torn down mid-keystroke),
        /// which would leave the pointer hidden for the whole app. The
        /// self-restoring form also matches what Ghostty asks for, since it
        /// re-requests visibility on the next mouse move anyway.
        ///
        /// Only the focused surface in the key window may hide the pointer. A
        /// background pane still receives output, and a program clearing the
        /// pointer there would take it away from whatever the user is
        /// actually pointing at.
        func applyMouseVisibility(_ visible: Bool) {
            guard visible else {
                guard window?.isKeyWindow == true,
                      window?.firstResponder === self else { return }
                NSCursor.setHiddenUntilMouseMoves(true)
                return
            }
            NSCursor.setHiddenUntilMouseMoves(false)
        }

        /// AppKit's own hook for "the pointer is over you, set your cursor".
        ///
        /// Preferred over a cursor rect: the tracking area this view already
        /// keeps delivers it, so there is no rect to re-register as the pane is
        /// resized or reparented, and nothing to lose when SwiftUI reframes the
        /// view after creating it.
        override open func cursorUpdate(with event: NSEvent) {
            Self.cursor(for: terminalMouseShape).set()
        }

        /// Maps Ghostty's CSS-derived shapes onto AppKit's cursors.
        ///
        /// Several shapes have no public AppKit equivalent on macOS 13: the
        /// busy states, the diagonal resizes, and zoom. Those fall back to the
        /// arrow rather than approximating with an unrelated cursor, which is
        /// what Ghostty's own macOS app does for the same gaps.
        static func cursor(for shape: TerminalMouseShape) -> NSCursor {
            switch shape {
            case .text:
                return .iBeam
            case .verticalText:
                return .iBeamCursorForVerticalLayout
            case .pointer:
                return .pointingHand
            case .crosshair, .cell:
                return .crosshair
            case .contextMenu:
                return .contextualMenu
            case .alias:
                return .dragLink
            case .copy:
                return .dragCopy
            case .noDrop, .notAllowed:
                return .operationNotAllowed
            case .grab, .move, .allScroll:
                return .openHand
            case .grabbing:
                return .closedHand
            case .colResize, .ewResize, .eResize, .wResize:
                return .resizeLeftRight
            case .rowResize, .nsResize, .nResize, .sResize:
                return .resizeUpDown
            case .default, .help, .progress, .wait,
                 .neResize, .nwResize, .seResize, .swResize,
                 .neswResize, .nwseResize, .zoomIn, .zoomOut:
                return .arrow
            }
        }
    }
#endif
