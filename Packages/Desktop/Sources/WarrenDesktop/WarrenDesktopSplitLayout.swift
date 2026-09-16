import Foundation
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Left and right columns.
    case horizontal
    /// Top and bottom rows.
    case vertical
}

public enum SplitFocusDirection: String, Codable, Hashable, Sendable {
    case left
    case right
    case up
    case down
}

public struct SplitPaneItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var tabID: String

    public init(id: String = UUID().uuidString, tabID: String) {
        self.id = id
        self.tabID = tabID
    }

    /// Stable identity used when a scope has no persisted layout yet. Split
    /// panes created by an explicit split still receive an independent UUID;
    /// only the single-pane fallback needs to survive repeated body passes.
    public static func fallbackID(forTabID tabID: String) -> String {
        "fallback-pane-\(tabID)"
    }
}

public indirect enum SplitLayoutTree: Codable, Hashable, Sendable {
    case leaf(SplitPaneItem)
    case split(axis: SplitAxis, ratio: Double, first: SplitLayoutTree, second: SplitLayoutTree)

    public static let maxPanes = 4
    public static let minimumInteractiveRatio = 0.15
    public static let maximumInteractiveRatio = 0.85

    /// Ratios a divider drag latches onto. An even split is the only alignment
    /// users aim for by eye, and keeping the list to one entry keeps the drag
    /// predictable: outside a single pull radius the divider tracks the pointer
    /// exactly.
    public static let snapRatios: [Double] = [0.5]

    /// Pull radius of a snap target, measured along the drag axis in points
    /// rather than in ratio space so the latch feels the same in a narrow pane
    /// and in a wide one.
    public static let snapDistance: CGFloat = 12

    /// The snap target pulling on `ratio`, or nil when the drag runs free.
    ///
    /// `totalLength` converts the point radius into ratio space, so a container
    /// that has not been laid out yet never snaps. Targets outside the clamp
    /// range are dropped: latching onto a ratio the divider cannot hold would
    /// leave the pointer stuck against a boundary it never reached.
    public static func snapTarget(
        for ratio: Double,
        totalLength: CGFloat,
        minimum: Double,
        maximum: Double
    ) -> Double? {
        guard ratio.isFinite, totalLength > 0, minimum <= maximum else { return nil }
        let radius = Double(Self.snapDistance / totalLength)
        return Self.snapRatios
            .filter { $0 >= minimum && $0 <= maximum && abs($0 - ratio) <= radius }
            .min { abs($0 - ratio) < abs($1 - ratio) }
    }

    private enum CodingKeys: String, CodingKey {
        case leaf
        case split
    }

    private enum SplitCodingKeys: String, CodingKey {
        case axis
        case ratio
        case first
        case second
    }

    /// Persisted layouts predate ratio validation, so decode them defensively.
    /// A malformed ratio must never produce a zero-sized terminal or a NaN
    /// that poisons SwiftUI's geometry calculations.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let item = try container.decodeIfPresent(SplitPaneItem.self, forKey: .leaf) {
            self = .leaf(item)
            return
        }
        let split = try container.nestedContainer(keyedBy: SplitCodingKeys.self, forKey: .split)
        let axis = try split.decode(SplitAxis.self, forKey: .axis)
        let rawRatio = try split.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
        let ratio = Self.normalizedRatio(rawRatio)
        self = .split(
            axis: axis,
            ratio: ratio,
            first: try split.decode(SplitLayoutTree.self, forKey: .first),
            second: try split.decode(SplitLayoutTree.self, forKey: .second)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let item):
            try container.encode(item, forKey: .leaf)
        case .split(let axis, let ratio, let first, let second):
            var split = container.nestedContainer(keyedBy: SplitCodingKeys.self, forKey: .split)
            try split.encode(axis, forKey: .axis)
            try split.encode(Self.normalizedRatio(ratio), forKey: .ratio)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }

    private static func normalizedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite,
              ratio >= 0.05,
              ratio <= 0.95 else {
            return 0.5
        }
        return ratio
    }

    private static func normalizedInteractiveRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(
            max(ratio, Self.minimumInteractiveRatio),
            Self.maximumInteractiveRatio
        )
    }

    public var count: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, let first, let second):
            return first.count + second.count
        }
    }

    /// Minimum width required to keep every leaf in this subtree at the
    /// desktop pane minimum. Horizontal children add their widths; vertical
    /// children share the same width and therefore use the larger child.
    public var minimumPaneWidth: CGFloat {
        switch self {
        case .leaf:
            return WarrenLayoutMetrics.paneMinimumWidth
        case .split(let axis, _, let first, let second):
            return axis == .horizontal
                ? first.minimumPaneWidth + second.minimumPaneWidth
                    + WarrenLayoutMetrics.splitHandleHitWidth + 1
                : max(first.minimumPaneWidth, second.minimumPaneWidth)
        }
    }

    /// Minimum height required to keep every leaf's terminal body and pane
    /// header visible. Vertical children add their heights; horizontal
    /// children share the same height and therefore use the larger child.
    public var minimumPaneHeight: CGFloat {
        let leafHeight = WarrenLayoutMetrics.paneHeaderHeight
            + WarrenLayoutMetrics.paneMinimumHeight
        switch self {
        case .leaf:
            return leafHeight
        case .split(let axis, _, let first, let second):
            return axis == .vertical
                ? first.minimumPaneHeight + second.minimumPaneHeight
                    + WarrenLayoutMetrics.splitHandleHitWidth + 1
                : max(first.minimumPaneHeight, second.minimumPaneHeight)
        }
    }

    /// Window minimums the layout may request. The exact subtree minimums
    /// drive divider clamps, but using them for the window would force a
    /// four-pane tree to grow the user's window past a comfortable size, so
    /// the window minimum stops at two panes per axis.
    public var windowMinimumPaneWidth: CGFloat {
        let twoPanes = WarrenLayoutMetrics.paneMinimumWidth * 2
            + WarrenLayoutMetrics.splitHandleHitWidth + 1
        return min(minimumPaneWidth, twoPanes)
    }

    public var windowMinimumPaneHeight: CGFloat {
        let leafHeight = WarrenLayoutMetrics.paneHeaderHeight
            + WarrenLayoutMetrics.paneMinimumHeight
        let twoPanes = leafHeight * 2
            + WarrenLayoutMetrics.splitHandleHitWidth + 1
        return min(minimumPaneHeight, twoPanes)
    }

    public var leaves: [SplitPaneItem] {
        switch self {
        case .leaf(let item):
            return [item]
        case .split(_, _, let first, let second):
            return first.leaves + second.leaves
        }
    }

    public var allPaneIDs: [String] {
        leaves.map(\.id)
    }

    public var allTabIDs: [String] {
        leaves.map(\.tabID)
    }

    public func item(for paneID: String) -> SplitPaneItem? {
        leaves.first { $0.id == paneID }
    }

    public func item(forTabID tabID: String) -> SplitPaneItem? {
        leaves.first { $0.tabID == tabID }
    }

    public func contains(paneID: String) -> Bool {
        allPaneIDs.contains(paneID)
    }

    public func contains(tabID: String) -> Bool {
        allTabIDs.contains(tabID)
    }

    /// Split the target pane in the specified direction.
    /// Strictly limits the total number of split panes to `maxPanes` (4).
    ///
    /// `newPaneID` names the pane the new Session lands in. Callers pass it when
    /// the Session already had a pane identity — a Session the panel is showing
    /// alone, for instance — so that adopting it into the layout does not
    /// re-create the very terminal the user is looking at.
    public func split(
        targetPaneID: String,
        newTabID: String,
        axis: SplitAxis,
        placeAfter: Bool = true,
        newPaneID: String? = nil
    ) -> SplitLayoutTree {
        guard count < Self.maxPanes,
              !contains(tabID: newTabID),
              !newTabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }
        var didSplit = false
        return splitRecursive(
            targetPaneID: targetPaneID,
            newTabID: newTabID,
            newPaneID: newPaneID,
            axis: axis,
            placeAfter: placeAfter,
            didSplit: &didSplit
        )
    }

    private func splitRecursive(
        targetPaneID: String,
        newTabID: String,
        newPaneID: String?,
        axis: SplitAxis,
        placeAfter: Bool,
        didSplit: inout Bool
    ) -> SplitLayoutTree {
        switch self {
        case .leaf(let existingItem):
            if existingItem.id == targetPaneID, !didSplit {
                didSplit = true
                let newItem = SplitPaneItem(
                    id: newPaneID ?? UUID().uuidString,
                    tabID: newTabID
                )
                let first = placeAfter ? SplitLayoutTree.leaf(existingItem) : SplitLayoutTree.leaf(newItem)
                let second = placeAfter ? SplitLayoutTree.leaf(newItem) : SplitLayoutTree.leaf(existingItem)
                return .split(axis: axis, ratio: 0.5, first: first, second: second)
            }
            return self
        case .split(let existingAxis, let ratio, let first, let second):
            let newFirst = first.splitRecursive(
                targetPaneID: targetPaneID,
                newTabID: newTabID,
                newPaneID: newPaneID,
                axis: axis,
                placeAfter: placeAfter,
                didSplit: &didSplit
            )
            let newSecond = second.splitRecursive(
                targetPaneID: targetPaneID,
                newTabID: newTabID,
                newPaneID: newPaneID,
                axis: axis,
                placeAfter: placeAfter,
                didSplit: &didSplit
            )
            return .split(axis: existingAxis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Remove a pane and collapse the parent split node.
    /// Returns `nil` if the tree becomes empty.
    public func remove(paneID: String) -> SplitLayoutTree? {
        switch self {
        case .leaf(let item):
            return item.id == paneID ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let newFirst = first.remove(paneID: paneID)
            let newSecond = second.remove(paneID: paneID)
            switch (newFirst, newSecond) {
            case (.some(let remaining), .none):
                return remaining
            case (.none, .some(let remaining)):
                return remaining
            case (.some(let f), .some(let s)):
                return .split(axis: axis, ratio: ratio, first: f, second: s)
            case (.none, .none):
                return nil
            }
        }
    }

    /// Maximize a pane, returning a single leaf tree.
    public func maximize(paneID: String) -> SplitLayoutTree {
        if let targetItem = item(for: paneID) {
            return .leaf(targetItem)
        }
        return self
    }

    /// Replace the displayed tab inside a pane.
    public func replace(paneID: String, withTabID newTabID: String) -> SplitLayoutTree {
        guard let existingItem = item(for: paneID),
              !newTabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              existingItem.tabID == newTabID || !contains(tabID: newTabID) else {
            return self
        }
        var didReplace = false
        return replaceRecursive(
            paneID: paneID,
            withTabID: newTabID,
            didReplace: &didReplace
        )
    }

    private func replaceRecursive(
        paneID: String,
        withTabID newTabID: String,
        didReplace: inout Bool
    ) -> SplitLayoutTree {
        switch self {
        case .leaf(var item):
            if item.id == paneID, !didReplace {
                didReplace = true
                item.tabID = newTabID
            }
            return .leaf(item)
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.replaceRecursive(
                    paneID: paneID,
                    withTabID: newTabID,
                    didReplace: &didReplace
                ),
                second: second.replaceRecursive(
                    paneID: paneID,
                    withTabID: newTabID,
                    didReplace: &didReplace
                )
            )
        }
    }

    /// Paths identify split nodes independently of preorder indices. `false`
    /// descends into the first child and `true` into the second child. This is
    /// the same stable, immutable-tree addressing model used by Ghostty's
    /// split handles and remains correct after adding a nested split.
    public func updateRatio(path: [Bool], ratio: Double) -> SplitLayoutTree {
        let clamped = Self.normalizedInteractiveRatio(ratio)
        guard !path.isEmpty else {
            guard case .split(let axis, _, let first, let second) = self else { return self }
            return .split(axis: axis, ratio: clamped, first: first, second: second)
        }
        guard case .split(let axis, let existingRatio, let first, let second) = self else {
            return self
        }
        var remaining = path
        let branch = remaining.removeFirst()
        if branch {
            return .split(
                axis: axis,
                ratio: existingRatio,
                first: first,
                second: second.updateRatio(path: remaining, ratio: clamped)
            )
        }
        return .split(
            axis: axis,
            ratio: existingRatio,
            first: first.updateRatio(path: remaining, ratio: clamped),
            second: second
        )
    }

    /// Update split ratio for a specific split node in preorder. Kept for
    /// persisted clients and source compatibility; new renderers should use
    /// `updateRatio(path:ratio:)` so nested dividers cannot be misidentified.
    public func updateRatio(splitIndex: Int, ratio: Double) -> SplitLayoutTree {
        guard splitIndex >= 0 else { return self }
        var currentIndex = 0
        return updateRatioRecursive(targetIndex: splitIndex, ratio: ratio, currentIndex: &currentIndex)
    }

    private func updateRatioRecursive(targetIndex: Int, ratio: Double, currentIndex: inout Int) -> SplitLayoutTree {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let existingRatio, let first, let second):
            if currentIndex == targetIndex {
                currentIndex += 1
                return .split(
                    axis: axis,
                    ratio: Self.normalizedInteractiveRatio(ratio),
                    first: first,
                    second: second
                )
            }
            currentIndex += 1
            let newFirst = first.updateRatioRecursive(targetIndex: targetIndex, ratio: ratio, currentIndex: &currentIndex)
            let newSecond = second.updateRatioRecursive(targetIndex: targetIndex, ratio: ratio, currentIndex: &currentIndex)
            return .split(axis: axis, ratio: existingRatio, first: newFirst, second: newSecond)
        }
    }

    /// Every split node in depth-first order, represented by a stable path.
    public var splitPaths: [[Bool]] {
        splitPathsRecursive(prefix: [])
    }

    private func splitPathsRecursive(prefix: [Bool]) -> [[Bool]] {
        switch self {
        case .leaf:
            return []
        case .split(_, _, let first, let second):
            return [prefix]
                + first.splitPathsRecursive(prefix: prefix + [false])
                + second.splitPathsRecursive(prefix: prefix + [true])
        }
    }

    /// Returns the nearest leaf in a visual direction. The layout is
    /// normalized to a unit square, so the result is independent of the
    /// current window size and can be used by keyboard focus commands.
    public func nearestPaneID(
        from paneID: String,
        direction: SplitFocusDirection,
        wrapping: Bool = true
    ) -> String? {
        let frames = normalizedFrames()
        guard let source = frames.first(where: { $0.id == paneID }) else {
            return nil
        }
        let candidates = frames.filter { candidate in
            guard candidate.id != paneID else { return false }
            switch direction {
            case .left:
                return candidate.frame.maxX <= source.frame.minX
            case .right:
                return candidate.frame.minX >= source.frame.maxX
            case .up:
                return candidate.frame.maxY <= source.frame.minY
            case .down:
                return candidate.frame.minY >= source.frame.maxY
            }
        }
        if let nearest = candidates.min(by: { distance($0.frame, source.frame, direction) < distance($1.frame, source.frame, direction) }) {
            return nearest.id
        }
        guard wrapping, !frames.isEmpty else { return nil }
        let wrapped = frames.filter { $0.id != paneID }.min {
            wrappedDistance($0.frame, source.frame, direction) < wrappedDistance($1.frame, source.frame, direction)
        }
        return wrapped?.id
    }

    private struct NormalizedFrame {
        let id: String
        let frame: CGRect
    }

    private func normalizedFrames() -> [NormalizedFrame] {
        frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func frames(in rect: CGRect) -> [NormalizedFrame] {
        switch self {
        case .leaf(let item):
            return [NormalizedFrame(id: item.id, frame: rect)]
        case .split(let axis, let rawRatio, let first, let second):
            let ratio = min(max(Self.normalizedRatio(rawRatio), 0.01), 0.99)
            switch axis {
            case .horizontal:
                let firstWidth = rect.width * ratio
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                let secondRect = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height)
                return first.frames(in: firstRect) + second.frames(in: secondRect)
            case .vertical:
                let firstHeight = rect.height * ratio
                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                let secondRect = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight)
                return first.frames(in: firstRect) + second.frames(in: secondRect)
            }
        }
    }

    private func distance(_ lhs: CGRect, _ rhs: CGRect, _ direction: SplitFocusDirection) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        switch direction {
        case .left, .right:
            return abs(lhs.midX - rhs.midX) + abs(dy) * 0.5
        case .up, .down:
            return abs(lhs.midY - rhs.midY) + abs(dx) * 0.5
        }
    }

    private func wrappedDistance(_ lhs: CGRect, _ rhs: CGRect, _ direction: SplitFocusDirection) -> CGFloat {
        var shifted = lhs
        switch direction {
        case .left: shifted.origin.x += 1
        case .right: shifted.origin.x -= 1
        case .up: shifted.origin.y += 1
        case .down: shifted.origin.y -= 1
        }
        return distance(shifted, rhs, direction)
    }

    /// Find the next or previous pane ID for cycling focus.
    public func nextPaneID(after currentPaneID: String, forward: Bool = true) -> String? {
        let ids = allPaneIDs
        guard !ids.isEmpty else { return nil }
        guard let index = ids.firstIndex(of: currentPaneID) else {
            return ids.first
        }
        if forward {
            let nextIndex = (index + 1) % ids.count
            return ids[nextIndex]
        } else {
            let prevIndex = (index - 1 + ids.count) % ids.count
            return ids[prevIndex]
        }
    }

    /// Reconcile against active tab IDs, pruning invalid or duplicate leaves
    /// and ensuring at least one leaf exists. A duplicate Session/Tab cannot
    /// be rendered twice because that would create competing viewports.
    public func reconcile(validTabIDs: Set<String>, fallbackTabID: String?) -> SplitLayoutTree? {
        var seenPaneIDs: Set<String> = []
        var seenTabIDs: Set<String> = []
        let pruned = reconcileRecursive(
            validTabIDs: validTabIDs,
            seenPaneIDs: &seenPaneIDs,
            seenTabIDs: &seenTabIDs
        )
        if let pruned { return pruned }
        guard let fallbackTabID,
              validTabIDs.contains(fallbackTabID),
              !fallbackTabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .leaf(
            SplitPaneItem(
                id: SplitPaneItem.fallbackID(forTabID: fallbackTabID),
                tabID: fallbackTabID
            )
        )
    }

    private func reconcileRecursive(
        validTabIDs: Set<String>,
        seenPaneIDs: inout Set<String>,
        seenTabIDs: inout Set<String>
    ) -> SplitLayoutTree? {
        switch self {
        case .leaf(let item):
            guard validTabIDs.contains(item.tabID),
                  !item.tabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenTabIDs.count < Self.maxPanes,
                  seenPaneIDs.insert(item.id).inserted,
                  seenTabIDs.insert(item.tabID).inserted else {
                return nil
            }
            return .leaf(item)
        case .split(let axis, let ratio, let first, let second):
            let firstResult = first.reconcileRecursive(
                validTabIDs: validTabIDs,
                seenPaneIDs: &seenPaneIDs,
                seenTabIDs: &seenTabIDs
            )
            let secondResult = second.reconcileRecursive(
                validTabIDs: validTabIDs,
                seenPaneIDs: &seenPaneIDs,
                seenTabIDs: &seenTabIDs
            )
            switch (firstResult, secondResult) {
            case (.some(let first), .some(let second)):
                return .split(axis: axis, ratio: Self.normalizedRatio(ratio), first: first, second: second)
            case (.some(let remaining), .none), (.none, .some(let remaining)):
                return remaining
            case (.none, .none):
                return nil
            }
        }
    }
}

