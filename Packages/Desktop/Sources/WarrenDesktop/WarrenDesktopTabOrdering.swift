import Foundation

/// The order a scope's Tabs hold once its layout owns some of them.
///
/// The pane bar draws a split's members as one run at the head of the strip, and
/// the very same order is what ⌘1-9, tab cycling, and every drag destination
/// read. Letting those two disagree is what makes "the first Tab" mean one thing
/// on screen and another thing to the keyboard, so the layout moves the order
/// itself — through the same command a drag uses — rather than the bar drawing
/// an order of its own.
enum WarrenDesktopTabOrdering {
    struct Move: Equatable {
        let tabID: String
        /// The Tab the moved one goes in front of, or nil for the end.
        let before: String?
    }

    /// `tabIDs` with the layout's members first, in pane order.
    ///
    /// A member the listing no longer carries is dropped rather than invented,
    /// and everything else keeps the order it already had.
    static func membersFirst(_ tabIDs: [String], members: [String]) -> [String] {
        let memberSet = Set(members)
        return members.filter { tabIDs.contains($0) }
            + tabIDs.filter { !memberSet.contains($0) }
    }

    /// The moves that turn `order` into `target`.
    ///
    /// Each move names the Tab that should follow the moved one, which is the
    /// Tab `moveTab(before:)` inserts against, so replaying these in order
    /// reproduces `target` exactly. The simulation below is the same
    /// removal-and-insert the model performs, which is what lets a scope's order
    /// be corrected with commands it already has instead of a new one.
    static func moves(from order: [String], to target: [String]) -> [Move] {
        guard order != target, target.count > 1 else { return [] }
        var working = order
        var moves: [Move] = []
        for index in 0..<(target.count - 1) {
            let desired = target[index + 1]
            guard let anchorIndex = working.firstIndex(of: target[index]),
                  let desiredIndex = working.firstIndex(of: desired),
                  desiredIndex != anchorIndex + 1 else { continue }
            working.remove(at: desiredIndex)
            guard let anchorIndex = working.firstIndex(of: target[index]) else { continue }
            let insertIndex = anchorIndex + 1
            working.insert(desired, at: insertIndex)
            moves.append(
                Move(
                    tabID: desired,
                    before: insertIndex + 1 < working.count ? working[insertIndex + 1] : nil
                )
            )
        }
        return moves
    }
}
