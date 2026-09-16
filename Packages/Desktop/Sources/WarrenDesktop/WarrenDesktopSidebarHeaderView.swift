import SwiftUI
import WarrenDesignSystem

struct WarrenDesktopSidebarHeader: View {
    let isCollapsed: Bool
    let chromeMode: WarrenDesktopChromeMode
    let updateStatus: WarrenDesktopUpdateStatus
    let onUpdateAction: () -> Void
    let onToggle: () -> Void
    let onCommandPalette: () -> Void
    var showsActiveOnly: Bool = false
    var onToggleActiveOnly: () -> Void = {}
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact
    var onToggleWorkspaceDisplayMode: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    init(
        isCollapsed: Bool,
        chromeMode: WarrenDesktopChromeMode,
        updateStatus: WarrenDesktopUpdateStatus,
        onUpdateAction: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onCommandPalette: @escaping () -> Void,
        showsActiveOnly: Bool = false,
        onToggleActiveOnly: @escaping () -> Void = {},
        workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact,
        onToggleWorkspaceDisplayMode: @escaping () -> Void = {}
    ) {
        self.isCollapsed = isCollapsed
        self.chromeMode = chromeMode
        self.updateStatus = updateStatus
        self.onUpdateAction = onUpdateAction
        self.onToggle = onToggle
        self.onCommandPalette = onCommandPalette
        self.showsActiveOnly = showsActiveOnly
        self.onToggleActiveOnly = onToggleActiveOnly
        self.workspaceDisplayMode = workspaceDisplayMode
        self.onToggleWorkspaceDisplayMode = onToggleWorkspaceDisplayMode
    }

    var body: some View {
        Group {
            if chromeMode == .workspace {
                workspaceHeader
            } else if isCollapsed {
                collapsedDashboardHeader
            } else {
                expandedDashboardHeader
            }
        }
        .background(
            chromeMode == .workspace
                ? WarrenColorTokens.resolved(for: colorScheme).sidebarSurface
                : .clear
        )
    }

    /// Superset's expanded dashboard header has a 32pt traffic-light row with
    /// an 80pt leading inset, followed by its compact navigation actions. Warren
    /// keeps the same geometry and exposes the one supported action: opening a
    /// new terminal session in the selected workspace.
    private var workspaceHeader: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                WarrenDesktopWindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: WarrenLayoutMetrics.tabBarHeight)
                    .background(WarrenColorTokens.resolved(for: colorScheme).chromeSurface)

                compactSearchButton
                    .padding(.top, WarrenSpacing.medium)
            } else {
                trafficRow

                expandedSearchButton
            }
        }
    }

    private var trafficRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return HStack(spacing: WarrenSpacing.xs) {
            // Superset owns an 80pt traffic-light pad; Warren renders the
            // lights itself because the window is borderless.
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset, alignment: .leading)

            WarrenDesktopChromeButton(
                systemImage: "sidebar.leading",
                label: "Collapse sidebar",
                hint: "Collapse the project and session list",
                action: onToggle
            )

            WarrenDesktopChromeButton(
                systemImage: showsActiveOnly ? "bolt.horizontal.fill" : "bolt.horizontal",
                label: showsActiveOnly ? "Show all workspaces" : "Filter active workspaces",
                hint: showsActiveOnly ? "Show all workspaces" : "Show only workspaces with active sessions",
                action: onToggleActiveOnly,
                tint: showsActiveOnly ? tokens.highlight : nil
            )

            WarrenDesktopChromeButton(
                systemImage: workspaceDisplayMode.systemImage,
                label: workspaceDisplayMode.toggleLabel,
                hint: workspaceDisplayMode.toggleHint,
                action: onToggleWorkspaceDisplayMode,
                tint: workspaceDisplayMode.isRich ? tokens.highlight : nil,
            )

            WarrenDesktopWindowDragRegion()
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityHidden(true)

            if WarrenBuildVariant.isBuild {
                // The provenance marker is the header's only disposable child.
                // It spends the reserved slot while the rail can carry it, then
                // the compact form, then nothing — so a narrow rail truncates
                // nothing and never widens the sidebar's content column.
                ViewThatFits(in: .horizontal) {
                    buildMarker()
                    buildMarker(isCompact: true)
                    EmptyView()
                }
                .padding(.trailing, WarrenSpacing.compact)
            }
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
    }

    private func buildMarker(isCompact: Bool = false) -> some View {
        WarrenDesktopBuildBadge(
            updateStatus: .none,
            showsBuildMarker: true,
            isCompact: isCompact,
            onUpdateAction: onUpdateAction
        )
    }

    private var expandedSearchButton: some View {
        Button(action: onCommandPalette) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text("Search")
                    .font(WarrenTypography.navigationItemLight)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("⌘K")
                    .font(WarrenTypography.shortcut)
                    .tracking(1.2)
                    .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(WarrenColorTokens.resolved(for: colorScheme).fillHover)
                    .clipShape(.rect(cornerRadius: WarrenRadius.xs))
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(height: WarrenLayoutMetrics.sidebarProjectRowHeight)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isFocused: searchFocused))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
        .focused($searchFocused)
        .padding(.horizontal, WarrenSpacing.xs)
        .accessibilityLabel("Search")
    }

    private var compactSearchButton: some View {
        Button(action: onCommandPalette) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isFocused: searchFocused))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .foregroundStyle(WarrenColorTokens.resolved(for: colorScheme).mutedForeground)
        .focused($searchFocused)
        .accessibilityLabel("Search")
    }

    private var collapsedDashboardHeader: some View {
        WarrenDesktopChromeButton(
            systemImage: "sidebar.left",
            label: "Expand sidebar",
            hint: "Show the project and workspace list",
            action: onToggle
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WarrenSpacing.compact)
    }

    private var expandedDashboardHeader: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return HStack(spacing: WarrenSpacing.xs) {
            WarrenDesktopChromeButton(
                systemImage: "sidebar.leading",
                label: "Collapse sidebar",
                hint: "Collapse the sidebar to icons",
                action: onToggle
            )

            WarrenDesktopChromeButton(
                systemImage: showsActiveOnly ? "bolt.horizontal.fill" : "bolt.horizontal",
                label: showsActiveOnly ? "Show all workspaces" : "Filter active workspaces",
                hint: showsActiveOnly ? "Show all workspaces" : "Show only workspaces with active sessions",
                action: onToggleActiveOnly,
                tint: showsActiveOnly ? tokens.highlight : nil
            )

            WarrenDesktopChromeButton(
                systemImage: workspaceDisplayMode.systemImage,
                label: workspaceDisplayMode.toggleLabel,
                hint: workspaceDisplayMode.toggleHint,
                action: onToggleWorkspaceDisplayMode,
                tint: workspaceDisplayMode.isRich ? tokens.highlight : nil,
            )

            Spacer(minLength: 0)
        }
        .frame(height: WarrenLayoutMetrics.sidebarHeaderRowHeight)
        .padding(.horizontal, WarrenSpacing.compact)
    }
}