/// Where one layout puts its panes and dividers inside a container.
///
/// The layout is flattened here rather than rendered as a recursive tree,
/// because a pane's view has to keep its identity when the tree's shape
/// changes. A recursive `switch` replaces its whole subtree — including the
/// panes that were already on screen — the moment a sibling appears, which
/// tears down and re-attaches their terminals: the panel flashes, every pane
/// re-reports its geometry, and the Sessions that did not move are resized
/// anyway.
public struct SplitLayoutPlacement: Equatable {
    public struct Pane: Equatable, Identifiable {
        public let item: SplitPaneItem
        public let frame: CGRect
        public var id: String { item.id }
    }

    public struct Divider: Equatable, Identifiable {
        /// The split node this divider belongs to, as `updateRatio(path:)`
        /// addresses it.
        public let path: [Bool]
        public let axis: SplitAxis
        public let ratio: Double
        /// The divider's own band, hit padding included.
        public let frame: CGRect
        /// The distance the divider travels along its axis. Ratios are
        /// expressed against this, so a drag converts points with it.
        public let totalLength: CGFloat
        public let minimumRatio: Double
        public let maximumRatio: Double
        public var id: [Bool] { path }
    }

    public let panes: [Pane]
    public let dividers: [Divider]
}

public extension SplitLayoutTree {
    /// The width a divider occupies, hit padding included.
    static let dividerThickness: CGFloat = 5

