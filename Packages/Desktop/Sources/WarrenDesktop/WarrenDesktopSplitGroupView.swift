import SwiftUI
import WarrenDesignSystem

/// One pane group the pane bar draws.
///
/// A scope can own several arrangements, so the bar draws one group per drawn
/// arrangement. The value exists so the bar, the track's width, and the scroll
/// follower all read one membership and one mark slot instead of each
/// recomputing them from a bare set of Tab IDs.
struct WarrenDesktopSplitGroup: Equatable {
    /// The Host arrangement this mark names. Unique among a scope's groups, so
    /// the track can key each run by it and give each its own hue.
    let id: String
    /// The scope that owns the tree — a Workspace. The
    /// group's color is derived from it, so the same scope keeps its hue.
    let scopeKey: String
    let tree: SplitLayoutTree
    /// The group's name in the top bar: its arrangement's name, or the scope's.
    var title: String = ""
    /// Where the group lives, e.g. "warren · feat/workbench-cards".
    var context: String = ""
    /// The member the layout last had active.
    var activeTabID: String? = nil
    /// One line per member on what its Session is doing, keyed by Tab.
    var activity: [String: String] = [:]
    /// Each member's app icon, resolved from its Session like the sidebar's.
    var icons: [String: WarrenDesktopAppIcon] = [:]

    init(
        id: String? = nil,
        scopeKey: String,
        tree: SplitLayoutTree,
        title: String = "",
        context: String = "",
        activeTabID: String? = nil,
        activity: [String: String] = [:],
        icons: [String: WarrenDesktopAppIcon] = [:]
    ) {
        self.id = id ?? scopeKey
        self.scopeKey = scopeKey
        self.tree = tree
        self.title = title
        self.context = context
        self.activeTabID = activeTabID
        self.activity = activity
        self.icons = icons
    }

    var tabIDs: [String] { tree.allTabIDs }

    /// Whether the group earns its mark. One pane is not a group: it draws no
    /// mark and no rule, because there is nothing to bind it to.
    var isDrawn: Bool { tree.count > 1 }
}

/// Which identity hue a group wears.
///
/// The mapping has to survive a relaunch, which rules out Swift's `hashValue`:
/// it is seeded per process, so a group would change color every time the app
/// started. FNV-1a over the scope key is stable for the life of the key.
enum WarrenDesktopSplitGroupPalette {
    static func colorIndex(for scopeKey: String, tintCount: Int) -> Int {
        guard tintCount > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in scopeKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(tintCount))
    }

    static func color(for scopeKey: String, tokens: WarrenColorTokens) -> Color {
        let tints = tokens.tabGroupTints
        guard !tints.isEmpty else { return tokens.mutedForeground }
        return tints[colorIndex(for: scopeKey, tintCount: tints.count)]
    }
}
