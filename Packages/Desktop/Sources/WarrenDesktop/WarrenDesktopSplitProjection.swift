import Foundation

/// Which layout the store keeps, and which one the panel shows.
///
/// These are two different questions that used to be answered by one function,
/// which is why a glance at another Session could retire a split for good: the
/// narrowed view the renderer needs was also what got written to the store.
///
/// * `stored` is the layout minus the Sessions the roster no longer has.
/// * `rendered` is what the panel draws: the stored layout, or the selected
///   Session alone while that Session is outside it.
///
/// A scope still owns exactly one layout. A visit to a Session outside it is
/// therefore temporary — the first action that reshapes the panel ends the
/// visit and retires the layout it was visiting from.
enum WarrenDesktopSplitProjection {
    /// The layout the scope's store keeps.
    ///
    /// Never narrowed to the current selection: merely looking at a Session
    /// must not be able to retire the split. Pruning is a different matter —
    /// a leaf whose Session the Host has ended has to go, or the next launch
    /// would restore a pane nothing can fill.
    static func stored(
        _ tree: SplitLayoutTree,
        validTabIDs: Set<String>,
        fallbackTabID: String?
    ) -> SplitLayoutTree? {
        tree.reconcile(validTabIDs: validTabIDs, fallbackTabID: fallbackTabID)
    }

    /// The layout the panel draws.
    ///
    /// A selection outside the layout renders as a lone pane, so the panel
    /// never shows Sessions the selected Tab does not own. `isHoldingForCreation`
    /// is the one exception: a split in flight has already selected the Session
    /// it is creating, before the roster can place it in the layout, and
    /// narrowing the tree during that window would drop the pane the split was
    /// aimed at.
    static func rendered(
        _ tree: SplitLayoutTree,
        selectedTabID: String?,
        validTabIDs: Set<String>,
        isHoldingForCreation: Bool
    ) -> SplitLayoutTree {
        guard !isHoldingForCreation,
              let selectedTabID,
              validTabIDs.contains(selectedTabID),
              !tree.contains(tabID: selectedTabID) else {
            return tree
        }
        return lonePane(tabID: selectedTabID)
    }

    /// The pane a split request extends.
    ///
    /// Always a pane of the scope's layout, because the layout is the panel's
    /// persistent arrangement: a Session being visited is not part of it, so it
    /// is not a place a new pane can be attached to. The selected Tab wins when
    /// it is a pane, since that is the pane the user is working in; otherwise
    /// the layout's remembered pane does, and only then its first pane.
    static func splitTargetPaneID(
        in layout: SplitLayoutTree,
        selectedTabID: String?,
        rememberedPaneID: String?
    ) -> String? {
        if let selectedTabID, let item = layout.item(forTabID: selectedTabID) {
            return item.id
        }
        if let rememberedPaneID, layout.contains(paneID: rememberedPaneID) {
            return rememberedPaneID
        }
        return layout.allPaneIDs.first
    }

    /// The Tab a scope with no arrangement renders.
    ///
    /// A split in flight has to keep the pane it was aimed at: creating the
    /// Session selects it as soon as the roster publishes it, so a fallback
    /// that followed the live selection would move to that Session before the
    /// pending request could consume it, and the recorded pane would no longer
    /// exist. The pending target therefore wins for as long as one is recorded.
    /// This is the fallback's half of `rendered(isHoldingForCreation:)`.
    static func baseTabID(
        selectedTabID: String?,
        pendingTargetTabID: String?,
        emptyTabID: String
    ) -> String {
        pendingTargetTabID ?? selectedTabID ?? emptyTabID
    }

    /// One Session filling the panel.
    ///
    /// `paneID` is passed only when the pane already had an identity — a split
    /// request names the pane it was aimed at — so the fallback ID keeps a
    /// selection-rendered pane stable across repeated body passes.
    static func lonePane(tabID: String, paneID: String? = nil) -> SplitLayoutTree {
        .leaf(
            SplitPaneItem(
                id: paneID ?? SplitPaneItem.fallbackID(forTabID: tabID),
                tabID: tabID
            )
        )
    }
}

/// Whether the Host's arrangement may replace a scope's local layout.
///
/// A local edit the Host has not echoed yet is the one case a roster must not
/// overwrite: the roster can still carry the arrangement from before the edit,
/// and adopting that collapses the split for as long as the Host's answer is in
/// flight — visible as a split that flashes and disappears when the roster is
/// slow, and a split whose new pane never lands at all.
///
/// An in-flight edit waits for the Host to show the same panes. Pane identity is
/// the Host's to assign, so the tabs — not the pane IDs — are what confirm it;
/// comparing IDs would make every echo look different and the edit would never
/// settle.
enum WarrenDesktopPaneGroupAdoption {
    static func shouldAdopt(
        local: SplitLayoutTree?,
        adopted: SplitLayoutTree?,
        host: SplitLayoutTree
    ) -> Bool {
        guard let local, local != adopted else { return true }
        return host.allTabIDs == local.allTabIDs
    }
}
