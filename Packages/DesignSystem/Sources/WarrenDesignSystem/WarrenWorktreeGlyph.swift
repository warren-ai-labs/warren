import SwiftUI

/// A shape authored in the sidebar spec's 16×16 viewBox and scaled to its
/// frame, so a stroke width scales with it and keeps the spec's weight.
public struct WarrenViewBoxShape: Shape {
    /// The outline in viewBox units.
    public let viewBoxPath: Path

    public init(_ draw: (inout Path) -> Void) {
        var path = Path()
        draw(&path)
        viewBoxPath = path
    }

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        return viewBoxPath.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}

/// The worktree/branch prefix glyph: three nodes, a trunk and one curved
/// branch, stroked at the sidebar spec's width.
///
/// Shared so the desktop sidebar and the iOS lists draw one mark for a
/// worktree instead of each resolving its own branch symbol.
public struct WarrenWorktreeGlyph: View {
    public let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    private var shape: WarrenViewBoxShape {
        WarrenViewBoxShape { path in
            for (x, y) in [(5.0, 3.5), (5.0, 12.5), (11.5, 6.0)] {
                path.addEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
            }
            path.move(to: CGPoint(x: 5, y: 5.1))
            path.addLine(to: CGPoint(x: 5, y: 10.9))
            path.move(to: CGPoint(x: 11.5, y: 7.6))
            path.addCurve(
                to: CGPoint(x: 5, y: 10.9),
                control1: CGPoint(x: 11.5, y: 10.0),
                control2: CGPoint(x: 5, y: 9.0)
            )
        }
    }

    public var body: some View {
        shape
            .stroke(style: StrokeStyle(lineWidth: 1.6 * size / 16, lineCap: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