    /// Flattens the layout for a container of `size`, in preorder.
    ///
    /// Every frame is snapped to whole points. A divider position derived from a
    /// fractional ratio lands between pixels, and AppKit and SwiftUI then round
    /// it in opposite directions from one layout pass to the next: the panes
    /// flip by a point, each flip reads as a new viewport, and the PTY is
    /// resized for a divider that never moved. Whole-point frames make the
    /// layout a fixed point of its own rounding, and the panes plus their
    /// dividers still cover the container exactly because each one is measured
    /// from the edges it shares with its neighbours.
    func placement(
        in size: CGSize,
        dividerThickness: CGFloat = SplitLayoutTree.dividerThickness
    ) -> SplitLayoutPlacement {
        var panes: [SplitLayoutPlacement.Pane] = []
        var dividers: [SplitLayoutPlacement.Divider] = []
        appendPlacement(
            in: CGRect(
                origin: .zero,
                size: CGSize(width: size.width.rounded(), height: size.height.rounded())
            ),
            path: [],
            dividerThickness: dividerThickness,
            panes: &panes,
            dividers: &dividers
        )
        return SplitLayoutPlacement(panes: panes, dividers: dividers)
    }

    /// How far a divider may travel, given the minimum size of the subtree on
    /// each side of it. A container too small to hold either minimum pins the
    /// divider at an even split, which is the only position it can hold.
    static func interactiveRatioBounds(
        first: SplitLayoutTree,
        second: SplitLayoutTree,
        total: CGFloat,
        axis: SplitAxis
    ) -> ClosedRange<Double> {
        guard total > 0 else {
            return minimumInteractiveRatio...maximumInteractiveRatio
        }
        let firstMinimum = axis == .horizontal ? first.minimumPaneWidth : first.minimumPaneHeight
        let secondMinimum = axis == .horizontal ? second.minimumPaneWidth : second.minimumPaneHeight
        let lower = min(max(Double(firstMinimum / total), minimumInteractiveRatio), 0.5)
        let upper = max(min(Double(1 - secondMinimum / total), maximumInteractiveRatio), 0.5)
        return lower...upper
    }

