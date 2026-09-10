import SwiftUI

/// The dark-only semantic color layer shared by the macOS and iOS clients.
///
/// Values are copied from Superset's default Ember theme. Warren intentionally
/// has no light appearance branch in the current product scope.
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

    /// Low-contrast chrome surface: `muted/35` over the Ember background.
    public let chromeSurface: Color
    /// The continuous Sidebar surface. Superset's desktop sidebar uses
    /// `bg-muted/45 dark:bg-muted/35`; Warren is dark-only, so keep the dark
    /// `muted/35` value here instead of introducing a separate panel color.
    public let sidebarSurface: Color
    /// Elevated surface for command palettes, menus, and relay popovers.
    public let popoverSurface: Color
    /// Surface for text inputs and other editable controls.
    public let inputSurface: Color
    /// Dedicated, low-saturation colors for client-local Host section washes.
    /// Callers apply these with a very small opacity; they are not status
    /// colors and must never be used for row foregrounds or selection states.
    public let hostSectionTints: [Color]

    /// Foreground-derived washes preserve Superset's contrast relationships.
    public let fillHover: Color
    public let fillSelected: Color
    public let tertiaryWash: Color

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
        fillHover: Color,
        fillSelected: Color,
        tertiaryWash: Color
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
        self.fillHover = fillHover
        self.fillSelected = fillSelected
        self.tertiaryWash = tertiaryWash
    }

    /// Superset globals.css dark fallback values.
    public static let dark = make(
        background: Color(red: 21 / 255, green: 17 / 255, blue: 16 / 255), // #151110
        foreground: Color(red: 234 / 255, green: 232 / 255, blue: 230 / 255), // #eae8e6
        muted: Color(red: 42 / 255, green: 40 / 255, blue: 39 / 255), // #2a2827
        mutedForeground: Color(red: 168 / 255, green: 165 / 255, blue: 163 / 255), // #a8a5a3
        border: Color(red: 42 / 255, green: 40 / 255, blue: 39 / 255), // #2a2827
        ring: Color(red: 58 / 255, green: 56 / 255, blue: 55 / 255), // #3a3837
        primary: Color(red: 234 / 255, green: 232 / 255, blue: 230 / 255), // #eae8e6
        highlight: Color(red: 224 / 255, green: 120 / 255, blue: 80 / 255), // #e07850
        destructive: Color(red: 204 / 255, green: 68 / 255, blue: 68 / 255), // #cc4444
        success: Color(red: 126 / 255, green: 198 / 255, blue: 153 / 255), // #7ec699
        warning: Color(red: 229 / 255, green: 192 / 255, blue: 123 / 255), // #e5c07b
        info: Color(red: 97 / 255, green: 175 / 255, blue: 239 / 255), // #61afef
        link: Color(red: 126 / 255, green: 192 / 255, blue: 245 / 255), // #7ec0f5
        amber: Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255), // #f59e0b
        chromeOpacity: 0.35,
        sidebarOpacity: 0.35,
        hoverOpacity: 0.07,
        selectedOpacity: 0.10,
        tertiaryOpacity: 0.05
    )

    /// Warren currently ships only Superset's default Ember dark appearance.
    public static func resolved(for _: ColorScheme) -> Self {
        .dark
    }

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
        chromeOpacity: Double,
        sidebarOpacity: Double,
        hoverOpacity: Double,
        selectedOpacity: Double,
        tertiaryOpacity: Double
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
            // Superset blends muted/35 over the Ember background before
            // compositing. An opacity color would otherwise render black over
            // an NSHostingView/terminal surface; keep the blended value opaque
            // so the top chrome and sidebar never look like a void.
            chromeSurface: Color(
                red: 28 / 255,
                green: 25 / 255,
                blue: 24 / 255
            ),
            sidebarSurface: Color(
                red: 28 / 255,
                green: 25 / 255,
                blue: 24 / 255
            ),
            popoverSurface: Color(red: 32 / 255, green: 30 / 255, blue: 28 / 255), // #201e1c
            inputSurface: Color(red: 24 / 255, green: 22 / 255, blue: 21 / 255),
            hostSectionTints: [
                Color(red: 104 / 255, green: 157 / 255, blue: 188 / 255),
                Color(red: 178 / 255, green: 128 / 255, blue: 173 / 255),
                Color(red: 137 / 255, green: 174 / 255, blue: 126 / 255),
                Color(red: 198 / 255, green: 157 / 255, blue: 106 / 255),
                Color(red: 145 / 255, green: 137 / 255, blue: 190 / 255),
                Color(red: 105 / 255, green: 177 / 255, blue: 168 / 255),
                Color(red: 187 / 255, green: 133 / 255, blue: 124 / 255),
                Color(red: 145 / 255, green: 160 / 255, blue: 111 / 255),
            ],
            fillHover: foreground.opacity(hoverOpacity),
            fillSelected: foreground.opacity(selectedOpacity),
            tertiaryWash: foreground.opacity(tertiaryOpacity)
        )
    }
}

public enum WarrenWashKind: Sendable {
    case hover
    case selected
    case tertiary
}

public extension WarrenColorTokens {
    /// Higher-contrast rule used to separate adjacent desktop chrome regions.
    /// The regular border token is intentionally softer for cards and fields.
    var chromeDivider: Color { mutedForeground.opacity(0.20) }

    /// Sidebar text hierarchy from brightest to most muted. Projects are the
    /// top-level navigation and read whitest; the selected workspace sits one
    /// step below; idle workspaces use the muted foreground.
    var projectText: Color { foreground.opacity(0.96) }
    var workspaceSelectedText: Color { foreground.opacity(0.90) }
    var workspaceText: Color { mutedForeground }

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
