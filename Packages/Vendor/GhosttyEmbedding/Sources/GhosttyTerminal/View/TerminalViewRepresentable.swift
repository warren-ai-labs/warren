//
//  TerminalViewRepresentable.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
struct TerminalViewRepresentable {
    let context: TerminalViewState
    let controller: TerminalController
    let configuration: TerminalSurfaceOptions
    let focusBinding: TerminalFocusBinding?

    func configureView(_ view: TerminalView, initial: Bool) {
        if initial {
            view.delegate = context
        }

        if let currentController = view.controller, currentController === controller {
            // Keep the current surface.
        } else {
            view.controller = controller
        }

        if !view.configuration.isEquivalent(to: configuration) {
            view.configuration = configuration
        }
    }

    static func synchronizeFocus(_ view: TerminalView, with binding: TerminalFocusBinding?) {
        #if canImport(UIKit)
            guard let binding else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                if binding.isFocused {
                    if !view.isFirstResponder { view.becomeFirstResponder() }
                } else if view.isFirstResponder {
                    _ = view.resignFirstResponder()
                }
            }
        #elseif canImport(AppKit)
            view.synchronizeFocus(with: binding)
        #endif
    }
}

@MainActor
struct TerminalFocusBinding {
    private let read: () -> Bool
    private let write: (Bool) -> Void

    init(
        read: @escaping () -> Bool,
        write: @escaping (Bool) -> Void
    ) {
        self.read = read
        self.write = write
    }

    var isFocused: Bool {
        read()
    }

    func setFocused(_ focused: Bool) {
        write(focused)
    }

    static func bool(_ binding: FocusState<Bool>.Binding) -> TerminalFocusBinding {
        TerminalFocusBinding(
            read: { binding.wrappedValue },
            write: { binding.wrappedValue = $0 }
        )
    }

    static func optional<Value: Hashable>(
        _ binding: FocusState<Value?>.Binding,
        equals value: Value
    ) -> TerminalFocusBinding {
        TerminalFocusBinding(
            read: { binding.wrappedValue == value },
            write: { focused in
                if focused {
                    binding.wrappedValue = value
                } else if binding.wrappedValue == value {
                    // A surface resigning after another enum case already became
                    // focused must not clear the new surface's focus intent.
                    binding.wrappedValue = nil
                }
            }
        )
    }
}

@MainActor
extension TerminalFocusBinding? {
    func setFocused(_ focused: Bool) {
        guard let binding = self, binding.isFocused != focused else {
            return
        }
        binding.setFocused(focused)
    }
}
