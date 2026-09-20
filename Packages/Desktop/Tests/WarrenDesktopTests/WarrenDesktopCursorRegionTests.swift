import AppKit
import XCTest
@testable import WarrenDesktop

/// A divider publishes a resize pointer through SwiftUI's `pointerStyle` on
/// macOS 15 and later, and through `NSCursor` before that. These cover the
/// mapping; whether the pointer visibly changes is AppKit's to honour and has to
/// be confirmed in the running app.
final class WarrenDesktopCursorRegionTests: XCTestCase {
    /// A vertical boundary between two regions is dragged sideways.
    func testSideToSideResizeMapsToAColumnBoundary() {
        XCTAssertEqual(
            WarrenPointerShape(.resizeLeftRight).shape,
            .resizeLeftRight
        )
    }

    func testUpAndDownResizeMapsToARowBoundary() {
        XCTAssertEqual(
            WarrenPointerShape(.resizeUpDown).shape,
            .resizeUpDown
        )
    }

    /// An unmapped cursor must not silently become a resize pointer: a divider
    /// that reads as draggable in the wrong direction is worse than one that
    /// reads as nothing.
    func testUnmappedCursorsCarryNoResizeShape() {
        XCTAssertEqual(WarrenPointerShape(.arrow).shape, .other)
        XCTAssertEqual(WarrenPointerShape(.iBeam).shape, .other)
    }

    @available(macOS 15, *)
    func testResizeShapesResolveToBoundaryPointerStyles() throws {
        // `PointerStyle` is not `Equatable`, so compare the descriptions. The
        // point of the assertion is that the two axes differ and that neither is
        // nil, which is what a wrong mapping or a missing case would produce.
        let column = try XCTUnwrap(WarrenPointerShape(.resizeLeftRight).pointerStyle)
        let row = try XCTUnwrap(WarrenPointerShape(.resizeUpDown).pointerStyle)

        XCTAssertNotEqual(String(describing: column), String(describing: row))
    }

    @available(macOS 15, *)
    func testUnmappedCursorsResolveToNoPointerStyle() {
        XCTAssertNil(WarrenPointerShape(.arrow).pointerStyle)
    }
}
