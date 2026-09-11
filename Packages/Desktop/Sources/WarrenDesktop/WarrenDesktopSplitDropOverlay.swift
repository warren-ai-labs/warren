import SwiftUI
import WarrenDesignSystem

public enum SplitDropTarget: String, Sendable, Equatable {
    case top
    case bottom
    case left
    case right
    case center
}

/// Tab drop zones layered over a pane's terminal.
///
/// The zones must never take a hit-test shape. `Color.clear` alone is not a
/// mouse target, so clicks, selection drags, and terminal mouse reporting keep
/// reaching the AppKit terminal underneath; adding `contentShape` here makes
/// the SwiftUI host swallow every click over the terminal body.
/// `WarrenDesktopSplitDropOverlayHitTestTests` pins that invariant.
struct WarrenDesktopSplitDropOverlay: View {
    let canSplit: Bool
    let onDrop: (String, SplitDropTarget) -> Void

    @State private var activeTarget: SplitDropTarget?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let edgeRatio: CGFloat = 0.25
            let ew = max(w * edgeRatio, 40)
            let eh = max(h * edgeRatio, 40)

            ZStack {
                // Visual highlight preview for currently hovered target zone
                if let target = activeTarget {
                    dropPreview(for: target, size: CGSize(width: w, height: h), tokens: tokens)
                        .transition(.opacity)
                }

                if canSplit {
                    // Top drop zone (split above)
                    Color.clear
                        .frame(width: w, height: eh)
                        .position(x: w / 2, y: eh / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .top)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .top }
                            else if activeTarget == .top { activeTarget = nil }
                        }

                    // Bottom drop zone (split below)
                    Color.clear
                        .frame(width: w, height: eh)
                        .position(x: w / 2, y: h - eh / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .bottom)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .bottom }
                            else if activeTarget == .bottom { activeTarget = nil }
                        }

                    // Left drop zone (split left)
                    Color.clear
                        .frame(width: ew, height: max(0, h - eh * 2))
                        .position(x: ew / 2, y: h / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .left)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .left }
                            else if activeTarget == .left { activeTarget = nil }
                        }

                    // Right drop zone (split right)
                    Color.clear
                        .frame(width: ew, height: max(0, h - eh * 2))
                        .position(x: w - ew / 2, y: h / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .right)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .right }
                            else if activeTarget == .right { activeTarget = nil }
                        }

                    // Center drop zone (replace tab)
                    Color.clear
                        .frame(width: max(0, w - ew * 2), height: max(0, h - eh * 2))
                        .position(x: w / 2, y: h / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .center)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .center }
                            else if activeTarget == .center { activeTarget = nil }
                        }
                } else {
                    // Maximum panes reached: allow replacing the pane tab
                    Color.clear
                        .frame(width: w, height: h)
                        .position(x: w / 2, y: h / 2)
                        .dropDestination(for: String.self) { items, _ in
                            guard let tabID = items.first else { return false }
                            onDrop(tabID, .center)
                            return true
                        } isTargeted: { targeted in
                            if targeted { activeTarget = .center }
                            else if activeTarget == .center { activeTarget = nil }
                        }
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
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
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
