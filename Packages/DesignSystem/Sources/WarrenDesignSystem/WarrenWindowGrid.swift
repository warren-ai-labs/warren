import CoreGraphics

/// The window's grid: one rule, and the values that satisfy it.
///
/// Every chrome measurement used to be justified on its own. Some of them
/// related to each other and some did not: insets of 8, a gutter of 8, a card
/// radius of 12, and then paddings of 5, spacings of 7, radii of 5 beside radii
/// of 7. Each of those was defensible alone; together they are why two rows in
/// the same rail do not line up.
///
/// The rule the measurements actually share is parity. Chrome moves in even
/// points — 2, 4, 6, 8, 12 — while hairlines are 1 and a corner radius follows
/// the radius scale rather than the spacing grid, because a curve is not a
/// step. So: paddings, spacings and frames are even; a 1pt stroke is the one
/// exception; radii are checked against `WarrenRadius` instead.
///
/// `WarrenDesktopMetricGridTests` enforces this over the Desktop sources, which
/// is the part that was missing. A rule that lives in a comment is a rule the
/// next view does not read.
public enum WarrenWindowGrid {
    /// The smallest step chrome moves by.
    public static let unit: CGFloat = 2

    /// A hairline never scales: one point is the thinnest line macOS draws.
    public static let hairline: CGFloat = 1

    /// The window's edge inset and the gutter between two cards.
    ///
    /// The same value on purpose: the margin around every card is one margin,
    /// which is what makes the cards read as one grid rather than as columns
    /// that happen to be spaced.
    public static let inset = unit * 4
    public static let gutter = unit * 4

    /// A card's corner: three steps of the radius scale, so an outer frame and
    /// the controls inside it stay one step apart at most.
    public static let cardRadius = unit * 6

    /// Whether a spacing, inset, padding or frame size sits on the grid.
    public static func contains(_ value: CGFloat) -> Bool {
        value == hairline || (value / unit).rounded() * unit == value
    }

    /// The nearest grid value, for code that has to compute a measurement.
    public static func snap(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return value }
        let steps = (value / unit).rounded()
        return steps * unit
    }
}
