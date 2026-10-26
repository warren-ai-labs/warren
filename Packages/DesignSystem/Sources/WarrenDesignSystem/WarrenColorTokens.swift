import SwiftUI

/// How loud each resting sidebar tier is, as a fraction of `sidebarTextBase`.
///
/// The tree's readability rests on one rule: a row never reads louder than the
/// row that contains it. That rule was documented on five separate color
/// properties and held by nothing, which is how a Session leaf ended up painted
/// from `foreground` — off this ladder entirely, and brighter than the workspace
/// above it. Keeping the tiers here as numbers makes the ordering something a
/// test can walk.
///
/// Selected rows are deliberately absent: selection is drawn from `foreground`,
/// so it is a different base and not comparable with these.
public enum WarrenSidebarTextWeight {
    /// Workspaces, and the resource rows that share their tier.
    public static let workspace: Double = 1.0
    /// Session leaves nested under a workspace.
    public static let leaf: Double = 0.78
    /// Region headings that name a part of the tree without joining it.
    public static let section: Double = 0.58
    /// Row metadata: branches, providers, counts, status words.
    public static let meta: Double = 0.58

    /// Brightest tier first.
    public static let descendingTiers: [Double] = [workspace, leaf, section]
}

/// The sidebar's five inks, brightest first, and its two washes.
///
/// Solid values rather than fades of one base: the sidebar design names each
/// step by its colour, so a row's tier is the same on every ground and the
/// steps stay as far apart as drawn.
public struct WarrenSidebarInk: Sendable {
    /// Project and Task names, a selected title, the selected tab.
    public let t1: Color
    /// A live Session's title.
    public let t2: Color
    /// A resting Session's title, a Task worktree's project name.
    public let t3: Color
    /// Branch names, a live second line, an unselected tab.
    public let t4: Color
    /// Times, counts, branch prefixes, glyphs, a resting second line.
    public let t5: Color
    public let hover: Color
    public let selected: Color
}

/// The semantic color layer shared by the macOS client and the design system.
///
/// The dark values are Superset's default Ember theme. The light values are
/// Ember Paper, the warm off-white ground the iOS client already ships, so the
/// two platforms read as one product rather than as two unrelated light modes.
///
/// Callers never pick a variant themselves: they resolve one through
/// `resolved(for:)` against the ambient `ColorScheme`, which the appearance
/// preference drives from `NSApp.appearance`.
public struct WarrenColorTokens: Sendable {
    public let background: Color
    public let foreground: Color
    public let muted: Color
    public let mutedForeground: Color
    /// The design's solid ink ladder below `foreground`: secondary labels,
    /// supporting text, then the quietest metadata. Solid rather than a fade of
    /// one base, so each step keeps the same contrast on every ground and the
    /// steps stay as far apart as the mockups draw them.
    public let ink2: Color
    public let ink3: Color
    public let ink4: Color
    public let border: Color
    public let ring: Color
    /// Focus ring used by keyboard navigation and other non-pointer focus.
    public let focusRing: Color
    public let primary: Color
    public let highlight: Color
    public let destructive: Color
    public let success: Color
    public let warning: Color
    public let info: Color
    /// Link and interactive text color, distinct from status/info blue.
    public let link: Color
    public let amber: Color