    private func appendPlacement(
        in rect: CGRect,
        path: [Bool],
        dividerThickness: CGFloat,
        panes: inout [SplitLayoutPlacement.Pane],
        dividers: inout [SplitLayoutPlacement.Divider]
    ) {
        switch self {
        case .leaf(let item):
            panes.append(SplitLayoutPlacement.Pane(item: item, frame: rect))

        case .split(let axis, let rawRatio, let first, let second):
            // The renderer clamps rather than rejects: a ratio outside the
            // interactive range is still drawn at the edge of it.
            let ratio = rawRatio.isFinite ? min(max(rawRatio, 0.05), 0.95) : 0.5
            let total = max(0, (axis == .horizontal ? rect.width : rect.height) - dividerThickness)
            // The divider's leading edge is the one number the split is built
            // from, so rounding it once keeps both panes whole and adjacent.
            let leading = min(
                max(
                    ((axis == .horizontal ? rect.minX : rect.minY) + total * CGFloat(ratio)).rounded(),
                    axis == .horizontal ? rect.minX : rect.minY
                ),
                (axis == .horizontal ? rect.maxX : rect.maxY) - dividerThickness
            )
            let firstRect: CGRect
            let dividerRect: CGRect
            let secondRect: CGRect
            switch axis {
            case .horizontal:
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: max(0, leading - rect.minX),
                    height: rect.height
                )
                dividerRect = CGRect(
                    x: leading,
                    y: rect.minY,
                    width: dividerThickness,
                    height: rect.height
                )
                secondRect = CGRect(
                    x: leading + dividerThickness,
                    y: rect.minY,
                    width: max(0, rect.maxX - leading - dividerThickness),
                    height: rect.height
                )
            case .vertical:
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: max(0, leading - rect.minY)
                )
                dividerRect = CGRect(
                    x: rect.minX,
                    y: leading,
                    width: rect.width,
                    height: dividerThickness
                )
                secondRect = CGRect(
                    x: rect.minX,
                    y: leading + dividerThickness,
                    width: rect.width,
                    height: max(0, rect.maxY - leading - dividerThickness)
                )
            }
            let bounds = Self.interactiveRatioBounds(
                first: first,
                second: second,
                total: total,
                axis: axis
            )
            dividers.append(
                SplitLayoutPlacement.Divider(
                    path: path,
                    axis: axis,
                    ratio: ratio,
                    frame: dividerRect,
                    totalLength: total,
                    minimumRatio: bounds.lowerBound,
                    maximumRatio: bounds.upperBound
                )
            )
            first.appendPlacement(
                in: firstRect,
                path: path + [false],
                dividerThickness: dividerThickness,
                panes: &panes,
                dividers: &dividers
            )
            second.appendPlacement(
                in: secondRect,
                path: path + [true],
                dividerThickness: dividerThickness,
                panes: &panes,
                dividers: &dividers
            )
        }
    }
}

