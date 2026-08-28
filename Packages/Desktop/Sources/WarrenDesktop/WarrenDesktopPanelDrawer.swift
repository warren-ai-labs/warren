import AppKit
import SwiftUI
import WarrenDesignSystem

public enum WarrenDesktopOverlayDismissal: Equatable, Sendable {
    case scrim
    case escape
}

public struct WarrenDesktopOverlayActions {
    private let dismissHandler: (WarrenDesktopOverlayDismissal) -> Void
    private let restoreFocusHandler: () -> Void

    public init(
        onDismiss: @escaping (WarrenDesktopOverlayDismissal) -> Void,
        onRestoreFocus: @escaping () -> Void
    ) {
        dismissHandler = onDismiss
        restoreFocusHandler = onRestoreFocus
    }

    public func dismiss(_ reason: WarrenDesktopOverlayDismissal) {
        dismissHandler(reason)
    }

    public func restoreFocus() {
        restoreFocusHandler()
    }
}

@MainActor
final class WarrenDesktopOverlayFocusRestorer {
    private weak var previousResponder: NSResponder?

    func capture() {
        previousResponder = NSApp.keyWindow?.firstResponder
    }

    func restore() {
        guard let window = NSApp.keyWindow,
              let previousResponder else { return }
        window.makeFirstResponder(previousResponder)
    }
}

public enum WarrenDesktopPanelResizePolicy {
    public static func draggedWidth(
        currentWidth: CGFloat,
        translation: CGFloat,
        containerCap: CGFloat
    ) -> CGFloat {
        resolvedWidth(
            currentWidth: currentWidth,
            delta: -translation,
            containerCap: containerCap
        )
    }

    public static func accessibilityWidth(
        currentWidth: CGFloat,
        direction: AccessibilityAdjustmentDirection,
        containerCap: CGFloat
    ) -> CGFloat {
        let delta: CGFloat = direction == .increment ? 20 : -20
        return resolvedWidth(
            currentWidth: currentWidth,
            delta: delta,
            containerCap: containerCap
        )
    }

    private static func resolvedWidth(
        currentWidth: CGFloat,
        delta: CGFloat,
        containerCap: CGFloat
    ) -> CGFloat {
        WarrenDesktopPanelLayout.resolvedWidth(
            requestedWidth: currentWidth + delta,
            containerCap: containerCap
        )
    }
}

struct WarrenDesktopPanelSurface<Content: View>: View {
    let width: CGFloat
    let containerCap: CGFloat
    let onResize: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        content()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: WarrenLayoutMetrics.splitHandleHitWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let startWidth = dragStartWidth ?? width
                                dragStartWidth = startWidth
                                onResize(WarrenDesktopPanelResizePolicy.draggedWidth(
                                    currentWidth: startWidth,
                                    translation: value.translation.width,
                                    containerCap: containerCap
                                ))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Resize panel")
                    .accessibilityAdjustableAction { direction in
                        onResize(WarrenDesktopPanelResizePolicy.accessibilityWidth(
                            currentWidth: width,
                            direction: direction,
                            containerCap: containerCap
                        ))
                    }
            }
    }
}

public struct WarrenDesktopPanelDrawer<Content: View>: View {
    let width: CGFloat
    let containerCap: CGFloat
    let onDismiss: (WarrenDesktopOverlayDismissal) -> Void
    let onResize: (CGFloat) -> Void
    let onRestoreFocus: () -> Void
    @ViewBuilder let content: () -> Content

    @FocusState private var drawerFocused: Bool
    @State private var focusRestorer = WarrenDesktopOverlayFocusRestorer()

    private var actions: WarrenDesktopOverlayActions {
        WarrenDesktopOverlayActions(onDismiss: onDismiss, onRestoreFocus: onRestoreFocus)
    }

    public init(
        width: CGFloat,
        containerCap: CGFloat,
        onDismiss: @escaping (WarrenDesktopOverlayDismissal) -> Void,
        onResize: @escaping (CGFloat) -> Void,
        onRestoreFocus: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.containerCap = containerCap
        self.onDismiss = onDismiss
        self.onResize = onResize
        self.onRestoreFocus = onRestoreFocus
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.42)
                .contentShape(Rectangle())
                .onTapGesture { actions.dismiss(.scrim) }
                .accessibilityLabel("Close panel")

            WarrenDesktopPanelSurface(
                width: width,
                containerCap: containerCap,
                onResize: onResize,
                content: content
            )
            .focusable()
            .focused($drawerFocused)
        }
        .onAppear {
            focusRestorer.capture()
            drawerFocused = true
        }
        .onDisappear {
            focusRestorer.restore()
            actions.restoreFocus()
        }
        .onExitCommand { actions.dismiss(.escape) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel drawer")
    }
}