    /// Low-contrast chrome surface behind the top bar and pane headers.
    public private(set) var chromeSurface: Color
    /// The continuous Sidebar surface. Superset's desktop sidebar uses
    /// `bg-muted/45 dark:bg-muted/35`; both appearances resolve that blend to
    /// an opaque value here rather than introducing a separate panel color.
    public private(set) var sidebarSurface: Color
    /// The floating peek overlay's fill.
    ///
    /// One step brighter than the docked card, because the peek is lifted off
    /// the content card it covers rather than sitting on the window backdrop.
    /// A shadow and a border carry the rest of the lift.
    public private(set) var peekSurface: Color
    /// The window's own ground: the gutter the sidebar and pane cards float on.
    ///
    /// One step darker than `background`, which is the cards' fill and the
    /// terminal's ground, so a card reads as a card without a shadow.
    public private(set) var windowBackdrop: Color
    /// Elevated surface for command palettes, menus, and relay popovers.
    public private(set) var popoverSurface: Color
    /// Surface for text inputs and other editable controls.
    public private(set) var inputSurface: Color
    /// Dedicated, low-saturation colors for client-local Host section washes.
    /// Callers apply these with a very small opacity; they are not status
    /// colors and must never be used for row foregrounds or selection states.
    public let hostSectionTints: [Color]
    /// Identity hues for the pane bar's split groups.
    ///
    /// A group is not a Host section, but it needs the same kind of quiet
    /// identity color: its rule and chip are the only place the hue appears,
    /// so a status color there would be read as agent state. The values are
    /// the shared identity palette; the names stay separate so neither
    /// feature's contract can drift into the other's.
    public let tabGroupTints: [Color]
    /// Pale, low-saturation hues for a Host section heading's foreground.
    ///
    /// A multi-Host sidebar no longer washes a plate behind each Host. The
    /// Host's identity is carried in the foreground only: the heading's hollow
    /// tile, its name, the rule that runs to the row's trailing edge, and the
    /// short scope rule beside its subtree. The status palette stays reserved
    /// for activity dots, so the two never read as the same signal.
    ///
    /// The light values are the same five hues taken darker, because a pale
    /// hue that reads on Ember vanishes as text on paper. Single-Host sections
    /// never draw a Host heading, so the neutral fallback is only a guard.
    public let hostForegroundTints: [Color]

    /// The base the sidebar's quiet text tiers are faded from.
    ///
    /// Not `mutedForeground`, because the tiers are a fade and a fade behaves
    /// differently against each ground. Fading a mid grey toward a dark ground
    /// leaves a dimmer grey; fading the same grey toward paper walks it straight
    /// into the ground — the quietest tier landed at 2.3:1 that way, against the
    /// 3.3:1 the identical fraction yields on Ember. So paper starts its ladder
    /// near the text color and steps down, rather than starting mid-scale and
    /// stepping out.
    public let sidebarTextBase: Color
    /// The sidebar's ink ladder and washes; see `WarrenSidebarInk`.
    public let sidebarInk: WarrenSidebarInk

    /// Foreground-derived washes preserve Superset's contrast relationships.
    public let fillHover: Color
    public let fillSelected: Color
    public let tertiaryWash: Color

    /// The dimming layer behind a modal, sheet, or command palette.
    public private(set) var modalScrim: Color
    /// Ambient occlusion shadow for the few genuinely floating elements.
    public let elevationShadow: Color

    /// The window material these tokens were resolved against. Surfaces read
    /// it through `canvas` and the surface properties above; a component never
    /// branches on it to pick its own alpha.
    public private(set) var material: WarrenWindowMaterial = .opaque

    private init(
        background: Color,
        foreground: Color,
        muted: Color,
        mutedForeground: Color,
        ink2: Color,
        ink3: Color,
        ink4: Color,
        border: Color,
        ring: Color,
        focusRing: Color,
        primary: Color,
        highlight: Color,
        destructive: Color,
        success: Color,
        warning: Color,
        info: Color,
        link: Color,
        amber: Color,
        chromeSurface: Color,
        sidebarSurface: Color,
        peekSurface: Color,
        windowBackdrop: Color,
        popoverSurface: Color,
        inputSurface: Color,
        hostSectionTints: [Color],
        tabGroupTints: [Color],
        hostForegroundTints: [Color],
        sidebarTextBase: Color,
        sidebarInk: WarrenSidebarInk,
        fillHover: Color,
        fillSelected: Color,
        tertiaryWash: Color,
        modalScrim: Color,
        elevationShadow: Color
    ) {
        self.background = background
        self.foreground = foreground
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.ink2 = ink2
        self.ink3 = ink3
        self.ink4 = ink4
        self.border = border
        self.ring = ring
        self.focusRing = focusRing
        self.primary = primary
        self.highlight = highlight
        self.destructive = destructive
        self.success = success
        self.warning = warning
        self.info = info
        self.link = link
        self.amber = amber
        self.chromeSurface = chromeSurface
        self.sidebarSurface = sidebarSurface
        self.peekSurface = peekSurface
        self.windowBackdrop = windowBackdrop
        self.popoverSurface = popoverSurface
        self.inputSurface = inputSurface
        self.hostSectionTints = hostSectionTints
        self.tabGroupTints = tabGroupTints
        self.hostForegroundTints = hostForegroundTints
        self.sidebarTextBase = sidebarTextBase
        self.sidebarInk = sidebarInk
        self.fillHover = fillHover
        self.fillSelected = fillSelected
        self.tertiaryWash = tertiaryWash
        self.modalScrim = modalScrim
        self.elevationShadow = elevationShadow
    }

