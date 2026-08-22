import SwiftUI
import WarrenDesignSystem

/// Dashboard-only chrome. v2 workspace routes deliberately do not render this
/// 48pt bar; their 40pt TabBar owns the complete top chrome instead.
struct WarrenDesktopTopBar: View {
    let hostName: String
    let isSidebarCollapsed: Bool
    let onToggleSidebar: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            // Superset's traffic-light inset is a non-interactive leaf. Keeping
            // it separate means a future AppKit window-drag bridge cannot steal
            // events from the controls next to it.
            Color.clear
                .frame(width: WarrenLayoutMetrics.expandedSidebarChromeInset)

            WarrenDesktopChromeButton(
                systemImage: isSidebarCollapsed ? "sidebar.left" : "sidebar.leading",
                label: isSidebarCollapsed ? "Expand sidebar" : "Collapse sidebar",
                hint: isSidebarCollapsed ? "Show the project and workspace list" : "Hide the project and workspace list",
                action: onToggleSidebar
            )

            Text(hostName)
                .font(WarrenTypography.chromeLabel)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            WarrenDesktopWindowDragRegion()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Color.clear
                .frame(width: WarrenSpacing.standard)
        }
        .frame(height: WarrenLayoutMetrics.topBarHeight)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            WarrenDesktopChromeDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top navigation bar")
    }
}
