import XCTest
@testable import WarrenDesktop

/// The strip's order and the keyboard's order are the same order.
///
/// The pane bar draws a split's members first, and ⌘1-9, tab cycling, and every
/// drag destination read the stored order. These tests hold down the two halves
/// of keeping them equal: the order the layout asks for, and the `moveTab`
/// commands that reach it.
final class WarrenDesktopTabOrderingTests: XCTestCase {
    func testMembersLeadInPaneOrder() {
        XCTAssertEqual(
            WarrenDesktopTabOrdering.membersFirst(
                ["p", "b", "q", "a"],
                members: ["a", "b"]
            ),
            ["a", "b", "p", "q"]
        )
    }

    /// A pane whose Tab the roster no longer lists is not invented, and the rest
    /// of the strip keeps the order the user gave it.
    func testMembersTheListingDoesNotCarryAreDropped() {
        XCTAssertEqual(
            WarrenDesktopTabOrdering.membersFirst(["p", "a"], members: ["a", "gone"]),
            ["a", "p"]
        )
    }

    func testAnAlignedOrderNeedsNoMoves() {
        XCTAssertTrue(
            WarrenDesktopTabOrdering.moves(from: ["a", "b", "p"], to: ["a", "b", "p"]).isEmpty
        )
    }

    /// Replaying a move list has to reproduce the target exactly, because that
    /// is all the model is given.
    func testMovesReproduceTheTargetOrder() {
        let cases: [(order: [String], target: [String])] = [
            (["p", "b", "q", "a"], ["a", "b", "p", "q"]),
            (["x", "a"], ["a", "x"]),
            (["a", "x", "b"], ["a", "b", "x"]),
            (["x", "y", "a", "b"], ["a", "b", "x", "y"]),
            (["b", "a", "c"], ["a", "b", "c"]),
            (["a", "b", "c", "d"], ["d", "c", "b", "a"]),
        ]
        for (order, target) in cases {
            var replayed = order
            for move in WarrenDesktopTabOrdering.moves(from: order, to: target) {
                replayed.removeAll { $0 == move.tabID }
                guard let before = move.before else {
                    replayed.append(move.tabID)
                    continue
                }
                guard let index = replayed.firstIndex(of: before) else {
                    return XCTFail("Move names a Tab that is not in the order: \(before)")
                }
                replayed.insert(move.tabID, at: index)
            }
            XCTAssertEqual(replayed, target, "Moves for \(order) -> \(target)")
        }
    }

    /// The layout's own case, end to end: a Session pulled into a split moves to
    /// the front, and the ones around it keep their relative order.
    func testAPulledInSessionReachesTheFront() {
        let order = ["shell", "dev", "notes", "logs"]
        let target = WarrenDesktopTabOrdering.membersFirst(order, members: ["notes", "shell"])
        XCTAssertEqual(target, ["notes", "shell", "dev", "logs"])
        var replayed = order
        for move in WarrenDesktopTabOrdering.moves(from: order, to: target) {
            replayed.removeAll { $0 == move.tabID }
            guard let before = move.before else {
                replayed.append(move.tabID)
                continue
            }
            replayed.insert(move.tabID, at: replayed.firstIndex(of: before) ?? replayed.count)
        }
        XCTAssertEqual(replayed, target)
    }
}
