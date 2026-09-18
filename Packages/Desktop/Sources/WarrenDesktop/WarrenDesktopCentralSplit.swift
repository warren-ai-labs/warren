import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// The Terminal beside the embedded editor region (RFC 0021 §4).
///
/// Warren owns exactly one divider here. The split inside the editor region —
/// code-server's editor area against its Explorer — belongs to code-server, so
/// this view knows only that the region has a width floor it must respect.
///
/// The editor region is deliberately not a `PaneGroup` leaf: RFC 0020 requires
/// every Host pane leaf to name a running Session, and this region has no PTY,
/// no Session lifecycle, and no input lease. The two are therefore composed here
/// at the content boundary rather than in the arrangement tree.
struct WarrenDesktopCentralSplit<Terminal: View, Editor: View>: View {
    /// The Terminal's share of the usable width, as a fraction.
    ///
    /// A fraction rather than a point width so that resizing the window keeps
    /// the user's balance instead of pinning the Terminal and giving every new
    /// point to the editor.
    @Binding var terminalRatio: Double
    let terminal: Terminal
    let editor: Editor

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let layout = Self.layout(
                terminalRatio: terminalRatio,
                availableWidth: proxy.size.width
            )
            HStack(spacing: 0) {
                terminal
                    .frame(width: layout.terminalWidth)
                divider(totalWidth: proxy.size.width)
                editor
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private struct Layout {
        let terminalWidth: CGFloat
    }

    /// Resolves the Terminal's width, honoring the editor region's floor.
    ///
    /// When the container is too narrow to seat both minimums the editor region
    /// keeps its floor and the Terminal absorbs the shortfall: a code-server
    /// surface below its floor clips its Explorer outright, where a narrow
    /// Terminal is only uncomfortable. In practice the window's own minimum
    /// width grows while the region is open, so this branch is a backstop for
    /// transient layout passes rather than a state a user can sit in.
    private static func layout(
        terminalRatio: Double,
        availableWidth: CGFloat
    ) -> Layout {
        let usableWidth = availableWidth - WarrenLayoutMetrics.editorSplitDividerWidth
        guard let clamped = WarrenLayoutMetrics.editorSplitTerminalWidth(
            proposedTerminalWidth: usableWidth * terminalRatio,
            availableWidth: availableWidth
        ) else {
            return Layout(
                terminalWidth: max(0, usableWidth - WarrenLayoutMetrics.editorRegionMinimumWidth)
            )
        }
        return Layout(terminalWidth: clamped)
    }

    /// The grab strip between the two regions.
    ///
    /// Translation is measured against the window: the strip moves with the
    /// boundary it controls, so a local coordinate space would feed the strip's
    /// own displacement back into the next translation and the split would
    /// oscillate instead of following the pointer.
    @ViewBuilder
    private func divider(totalWidth: CGFloat) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let isActive = dragStartWidth != nil
        Rectangle()
            .fill(tokens.chromeDivider)
            .frame(width: WarrenSpacing.hairline)
            .frame(width: WarrenLayoutMetrics.editorSplitDividerWidth)
            .overlay {
                Rectangle()
                    .fill(isActive ? tokens.focusRing.opacity(0.55) : .clear)
                    .frame(width: 2)
            }
            .contentShape(.rect)
            .onHover { hovering in
                (hovering || dragStartWidth != nil
                    ? NSCursor.resizeLeftRight
                    : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let usableWidth = totalWidth
                            - WarrenLayoutMetrics.editorSplitDividerWidth
                        if dragStartWidth == nil {
                            // Seed from the width actually on screen, not from
                            // the raw ratio: a ratio that was clamped by the
                            // region's floor would otherwise make the first
                            // drag jump by the difference.
                            dragStartWidth = Self.layout(
                                terminalRatio: terminalRatio,
                                availableWidth: totalWidth
                            ).terminalWidth
                        }
                        guard let dragStartWidth, usableWidth > 0 else { return }
                        guard let clamped = WarrenLayoutMetrics.editorSplitTerminalWidth(
                            proposedTerminalWidth: dragStartWidth + value.translation.width,
                            availableWidth: totalWidth
                        ) else { return }
                        terminalRatio = clamped / usableWidth
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        NSCursor.arrow.set()
                    }
            )
            .onTapGesture(count: 2) {
                terminalRatio = WarrenLayoutMetrics.editorSplitDefaultRatio
            }
            .accessibilityElement()
            .accessibilityLabel("Terminal and editor split")
            .accessibilityValue("\(Int((terminalRatio * 100).rounded()))% terminal")
            .accessibilityHint("Drag to resize, or double-click to reset")
            .accessibilityAdjustableAction { direction in
                let step = 0.05
                switch direction {
                case .increment:
                    terminalRatio = min(1, terminalRatio + step)
                case .decrement:
                    terminalRatio = max(0, terminalRatio - step)
                @unknown default:
                    break
                }
            }
            .warrenSemanticElement(
                id: "central-split.resize",
                role: .button,
                label: "Terminal and editor split",
                value: "\(Int((terminalRatio * 100).rounded()))% terminal",
                action: {
                    terminalRatio = WarrenLayoutMetrics.editorSplitDefaultRatio
                }
            )
    }
}
