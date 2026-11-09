import SwiftUI
import XCTest
@testable import WarrenDesignSystem

/// The palette states an order; these tests are that order.
///
/// Before the ladder existed, every surface and ink step was a hex literal and
/// the only thing keeping a card's edge lighter than its ground, or its quietest
/// metadata quieter than its body text, was that each pair had been measured by
/// hand. Nothing said what the order was, so nothing could fail when an edit
/// broke it. These assertions are what the literals could not do.
final class WarrenPaletteTests: XCTestCase {
    private let themes: [(String, WarrenPalette)] = [
        ("neutral dark", .neutralDark),
        ("ember paper", .emberPaper),
    ]

    /// How far a step sits from the card ground, in luminance.
    private func distance(_ step: WarrenRGB, from ground: WarrenRGB) -> Double {
        abs(step.relativeLuminance - ground.relativeLuminance)
    }

    /// A card stands off the window. On both appearances the recess is darker
    /// than the card ground, which is what lets one shadowless edge read as a
    /// card on either theme.
    func testTheWindowRecessIsDarkerThanTheCardGround() {
        for (name, palette) in themes {
            XCTAssertLessThan(
                palette.recess.relativeLuminance,
                palette.background.relativeLuminance,
                "\(name): the window gutters must read as behind the cards"
            )
        }
    }

    /// The raised surfaces climb away from the ground in one direction, in one
    /// order: a popover floats above a panel, and a panel above the card.
    func testRaisedSurfacesClimbInOneOrderOnBothAppearances() {
        for (name, palette) in themes {
            let ground = palette.background
            if palette.appearance == .dark {
                XCTAssertGreaterThan(
                    distance(palette.popoverSurface, from: ground),
                    distance(palette.chromeSurface, from: ground),
                    "\(name): a popover must sit above a panel"
                )
                XCTAssertGreaterThan(
                    distance(palette.chromeSurface, from: ground),
                    distance(palette.inputSurface, from: ground),
                    "\(name): an input well must recede below a panel"
                )
            } else {
                XCTAssertGreaterThan(
                    distance(palette.chromeSurface, from: ground),
                    distance(palette.inputSurface, from: ground),
                    "\(name): a warm panel must step further than a field"
                )
            }
        }
    }

    /// No chrome rung may travel so far that it becomes a second ground. A
    /// panel is a shade of the card, not a plate on top of it: at most a 1.35
    /// contrast step, which is what keeps a rail of panels reading as one
    /// window. Contrast rather than luminance, because the same luminance
    /// distance is a whisper on black and a visible plate on paper.
    func testChromeStaysWithinARungOfTheGround() {
        for (name, palette) in themes {
            for (rung, step) in [
                ("panel", palette.chromeSurface),
                ("input", palette.inputSurface),
                ("popover", palette.popoverSurface),
                ("peek", palette.peekSurface),
            ] {
                XCTAssertLessThan(
                    step.contrastRatio(with: palette.background), 1.35,
                    "\(name): \(rung) is too far from the card ground"
                )
            }
        }
    }

    /// The ink ladder descends by construction. Same ground, same ink, three
    /// fractions: the only way to break it is to stop deriving.
    func testNeutralInkDescendsInBothAppearances() {
        for (name, palette) in themes {
            let ground = palette.background
            let steps = [
                ("ink2", palette.ink2),
                ("ink3", palette.ink3),
                ("ink4", palette.ink4),
            ]
            for (index, step) in steps.enumerated() where index > 0 {
                XCTAssertGreaterThan(
                    distance(steps[index - 1].1, from: ground),
                    distance(step.1, from: ground),
                    "\(name): \(step.0) must read quieter than \(steps[index - 1].0)"
                )
            }
            // Secondary ink is body text on a description; it must clear AA.
            XCTAssertGreaterThanOrEqual(
                palette.ink3.contrastRatio(with: ground), 4.5,
                "\(name): secondary ink is below the small-text floor"
            )
        }
    }

    /// A card edge has to be visible and quiet at once: enough to name the
    /// boundary, not enough to draw a box.
    func testCardEdgesAreVisibleButQuiet() {
        for (name, palette) in themes {
            let ratio = palette.border.contrastRatio(with: palette.background)
            XCTAssertGreaterThan(ratio, 1.05, "\(name): the card edge disappears")
            XCTAssertLessThan(ratio, 2.0, "\(name): the card edge draws a box")
        }
    }

    /// The control boundary is one step louder than the card edge, because a
    /// field has to say "type here" while a card only says "this is one thing".
    func testTheControlBoundarySitsAboveTheCardEdge() {
        for (name, palette) in themes {
            XCTAssertGreaterThan(
                palette.ring.contrastRatio(with: palette.background),
                palette.border.contrastRatio(with: palette.background),
                "\(name): a control edge must outrank a card edge"
            )
        }
    }

    /// The sidebar's base is a fraction of the ink, and paper starts closer to
    /// its ink than Ember does: the same fraction that lands on a legible
    /// metadata grey over black walks into white on paper.
    func testPaperStartsItsSidebarLadderCloserToTheInk() {
        let dark = WarrenPalette.neutralDark
        let light = WarrenPalette.emberPaper
        let darkFraction = dark.sidebarTextBase.contrastRatio(with: dark.background)
        let lightFraction = light.sidebarTextBase.contrastRatio(with: light.background)
        XCTAssertGreaterThan(
            lightFraction, darkFraction,
            "paper needs the darker base or its quietest tier disappears"
        )
    }

    /// Mixing is the whole mechanism, so it must be exact at both ends.
    func testMixIsExactAtItsEndpoints() {
        let a = WarrenRGB.hex(0x1020_30)
        let b = WarrenRGB.hex(0xF0E0_D0)
        XCTAssertEqual(a.mixed(with: b, 0), a)
        XCTAssertEqual(a.mixed(with: b, 1), b)
        XCTAssertEqual(a.mixed(with: b, 2), b, "a caller cannot step past the end")
        XCTAssertEqual(a.mixed(with: b, -1), a)
        XCTAssertEqual(a.mixed(with: b, 0.5).red, (a.red + b.red) / 2, accuracy: 0.000_001)
    }

    /// Contrast is measured, not eyeballed: black on white is the known 21:1
    /// and white on white is 1:1.
    func testContrastIsTheStandardRatio() {
        let black = WarrenRGB.hex(0x0000_00)
        let white = WarrenRGB.hex(0xFFFF_FF)
        XCTAssertEqual(black.contrastRatio(with: white), 21, accuracy: 0.001)
        XCTAssertEqual(white.contrastRatio(with: white), 1, accuracy: 0.001)
        XCTAssertEqual(black.contrastRatio(with: white), white.contrastRatio(with: black))
    }
}
