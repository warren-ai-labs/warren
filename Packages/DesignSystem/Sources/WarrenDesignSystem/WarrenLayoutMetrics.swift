import CoreGraphics

/// Superset parity measurements and the small set of shared layout values used
/// by both clients. Keep these values in one place so semantic frame contracts
/// can change a token instead of chasing literals through view code.
public enum WarrenLayoutMetrics {
    // Superset workspace sidebar state.
    public static let sidebarExpandedWidth: CGFloat = 300
    /// A collapsed sidebar renders no rail at all: the content card moves to
    /// the window inset and the sidebar is reached by peeking from the edge.
    public static let sidebarCollapsedWidth: CGFloat = 0
    public static let sidebarMinimumWidth: CGFloat = 220
    public static let sidebarMaximumWidth: CGFloat = 400
    public static let sidebarSnapThreshold: CGFloat = 120

    // Central split between the Terminal and the embedded editor region.
    //
    // The region carries a whole code-server surface, whose editor part reports
    // a hard 220pt floor and whose Explorer defaults to about 300pt. Anything
    // narrower than their sum clips the file tree instead of compressing it, so
    // the region is not allowed below it and the Terminal keeps the remainder.
    public static let editorRegionEditorMinimumWidth: CGFloat = 220
    /// The narrowest Explorer Warren will reserve room for.
    ///
    /// This is a floor, not the width the file tree opens at: code-server keeps
    /// its sidebar width in its own workbench state, which `settings.json` has no
    /// key for, so Warren cannot set the initial tree width declaratively. What
    /// it can do is stop reserving a comfortable 300pt for a column the user is
    /// free to drag: 180pt still shows ordinary file names, and the space it
    /// gives back goes to the document.
    public static let editorRegionExplorerWidth: CGFloat = 180
    public static let editorRegionMinimumWidth: CGFloat = editorRegionEditorMinimumWidth
        + editorRegionExplorerWidth
    /// The two regions open on even halves.
    ///
    /// The editor region has two columns of its own inside its share, so it used
    /// to open wider than the Terminal. That made the Terminal — the surface the
    /// user was already working in when they opened a file — the smaller one.
    /// Half and half favors neither, and the divider settles the rest.
    public static let editorSplitDefaultRatio: Double = 0.5
    public static let editorSplitDividerWidth: CGFloat = 8

    /// Returns the Terminal's width for a proposed central split, or `nil` when
    /// the available width cannot seat both regions at their minimums.
    ///
    /// The editor region's floor wins ties. A code-server surface below its
    /// floor clips its Explorer, while a narrow Terminal is merely cramped.
    public static func editorSplitTerminalWidth(
        proposedTerminalWidth: CGFloat,
        availableWidth: CGFloat,
        trailingMinimumWidth: CGFloat = editorRegionMinimumWidth,
        defaultRatio: Double = editorSplitDefaultRatio
    ) -> CGFloat? {
        let usableWidth = availableWidth - editorSplitDividerWidth
        guard usableWidth >= paneMinimumWidth + trailingMinimumWidth else {
            return nil
        }
        guard proposedTerminalWidth.isFinite else {
            return usableWidth * defaultRatio
        }
        return min(
            max(proposedTerminalWidth, paneMinimumWidth),
            usableWidth - trailingMinimumWidth
        )
    }

    /// The Inspector beside the terminal: a single column, so its floor is
    /// narrower than the editor region's, and it opens as the smaller side.
    public static let inspectorMinimumWidth: CGFloat = 320
    public static let inspectorSplitDefaultRatio: Double = 0.62

