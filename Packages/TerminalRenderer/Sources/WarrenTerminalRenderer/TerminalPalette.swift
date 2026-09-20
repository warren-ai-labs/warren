/// A platform-neutral RGB color used by the terminal's sixteen ANSI slots.
public struct TerminalPaletteColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The sixteen ANSI slots, per appearance.
///
/// A palette is calibrated against a ground, which is why there are two rather
/// than one that gets lightened. The sixteen slots are a fixed vocabulary that
/// programs address by index, and the index carries an expectation: slot 0 is
/// the one that recedes into the ground, slot 15 the one that stands furthest
/// out. On paper those two expectations swap ends of the value scale, so the
/// palette has to be rebuilt rather than shifted.
public enum TerminalPalette {
    /// Superset's default Ember palette, for a dark ground.
    public static let ember: [TerminalPaletteColor] = [
        color(0x15, 0x11, 0x10), color(0xdc, 0x6b, 0x6b),
        color(0x7e, 0xc6, 0x99), color(0xe5, 0xc0, 0x7b),
        color(0x61, 0xaf, 0xef), color(0xc6, 0x78, 0xdd),
        color(0x56, 0xb6, 0xc2), color(0xea, 0xe8, 0xe6),
        color(0x5c, 0x58, 0x56), color(0xe8, 0x88, 0x88),
        color(0x98, 0xd1, 0xa8), color(0xec, 0xd0, 0x8f),
        color(0x7e, 0xc0, 0xf5), color(0xd4, 0x94, 0xe6),
        color(0x73, 0xc7, 0xd3), color(0xff, 0xff, 0xff),
    ]

    /// Ember Paper, matching Superset's light theme terminal palette (Tango / xterm defaults).
    public static let emberPaper: [TerminalPaletteColor] = [
        color(0x2e, 0x34, 0x36), color(0xcc, 0x00, 0x00),
        color(0x4e, 0x9a, 0x06), color(0xc4, 0xa0, 0x00),
        color(0x34, 0x65, 0xa4), color(0x75, 0x50, 0x7b),
        color(0x06, 0x98, 0x9a), color(0xd3, 0xd7, 0xcf),
        color(0x55, 0x57, 0x53), color(0xef, 0x29, 0x29),
        color(0x8a, 0xe2, 0x34), color(0xfc, 0xe9, 0x4f),
        color(0x72, 0x9f, 0xcf), color(0xad, 0x7f, 0xa8),
        color(0x34, 0xe2, 0xe2), color(0xee, 0xee, 0xec),
    ]

    @available(*, deprecated, renamed: "ember")
    public static let slate = ember

    private static func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> TerminalPaletteColor {
        TerminalPaletteColor(red: red, green: green, blue: blue)
    }
}