/// Which Tabs the pane bar lists for a split layout.
///
/// This is the mode-independent half of the pane bar: given a scope's Tabs and
/// the layout on screen, it answers what the bar has to enumerate. Whether that
/// answer is a pane control or the Session list itself comes from the display
/// mode, and is resolved in `WarrenDesktopPaneBar.presentation(...)` next to the
/// bar that renders it.
public enum WarrenDesktopPaneBar {
    /// Exactly one surface enumerates a scope's Sessions, and which one it is
    /// depends on the tree.
    ///
    /// When the sidebar lists Sessions as leaves, the bar is a pure pane control:
    /// it shows what is on screen, in pane order, so panes can be focused and
    /// closed, and navigation lives in the one place that already has it. When
    /// the sidebar stops listing them, the bar has to take that job back —
    /// otherwise toggling the tree's density silently strips access to every
    /// Session that is not currently in a pane.
    ///
    /// `selected` is the fallback for the frame between selecting a Session and
    /// the split tree catching up; without it the bar would blink empty. It is
    /// also how a Session selected from outside the layout stays reachable: the
    /// bar lists it after the panes rather than in place of them, so a visit
    /// never hides the group it is visiting from.
    public static func tabs(
        visibleIn tree: SplitLayoutTree,
        from tabs: [ClientTab],
        selected: ClientTab?,
        mode: WarrenDesktopWorkspaceDisplayMode
    ) -> [ClientTab] {
        if mode.paneBarListsEverySession {
            // The projection's order is the one the user reordered by dragging,
            // so it survives however the panes are currently arranged.
            return tabs.isEmpty ? [selected].compactMap { $0 } : tabs
        }
        let tabsByID = Dictionary(
            tabs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let visible = tree.leaves.compactMap { tabsByID[$0.tabID] }
        if let selected, !tree.contains(tabID: selected.id) {
            // A visit, not a replacement: the panel's own panes come first so
            // the group keeps its place in the strip, and the Session being
            // looked at follows them.
            return visible + [selected]
        }
        if visible.isEmpty, let selected {
            return [selected]
        }
        return visible
    }
}


/// Which scope owns an arrangement. A Pane Group belongs to exactly one
/// Workspace or Terminal Group, so the owner is the addressing key a client uses
/// to turn a scope into the Host's group.
public enum WarrenDesktopPaneOwner: Hashable, Sendable {
    case workspace(WorkspaceID)
    case terminalGroup(TerminalGroupID)