    /// The Workbench spec's neutral dark: #0B0B0B cards on a black window,
    /// #1F1F1F hairlines and an #EDEDED ink. Neutral rather than Ember's warm
    /// brown, so the greys of the tree stay crisp against the ground.
    public static let dark = make(
        background: hex(0x0B0B_0B),
        foreground: hex(0xEDED_ED),
        muted: hex(0x1C1C_1C),
        // The design's ink3. Secondary text a step brighter than this sat too
        // close to body text and blurred the two tiers together.
        mutedForeground: hex(0x8A8A_8A),
        ink2: hex(0xD4D4_D4),
        ink3: hex(0x8A8A_8A),
        ink4: hex(0x5C5C_5C),
        border: hex(0x1F1F_1F),
        ring: hex(0x3A3A_3A),
        primary: hex(0xEDED_ED),
        highlight: hex(0xE078_50),
        destructive: hex(0xCC44_44),
        success: hex(0x7EC6_99),
        warning: hex(0xE5C0_7B),
        info: hex(0x61AF_EF),
        link: hex(0x7EC0_F5),
        amber: hex(0xF59E_0B),
        identityTints: Self.darkIdentityTints,
        hostForegroundTints: Self.darkHostForegroundTints,
        // One step above the card ground, opaque: an opacity color would
        // render black over an NSHostingView/terminal surface.
        chromeSurface: hex(0x1212_12),
        // The sidebar is a card on the window backdrop, filled like the pane
        // cards beside it.
        sidebarSurface: hex(0x0B0B_0B),
        // The peek overlay floats over the content card, so it is one step
        // brighter than the card it covers.
        peekSurface: hex(0x0E0E_0E),
        // Near pure black, so the gutters between cards read as the window
        // and every card stands off it.
        windowBackdrop: hex(0x0000_00),
        popoverSurface: hex(0x1A1A_1A),
        inputSurface: hex(0x1111_11),
        // The leaf tier lands on the spec's #858585 activity grey and the
        // section tier at #666666, near its #5C5C5C.
        sidebarTextBase: hex(0xA8A8_A8),
        sidebarInk: WarrenSidebarInk(
            t1: hex(0xEDED_ED),
            t2: hex(0xD4D4_D4),
            t3: hex(0x9999_99),
            t4: hex(0x7A7A_7A),
            t5: hex(0x5757_57),
            hover: hex(0xEDED_ED).opacity(0.05),
            selected: hex(0xEDED_ED).opacity(0.085)
        ),
        hoverOpacity: 0.07,
        selectedOpacity: 0.10,
        tertiaryOpacity: 0.05,
        scrimOpacity: 0.50,
        shadowOpacity: 0.15
    )

