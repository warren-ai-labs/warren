import AppKit
import SwiftUI
import WarrenDesignSystem

/// The sidebar's trailing resize edge.
///
/// `WarrenDesktopSidebarState` has always been able to take a width, and
/// `WarrenLayoutMetrics.sidebarWidth(for:)` has always known how to clamp and
/// snap one, but nothing ever called them: the rail was fixed at 280pt with the
/// collapse button as the only escape. As soon as the tree lists Sessions the
/// titles need more room than that, and there was no way to ask for it.
///
/// The handle is a 6pt hit strip that draws nothing until it is hovered, so the
/// rail keeps its hairline border at rest. Double-clicking returns to the
/// default width, which is the usual way out of a drag that went too far.
///
/// A drag below the minimum holds the edge there and shows the pull instead of
/// hiding the rail mid-drag: the outcome is decided when the pointer lets go,
/// so a drag that strays below the minimum and comes back never loses the
/// sidebar.
struct WarrenDesktopSidebarResizeHandle: View {
    let width: CGFloat
    let onResize: (CGFloat) -> Void
    let onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenForceHover) private var forceHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var dragStartWidth: CGFloat?
    /// The width the drag is asking for, which may be below what the rail
    /// shows. Nil outside a drag.
    @State private var proposedWidth: CGFloat?

    /// Wide enough to catch the pointer, narrow enough that the rail's own rows
    /// keep their full click target.
    static let hitWidth: CGFloat = 6

    private var isActive: Bool { isHovered || dragStartWidth != nil || forceHover }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Rectangle()
            .fill(.clear)
            .frame(width: Self.hitWidth)
            .overlay(alignment: .center) {
                // A two-point rule reads as a grab target where the rail's own
                // one-point border reads as an edge.
                Rectangle()
                    .fill(ruleColor(tokens))
                    .frame(width: 2)
            }
            .overlay(alignment: .trailing) { pullRule(tokens) }
            .overlay(alignment: .trailing) { pullTag(tokens) }
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            // The cursor is the affordance: there is no room for a visible grip
            // at 6pt, so the pointer has to say the edge is draggable. A cursor
            // rect also holds through the drag on its own, where the previous
            // `set` had to be re-applied as hover came and went.
            .warrenCursor(.resizeLeftRight)
            .gesture(
                // Translation is measured against the window, not the handle.
                // The handle tracks the rail's trailing edge, so a local
                // coordinate space moves with every update and feeds the
                // handle's own displacement back into the next translation —
                // the width alternates instead of following the pointer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        guard let dragStartWidth else { return }
                        let proposed = dragStartWidth + value.translation.width
                        let wasHiding = proposedWidth.map(WarrenDesktopSidebarResize.releaseHides) ?? false
                        proposedWidth = proposed
                        if WarrenDesktopSidebarResize.releaseHides(proposed), !wasHiding {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .levelChange,
                                performanceTime: .now
                            )
                        }
                        onResize(WarrenDesktopSidebarResize.liveWidth(for: proposed))
                    }
                    .onEnded { value in
                        let proposed = dragStartWidth.map { $0 + value.translation.width }
                        dragStartWidth = nil
                        // Only the indicator animates as it lets go; the rail's
                        // width sits next to the terminal and switches without
                        // animation.
                        withAnimation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion)) {
                            proposedWidth = nil
                        }
                        // Letting go below the hide threshold takes the policy's
                        // own collapse path; anywhere else the edge was already
                        // held at the minimum, so there is nothing to undo.
                        if let proposed, WarrenDesktopSidebarResize.releaseHides(proposed) {
                            onResize(proposed)
                        }
                    }
            )
            .onTapGesture(count: 2, perform: onReset)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityHint("Drag to resize the sidebar, or double-click to reset it")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onResize(width + WarrenLayoutMetrics.sidebarIndentStep)
                case .decrement:
                    onResize(width - WarrenLayoutMetrics.sidebarIndentStep)
                @unknown default:
                    break
                }
            }
            .warrenSemanticElement(
                id: "sidebar.resize",
                role: .button,
                label: "Sidebar width",
                value: "\(Int(width)) points",
                action: onReset
            )
    }

    private var overshoot: CGFloat {
        proposedWidth.map(WarrenDesktopSidebarResize.overshoot) ?? 0
    }

    private var releaseHides: Bool {
        proposedWidth.map(WarrenDesktopSidebarResize.releaseHides) ?? false
    }

    private func ruleColor(_ tokens: WarrenColorTokens) -> Color {
        if releaseHides { return tokens.warning }
        if overshoot > 0 { return tokens.mutedForeground.opacity(0.8) }
        return isActive ? tokens.focusRing.opacity(0.55) : .clear
    }

    /// A short rule reaching from the edge toward the pointer, growing with
    /// how far the drag is below the minimum the edge holds at.
    private func pullRule(_ tokens: WarrenColorTokens) -> some View {
        let length = WarrenDesktopSplitDivider.pullIndicatorLength(for: overshoot)
        return Capsule()
            .fill(releaseHides ? tokens.warning : tokens.mutedForeground.opacity(0.6))
            .frame(width: length, height: 2)
            .fixedSize()
            .opacity(overshoot > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Names what letting go does: stay at the minimum, or hide the sidebar.
    private func pullTag(_ tokens: WarrenColorTokens) -> some View {
        Text(releaseHides ? "Hide" : "\(Int(WarrenLayoutMetrics.sidebarMinimumWidth)) pt")
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(releaseHides ? tokens.warning : tokens.mutedForeground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, WarrenSpacing.small)
            .padding(.vertical, WarrenSpacing.xxs)
            .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(tokens.cardBorder, lineWidth: 1)
            }
            .padding(.trailing, WarrenSpacing.compact)
            .offset(y: 22)
            .opacity(overshoot > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The sidebar edge's drag policy, kept apart from the view so the hold and the
/// release decision are testable.
///
/// `WarrenLayoutMetrics.sidebarWidth(for:)` is the stored policy and collapses
/// below its threshold; applied on every drag step it hid the rail the moment
/// the pointer crossed, which also ended the drag under the pointer. During a
/// drag the edge only clamps, and the collapse is left to the release.
enum WarrenDesktopSidebarResize {
    /// The width the rail shows while a drag asks for `proposed`: clamped to
    /// the expanded range, never collapsed.
    static func liveWidth(for proposed: CGFloat) -> CGFloat {
        guard proposed.isFinite else { return WarrenLayoutMetrics.sidebarExpandedWidth }
        return min(
            max(proposed, WarrenLayoutMetrics.sidebarMinimumWidth),
            WarrenLayoutMetrics.sidebarMaximumWidth
        )
    }

    /// How far below the minimum the drag is, in points.
    static func overshoot(for proposed: CGFloat) -> CGFloat {
        guard proposed.isFinite else { return 0 }
        return max(0, WarrenLayoutMetrics.sidebarMinimumWidth - proposed)
    }

    /// Whether letting go at `proposed` hides the sidebar. Matches the stored
    /// policy's collapse, so the release can hand `proposed` straight to it.
    static func releaseHides(_ proposed: CGFloat) -> Bool {
        proposed.isFinite && proposed < WarrenLayoutMetrics.sidebarSnapThreshold
    }
}
