import SwiftUI
import WarrenDesignSystem

public enum SplitDropTarget: String, Sendable, Equatable {
    case top
    case bottom
    case left
    case right
    case center
}

/// The activation rectangles for a pane's tab drop zones.
///
/// Pure geometry, so the regions a drop is accepted in are asserted directly
/// rather than inferred from a rendered view. The edge strips own the outer
/// quarter of the pane and the center owns what is left, so the five targets
/// tile the pane without overlapping.
enum WarrenDesktopSplitDropZones {
    struct Rects: Equatable {
        let top: CGRect
        let bottom: CGRect
        let left: CGRect
        let right: CGRect
        let center: CGRect
    }

    static let edgeRatio: CGFloat = 0.25
    static let minimumEdgeLength: CGFloat = 40

    static func rects(in size: CGSize) -> Rects {
        let w = size.width
        let h = size.height
        let ew = max(w * edgeRatio, minimumEdgeLength)
        let eh = max(h * edgeRatio, minimumEdgeLength)
        let middleWidth = max(0, w - ew * 2)
        let middleHeight = max(0, h - eh * 2)
        return Rects(
            top: CGRect(x: 0, y: 0, width: w, height: eh),
            bottom: CGRect(x: 0, y: h - eh, width: w, height: eh),
            left: CGRect(x: 0, y: eh, width: ew, height: middleHeight),
            right: CGRect(x: w - ew, y: eh, width: ew, height: middleHeight),
            center: CGRect(x: ew, y: eh, width: middleWidth, height: middleHeight)
        )
    }
}

/// Tab drop zones layered over a pane's terminal.
///
/// This view is presentation only. The drop is resolved by the native tab drag
/// session (`WarrenDesktopTabDragHandleView`), which reads the pane under the
/// pointer and performs the split itself; a SwiftUI `dropDestination` over the
/// AppKit terminal is never delivered. The zones must never take a hit-test
/// shape: `contentShape` here makes the SwiftUI host swallow every click over
/// the terminal body, which breaks click-to-position, selection drags, and
/// terminal mouse reporting. `WarrenDesktopSplitDropOverlayHitTestTests` pins
/// that invariant.
struct WarrenDesktopSplitDropOverlay: View {
    let paneID: String
    let canSplit: Bool

    /// Observed rather than read through the plain environment value: the
    /// preview has to redraw when the in-flight drag moves to another zone, and
    /// only an observed object republishes changes to SwiftUI.
    @EnvironmentObject private var drag: WarrenDesktopTabDrag
    @Environment(\.colorScheme) private var colorScheme

    /// The zone the in-flight tab drag is over for this pane, if any.
    private var activeTarget: SplitDropTarget? {
        guard let splitTarget = drag.splitTarget, splitTarget.paneID == paneID else {
            return nil
        }
        return splitTarget.target
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        GeometryReader { proxy in
            ZStack {
                // Marks this pane's drop area for the native drag session.
                // Without it the drag source cannot name the pane it is over.
                WarrenDesktopPaneDropMarker(paneID: paneID, canSplit: canSplit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Visual highlight preview for the currently hovered target zone
                if let target = activeTarget {
                    dropPreview(for: target, size: proxy.size, tokens: tokens)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func dropPreview(
        for target: SplitDropTarget,
        size: CGSize,
        tokens: WarrenColorTokens
    ) -> some View {
        let previewFrame = previewGeometry(for: target, size: size)
        let iconName: String = {
            switch target {
            case .top, .bottom: return "rectangle.split.1x2.fill"
            case .left, .right: return "rectangle.split.2x1.fill"
            case .center: return "arrow.triangle.2.circlepath"
            }
        }()
        let labelText: String = {
            switch target {
            case .top: return "Split Top"
            case .bottom: return "Split Bottom"
            case .left: return "Split Left"
            case .right: return "Split Right"
            case .center: return "Replace"
            }
        }()

        ZStack {
            RoundedRectangle(cornerRadius: WarrenRadius.base)
                .fill(tokens.info.opacity(0.2))
            RoundedRectangle(cornerRadius: WarrenRadius.base)
                .stroke(tokens.info.opacity(0.8), lineWidth: 2)

            HStack(spacing: WarrenSpacing.xs) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                Text(labelText)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tokens.info)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tokens.background.opacity(0.85))
            .clipShape(Capsule())
            .shadow(color: tokens.elevationShadow, radius: 3, y: 1)
        }
        .frame(width: previewFrame.width, height: previewFrame.height)
        .position(previewFrame.center)
        .allowsHitTesting(false)
    }

    private struct PreviewGeometry {
        let width: CGFloat
        let height: CGFloat
        let center: CGPoint
    }

    private func previewGeometry(for target: SplitDropTarget, size: CGSize) -> PreviewGeometry {
        let inset: CGFloat = 4
        switch target {
        case .top:
            let h = max(0, size.height * 0.5 - inset * 2)
            let w = max(0, size.width - inset * 2)
            return PreviewGeometry(width: w, height: h, center: CGPoint(x: size.width / 2, y: h / 2 + inset))
        case .bottom:
            let h = max(0, size.height * 0.5 - inset * 2)
            let w = max(0, size.width - inset * 2)
            return PreviewGeometry(width: w, height: h, center: CGPoint(x: size.width / 2, y: size.height - h / 2 - inset))
        case .left:
            let w = max(0, size.width * 0.5 - inset * 2)
            let h = max(0, size.height - inset * 2)
            return PreviewGeometry(width: w, height: h, center: CGPoint(x: w / 2 + inset, y: size.height / 2))
        case .right:
            let w = max(0, size.width * 0.5 - inset * 2)
            let h = max(0, size.height - inset * 2)
            return PreviewGeometry(width: w, height: h, center: CGPoint(x: size.width - w / 2 - inset, y: size.height / 2))
        case .center:
            let w = max(0, size.width - inset * 2)
            let h = max(0, size.height - inset * 2)
            return PreviewGeometry(width: w, height: h, center: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }
}
