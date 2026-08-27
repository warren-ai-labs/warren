//
//  AppTerminalView+Focus.swift
//  WarrenGhosttyEmbedding
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    @MainActor
    extension AppTerminalView {
        /// Reconcile declarative SwiftUI intent with AppKit's actual first responder.
        /// Focus acquisition uses Ghostty's retry/backoff pattern rather than relying
        /// on another SwiftUI update to arrive after this view enters a window.
        func synchronizeFocus(with binding: TerminalFocusBinding?) {
            focusBinding = binding
            focusResignGeneration += 1

            guard let binding else {
                cancelFocusMove()
                return
            }
            if binding.isFocused {
                requestFocusMove()
            } else {
                cancelFocusMove()
                if let window, window.firstResponder === self, window.isKeyWindow {
                    window.makeFirstResponder(nil)
                }
            }
        }

        func teardownFocusSynchronization() {
            focusBinding = nil
            focusResignGeneration += 1
            cancelFocusMove()
        }

        /// Retry until the view is windowed, using the same 50ms doubling backoff
        /// and 0.5s cap as Ghostty's macOS `moveFocus` implementation.
        func requestFocusMove() {
            focusMoveGeneration += 1
            scheduleFocusMove(generation: focusMoveGeneration, delay: nil)
        }

        func focusDidBecomeFirstResponder() {
            focusResignGeneration += 1
            cancelFocusMove()
        }

        /// A resign while the binding still requests this surface may be a transient
        /// SwiftUI/AppKit reconciliation orphan. Wait until the responder transaction
        /// settles: a real new responder wins, while window/nil triggers moveFocus.
        func focusDidResignFirstResponder(
            from focusWindow: NSWindow?,
            wasIntended: Bool
        ) {
            focusResignGeneration += 1
            let generation = focusResignGeneration

            guard wasIntended else {
                onFocusChange?(false)
                return
            }

            DispatchQueue.main.async { [weak self, weak focusWindow] in
                guard let self,
                      generation == focusResignGeneration else { return }

                // The host changed its intent during the responder transaction, or
                // another enum-bound surface became focused. Do not overwrite it.
                guard focusBinding?.isFocused == true else { return }

                let responder = focusWindow?.firstResponder
                if responder === self {
                    return
                }
                if responder == nil || responder === focusWindow {
                    requestFocusMove()
                } else {
                    // A field, browser, or another surface legitimately took focus.
                    onFocusChange?(false)
                }
            }
        }

        private func cancelFocusMove() {
            focusMoveGeneration += 1
        }

        private func scheduleFocusMove(
            generation: Int,
            delay: TimeInterval?
        ) {
            let maxDelay: TimeInterval = 0.5
            guard (delay ?? 0) < maxDelay else { return }

            let nextDelay = delay.map { $0 * 2 } ?? 0.05
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      generation == focusMoveGeneration,
                      focusBinding?.isFocused == true else { return }

                guard let window else {
                    scheduleFocusMove(generation: generation, delay: nextDelay)
                    return
                }

                if window.firstResponder === self {
                    core.setFocus(window.isKeyWindow)
                    return
                }

                // AppKit should resign the current terminal as part of the move, but
                // Ghostty explicitly does this too because the callback is sometimes
                // skipped during SwiftUI reconciliation.
                if let previous = window.firstResponder as? AppTerminalView,
                   previous !== self {
                    _ = previous.resignFirstResponder()
                }

                if !window.makeFirstResponder(self) {
                    scheduleFocusMove(generation: generation, delay: nextDelay)
                }
            }

            if let delay {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: work
                )
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }
#endif
