//
//  TerminalSurfaceView.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import SwiftUI

public struct TerminalSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var context: TerminalViewState
    let focusBinding: TerminalFocusBinding?

    public init(context: TerminalViewState) {
        self.context = context
        focusBinding = nil
    }

    init(
        context: TerminalViewState,
        focusBinding: TerminalFocusBinding?
    ) {
        self.context = context
        self.focusBinding = focusBinding
    }

    public var body: some View {
        TerminalViewRepresentable(
            context: context,
            controller: context.controller,
            configuration: context.configuration,
            focusBinding: focusBinding
        )
        .background(.clear)
        .onChange(of: colorScheme) { newScheme in
            context.adopt(colorScheme: newScheme)
        }
        .onAppear {
            context.adopt(colorScheme: colorScheme)
        }
    }

    /// Synchronizes this surface's first-responder intent with a Boolean focus
    /// binding. On AppKit, acquisition is retried briefly if the surface has not
    /// entered a window yet, and transient responder orphans are repaired without
    /// stealing focus from another real control.
    ///
    /// Prefer one Boolean binding per mounted terminal surface. Window-key status
    /// is tracked separately and does not clear this surface's focus intent.
    public func terminalFocused(
        _ condition: FocusState<Bool>.Binding
    ) -> TerminalSurfaceView {
        TerminalSurfaceView(
            context: context,
            focusBinding: .bool(condition)
        )
    }

    /// Synchronizes this surface with one case of an optional focus binding.
    /// A late resign from this surface will not clear a different case that has
    /// already become focused.
    public func terminalFocused<Value: Hashable>(
        _ binding: FocusState<Value?>.Binding,
        equals value: Value
    ) -> TerminalSurfaceView {
        TerminalSurfaceView(
            context: context,
            focusBinding: .optional(binding, equals: value)
        )
    }

    public func terminalFocusOnAppear(
        _ condition: FocusState<Bool>.Binding
    ) -> some View {
        terminalFocused(condition)
            .onAppear {
                condition.wrappedValue = true
            }
    }

    public func terminalFocusOnAppear<Value: Hashable>(
        _ binding: FocusState<Value?>.Binding,
        equals value: Value
    ) -> some View {
        terminalFocused(binding, equals: value)
            .onAppear {
                binding.wrappedValue = value
            }
    }
}