    public var terminalGroupID: TerminalGroupID? {
        if case .terminalGroup(let id) = self { return id }
        return nil
    }

    public var workspaceID: WorkspaceID? {
        if case .workspace(let id) = self { return id }
        return nil
    }
}

/// Translates between the Host's arrangement and the renderer's local tree.
///
/// The Host owns the shape, so the renderer is a pure function of it: the local
/// tree exists to be laid out, not to be stored. A leaf carries the Host's Pane
/// ID when it has one, which is what lets focus and pane identity survive an
/// unrelated change.
public enum WarrenDesktopPaneGroupMapping {
    /// The local tree for one Host arrangement.
    public static func tree(from group: PaneGroup) -> SplitLayoutTree {
        tree(from: group.tree)
    }

    public static func tree(from node: PaneNode) -> SplitLayoutTree {
        switch node {
        case .leaf(let paneID, let sessionID):
            let tabID = WarrenDesktopPaneGroupMapping.tabID(for: sessionID)
            return .leaf(
                SplitPaneItem(
                    id: paneID?.description ?? SplitPaneItem.fallbackID(forTabID: tabID),
                    tabID: tabID
                )
            )
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis == .horizontal ? .horizontal : .vertical,
                ratio: ratio,
                first: tree(from: first),
                second: tree(from: second)
            )
        }
    }

