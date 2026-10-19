import SwiftUI
import WarrenDesignSystem

/// The 16×16 viewBox shape and the worktree mark now live in the shared design
/// system, so Desktop and iOS draw one branch glyph. This alias keeps the
/// sidebar's other viewBox glyphs on the same implementation.
typealias WarrenDesktopViewBoxShape = WarrenViewBoxShape

/// A 16-unit viewBox glyph stroked at the spec's width.
struct WarrenDesktopViewBoxGlyph: View {
    let shape: WarrenDesktopViewBoxShape
    let size: CGFloat
    let lineWidth: CGFloat
    var lineCap: CGLineCap = .butt

    var body: some View {
        shape
            .stroke(style: StrokeStyle(lineWidth: lineWidth * size / 16, lineCap: lineCap))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension WarrenDesktopViewBoxGlyph {
    /// The worktree branch, drawn by the shared design-system glyph so the
    /// iOS lists match.
    static func worktreeBranch(size: CGFloat) -> WarrenWorktreeGlyph {
        WarrenWorktreeGlyph(size: size)
    }
}
