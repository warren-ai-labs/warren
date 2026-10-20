import SwiftUI
import XCTest
@testable import WarrenDesignSystem

final class WarrenDialogTests: XCTestCase {
    /// A destructive confirm answers to Command-Return only, so a stray Return
    /// cannot delete anything, and its keycap says so. A primary confirm is the
    /// plain default action. The cap and the binding come from one definition.
    @MainActor
    func testConfirmKeycapMatchesTheBoundShortcut() {
        let destructive = WarrenDialogConfirmButtonStyle.shortcut(isDestructive: true)
        XCTAssertEqual(destructive.key, .return)
        XCTAssertEqual(destructive.modifiers, .command)
        XCTAssertEqual(WarrenDialogConfirmButtonStyle.keycap(isDestructive: true), "\u{2318}\u{23CE}")

        let primary = WarrenDialogConfirmButtonStyle.shortcut(isDestructive: false)
        XCTAssertEqual(primary.key, KeyboardShortcut.defaultAction.key)
        XCTAssertEqual(primary.modifiers, KeyboardShortcut.defaultAction.modifiers)
        XCTAssertEqual(WarrenDialogConfirmButtonStyle.keycap(isDestructive: false), "\u{23CE}")
    }
}
