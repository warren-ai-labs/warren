import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The three colours a theme author picks, and the ladder derived from them.
///
/// This file exists because the tokens it feeds used to be hand-picked one by
/// one: every surface, hairline, and ink step was a hex literal, so the only
/// thing keeping a card edge lighter than its ground and a leaf quieter than
/// its workspace was that someone had measured each pair by hand. Nothing
/// stopped the next value from breaking the order, and nothing said what the
/// order was.
///
/// The palette states the order instead. A theme authors a ground, an ink, a
/// recess, and the status hues; every chrome value is then a mix of those. The
/// ladder cannot invert, cannot go missing a rung, and cannot be one theme's
/// answer reused on the other theme's ground.
public struct WarrenPalette: Sendable {
    public enum Appearance: Sendable {
        case dark
        case light
    }

    public let appearance: Appearance
    /// The card ground: the terminal, a pane, the sidebar, a settings page.
    public let background: WarrenRGB
    /// The text ink. Every neutral step in the UI is this mixed toward
    /// `background`, so text and filler cannot drift apart in hue.
    public let foreground: WarrenRGB
    /// What the window behind the cards recedes to: black on Ember, warm paper
    /// on paper. Cards stand off it, so it is the one value a theme must pick
    /// separately from its ground.
    public let recess: WarrenRGB

    // Status and identity are authored, not derived. They are hues, not steps
    // of one ladder, and a mix cannot produce a red that means "failed".
    public let highlight: WarrenRGB
    public let destructive: WarrenRGB
    public let success: WarrenRGB
    public let warning: WarrenRGB
    public let info: WarrenRGB
    public let link: WarrenRGB
    public let amber: WarrenRGB
    public let identityTints: [WarrenRGB]
    public let hostForegroundTints: [WarrenRGB]
}

// MARK: - The ladder

public extension WarrenPalette {
    /// One chrome step above the card ground.
    ///
    /// Ember steps toward its ink and paper steps toward its recess, because a
    /// panel that lifts off black has to get lighter and a panel that recedes
    /// on warm paper has to get warmer. Branching here is what lets every
    /// caller stay appearance-blind.
    var chromeSurface: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.045)
        case .light: background.mixed(with: recess, 0.62)
        }
    }

    /// The lifted peek overlay: one step above `chromeSurface`, because it
    /// covers a card rather than sitting on the window.
    var peekSurface: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.02)
        case .light: background
        }
    }

    /// Text fields and other editable wells, which recede instead of lifting.
    var inputSurface: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.03)
        case .light: background.mixed(with: recess, 0.10)
        }
    }

    /// Menus, popovers, dialogs: the surface that floats highest.
    var popoverSurface: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.065)
        case .light: background
        }
    }

    /// The quiet fill behind an enumerated value (a selected row's plate, a
    /// segmented control's track).
    var mutedSurface: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.075)
        case .light: recess
        }
    }

    /// The hairline around a card on the window backdrop.
    var border: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.085)
        case .light: recess.mixed(with: foreground, 0.045)
        }
    }

    /// The control boundary: one step louder than `border`, still neutral.
    var ring: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.20)
        case .light: recess.mixed(with: foreground, 0.13)
        }
    }

    /// Secondary ink: a selected workspace's title, a live Session's name.
    var ink2: WarrenRGB { background.mixed(with: foreground, 0.89) }
    /// Supporting ink: quiet labels and descriptions.
    ///
    /// Paper takes one more step than Ember. The same fraction that clears AA
    /// on a near-black ground lands just under it on white, because contrast is
    /// measured against the ground and paper's ground is the bright end.
    var ink3: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.585)
        case .light: background.mixed(with: foreground, 0.62)
        }
    }
    /// Metadata ink: the quietest tier that is still read as text.
    var ink4: WarrenRGB { background.mixed(with: foreground, 0.365) }

    /// The one base the sidebar's tiers fade from.
    ///
    /// The two appearances start at different fractions on purpose. Paper has
    /// to start closer to its ink: fading a mid grey toward paper walks it into
    /// the ground far faster than fading the same grey toward Ember, and the
    /// quietest tier lands below the legibility floor long before the dark
    /// ladder's does.
    var sidebarTextBase: WarrenRGB {
        switch appearance {
        case .dark: background.mixed(with: foreground, 0.72)
        case .light: background.mixed(with: foreground, 0.86)
        }
    }

    /// A sidebar ink tier, as a solid value: `weight` is how much of the base
    /// survives, and the rest mixes toward the ground.
    func sidebarInk(weight: Double) -> WarrenRGB {
        sidebarTextBase.mixed(with: background, 1 - weight)
    }

    /// A neutral ink step, for the places that used `foreground.opacity(_:)`.
    func ink(_ weight: Double) -> WarrenRGB {
        background.mixed(with: foreground, weight)
    }
}