    /// Ember Paper: the warm off-white ground the iOS client already ships.
    ///
    /// The light appearance is not a neutral grey inversion of `dark`. Dropping
    /// to grey loses Ember's hue family and makes the two appearances read as
    /// two products. Keeping the paper warm — and pulling the accent and status
    /// colors darker so one value still serves as both a dot and small label
    /// text — is what keeps them recognizably the same surface.
    public static let light = make(
        background: hex(0xFFFF_FF),
        foreground: hex(0x1C19_17),
        muted: hex(0xEBE7_E3),
        mutedForeground: hex(0x6B65_60),
        ink2: hex(0x3A34_2F),
        ink3: hex(0x6B65_60),
        ink4: hex(0x9A93_8C),
        // The design's warm paper line, so a card's edge reads against the
        // #EBE7E3 backdrop without going grey.
        border: hex(0xE6E1_DC),
        ring: hex(0xD2CC_C6),
        primary: hex(0x1C19_17),
        highlight: hex(0xB752_2C),
        destructive: hex(0xB326_1E),
        success: hex(0x2F7D_51),
        warning: hex(0x8A5A_00),
        info: hex(0x1C6F_B8),
        link: hex(0x1B6E_C2),
        amber: hex(0x8A5A_00),
        identityTints: Self.lightIdentityTints,
        hostForegroundTints: Self.lightHostForegroundTints,
        chromeSurface: hex(0xF2EF_EC),
        sidebarSurface: hex(0xFFFF_FF),
        // Paper's raised surfaces are whiter than the page, and the card is
        // already white: the border and shadow carry the lift instead.
        peekSurface: hex(0xFFFF_FF),
        windowBackdrop: hex(0xEBE7_E3),
        // Elevation darkens the ground on paper and lightens it on Ember, so a
        // raised surface cannot be one alpha wash shared by both appearances.
        // A popover here reads as raised because it is the whitest thing on
        // screen and carries a border; an input recedes instead.
        popoverSurface: hex(0xFFFF_FF),
        inputSurface: hex(0xFCFB_FA),
        // Deliberately much darker than `mutedForeground`, and chosen by working
        // backwards from the quietest tier: at the 0.58 fraction this lands on
        // 3.1:1, matching what Ember gives that same tier. Starting the ladder
        // from `mutedForeground` instead put metadata at 2.3:1, which is the
        // difference between quiet and gone.
        sidebarTextBase: hex(0x413B_34),
        sidebarInk: WarrenSidebarInk(
            t1: hex(0x1C19_17),
            t2: hex(0x3A34_2F),
            t3: hex(0x6E68_62),
            t4: hex(0x8A83_7C),
            t5: hex(0xABA4_9D),
            hover: hex(0x1C19_17).opacity(0.045),
            selected: hex(0x1C19_17).opacity(0.07)
        ),
        // A wash is `foreground`-derived, so it darkens paper and lightens
        // Ember without needing a separate mechanism. Only the amounts differ:
        // a dark wash on white reads stronger at the same alpha.
        hoverOpacity: 0.05,
        selectedOpacity: 0.08,
        tertiaryOpacity: 0.035,
        scrimOpacity: 0.32,
        shadowOpacity: 0.12
    )

    public static func resolved(for colorScheme: ColorScheme) -> Self {
        switch colorScheme {
        case .light: light
        case .dark: dark
        @unknown default: dark
        }
    }

    /// Resolves the tokens for a color scheme and a window material.
    ///
    /// Opaque returns exactly `resolved(for:)`. Glass keeps every text, status
    /// and wash value and changes only the surfaces, because the window itself
    /// now carries the one coat (`WarrenGlassMetrics`): region fills clear so
    /// the coat shows through, and raised surfaces become the same Ember tone
    /// made denser rather than a second opaque plate.
    public static func resolved(
        for colorScheme: ColorScheme,
        material: WarrenWindowMaterial
    ) -> Self {
        var tokens = resolved(for: colorScheme)
        guard material == .glass else { return tokens }
        let isLight = colorScheme == .light
        let raised = tokens.popoverSurface.opacity(WarrenGlassMetrics.raisedOpacity(isLight: isLight))
        tokens.material = .glass
        tokens.chromeSurface = .clear
        tokens.sidebarSurface = .clear
        // The gutters between the Workbench's cards darken the coat, so the
        // opaque cards stay distinct from the glass around them.
        tokens.windowBackdrop = Color.black.opacity(isLight ? 0.06 : 0.55)
        tokens.popoverSurface = raised
        tokens.inputSurface = raised
        tokens.peekSurface = raised
        tokens.modalScrim = Color.black.opacity(WarrenGlassMetrics.scrimOpacity(isLight: isLight))
        return tokens
    }

    /// A colour from a `0xRRGGBB` literal. The one place hex literals become
    /// colours; palettes outside this file call it too.
    public static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The one low-saturation identity palette. Host sections and split groups
    /// both index it; keeping the literals in a single place is what stops the
    /// two features from drifting into different colors for the same idea.
    ///
    /// Callers apply these at a very small opacity as a wash, and also draw
    /// them at full strength as a rule or chip. That dual use is why the light
    /// set is not the dark set: a mid-luminance hue that reads as a quiet tint
    /// over Ember turns muddy over paper, and the full-strength rule drawn from
    /// it disappears. The light values are the same eight hues taken darker and
    /// slightly more saturated so both uses survive.
    private static let darkIdentityTints: [Color] = [
        hex(0x689D_BC),
        hex(0xB280_AD),
        hex(0x89AE_7E),
        hex(0xC69D_6A),
        hex(0x9189_BE),
        hex(0x69B1_A8),
        hex(0xBB85_7C),
        hex(0x91A0_6F),
    ]

