import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// What is left of a pane folded by pulling its divider past the minimum.
///
/// Folding is device-local view state, like zoom: the Host's arrangement keeps
/// the pane and its ratio, and the pane's terminal stays mounted, parked
/// beneath its sibling at the size it had. The rail only has to say which pane
/// is folded and bring it back, so it carries the pane header's badge and title
/// and nothing else.
///
/// A column folds into a standing rail with its title running down it; a row
/// folds into a strip as high as the header it already had.
struct WarrenDesktopFoldedPaneRail: View {
    /// The axis of the split the pane folded out of.
    let axis: SplitAxis
    let icon: WarrenDesktopAppIcon
    let title: String
    let onRestore: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Button(action: onRestore) {
            Group {
                if axis == .horizontal {
                    standingRail(tokens: tokens)
                } else {
                    stripRail(tokens: tokens)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .warrenCard(fill: isHovered ? tokens.fillHover : nil)
        .onHover { isHovered = $0 }
        .help("Restore \(title)")
        .accessibilityLabel("Restore \(title)")
        .accessibilityHint("Brings the folded pane back at the size it had")
        .warrenSemanticElement(
            id: "pane.folded-rail",
            role: .button,
            label: "Restore \(title)",
            action: onRestore
        )
    }

    private func standingRail(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.compact) {
            WarrenDesktopSessionKindBadge(icon: icon, size: 16)
            // The title is laid out along the rail's length and turned a
            // quarter clockwise, so its leading end sits under the badge and a
            // title longer than the rail truncates at the bottom.
            GeometryReader { proxy in
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        width: proxy.size.height,
                        height: proxy.size.width,
                        alignment: .leading
                    )
                    .rotationEffect(.degrees(90))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .padding(.vertical, WarrenSpacing.compact)
    }

    private func stripRail(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            WarrenDesktopSessionKindBadge(icon: icon, size: 16)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .frame(height: SplitLayoutTree.foldedRailThickness)
    }
}
