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
    public let chromeSurface: Color
    /// The continuous Sidebar surface. Superset's desktop sidebar uses
    /// `bg-muted/45 dark:bg-muted/35`; both appearances resolve that blend to
    /// an opaque value here rather than introducing a separate panel color.
    public let sidebarSurface: Color
    /// Elevated surface for command palettes, menus, and relay popovers.
    public let popoverSurface: Color
    /// Surface for text inputs and other editable controls.
    public let inputSurface: Color
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

    /// Foreground-derived washes preserve Superset's contrast relationships.
    public let fillHover: Color
    public let fillSelected: Color
    public let tertiaryWash: Color

    /// The dimming layer behind a modal, sheet, or command palette.
    public let modalScrim: Color
    /// Ambient occlusion shadow for the few genuinely floating elements.
    public let elevationShadow: Color

    private init(
        background: Color,
        foreground: Color,
        muted: Color,
        mutedForeground: Color,
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
        popoverSurface: Color,
        inputSurface: Color,
        hostSectionTints: [Color],
        tabGroupTints: [Color],
        sidebarTextBase: Color,
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
        self.popoverSurface = popoverSurface
        self.inputSurface = inputSurface
        self.hostSectionTints = hostSectionTints
        self.tabGroupTints = tabGroupTints
        self.sidebarTextBase = sidebarTextBase
        self.fillHover = fillHover
        self.fillSelected = fillSelected
        self.tertiaryWash = tertiaryWash
        self.modalScrim = modalScrim
        self.elevationShadow = elevationShadow
    }

    /// Superset globals.css dark fallback values.
    public static let dark = make(
        background: hex(0x1511_10),
        foreground: hex(0xEAE8_E6),
        muted: hex(0x2A28_27),
        mutedForeground: hex(0xA8A5_A3),
        border: hex(0x2A28_27),
        ring: hex(0x3A38_37),
        primary: hex(0xEAE8_E6),
        highlight: hex(0xE078_50),
        destructive: hex(0xCC44_44),
        success: hex(0x7EC6_99),
        warning: hex(0xE5C0_7B),
        info: hex(0x61AF_EF),
        link: hex(0x7EC0_F5),
        amber: hex(0xF59E_0B),
        identityTints: Self.darkIdentityTints,
        // Superset blends muted/35 over the Ember background before
        // compositing. An opacity color would otherwise render black over an
        // NSHostingView/terminal surface; keep the blended value opaque so the
        // top chrome and sidebar never look like a void.
        chromeSurface: hex(0x1C19_18),
        sidebarSurface: hex(0x1C19_18),
        popoverSurface: hex(0x201E_1C),
        inputSurface: hex(0x1816_15),
        // On Ember the ladder starts mid-scale and fades outward, which is what
        // the tier fractions were measured against.
        sidebarTextBase: hex(0xA8A5_A3),
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
        border: hex(0xE0DB_D6),
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
        chromeSurface: hex(0xF2EF_EC),
        sidebarSurface: hex(0xF2EF_EC),
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

    static func hex(_ value: UInt32) -> Color {
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

    private static func make(
        background: Color,
        foreground: Color,
        muted: Color,
        mutedForeground: Color,
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
        chromeSurface: Color,
        sidebarSurface: Color,
        popoverSurface: Color,
        inputSurface: Color,
        sidebarTextBase: Color,
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
            popoverSurface: popoverSurface,
            inputSurface: inputSurface,
            // Host sections and split groups index the same palette. They stay
            // separate properties so neither feature's contract can drift into
            // the other's.
            hostSectionTints: identityTints,
            tabGroupTints: identityTints,
            sidebarTextBase: sidebarTextBase,
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

public enum WarrenWashKind: Sendable {
    case hover
    case selected
    case tertiary
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

    /// Higher-contrast rule used to separate adjacent desktop chrome regions.
    /// The regular border token is intentionally softer for cards and fields.
    var chromeDivider: Color { mutedForeground.opacity(0.20) }

    /// The active tab's selection rule.
    ///
    /// Deliberately neutral rather than `highlight`: the accent already means
    /// "agent activity" in this very row (the working dot sits beside the tab
    /// title), so spending it on selection would put two meanings on one color.
    var activeTabIndicator: Color { foreground.opacity(0.55) }

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
    var sidebarLeafSelectedText: Color { workspaceSelectedText }

    /// The rail tying a workspace's Session leaves to it.
    ///
    /// Indentation alone answers containment only when the eye can measure it,
    /// and one 10pt step is below that threshold. A stroked line in the gutter
    /// answers it without spending contrast on either row.
    ///
    /// The rail is structure rather than decoration, so it has to survive a
    /// squint the way a divider does. At 0.18 it sat within a few units of the
    /// sidebar's own trailing divider and read as noise instead of as a figure;
    /// 0.30 keeps it quieter than any row text while staying continuous to the
    /// eye. `WarrenLayoutMetrics.sidebarRailWidth` owns the matching width, and
    /// a Host section rule uses the same pair so the tree has one rail spec.
    var sidebarTreeGuide: Color { mutedForeground.opacity(0.30) }

    /// The rail while the pointer is over the group it ties.
    ///
    /// Rich mode's workspace row does not act on a click, so the row can no
    /// longer spend its hover wash on a navigation affordance it does not have.
    /// The feedback moves to the figure the pointer is actually over. Lifting
    /// the same hue past the resting 0.30 keeps the rail structural rather than
    /// turning it into `highlight`, which already means agent activity in this
    /// rail.
    var sidebarTreeGuideHighlight: Color { mutedForeground.opacity(0.65) }

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

    func wash(_ kind: WarrenWashKind) -> Color {
        switch kind {
        case .hover:
            fillHover
        case .selected:
            fillSelected
        case .tertiary:
            tertiaryWash
        }
    }

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