    private static let lightIdentityTints: [Color] = [
        hex(0x2F6E_90),
        hex(0x8546_7F),
        hex(0x4A7A_3D),
        hex(0x9466_25),
        hex(0x5A50_8E),
        hex(0x2A7B_72),
        hex(0x8C4B_41),
        hex(0x5F6C_35),
    ]

    /// The Host heading's pale foreground hues: mist blue, sand, mint, lilac,
    /// pink. Kept apart from `identityTints` because a Host signposts its
    /// section with text and rules rather than a plate, and the light set has
    /// to carry the name as readable text on paper.
    private static let darkHostForegroundTints: [Color] = [
        hex(0x9FB8_E6),
        hex(0xE2C3_8F),
        hex(0x93CD_B8),
        hex(0xC3AE_E3),
        hex(0xE3A9_B8),
    ]

    private static let lightHostForegroundTints: [Color] = [
        hex(0x3C6B_A8),
        hex(0x8A65_20),
        hex(0x2C7A_63),
        hex(0x6A52_98),
        hex(0x9E4A_64),
    ]

    private static func make(
        background: Color,
        foreground: Color,
        muted: Color,
        mutedForeground: Color,
        ink2: Color,
        ink3: Color,
        ink4: Color,
        border: Color,
        ring: Color,
        primary: Color,
        highlight: Color,
        destructive: Color,
        success: Color,
        warning: Color,
        info: Color,
        link: Color,
        amber: Color,
        identityTints: [Color],
        hostForegroundTints: [Color],
        chromeSurface: Color,
        sidebarSurface: Color,
        peekSurface: Color,
        windowBackdrop: Color,
        popoverSurface: Color,
        inputSurface: Color,
        sidebarTextBase: Color,
        sidebarInk: WarrenSidebarInk,
        hoverOpacity: Double,
        selectedOpacity: Double,
        tertiaryOpacity: Double,
        scrimOpacity: Double,
        shadowOpacity: Double
    ) -> Self {
        Self(
            background: background,
            foreground: foreground,
            muted: muted,
            mutedForeground: mutedForeground,
            ink2: ink2,
            ink3: ink3,
            ink4: ink4,
            border: border,
            ring: ring,
            // Focus is an interaction signal, not a passive separator. Keep
            // it on the same Ember accent as Web and the iOS composer.
            focusRing: highlight,
            primary: primary,
            highlight: highlight,
            destructive: destructive,
            success: success,
            warning: warning,
            info: info,
            link: link,
            amber: amber,
            chromeSurface: chromeSurface,
            sidebarSurface: sidebarSurface,
            peekSurface: peekSurface,
            windowBackdrop: windowBackdrop,
            popoverSurface: popoverSurface,
            inputSurface: inputSurface,
            // Host sections and split groups index the same palette. They stay
            // separate properties so neither feature's contract can drift into
            // the other's.
            hostSectionTints: identityTints,
            tabGroupTints: identityTints,
            hostForegroundTints: hostForegroundTints,
            sidebarTextBase: sidebarTextBase,
            sidebarInk: sidebarInk,
            fillHover: foreground.opacity(hoverOpacity),
            fillSelected: foreground.opacity(selectedOpacity),
            tertiaryWash: foreground.opacity(tertiaryOpacity),
            // A scrim dims whatever is behind it, so it is black in both
            // appearances — the light variant simply needs less of it, because
            // the same alpha over paper darkens much more visibly.
            modalScrim: Color.black.opacity(scrimOpacity),
            elevationShadow: Color.black.opacity(shadowOpacity)
        )
    }
}

/// Colors that are deliberately the same in both appearances.
///
/// Everything else in this file resolves per appearance. These do not, and each
/// one needs a reason, because a value that ignores the appearance preference
/// is a value the user cannot change.
public extension WarrenColorTokens {
    /// The wash over a split pane that does not hold the keyboard.
    ///
    /// Darkening in both appearances is the point. It sits on a canvas carrying
    /// whatever the running program painted, so a `foreground`-derived wash
    /// would lighten paper and darken Ember — and on paper that inverts the
    /// signal, making the *inactive* pane the brighter one. Receding reads as
    /// dimmer in both appearances; only in one of them is it also lighter.
    var terminalInactiveWash: Color { Color.black.opacity(0.08) }

    /// Transient HUD chips: the pending-chord badge and similar momentary
    /// overlays that must be legible over a terminal, a light pane, or both at
    /// once. A dark translucent chip with light text is the platform's own
    /// answer for this in both appearances.
    var hudSurface: Color { Color.black.opacity(0.85) }
    var hudForeground: Color { .white }