    // Superset chrome and pane measurements.
    public static let topBarHeight: CGFloat = 48
    /// The only chrome row above the Terminal: tabs on the leading side, the
    /// panels and "+" buttons on the trailing side. The presets that used to
    /// be a second row live behind "+", so one compact row is enough.
    public static let tabBarHeight: CGFloat = 32
    /// The window is a dark backdrop with cards on it: the sidebar, the tab
    /// capsule, and every pane. This is the backdrop's inset from the window
    /// edge and the gutter between neighbouring cards.
    public static let windowInset: CGFloat = 8
    public static let cardGap: CGFloat = 8
    public static let cardRadius: CGFloat = 12
    /// The capsule that holds the Tabs, and the one that holds the panels and
    /// "+" buttons, sit inside the 32pt row with a 3pt inner padding.
    public static let tabCapsulePadding: CGFloat = 3
    public static let tabCapsuleRadius: CGFloat = 9
    public static let tabPillHeight: CGFloat = 24
    public static let tabPillRadius: CGFloat = 7
    /// The lone pane's title. The design caps the title capsule at 360pt; long
    /// Session names earn a little more room, so the title alone may take 345 —
    /// with the badge, the hover controls, and the paddings, the pill lands near
    /// 420 — while a shorter name hugs its own width.
    public static let soloPillTitleMaxWidth: CGFloat = 345
    /// A touch narrower than Superset's 160pt tab; titles still fit while more
    /// tabs stay visible before overflow kicks in.
    public static let tabWidth: CGFloat = 150
    /// A Tab's ceiling: a few Tabs get the room a long title needs.
    public static let tabWidthMax: CGFloat = 200
    /// A Tab's floor: past this the track scrolls rather than shrinking further.
    public static let tabWidthMin: CGFloat = 96
    public static let tabAccessoryColumnWidth: CGFloat = 28
    /// A split group's layout glyph, as drawn by `WarrenDesktopSplitGroupGlyph`.
    /// The glyph scales from its own 12pt design square, so this value sets the
    /// whole mark's weight.
    public static let tabGroupMarkSize: CGFloat = 15
    /// The room a drawn group's mark takes in the track, including the gap
    /// that separates it from the Tab that follows.
    public static let tabGroupMarkLeadingInset: CGFloat = 6
    public static let tabGroupMarkTrailingInset: CGFloat = 6
    public static let tabGroupMarkSlotWidth: CGFloat = tabGroupMarkSize
        + tabGroupMarkLeadingInset + tabGroupMarkTrailingInset
    /// A split group is one fixed-width pill. Its width never changes while
    /// the group lifts or its control shelf opens, so nothing beside it moves.
    public static let tabGroupPillWidth: CGFloat = 196
    /// The group's Session icons, stacked at rest with each one tucked behind
    /// the next and spread apart while the pointer lifts them.
    public static let tabGroupIconSize: CGFloat = 16
    public static let tabGroupIconRestPitch: CGFloat = 5
    public static let tabGroupIconLiftedPitch: CGFloat = 22
    /// How far every icon rises once lifted, and how far the one under the
    /// pointer rises and grows on top of that.
    public static let tabGroupIconLift: CGFloat = 3
    public static let tabGroupIconHotLift: CGFloat = 6
    public static let tabGroupIconHotScale: CGFloat = 1.18
    /// The control shelf that drops below the group pill.
    public static let tabGroupShelfWidth: CGFloat = 340
    /// The gap between the bottom of the tab bar and the shelf.
    public static let tabGroupShelfGap: CGFloat = 4
    /// Compact action controls used by popovers and dense chrome rows.
    public static let compactControlHeight: CGFloat = 28
    public static let paneHeaderHeight: CGFloat = 32
    public static let paneMinimumWidth: CGFloat = 260
    public static let paneMinimumHeight: CGFloat = 160

    // Sidebar row geometry from DashboardSidebar's Tailwind classes.
    public static let sidebarProjectRowHeight: CGFloat = 32
    public static let sidebarWorkspaceRowHeight: CGFloat = 28
    public static let sidebarSectionLabelHeight: CGFloat = 32
    /// Host labels are subordinate tree-group controls, not resource rows.
    public static let sidebarHostHeaderHeight: CGFloat = 24

    public static let sidebarActionButtonSize: CGFloat = 24

    /// One indent step in the sidebar tree.
    ///
    /// Depth is the only thing that moves a row's text origin, so a level is
    /// legible without reading the label. 10pt is the smallest step that still
    /// reads as a level in a 280pt rail: indent competes with title width, and
    /// a wider step truncates ordinary branch names.
    public static let sidebarIndentStep: CGFloat = 10

    /// The text origin for a sidebar row at the given tree depth.
    ///
    /// Depth 0 is a section label. Host labels, projects, tasks, and terminal
    /// groups are depth 1; a Host label does not claim its own level because
    /// it is a lightweight group heading rather than a resource row.
    /// Workspaces are depth 2.
    public static func sidebarLeadingInset(depth: Int) -> CGFloat {
        WarrenSpacing.standard + CGFloat(depth) * sidebarIndentStep
    }
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
    public static let sidebarHeaderRowHeight: CGFloat = 32

    // Superset settings and command-palette measurements.
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
    /// Command-palette results are one line each. The row carries a title, its
    /// ancestry, and the field that explains the match side by side, so height
    /// buys nothing and costs the number of results a user can see at once.
    public static let commandPaletteRowHeight: CGFloat = 28

    // Presentation surface geometry. Business surfaces use a documented width
    // instead of inheriting arbitrary frame values from individual screens.
#if os(iOS)
    public static let compactDialogWidth: CGFloat = 320
    public static let standardDialogWidth: CGFloat = 340
#else
    public static let compactDialogWidth: CGFloat = 400
    public static let standardDialogWidth: CGFloat = 480
#endif

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
    /// The Conversation composer: the kit's `composer` radius, one step louder
    /// than a card because it is the one control the person writes in.
    public static let composer: CGFloat = 16
    /// Mobile sheets round only their top edge at this larger radius.
    public static let sheet: CGFloat = 16
}
