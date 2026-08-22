import CoreGraphics

/// Superset parity measurements and the small set of shared layout values used
/// by both clients. Keep these values in one place so semantic frame contracts
/// can change a token instead of chasing literals through view code.
public enum WarrenLayoutMetrics {
    // Superset workspace sidebar state.
    public static let sidebarExpandedWidth: CGFloat = 280
    public static let sidebarCollapsedWidth: CGFloat = 52
    public static let sidebarMinimumWidth: CGFloat = 220
    public static let sidebarMaximumWidth: CGFloat = 400
    public static let sidebarSnapThreshold: CGFloat = 120

    // Superset chrome and pane measurements.
    /// The desktop workspace chrome is a 48pt row above the session tabs.
    public static let workspaceBarHeight: CGFloat = 48
    public static let workspaceBarProjectWidth: CGFloat = 160
    public static let workspaceBarWorkspaceWidth: CGFloat = 240
    public static let topBarHeight: CGFloat = 48
    /// Slightly more compact than Superset's 40pt row; keeps the same dense
    /// workspace chrome while giving content a little more vertical room.
    public static let tabBarHeight: CGFloat = 36
    /// Superset's pinned command preset row is `h-8`; Warren keeps the bar
    /// slightly flatter so the command row reads as chrome, not a toolbar.
    public static let presetBarHeight: CGFloat = 28
    /// A touch narrower than Superset's 160pt tab; titles still fit while more
    /// tabs stay visible before overflow kicks in.
    public static let tabWidth: CGFloat = 150
    /// Superset keeps the add-tab affordance in a fixed `w-10` slot.
    public static let tabAddButtonSlotWidth: CGFloat = 40
    /// The close control is a 20pt button inside a 28pt accessory column.
    public static let tabCloseButtonSize: CGFloat = 20
    public static let tabAccessoryColumnWidth: CGFloat = 28
    /// Compact action controls used by popovers and dense chrome rows.
    public static let compactControlHeight: CGFloat = 28
    /// The Web popover needs room for a tokenized URL and its adjacent
    /// actions, without reading like a persistent side panel.
    public static let webPopoverWidth: CGFloat = 288
    public static let paneHeaderHeight: CGFloat = 28
    public static let paneMinimumWidth: CGFloat = 260
    public static let paneMinimumHeight: CGFloat = 160

    // Sidebar row geometry from DashboardSidebar's Tailwind classes.
    public static let sidebarProjectRowHeight: CGFloat = 32
    public static let sidebarWorkspaceRowHeight: CGFloat = 28
    public static let sidebarSectionLabelHeight: CGFloat = 32
    public static let sidebarRowIconSlotSize: CGFloat = 18
    public static let sidebarActionButtonSize: CGFloat = 24
    /// `OverflowFadeContainer` uses a 1.5rem edge fade in Superset.
    public static let sidebarScrollFadeLength: CGFloat = 24
    /// Tab overflow needs to read as a real affordance; use a longer gradient
    /// than the sidebar so the hidden track is obvious at a glance.
    public static let tabScrollFadeLength: CGFloat = 36

    // Confirmed interaction hit areas from Superset's resizable panel.
    public static let sidebarResizeHitWidth: CGFloat = 20
    public static let sidebarDividerWidth: CGFloat = 4
    public static let splitHandleHitWidth: CGFloat = 4

    // Chrome alignment values from the macOS implementation.
    /// Every top-chrome action icon uses the same 13pt glyph size.
    public static let chromeIconSize: CGFloat = 13
    /// External IDE artwork is intentionally larger than a chrome glyph while
    /// remaining tied to the same baseline instead of using an intrinsic app size.
    public static let externalIDEIconScale: CGFloat = 1.8
    public static let externalIDEIconSize: CGFloat = chromeIconSize * externalIDEIconScale
    public static let macTrafficLightInset: CGFloat = 80
    public static let expandedSidebarChromeInset: CGFloat = 16
    /// Superset's macOS traffic-light/navigation row is `h-8`.
    public static let sidebarTrafficRowHeight: CGFloat = 32
    public static let sidebarHeaderRowHeight: CGFloat = 32
    public static let sidebarHeaderTopPadding: CGFloat = 8
    public static let sidebarHeaderBottomGap: CGFloat = 12

    // Superset settings and command-palette measurements.
    /// Superset's settings sidebar is `w-56`.
    public static let settingsNavigationWidth: CGFloat = 224
    /// Superset's settings content column is `max-w-5xl`.
    public static let settingsContentMaxWidth: CGFloat = 1024
    /// Superset's command dialog uses `max-w-[720px]`.
    public static let commandPaletteWidth: CGFloat = 720
    public static let commandPaletteResultsMaxHeight: CGFloat = 560
    public static let commandPaletteInputHorizontalPadding: CGFloat = 14
    public static let commandPaletteResultsPadding: CGFloat = 6
    public static let commandPaletteItemHorizontalPadding: CGFloat = 10
    /// Superset's command input row is `h-12`.
    public static let commandInputHeight: CGFloat = 48
    /// Idle search guidance stays a single compact row until a query is entered.
    public static let commandPaletteIdleHeight: CGFloat = 32
    /// Superset's settings search field is `h-8`.
    public static let settingsSearchHeight: CGFloat = 32

    // Presentation surface geometry. Business surfaces use a documented width
    // instead of inheriting arbitrary frame values from individual screens.
    public static let compactDialogWidth: CGFloat = 400
    public static let standardDialogWidth: CGFloat = 480
    public static let wideSheetWidth: CGFloat = 720
    public static let desktopSheetMaximumHeight: CGFloat = 680
    public static let mobileActionRowHeight: CGFloat = 44

    /// Returns the width Superset's resize policy would display for a drag.
    /// Values below the snap threshold collapse the rail; other values are
    /// clamped to the expanded range.
    public static func sidebarWidth(for proposedWidth: CGFloat) -> CGFloat {
        guard proposedWidth.isFinite else { return sidebarExpandedWidth }
        guard proposedWidth >= sidebarSnapThreshold else {
            return sidebarCollapsedWidth
        }
        return min(max(proposedWidth, sidebarMinimumWidth), sidebarMaximumWidth)
    }
}

/// Shared spacing values. The named values describe intent; components should
/// prefer these tokens over scattering unrelated padding literals.
public enum WarrenSpacing {
    public static let hairline: CGFloat = 1
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let small: CGFloat = 6
    public static let compact: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let standard: CGFloat = 16
    public static let large: CGFloat = 24
    /// Extra-large spacing for calm, breathing settings layouts.
    public static let xlarge: CGFloat = 32
    /// The largest shared spacing tier; settings detail sections use it so each
    /// page reads as a calm, isolated block.
    public static let xxlarge: CGFloat = 40
}

/// Shared corner-radius tokens. `base` is the confirmed Superset radius
/// fallback (`0.625rem`, i.e. 10px); the smaller values cover confirmed row
/// hit areas and compact controls.
public enum WarrenRadius {
    public static let xs: CGFloat = 4
    public static let row: CGFloat = 6
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let base: CGFloat = 10
    public static let large: CGFloat = 12
    /// Mobile sheets round only their top edge at this larger radius.
    public static let sheet: CGFloat = 16
}
