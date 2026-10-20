import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem

/// Every Host tile — the sidebar's Host row, the collapsed rail's button, the
/// foot's stack and the multi-Host headers — reads reachability through one
/// rule, so an unreachable Host is red wherever it is drawn.
final class WarrenDesktopHostTileTests: XCTestCase {
    func testConnectionStatesFoldIntoOneReachability() {
        XCTAssertEqual(WarrenDesktopHostReachability(.attached), .reachable)
        XCTAssertEqual(WarrenDesktopHostReachability(.connecting), .connecting)
        XCTAssertEqual(WarrenDesktopHostReachability(.reconnecting), .connecting)
        XCTAssertEqual(WarrenDesktopHostReachability(.disconnected), .unreachable)
        XCTAssertEqual(WarrenDesktopHostReachability(.failed), .unreachable)
        XCTAssertEqual(WarrenDesktopHostReachability(isOnline: false), .unreachable)
    }

    func testUnreachableIsDestructive() {
        let tokens = WarrenColorTokens.dark
        XCTAssertEqual(WarrenDesktopHostReachability.unreachable.color(tokens), tokens.destructive)
        XCTAssertEqual(WarrenDesktopHostReachability.reachable.color(tokens), tokens.success)
    }

    @MainActor
    func testInitialIsTheNamesFirstLetterLowercased() {
        XCTAssertEqual(WarrenDesktopHostInitialTile.initial(of: "Mac Studio"), "m")
        XCTAssertEqual(WarrenDesktopHostInitialTile.initial(of: "  fsn1"), "f")
    }
}
