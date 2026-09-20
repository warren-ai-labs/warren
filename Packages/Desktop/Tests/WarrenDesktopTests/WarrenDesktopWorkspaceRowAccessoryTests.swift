import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem

/// The workspace row's accessories are drawn in an overlay, which takes no
/// layout space, so the row has to inset its own content by their width or the
/// name and the activity marker are drawn underneath them.
final class WarrenDesktopWorkspaceRowAccessoryTests: XCTestCase {
    func testRowWithNoAccessoriesKeepsItsFullWidth() {
        XCTAssertEqual(
            WarrenDesktopWorkspaceRowAccessories.inset(
                isEditorMarked: false,
                showsTaskLink: false
            ),
            0,
            "Insetting a row with nothing on its edge would truncate names for no reason."
        )
    }

    func testEditorMarkerReservesItsOwnWidth() {
        let inset = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: true,
            showsTaskLink: false
        )

        XCTAssertGreaterThanOrEqual(
            inset,
            WarrenDesktopWorkspaceRowAccessories.editorEntryWidth
        )
    }

    func testTaskLinkReservesItsOwnWidth() {
        let inset = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: false,
            showsTaskLink: true
        )

        XCTAssertGreaterThanOrEqual(
            inset,
            WarrenDesktopWorkspaceRowAccessories.taskLinkWidth
        )
    }

    /// The case the overlap was reported in: an open editor and a Task on one
    /// row. The inset has to cover both plus the gap between them, or the wider
    /// of the two still overlaps the name.
    func testBothAccessoriesReserveBothWidthsAndTheGap() {
        let inset = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: true,
            showsTaskLink: true
        )
        let bothPlusGap = WarrenDesktopWorkspaceRowAccessories.editorEntryWidth
            + WarrenDesktopWorkspaceRowAccessories.taskLinkWidth
            + WarrenSpacing.xs

        XCTAssertGreaterThanOrEqual(inset, bothPlusGap)
    }

    /// Two accessories need strictly more room than either alone, which is what
    /// a mistakenly shared constant would break.
    func testBothAccessoriesReserveMoreThanEitherAlone() {
        let editorOnly = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: true,
            showsTaskLink: false
        )
        let taskOnly = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: false,
            showsTaskLink: true
        )
        let both = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: true,
            showsTaskLink: true
        )

        XCTAssertGreaterThan(both, editorOnly)
        XCTAssertGreaterThan(both, taskOnly)
    }

    /// The gap is only spent when there are two things to separate.
    func testSingleAccessoryDoesNotReserveTheGap() {
        let editorOnly = WarrenDesktopWorkspaceRowAccessories.inset(
            isEditorMarked: true,
            showsTaskLink: false
        )

        XCTAssertEqual(
            editorOnly,
            WarrenDesktopWorkspaceRowAccessories.editorEntryWidth
                + WarrenSpacing.compact
        )
    }
}
