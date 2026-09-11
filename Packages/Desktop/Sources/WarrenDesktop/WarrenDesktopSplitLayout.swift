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

    /// Identity for SwiftUI tree replacement. Ratios are intentionally omitted
    /// so a divider drag updates the existing terminal hosts instead of
    /// rebuilding every surface on each pointer event. Maximization is encoded
    /// by the resulting tree shape, which naturally changes this identity.
    public indirect enum StructuralIdentity: Hashable, Sendable {
        case leaf(paneID: String, tabID: String)
        case split(axis: SplitAxis, first: StructuralIdentity, second: StructuralIdentity)
    }

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

    /// A structural identity suitable for SwiftUI's `.id(...)` modifier.
    /// Unlike `Hashable` on the full tree, this value ignores divider ratios.
    public var structuralIdentity: StructuralIdentity {
        switch self {
        case .leaf(let item):
            return .leaf(paneID: item.id, tabID: item.tabID)
        case .split(let axis, _, let first, let second):
            return .split(
                axis: axis,
                first: first.structuralIdentity,
                second: second.structuralIdentity
            )
        }
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
    public func split(
        targetPaneID: String,
        newTabID: String,
        axis: SplitAxis,
        placeAfter: Bool = true
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
            axis: axis,
            placeAfter: placeAfter,
            didSplit: &didSplit
        )
    }

    private func splitRecursive(
        targetPaneID: String,
        newTabID: String,
        axis: SplitAxis,
        placeAfter: Bool,
        didSplit: inout Bool
    ) -> SplitLayoutTree {
        switch self {
        case .leaf(let existingItem):
            if existingItem.id == targetPaneID, !didSplit {
                didSplit = true
                let newItem = SplitPaneItem(tabID: newTabID)
                let first = placeAfter ? SplitLayoutTree.leaf(existingItem) : SplitLayoutTree.leaf(newItem)
                let second = placeAfter ? SplitLayoutTree.leaf(newItem) : SplitLayoutTree.leaf(existingItem)
                return .split(axis: axis, ratio: 0.5, first: first, second: second)
            }
            return self
        case .split(let existingAxis, let ratio, let first, let second):
            let newFirst = first.splitRecursive(
                targetPaneID: targetPaneID,
                newTabID: newTabID,
                axis: axis,
                placeAfter: placeAfter,
                didSplit: &didSplit
            )
            let newSecond = second.splitRecursive(
                targetPaneID: targetPaneID,
                newTabID: newTabID,
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

/// Device-local persistence for split layouts per workspace or terminal group.
public enum WarrenDesktopSplitLayoutPersistence {
    private static let key = "warren.desktop.splitLayouts"
    private static let endpointPrefix = "endpoint-"
    /// Coalescing window for divider drags, which republish a new ratio on
    /// every pointer event.
    public static let saveCoalescingInterval: TimeInterval = 0.4
    @MainActor private static var pendingSave: DispatchWorkItem?
    @MainActor private static var pendingLayouts: [String: SplitLayoutTree]?
    @MainActor private static var pendingDefaults: UserDefaults?

    /// Writes the layouts after a short quiet period. Repeated calls replace
    /// the pending write, so a drag persists once when it settles.
    @MainActor
    public static func scheduleSave(
        _ layouts: [String: SplitLayoutTree],
        to defaults: UserDefaults = .standard,
        after interval: TimeInterval = saveCoalescingInterval
    ) {
        pendingSave?.cancel()
        pendingLayouts = layouts
        pendingDefaults = defaults
        let work = DispatchWorkItem { flushPendingSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Flushes a pending coalesced write immediately.
    @MainActor
    public static func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let layouts = pendingLayouts else { return }
        let defaults = pendingDefaults ?? .standard
        pendingLayouts = nil
        pendingDefaults = nil
        save(layouts, to: defaults)
    }

    /// Drops layouts for scopes of `endpointID` that no longer exist. Other
    /// endpoints keep their layouts: their Workspaces are not represented in
    /// the current projection and must not be treated as deleted.
    public static func pruned(
        _ layouts: [String: SplitLayoutTree],
        endpointID: String,
        liveScopeKeys: Set<String>
    ) -> [String: SplitLayoutTree] {
        let ownedPrefix = endpointPrefix + endpointID + "-"
        return layouts.filter { key, _ in
            guard key.hasPrefix(ownedPrefix) else { return true }
            return liveScopeKeys.contains(key)
        }
    }

    public static func restore(
        from defaults: UserDefaults = .standard
    ) -> [String: SplitLayoutTree] {
        guard let data = defaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: SplitLayoutTree].self, from: data) else {
            return [:]
        }
        // Layouts written before endpoint scoping cannot be safely rebound:
        // their Session IDs may belong to a different Host. Keep only the
        // namespaced form and let the current scope build a fresh fallback.
        return dict.filter { $0.key.hasPrefix(endpointPrefix) }
    }

    public static func save(
        _ layouts: [String: SplitLayoutTree],
        to defaults: UserDefaults = .standard
    ) {
        let endpointScoped = layouts.filter { $0.key.hasPrefix(endpointPrefix) }
        if let data = try? JSONEncoder().encode(endpointScoped) {
            defaults.set(data, forKey: key)
        }
    }
}