// MARK: - Authored themes

public extension WarrenPalette {
    /// The Workbench spec's neutral dark: #0B0B0B cards on a black window.
    static let neutralDark = WarrenPalette(
        appearance: .dark,
        background: .hex(0x0B0B_0B),
        foreground: .hex(0xEDED_ED),
        recess: .hex(0x0000_00),
        highlight: .hex(0xE078_50),
        destructive: .hex(0xCC44_44),
        success: .hex(0x7EC6_99),
        warning: .hex(0xE5C0_7B),
        info: .hex(0x61AF_EF),
        link: .hex(0x7EC0_F5),
        amber: .hex(0xF59E_0B),
        // The one low-saturation identity palette: Host sections and split
        // groups both index it, so the two features cannot drift into
        // different colours for the same idea.
        identityTints: [
            .hex(0x689D_BC),
            .hex(0xB280_AD),
            .hex(0x89AE_7E),
            .hex(0xC69D_6A),
            .hex(0x9189_BE),
            .hex(0x69B1_A8),
            .hex(0xBB85_7C),
            .hex(0x91A0_6F),
        ],
        // A Host heading carries its hue in the foreground, so these are the
        // pale versions of the same five hues.
        hostForegroundTints: [
            .hex(0x9FB8_E6),
            .hex(0xE2C3_8F),
            .hex(0x93CD_B8),
            .hex(0xC3AE_E3),
            .hex(0xE3A9_B8),
        ]
    )

    /// Ember Paper: the warm off-white ground the iOS client already ships.
    ///
    /// Not a grey inversion of the dark theme. Dropping to grey loses Ember's
    /// hue family and makes the two appearances read as two products; keeping
    /// the paper warm is what keeps them recognizably one surface.
    static let emberPaper = WarrenPalette(
        appearance: .light,
        background: .hex(0xFFFF_FF),
        foreground: .hex(0x1C19_17),
        recess: .hex(0xEBE7_E3),
        highlight: .hex(0xB752_2C),
        destructive: .hex(0xB326_1E),
        success: .hex(0x2F7D_51),
        warning: .hex(0x8A5A_00),
        info: .hex(0x1C6F_B8),
        link: .hex(0x1B6E_C2),
        amber: .hex(0x8A5A_00),
        identityTints: [
            .hex(0x2F6E_90),
            .hex(0x8546_7F),
            .hex(0x4A7A_3D),
            .hex(0x9466_25),
            .hex(0x5A50_8E),
            .hex(0x2A7B_72),
            .hex(0x8C4B_41),
            .hex(0x5F6C_35),
        ],
        hostForegroundTints: [
            .hex(0x3C6B_A8),
            .hex(0x8A65_20),
            .hex(0x2C7A_63),
            .hex(0x6A52_98),
            .hex(0x9E4A_64),
        ]
    )
}

// MARK: - Components

/// An sRGB colour held as components.
///
/// Derivation is arithmetic on numbers, so the palette cannot depend on
/// `Color`'s opaque representation or on the appearance it resolves in. The
/// `Color` only appears at the boundary, where SwiftUI needs one.
public struct WarrenRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A `0xRRGGBB` literal; the one place palette numbers become components.
    public static func hex(_ value: UInt32, alpha: Double = 1) -> Self {
        Self(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Reads a `Color` back as components, so a step can be composited against
    /// a known ground. A colour outside sRGB, or one the platform cannot
    /// describe, falls back to opaque black rather than guessing.
    public init(_ color: Color) {
        #if os(macOS)
        let resolved = NSColor(color).usingColorSpace(.sRGB)
        self.init(
            red: Double(resolved?.redComponent ?? 0),
            green: Double(resolved?.greenComponent ?? 0),
            blue: Double(resolved?.blueComponent ?? 0),
            alpha: Double(resolved?.alphaComponent ?? 1)
        )
        #elseif os(iOS)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
        #else
        self.init(red: 0, green: 0, blue: 0, alpha: 1)
        #endif
    }

    /// Linear interpolation toward `other`. `0` keeps this colour, `1` returns
    /// `other`, clamped so a caller cannot step past either end.
    public func mixed(with other: Self, _ t: Double) -> Self {
        let t = min(max(t, 0), 1)
        return Self(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// WCAG relative luminance, so the ladder's order can be asserted instead
    /// of eyeballed.
    public var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio against another colour, ignoring alpha.
    public func contrastRatio(with other: Self) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