    /// The fill for a whole region — a pane, a column, a page — as opposed to
    /// something raised inside one.
    ///
    /// Opaque, it is `background`, which is also the terminal's ground. Glass
    /// clears it: the window's coat is already that same color, and painting
    /// it again per region would stack two coats into an opaque plate.
    var canvas: Color { material == .glass ? .clear : background }

    /// The fill for a card that groups content inside a page: settings cards,
    /// usage panels. Opaque, a card is a step of chrome; on glass chrome is
    /// clear, so a card is raised instead.
    var cardSurface: Color { material == .glass ? popoverSurface : chromeSurface }

    /// The hairline around a card on the window backdrop: the sidebar, a pane,
    /// the tab capsule. Opaque, it is the design's solid `border` line: a
    /// `foreground` fade landed on a cool #EEEEED on paper that all but vanished
    /// against the warm backdrop. Glass has no fixed ground under it, so there
    /// it stays a fade that lightens Ember and darkens paper by one small step.
    var cardBorder: Color { material == .glass ? foreground.opacity(0.07) : border }

    /// The hairline around the card that holds the keyboard. Brighter rather
    /// than tinted: a hue here would be read as Agent state.
    var cardBorderFocused: Color { foreground.opacity(0.16) }

    /// Higher-contrast rule used to separate adjacent desktop chrome regions.
    /// The regular border token is intentionally softer for cards and fields.
    ///
    /// On glass there is no fill change left to reinforce, so the rule only has
    /// to name the boundary and drops to a faint foreground-derived line, which
    /// lightens Ember and darkens paper the way a wash does.
    var chromeDivider: Color {
        material == .glass
            ? foreground.opacity(WarrenGlassMetrics.dividerOpacity)
            : mutedForeground.opacity(0.20)
    }

    /// The selected tab's fill. Opaque, the tab takes the content's ground so
    /// it reads as joined to the pane below; on glass that ground is clear, so
    /// the tab lifts to the raised tone instead.
    var selectedTabFill: Color { material == .glass ? popoverSurface : background }

    /// Sidebar text hierarchy from brightest to most muted. Projects are the
    /// top-level navigation and read whitest; the selected workspace sits one
    /// step below; idle workspaces use the muted foreground.
    var projectText: Color { foreground.opacity(0.96) }
    var workspaceSelectedText: Color { foreground.opacity(0.90) }
    var workspaceText: Color {
        sidebarTextBase.opacity(WarrenSidebarTextWeight.workspace)
    }

    /// Tree leaves — the Session rows the rich presentation nests under a
    /// workspace.
    ///
    /// A leaf must read as quieter than the row that contains it. Giving it the
    /// full foreground made a running Session outrank its own workspace, so a
    /// rail of leaves inverted the tree: the deepest rows were the loudest and
    /// the eye could not find where one workspace ended. Selection is what lifts
    /// a leaf back to the top of the gradient, because then it is the live row.
    var sidebarLeafText: Color {
        sidebarTextBase.opacity(WarrenSidebarTextWeight.leaf)
    }

    /// Section headings that name a region rather than participate in it.
    ///
    /// A dense tree reads as calm when its structural labels recede far enough
    /// to stop competing with the resource names under them. Full-strength
    /// muted text is still loud enough to scan as a row, which is why a rail of
    /// four sections looks crowded before a single project is added.
    var sidebarSectionText: Color {
        sidebarTextBase.opacity(WarrenSidebarTextWeight.section)
    }

    /// Resting row metadata: branch names, provider names, counts, status text.
    ///
    /// This is deliberately much fainter than the row label it accompanies.
    /// Metadata is there to answer a question the user already has, not to be
    /// read on every pass down the rail.
    var sidebarMetaText: Color {
        sidebarTextBase.opacity(WarrenSidebarTextWeight.meta)
    }

    /// Row metadata on the selected or hovered row, where the user has already
    /// signalled interest in this row's detail.
    var sidebarMetaTextActive: Color { sidebarTextBase.opacity(0.92) }

    func interactionBackground(for state: WarrenInteractionState) -> Color {
        switch state {
        case .pressed, .selected:
            fillSelected
        case .focused, .hovered:
            fillHover
        case .default, .disabled:
            .clear
        }
    }
}