    /// The Host tree for one local arrangement.
    ///
    /// A leaf whose Tab no longer maps to a running Session is dropped together
    /// with the split that only held it: the Host would reject the tree anyway,
    /// and the renderer must not send a pane it cannot show.
    public static func paneNode(
        from tree: SplitLayoutTree,
        sessionIDForTabID: (String) -> TerminalSessionID?
    ) -> PaneNode? {
        switch tree {
        case .leaf(let item):
            guard let sessionID = sessionIDForTabID(item.tabID) else { return nil }
            // A fallback identity is the client's placeholder for "one pane of
            // this Tab"; it is not a pane the Host ever assigned, so it is sent
            // as no identity and the Host assigns one.
            let paneID = item.id.hasPrefix("fallback-pane-") ? nil : PaneID(uuidString: item.id)
            return .leaf(paneID: paneID, sessionID: sessionID)
        case .split(let axis, let ratio, let first, let second):
            switch (
                paneNode(from: first, sessionIDForTabID: sessionIDForTabID),
                paneNode(from: second, sessionIDForTabID: sessionIDForTabID)
            ) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                return only
            case (let firstChild?, let secondChild?):
                return .split(
                    axis: axis == .horizontal ? .horizontal : .vertical,
                    ratio: ratio,
                    first: firstChild,
                    second: secondChild
                )
            }
        }
    }

    /// The Tab identity one Session has in the projection. A Tab is the
    /// presentation entry for a Session, and its identity is derived from the
    /// Session ID.
    public static func tabID(for sessionID: TerminalSessionID) -> String {
        "remote-\(sessionID.description)"
    }

    public static func sessionID(forTabID tabID: String) -> TerminalSessionID? {
        guard tabID.hasPrefix("remote-") else { return nil }
        return TerminalSessionID(uuidString: String(tabID.dropFirst("remote-".count)))
    }
}
