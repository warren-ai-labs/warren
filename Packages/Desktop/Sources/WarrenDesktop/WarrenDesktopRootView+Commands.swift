import AppKit
import SwiftUI
import os
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopRoot {
    func toggleSidebar() {
        // The rail's width is its own animation; the terminal only sees the
        // final geometry once the card is gone.
        withAnimation(sidebarCollapseAnimation) {
            sidebarState.toggleCollapsed()
        }
        actions(.toggleSidebar)
    }

    func setCommandPalettePresented(_ presented: Bool) {
        withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
            commandPalettePresented = presented
        }
    }

    func tabIndex(from rawValue: Any?) -> Int? {
        if let index = rawValue as? Int {
            return index
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        return nil
    }

    func handleNewSession(in presentation: Presentation) {
        addSession(in: presentation)
    }

    /// Cycles Sessions only.
    ///
    /// The editor used to be the track's last stop, so cycling past the final
    /// Session opened it and cycling out of it returned to a Session. It is no
    /// longer a Tab — it is a region beside the whole track — so the cycle is
    /// once again exactly the Sessions.
    func handleTabMove(forward: Bool, in presentation: Presentation) {
        guard let tabID = WarrenDesktopTabCycler.tabID(
            forward: forward,
            in: presentation.tabs,
            selectedTabID: navigation.selectedTabID
        ) else { return }
        selectTab(tabID, in: presentation)
    }

    func handleSelectTab(
        _ note: Notification,
        in presentation: Presentation
    ) {
        let rawIndex = note.userInfo?[WarrenDesktopCommand.selectTabIndexKey]
        guard let index = tabIndex(from: rawIndex),
              let tabID = WarrenDesktopTabSelector.tabID(
                in: presentation.tabs,
                number: index
              ) else { return }
        selectTab(tabID, in: presentation)
    }

    func currentScopeKey(presentation: Presentation) -> String? {
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        if let workspace = presentation.workspace {
            return endpointScope + "workspace-\(workspace.id.rawValue.uuidString)"
        }
        return nil
    }

    /// The scope's layout: what the store holds, reconciled against the roster.
    ///
    /// This is the layout the panel belongs to, whether or not it is the one on
    /// screen — a Session selected from outside it is a visit, and the layout
    /// survives it so the split can be returned to.
    func scopeSplitTree(presentation: Presentation) -> SplitLayoutTree {
        guard let scope = currentScopeKey(presentation: presentation) else {
            return WarrenDesktopSplitProjection.lonePane(
                tabID: presentation.tab?.id ?? "default"
            )
        }
        let validTabIDs = Set(presentation.tabs.map(\.id))
        // The only Session a scope may fall back to is the selected one. Falling
        // back to the workspace's first Tab used to resurrect a Session the user
        // had just cleared: closing the last pane emptied the content but the
        // pane bar redrew that Session's identity, so the close read as a no-op.
        let fallbackTabID = presentation.tab?.id
        // A split in flight pins the base to the Session it was aimed at. The
        // Session it creates is selected as soon as the roster publishes it, so
        // a lone-pane fallback that followed the live selection would move to
        // that Session before the pending request could consume it; the scope
        // has no tree yet to hold through the window, so the fallback is the
        // only thing that can. `rendered(isHoldingForCreation:)` is the same
        // guard for a scope that already has one.
        let baseTabID = WarrenDesktopSplitProjection.baseTabID(
            selectedTabID: fallbackTabID,
            pendingTargetTabID: pendingSplits[scope]?.targetTabID,
            emptyTabID: Self.emptyPaneTabID
        )
        // The Host's arrangement is the shape, whether or not this client has
        // caught up with a local edit yet. Only a scope the Host does not own a
        // group for falls through to the local value and the lone-pane fallback.
        let local = splitTrees[scope]
        let isEditInFlight = local != nil && local != adoptedPaneTrees[scope]
        if let group = hostPaneGroup(for: presentation), !isEditInFlight {
            if let reconciled = WarrenDesktopSplitProjection.stored(
                WarrenDesktopPaneGroupMapping.tree(from: group),
                validTabIDs: validTabIDs,
                fallbackTabID: fallbackTabID
            ) {
                return reconciled
            }
            return WarrenDesktopSplitProjection.lonePane(
                tabID: baseTabID
            )
        }
        if let existing = splitTrees[scope],
           let reconciled = WarrenDesktopSplitProjection.stored(
               existing,
               validTabIDs: validTabIDs,
               fallbackTabID: fallbackTabID
           ) {
            return reconciled
        }
        return WarrenDesktopSplitProjection.lonePane(
            tabID: baseTabID
        )
    }

    /// The layout the panel draws, which is the scope's layout unless the
    /// selection is visiting a Session outside it.
    func currentSplitTree(presentation: Presentation) -> SplitLayoutTree {
        let isHoldingForCreation = currentScopeKey(presentation: presentation)
            .map { pendingSplits[$0] != nil } ?? false
        return WarrenDesktopSplitProjection.rendered(
            scopeSplitTree(presentation: presentation),
            selectedTabID: navigation.selectedTabID,
            validTabIDs: Set(presentation.tabs.map(\.id)),
            isHoldingForCreation: isHoldingForCreation
        )
    }

    /// Leaf identity for a scope with nothing on screen. It names no Session, so
    /// the pane bar filters it out and the content renders the empty state while
    /// the workspace's Sessions keep running in the tree.
    ///
    /// Computed rather than stored: a generic view type cannot hold static
    /// storage.
    static var emptyPaneTabID: String { "empty" }

    func currentActivePaneID(presentation: Presentation, tree: SplitLayoutTree) -> String {
        let scope = currentScopeKey(presentation: presentation)
        // Navigation changes can select the successor tab synchronously when
        // a pane is closing, before the Host roster removes the old leaf.
        // Prefer the selected tab whenever it is already represented so the
        // control/focus intent follows that pane instead of briefly targeting
        // the session that is being deleted.
        return WarrenDesktopSplitProjection.splitTargetPaneID(
            in: tree,
            selectedTabID: navigation.selectedTabID,
            rememberedPaneID: scope.flatMap { activePaneIDs[$0] }
        ) ?? "pane-default"
    }

    /// The arrangements the bar labels, in the order it draws them.
    ///
    /// Which arrangements that is follows the display mode. Rich mode's sidebar
    /// lists Sessions, so the bar is a pane control for what is on screen and
    /// only the rendered arrangement earns a mark — a visit draws none. Compact
    /// mode's bar *is* the Session list, so every arrangement of the scope is
    /// gathered into its own run and stays reachable. One pane is not a group:
    /// there is no second pane to bind it to, and no mark to draw.
    func splitGroups(presentation: Presentation) -> [WarrenDesktopSplitGroup] {
        guard let scope = currentScopeKey(presentation: presentation) else { return [] }
        if workspaceDisplayMode.isRich {
            let tree = currentSplitTree(presentation: presentation)
            guard tree.count > 1 else { return [] }
            let group = hostPaneGroup(for: presentation)
            return [
                splitGroup(
                    id: group?.id.description,
                    name: group?.name,
                    scope: scope,
                    tree: tree,
                    presentation: presentation
                )
            ]
        }
        return hostPaneGroups(for: presentation).compactMap { group in
            let tree = WarrenDesktopPaneGroupMapping.tree(from: group)
            guard tree.count > 1 else { return nil }
            return splitGroup(
                id: group.id.description,
                name: group.name,
                scope: scope,
                tree: tree,
                presentation: presentation
            )
        }
    }

    /// One Host arrangement with the title, context and per-Tab activity the
    /// bar and its shelf read.
    func splitGroup(
        id: String?,
        name: String?,
        scope: String,
        tree: SplitLayoutTree,
        presentation: Presentation
    ) -> WarrenDesktopSplitGroup {
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        var activity: [String: String] = [:]
        var icons: [String: WarrenDesktopAppIcon] = [:]
        for tab in presentation.tabs where tree.contains(tabID: tab.id) {
            let session = tab.sessionID.flatMap { projection.session(id: $0) }
            activity[tab.id] = session.map(Self.paneActivityLine) ?? ""
            icons[tab.id] = session.map(WarrenDesktopAppIcon.resolve) ?? WarrenDesktopAppIcon(kind: tab.kind)
        }
        return WarrenDesktopSplitGroup(
            id: id,
            scopeKey: scope,
            tree: tree,
            title: paneGroupTitle(name: name, presentation: presentation),
            context: paneGroupContext(presentation: presentation),
            activeTabID: tree.item(for: activePaneID)?.tabID,
            activity: activity,
            icons: icons
        )
    }

    /// The group's name: the Host arrangement's own name when it has one,
    /// otherwise the scope it belongs to.
    func paneGroupTitle(name: String?, presentation: Presentation) -> String {
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        return presentation.workspace?.name ?? ""
    }

    /// Where the group lives: the project and the branch.
    func paneGroupContext(presentation: Presentation) -> String {
        if let workspace = presentation.workspace {
            let project = projection.projectGroup(id: workspace.projectID)?.project.name
            let branch = workspace.branch?.isEmpty == false ? workspace.branch : workspace.name
            return [project, branch].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        return ""
    }

    /// One line on what a pane's Session is doing: the question it is waiting
    /// on, else the command it runs, else its state.
    static func paneActivityLine(_ session: WarrenDesktopSession) -> String {
        if let reason = session.agentStatus?.attention?.reason
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return reason
        }
        // The raw command line, not the command label: for an Agent the label
        // is the Agent's own name, which the icon beside the line already says.
        let command = session.runtimeCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { return command }
        switch session.activity {
        case .working: return "Working"
        case .blocked: return "Waiting for you"
        case .failed: return "Failed"
        case .ready: return "Ready"
        case .exited: return "Exited"
        case nil: return session.workingDirectory
        }
    }

    /// The moves that bring a scope's Tab order back in line with its layout.
    ///
    /// Called whenever the layout changes, and once on appear so a restored
    /// layout is matched by a restored order. An unchanged order costs nothing,
    /// which matters because a divider drag also lands here.
    func alignTabOrderWithLayout() {
        let presentation = makePresentation()
        // The members the bar leads with are exactly the ones its runs hold, so
        // the stored order has to match whichever arrangements it draws: the
        // rendered one in rich mode, every drawn one in compact mode.
        let members: [String]
        if workspaceDisplayMode.isRich {
            let layout = scopeSplitTree(presentation: presentation)
            guard layout.count > 1 else { return }
            members = layout.allTabIDs
        } else {
            members = hostPaneGroups(for: presentation)
                .map { WarrenDesktopPaneGroupMapping.tree(from: $0) }
                .filter { $0.count > 1 }
                .flatMap(\.allTabIDs)
            guard !members.isEmpty else { return }
        }
        guard let workspaceID = presentation.workspace?.id else { return }
        let order = projection.tabs(in: workspaceID).map(\.id)
        let target = WarrenDesktopTabOrdering.membersFirst(order, members: members)
        for move in WarrenDesktopTabOrdering.moves(from: order, to: target) {
            dispatch(.moveTab(move.tabID, before: move.before))
        }
    }

    func setSplitTree(_ tree: SplitLayoutTree, for scope: String, asNewGroup: Bool = false) {
        splitTrees[scope] = tree
        commitSplitTree(tree, for: scope, asNewGroup: asNewGroup)
    }

    /// The arrangement the Host owns for the current presentation, if any. The
    /// first group in draw order is the one on screen: pane geometry is relative
    /// to the whole content area, so a client renders exactly one arrangement.
    func hostPaneGroup(for presentation: Presentation) -> PaneGroup? {
        let groups = hostPaneGroups(for: presentation)
        guard !groups.isEmpty else { return nil }
        guard let scope = currentScopeKey(presentation: presentation),
              let selected = activePaneGroupIDs[scope],
              let match = groups.first(where: { $0.id.description == selected }) else {
            return groups.first
        }
        return match
    }

    /// Every arrangement of the current scope, in the Host's draw order. More
    /// than one means the top bar has something to switch between.
    func hostPaneGroups(for presentation: Presentation) -> [PaneGroup] {
        if let workspace = presentation.workspace {
            return projection.paneGroups(in: workspace.id)
        }
        return []
    }

    /// Selects the arrangement this window renders, or steps to the next one.
    ///
    /// Entering an arrangement also enters its active Session. Writing only
    /// the drawn group left the keyboard in the arrangement that had just been
    /// parked: no Tab changed, so nothing asked the Session's input to take
    /// focus, and typing went nowhere.
    func selectPaneGroup(id: PaneGroupID?, step: Int = 0, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let groups = hostPaneGroups(for: presentation)
        guard !groups.isEmpty else { return }
        let target: PaneGroup?
        if let id {
            target = groups.first { $0.id == id }
        } else {
            let current = hostPaneGroup(for: presentation)?.id
            let index = groups.firstIndex { $0.id == current } ?? -1
            let next = ((index + step) % groups.count + groups.count) % groups.count
            target = groups[next]
        }
        guard let target else { return }
        if activePaneGroupIDs[scope] != target.id.description {
            activePaneGroupIDs[scope] = target.id.description
            // Cache the group now on screen, as `showPaneGroup` does, so the
            // scope's local layout describes the arrangement being drawn
            // rather than the one it replaced.
            adoptHostPaneGroups(projection.paneGroups)
        }
        let tree = WarrenDesktopPaneGroupMapping.tree(from: target)
        guard let tabID = WarrenDesktopPaneGroupEntry.tabID(
            in: tree,
            selectedTabID: navigation.selectedTabID,
            rememberedPaneID: activePaneIDs[scope]
        ) else { return }
        if let item = tree.item(forTabID: tabID) {
            restoreZoom(unlessShowing: item.id, scope: scope)
            restoreFold(ifFolded: item.id, scope: scope)
            activePaneIDs[scope] = item.id
        }
        // Dispatch even when the Tab is already selected: the arrangement
        // changed, so this is how the newly drawn pane asks for the keyboard.
        dispatch(.selectTab(tabID))
    }

    func paneOwner(for presentation: Presentation) -> WarrenDesktopPaneOwner? {
        if let workspace = presentation.workspace {
            return .workspace(workspace.id)
        }
        return nil
    }

    /// Sends one local arrangement to the Host. The Host assigns pane identity
    /// and rejects a tree it cannot validate, so the local value is only an
    /// optimistic head start: the roster's answer replaces it.
    func commitSplitTree(
        _ tree: SplitLayoutTree,
        for scope: String,
        asNewGroup: Bool = false
    ) {
        let presentation = makePresentation()
        guard currentScopeKey(presentation: presentation) == scope,
              let owner = paneOwner(for: presentation),
              let node = WarrenDesktopPaneGroupMapping.paneNode(
                  from: tree,
                  sessionIDForTabID: { WarrenDesktopPaneGroupMapping.sessionID(forTabID: $0) }
              ) else {
            paneDiagnostic("pane_commit_skipped", scope: scope, [
                "reason": currentScopeKey(presentation: presentation) == scope ? "unmappable" : "scopeChanged",
                "tabs": Self.diagnosticTabs(tree.allTabIDs),
            ])
            return
        }
        // A split whose Session the Host has not published yet would be rejected
        // as an unknown Session. The pending-split path calls back here once the
        // roster confirms it, so skipping is what keeps the two in step.
        let live = Set(projection.sessions.map(\.id))
        guard node.sessionIDs.allSatisfy({ live.contains($0) }) else {
            paneDiagnostic("pane_commit_skipped", scope: scope, [
                "reason": "sessionNotLive",
                "tabs": Self.diagnosticTabs(tree.allTabIDs),
            ])
            return
        }
        // A scope can hold several arrangements. An edit replaces the one this
        // window renders, so the write names it rather than reaching for the
        // first group the scope happens to have. A scope with no group yet — or
        // a split that deliberately starts a new one — asks for a new group.
        let target: WarrenDesktopPaneGroupTarget
        if !asNewGroup, let group = hostPaneGroup(for: presentation) {
            target = .group(group.id)
        } else {
            target = .newGroup
        }
        paneDiagnostic("pane_commit", scope: scope, [
            "tabs": Self.diagnosticTabs(tree.allTabIDs),
            "target": asNewGroup ? "new" : (hostPaneGroup(for: presentation).map { String($0.id.description.prefix(8)) } ?? "new"),
        ])
        onCommitPaneTree(owner, node, target)
    }

    func paneDiagnostic(_ event: String, scope: String?, _ fields: [String: String] = [:]) {
        var fields = fields
        if let scope {
            fields["scope"] = String(scope.suffix(8))
        }
        onPaneDiagnostic(event, fields)
    }

    /// Tab IDs shortened to the Session prefix, in pane order.
    static func diagnosticTabs(_ tabIDs: [String]) -> String {
        tabIDs.map { String($0.replacingOccurrences(of: "remote-", with: "").prefix(8)) }
            .joined(separator: ",")
    }

    static func diagnosticTab(_ tabID: String?) -> String {
        tabID.map { diagnosticTabs([$0]) } ?? "nil"
    }

    /// Adopts the Host's arrangements after a roster change, so a summary of
    /// every scope that gained, changed, or lost a group is reflected locally.
    func adoptHostPaneGroups(_ paneGroups: [PaneGroup]) {
        let endpointPrefix = "endpoint-\(selectedEndpointID)-"
        var groupsByScope: [String: [PaneGroup]] = [:]
        for group in paneGroups {
            guard let scope = paneGroupScopeKey(for: group) else { continue }
            groupsByScope[scope, default: []].append(group)
        }
        // A split that opened a new arrangement becomes the one this window
        // renders the moment the roster carries it. The Session it was started
        // around is the marker: the new group is the one that holds it, and no
        // other group of the scope does.
        for (scope, groups) in groupsByScope {
            guard let visitTabID = pendingNewGroupVisitTabIDs[scope] else { continue }
            guard let created = groups.first(where: {
                WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: visitTabID)
            }) else { continue }
            activePaneGroupIDs[scope] = created.id.description
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
        }
        // Only the rendered arrangement is cached locally; every other group of
        // the scope is derived from the projection once it becomes active.
        // Adopting all of them would leave `splitTrees[scope]` holding whichever
        // came last, which is not the one the window draws.
        var ownedScopes: Set<String> = []
        for (scope, groups) in groupsByScope {
            ownedScopes.insert(scope)
            let active: PaneGroup
            if let selected = activePaneGroupIDs[scope],
               let match = groups.first(where: { $0.id.description == selected }) {
                active = match
            } else {
                active = groups[0]
            }
            let adopted = WarrenDesktopPaneGroupMapping.tree(from: active)
            // A roster can still carry the arrangement from before a local edit,
            // so adopting it here would collapse the split until the Host's own
            // answer arrives. Keep the edit and let the confirming tree land.
            guard WarrenDesktopPaneGroupAdoption.shouldAdopt(
                local: splitTrees[scope],
                adopted: adoptedPaneTrees[scope],
                host: adopted
            ) else {
                paneDiagnostic("pane_adopt_held", scope: scope, [
                    "local": splitTrees[scope].map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
                    "host": Self.diagnosticTabs(adopted.allTabIDs),
                    "hostRevision": String(active.revision),
                ])
                continue
            }
            if splitTrees[scope] != adopted {
                if adoptedPaneTrees[scope]?.allTabIDs != adopted.allTabIDs {
                    paneDiagnostic("pane_adopt", scope: scope, [
                        "local": splitTrees[scope].map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
                        "host": Self.diagnosticTabs(adopted.allTabIDs),
                        "hostRevision": String(active.revision),
                    ])
                }
                splitTrees[scope] = adopted
            }
            adoptedPaneTrees[scope] = adopted
        }
        // A scope the Host no longer owns has no arrangement; a local tree left
        // behind is the remnant of one removed on the Host, and keeping it made
        // the next split adopt one of its surviving Sessions instead of the
        // Session being split. An edit still in flight is the exception — the
        // Host has simply not echoed it yet — and the endpoint prefix keeps
        // another Host's arrangements out of this window's cleanup.
        let staleScopes = splitTrees.compactMap { scope, local -> String? in
            guard scope.hasPrefix(endpointPrefix),
                  !ownedScopes.contains(scope),
                  adoptedPaneTrees[scope] == local else { return nil }
            return scope
        }
        for scope in staleScopes {
            paneDiagnostic("pane_adopt_removed", scope: scope)
            splitTrees.removeValue(forKey: scope)
            adoptedPaneTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
        }
    }

    /// The scope key a Host arrangement belongs to, for this window's endpoint.
    func paneGroupScopeKey(for group: PaneGroup) -> String? {
        if let workspaceID = group.workspaceID {
            return "endpoint-\(selectedEndpointID)-workspace-\(workspaceID.rawValue.uuidString)"
        }
        return nil
    }

    /// Persist the same reconciled tree that the renderer uses. Keeping this
    /// out of `body` avoids mutating SwiftUI state during view evaluation,
    /// while still removing ended/foreign leaves instead of carrying them
    /// across the next launch.
    func reconcilePersistedSplitTree() {
        let presentation = makePresentation()
        guard let scope = currentScopeKey(presentation: presentation),
              let existing = splitTrees[scope] else { return }
        let validTabIDs = Set(presentation.tabs.map(\.id))
        let fallbackTabID = presentation.tab?.id
        guard let reconciled = WarrenDesktopSplitProjection.stored(
            existing,
            validTabIDs: validTabIDs,
            fallbackTabID: fallbackTabID
        ) else {
            // Nothing survived, which is a real answer only when the scope still
            // lists Sessions. An empty or not-yet-refreshed roster says nothing
            // about the panes, and dropping the layout on it would lose a split
            // the user never closed.
            guard !presentation.tabs.isEmpty else { return }
            paneDiagnostic("pane_layout_cleared", scope: scope, [
                "local": Self.diagnosticTabs(existing.allTabIDs),
            ])
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            return
        }
        // Only the layout is written back, never the current selection's view
        // of it. Persisting the aligned projection is what used to turn a
        // glance at another Session into a permanent exit from the split.
        if splitTrees[scope] != reconciled {
            splitTrees[scope] = reconciled
        }
        if let activePaneID = activePaneIDs[scope], !reconciled.contains(paneID: activePaneID) {
            activePaneIDs[scope] = reconciled.item(forTabID: navigation.selectedTabID ?? "")?.id
                ?? reconciled.allPaneIDs.first
        }
        pruneSplitTreesForDeletedScopes()
    }

    /// Arrangements are keyed by endpoint and scope, so a deleted Workspace
    /// would otherwise keep a local tree forever. Only the current
    /// endpoint's scopes are evaluated: another endpoint's Workspaces are absent
    /// from this projection and are not deleted.
    func pruneSplitTreesForDeletedScopes() {
        var liveScopeKeys: Set<String> = []
        let endpointScope = "endpoint-\(selectedEndpointID)-"
        for workspace in projection.groups.flatMap(\.workspaces) {
            liveScopeKeys.insert(endpointScope + "workspace-\(workspace.id.rawValue.uuidString)")
        }
        let pruned = splitTrees.filter { key, _ in
            guard key.hasPrefix("endpoint-\(selectedEndpointID)-") else { return true }
            return liveScopeKeys.contains(key)
        }
        guard pruned.count != splitTrees.count else { return }
        let removed = Set(splitTrees.keys).subtracting(pruned.keys)
        splitTrees = pruned
        for scope in removed {
            activePaneIDs.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            if pendingSplits.removeValue(forKey: scope) != nil {
                paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "scopePruned"])
            }
        }
    }

    func visibleScreenSessionIDs(
        for presentation: Presentation,
        in tree: SplitLayoutTree
    ) -> Set<TerminalSessionID> {
        let tabsByID = Dictionary(presentation.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A browser pane is a pane like any other, but its Session has no PTY:
        // there is nothing to subscribe, size, or recover for it, and only the
        // viewer page renders it (RFC 0022 §3).
        let sessionIDs = tree.leaves.compactMap { leaf -> TerminalSessionID? in
            guard let sessionID = tabsByID[leaf.tabID]?.sessionID else { return nil }
            return projection.session(id: sessionID)?.kind == .browser ? nil : sessionID
        }
        if sessionIDs.isEmpty,
           let fallback = presentation.tab?.sessionID,
           projection.session(id: fallback)?.kind != .browser {
            return [fallback]
        }
        return Set(sessionIDs)
    }

    func selectTabFromTabBar(_ tabID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else {
            selectTab(tabID, in: presentation)
            return
        }
        // A run in the bar is one arrangement, so selecting one of its panes
        // selects that arrangement: compact mode lists every arrangement's
        // panes, and a Tab from a background one has to swap the screen to the
        // arrangement it lives in rather than visit it alone.
        if hostPaneGroups(for: presentation).contains(where: {
            WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: tabID)
        }) {
            showPaneGroup(containing: tabID)
            selectTab(tabID, in: presentation)
            return
        }
        // A Session in no arrangement is a visit, not an exit. The stored
        // layout survives the visit, so returning to one of its panes restores
        // the split; the next action that reshapes the panel — a split, a drop,
        // a maximized pane — is what retires it.
        selectTab(tabID, in: presentation)
    }

    /// Renders the arrangement that holds a Tab, so a Session selected from
    /// anywhere — the bar, the sidebar, the command palette — shows the group
    /// it belongs to instead of being visited alone over another group.
    ///
    /// The group is looked up across the roster rather than in the current
    /// presentation, which may still describe the previous selection when this
    /// runs from a navigation change. A Tab in no arrangement is left alone:
    /// that is a visit, and the stored layout survives it.
    func showPaneGroup(containing tabID: String?) {
        guard let tabID,
              let group = projection.paneGroups.first(where: {
                  WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: tabID)
              }),
              let scope = paneGroupScopeKey(for: group) else { return }
        if activePaneGroupIDs[scope] != group.id.description {
            activePaneGroupIDs[scope] = group.id.description
            // Cache the group now on screen, so the scope's local layout
            // describes it rather than the group it replaced.
            adoptHostPaneGroups(projection.paneGroups)
        }
        if let item = WarrenDesktopPaneGroupMapping.tree(from: group).item(forTabID: tabID) {
            restoreZoom(unlessShowing: item.id, scope: scope)
            restoreFold(ifFolded: item.id, scope: scope)
            activePaneIDs[scope] = item.id
        }
    }

    func handleSelectPane(_ paneID: String, in presentation: Presentation, tree: SplitLayoutTree) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        // Selecting the pane that is already active is not a change. `selectTab`
        // drops the redundant dispatch; this only has to avoid rewriting the
        // remembered pane, which would make the next split forget the one the
        // user was working in.
        if activePaneIDs[scope] == paneID,
           let item = tree.item(for: paneID),
           navigation.selectedTabID == item.tabID {
            return
        }
        restoreZoom(unlessShowing: paneID, scope: scope)
        restoreFold(ifFolded: paneID, scope: scope)
        activePaneIDs[scope] = paneID
        if let item = tree.item(for: paneID) {
            selectTab(item.tabID, in: presentation)
        }
    }

    func handleSplitBelow(in presentation: Presentation) {
        handleSplit(axis: .vertical, in: presentation)
    }

    func handleSplitRight(in presentation: Presentation) {
        handleSplit(axis: .horizontal, in: presentation)
    }

    /// Splits the pane the user is working in, filling the new one with a
    /// Session the Host creates.
    ///
    /// The Session the user is looking at decides where the new pane goes. When
    /// that Session already has a pane, the split extends that pane in place.
    /// When it does not — a Session opened from the sidebar, or one the panel is
    /// showing on its own — it does not belong to the arrangement on screen, so
    /// the split opens a *new* arrangement around it instead of joining one the
    /// user is not looking at. The Session this request creates then splits that
    /// new arrangement, so the two panes land together and every arrangement
    /// already in the scope keeps its own shape.
    ///
    /// The one exception is a scope with no arrangement at all: there the lone
    /// pane *is* the scope's layout, so the split extends it as before.
    func handleSplit(axis: SplitAxis, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let openedTab = navigation.selectedTabID.flatMap { id in
            presentation.tabs.first { $0.id == id }
        }
        let groups = hostPaneGroups(for: presentation)
        // A Session shown on its own may belong to a background arrangement; if
        // it does, that arrangement is the one the split extends, so render it
        // before reading the layout.
        if let openedTab,
           let containing = groups.first(where: {
               WarrenDesktopPaneGroupMapping.tree(from: $0).contains(tabID: openedTab.id)
           }),
           activePaneGroupIDs[scope] != containing.id.description {
            activePaneGroupIDs[scope] = containing.id.description
        }
        let layout = scopeSplitTree(presentation: presentation)
        let activePaneID = currentActivePaneID(presentation: presentation, tree: layout)
        // A Session the layout does not hold is not in the arrangement on
        // screen. When the scope has one, the split opens a second arrangement
        // around the visited Session rather than folding it into a layout the
        // user is not looking at.
        let adoptsOpenedSession = openedTab.map { tab in
            tab.sessionID != nil && !layout.contains(tabID: tab.id)
        } ?? false
        let startsNewGroup = adoptsOpenedSession
            && openedTab?.sessionID != nil
            && !groups.isEmpty
        let isCreating = presentation.workspace.map {
            creatingSessionWorkspaceIDs.contains($0.id)
        } ?? false
        let local = splitTrees[scope]
        paneDiagnostic("pane_split_request", scope: scope, [
            "axis": axis.rawValue,
            "selected": Self.diagnosticTab(navigation.selectedTabID),
            "layout": Self.diagnosticTabs(layout.allTabIDs),
            "host": hostPaneGroup(for: presentation).map {
                Self.diagnosticTabs(WarrenDesktopPaneGroupMapping.tree(from: $0).allTabIDs)
            } ?? "none",
            "hostRevision": hostPaneGroup(for: presentation).map { String($0.revision) } ?? "none",
            "local": local.map { Self.diagnosticTabs($0.allTabIDs) } ?? "none",
            "editInFlight": String(local != nil && local != adoptedPaneTrees[scope]),
            "adoptsOpened": String(adoptsOpenedSession),
            "newGroup": String(startsNewGroup),
            "creating": String(isCreating),
            "pending": String(pendingSplits[scope] != nil),
        ])
        // A new arrangement starts at one pane around the visited Session; every
        // other split starts from the arrangement it extends.
        let baseCount = startsNewGroup ? 1 : layout.count
        let addedCount = (startsNewGroup || !adoptsOpenedSession) ? 1 : 2
        guard baseCount + addedCount <= SplitLayoutTree.maxPanes else {
            paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "paneLimit"])
            return
        }
        guard !isCreating, pendingSplits[scope] == nil else {
            paneDiagnostic("pane_split_dropped", scope: scope, [
                "reason": isCreating ? "creatingSession" : "splitPending",
            ])
            return
        }

        var tree = layout
        if startsNewGroup, let openedTab {
            // A fresh arrangement: the visited Session is its only pane so far.
            // The arrangement it is leaving stays in the roster, untouched.
            tree = WarrenDesktopSplitProjection.lonePane(tabID: openedTab.id)
            // Cached but not committed yet: the complete tree is written once the
            // Session this request creates has arrived, so the new group is
            // created with its final shape instead of in two competing writes.
            splitTrees[scope] = tree
        } else if adoptsOpenedSession, let openedTab {
            // The pane the layout already has an identity for is reused when the
            // Session is the one the panel draws alone, so adopting it does not
            // re-create the terminal the user is looking at.
            tree = tree.split(
                targetPaneID: activePaneID,
                newTabID: openedTab.id,
                axis: axis,
                placeAfter: true,
                newPaneID: SplitPaneItem.fallbackID(forTabID: openedTab.id)
            )
            guard tree.contains(tabID: openedTab.id) else {
                paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "adoptFailed"])
                return
            }
            setSplitTree(tree, for: scope)
        }

        let targetPaneID = openedTab.flatMap { tree.item(forTabID: $0.id)?.id }
            ?? activePaneID
        guard let targetItem = tree.item(for: targetPaneID),
              let targetTab = presentation.tabs.first(where: { $0.id == targetItem.tabID }),
              targetTab.sessionID != nil else {
            paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "noTarget"])
            return
        }
        activePaneIDs[scope] = targetPaneID

        let token = UUID()
        pendingSplits[scope] = PendingSplit(
            targetPaneID: targetPaneID,
            targetTabID: targetTab.id,
            token: token,
            axis: axis,
            createsNewGroup: startsNewGroup
        )
        if startsNewGroup, let openedTab {
            pendingNewGroupVisitTabIDs[scope] = openedTab.id
        }
        if let workspace = presentation.workspace {
            dispatch(.requestNewSession(workspace.id, token: token))
        } else {
            pendingSplits.removeValue(forKey: scope)
            pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
            return
        }

        // Creation is asynchronous and the roster may be delayed. Keep the
        // captured target alive only for a bounded interval; a failed request
        // must not make all future split commands inert.
        paneDiagnostic("pane_split_pending", scope: scope, [
            "target": Self.diagnosticTab(targetTab.id),
            "newGroup": String(startsNewGroup),
            "tree": Self.diagnosticTabs(tree.allTabIDs),
        ])
        let captured = pendingSplits[scope]
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard self.pendingSplits[scope] == captured else { return }
            self.pendingSplits.removeValue(forKey: scope)
            if captured?.createsNewGroup == true { self.discardUncommittedNewGroupEdit(scope) }
            self.paneDiagnostic("pane_split_dropped", scope: scope, ["reason": "timeout"])
        }
        reconcilePendingSplitsOnTick()
    }

    /// Reverts a split that opened a new arrangement but never wrote it, so a
    /// failed or timed-out request leaves the scope on the arrangement it was
    /// showing instead of a local edit the Host never received.
    func discardUncommittedNewGroupEdit(_ scope: String) {
        pendingNewGroupVisitTabIDs.removeValue(forKey: scope)
        if let adopted = adoptedPaneTrees[scope] {
            splitTrees[scope] = adopted
        } else {
            splitTrees.removeValue(forKey: scope)
        }
    }

    /// Re-runs the completion while a split is waiting for its Session.
    ///
    /// Called from a tick rather than from a change notification, and bounded by
    /// the pending itself: the moment the split lands, or the request times out,
    /// there is nothing left to retry.
    func reconcilePendingSplitsOnTick() {
        guard !pendingSplits.isEmpty else { return }
        reconcilePendingSplitMutations()
    }
    ///
    /// Closing is a Session command: the Host owns process lifetime, so the
    /// pane's Session is terminated rather than merely taken off screen. The
    /// scope then follows the Session list — a split collapses to its surviving
    /// pane, and the last pane leaves the Session list to choose what shows next
    /// Closes one Tab: the pane it owns, or the Session itself.
    ///
    /// A Tab that is a pane of the scope's layout closes as a pane — the layout
    /// loses that pane and the pane's Session ends with it. A Tab that is not a
    /// pane has none to close, so only its Session ends. That distinction is why
    /// a close is named by a Tab rather than by "the active pane": with the
    /// split on screen, a stray Tab's close control used to take a pane of the
    /// split with it, and a two-pane split read as if closing an unrelated
    /// Session had thrown the split away.
    ///
    /// `tabID` of nil means the selected Tab, which is what the keyboard
    /// shortcut asks for.
    func handleCloseTab(_ tabID: String?, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation),
              let targetTabID = tabID ?? navigation.selectedTabID else { return }
        if let item = scopeSplitTree(presentation: presentation).item(forTabID: targetTabID) {
            handleClosePane(paneID: item.id, in: presentation)
            return
        }
        // Not a pane: the Tab is its own Session, so that is all there is to
        // end. The layout keeps the pane focus it had.
        guard let sessionID = presentation.tabs
            .first(where: { $0.id == targetTabID })?.sessionID else { return }
        dispatch(.deleteSession(sessionID))
    }

    /// Closes every other pane of the layout and ends its Session, leaving this
    /// one alone.
    ///
    /// A Tab that is not a pane has no other panes to close, so the command is a
    /// no-op for one: it must never reshape a layout the Tab does not own.
    func handleCloseOtherTabs(_ tabID: String, in presentation: Presentation) {
        guard let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) else {
            return
        }
        handleCloseOtherPanes(paneID: item.id, in: presentation)
    }

    /// Closes every pane of one layout and ends the Sessions in them.
    ///
    /// A Tab that is not a pane stands for one Session and no pane, so only that
    /// Session ends and the layout is left alone.
    func handleCloseAllTabs(_ tabID: String, in presentation: Presentation) {
        if let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) {
            handleCloseAllPanes(paneID: item.id, in: presentation)
            return
        }
        guard let sessionID = presentation.tabs
            .first(where: { $0.id == tabID })?.sessionID else { return }
        dispatch(.deleteSession(sessionID))
    }

    /// (the next Session, or nothing when the workspace is now empty).
    ///
    /// The layout change applies immediately; deleting the Session still waits
    /// for the Host to confirm it, so a failed delete cannot hide a running
    /// process.
    func handleClosePane(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        // A close names the pane it applies to. The scope's layout owns the
        // panes, so the named pane decides which tree is being closed — and a
        // close that is not about the layout must leave it exactly as it was,
        // which is what the `shapesTheLayout` test below guards.
        let scopeTree = scopeSplitTree(presentation: presentation)
        let renderedTree = currentSplitTree(presentation: presentation)
        let tree = paneID.map { scopeTree.contains(paneID: $0) } == true ? scopeTree : renderedTree
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: tree)
        guard let item = tree.item(for: targetPaneID) else { return }
        let sessionID = presentation.tabs.first(where: { $0.id == item.tabID })?.sessionID
        let shapesTheLayout = scopeTree.contains(paneID: targetPaneID)

        if shapesTheLayout, let newTree = tree.remove(paneID: targetPaneID) {
            setSplitTree(newTree, for: scope)
            let survivorID = newTree.allPaneIDs.first
            activePaneIDs[scope] = survivorID
            if let survivorID, let survivor = newTree.item(for: survivorID) {
                selectTab(survivor.tabID, in: presentation)
            }
        } else if shapesTheLayout {
            // The last pane is gone. Drop the stored layout and selection so the
            // Session list decides what shows next; nothing is left to clear.
            splitTrees.removeValue(forKey: scope)
            activePaneIDs.removeValue(forKey: scope)
        }

        if let sessionID {
            dispatch(.deleteSession(sessionID))
        }
    }

    /// Closes every other pane of the layout and ends its Session, leaving this
    /// one alone.
    func handleCloseOtherPanes(paneID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let scopeTree = scopeSplitTree(presentation: presentation)
        guard scopeTree.contains(paneID: paneID),
              let item = scopeTree.item(for: paneID) else { return }
        let tree = scopeTree
        let targetPaneID = paneID
        let otherSessionIDs = tree.leaves
            .filter { $0.id != targetPaneID }
            .compactMap { leaf in presentation.tabs.first(where: { $0.id == leaf.tabID })?.sessionID }
        setSplitTree(.leaf(item), for: scope)
        activePaneIDs[scope] = item.id
        selectTab(item.tabID, in: presentation)
        for sessionID in otherSessionIDs {
            dispatch(.deleteSession(sessionID))
        }
    }

    /// Closes every pane of one layout and ends the Sessions in it.
    func handleCloseAllPanes(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let scopeTree = scopeSplitTree(presentation: presentation)
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: scopeTree)
        let sessionIDs = scopeTree.leaves.compactMap { leaf in
            presentation.tabs.first(where: { $0.id == leaf.tabID })?.sessionID
        }
        if scopeTree.contains(paneID: targetPaneID) {
            clearSelectedPane(for: scope)
        }
        for sessionID in sessionIDs {
            dispatch(.deleteSession(sessionID))
        }
    }

    func clearSelectedPane(for scope: String) {
        splitTrees.removeValue(forKey: scope)
        activePaneIDs.removeValue(forKey: scope)
        dispatch(.clearSelectedTab)
    }

    func handleMaximizePane(paneID: String? = nil, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.count > 1 else { return }
        let targetPaneID = paneID ?? currentActivePaneID(presentation: presentation, tree: tree)
        let newTree = tree.maximize(paneID: targetPaneID)
        setSplitTree(newTree, for: scope)
    }

    /// The pane a scope shows alone, while it is still one of the layout's.
    func zoomedPaneID(in tree: SplitLayoutTree, presentation: Presentation) -> String? {
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = zoomedPaneIDs[scope],
              tree.count > 1,
              tree.contains(paneID: paneID) else { return nil }
        return paneID
    }

    /// Shows one member alone, or restores the layout when it already is.
    func toggleZoom(tabID: String, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation),
              let item = scopeSplitTree(presentation: presentation).item(forTabID: tabID) else { return }
        if zoomedPaneIDs[scope] == item.id {
            zoomedPaneIDs.removeValue(forKey: scope)
            return
        }
        zoomedPaneIDs[scope] = item.id
        activePaneIDs[scope] = item.id
        selectTab(tabID, in: presentation)
    }

    /// The pane a scope shows as a rail, while it can still fold: it is one
    /// of the layout's leaves, beside a divider, and not the pane being worked
    /// in. A folded pane's terminal is parked out of sight, so the selected
    /// pane is never drawn folded whatever path selected it.
    func foldedPaneID(in tree: SplitLayoutTree, presentation: Presentation) -> String? {
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = foldedPaneIDs[scope],
              tree.count > 1,
              tree.canFold(paneID: paneID),
              currentActivePaneID(presentation: presentation, tree: tree) != paneID else { return nil }
        return paneID
    }

    /// Folds a pane into a rail.
    ///
    /// The drag that folds held the divider at the minimum on its way past it,
    /// and each step was a ratio the Host stored. Putting back the ratio the
    /// drag started from is what lets the rail restore the balance the pane
    /// had, and leaves other devices — which never see the fold — with the
    /// layout as it was. The keyboard moves to another pane, because the
    /// folded one's terminal is out of sight.
    func handleFoldPane(
        _ paneID: String,
        splitPath: [Bool],
        restoreRatio: Double?,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        guard tree.count > 1, tree.canFold(paneID: paneID) else { return }
        if let restoreRatio {
            setSplitTree(tree.updateRatio(path: splitPath, ratio: restoreRatio), for: scope)
        }
        foldedPaneIDs[scope] = paneID
        guard currentActivePaneID(presentation: presentation, tree: tree) == paneID,
              let nextID = tree.nextPaneID(after: paneID, forward: true),
              nextID != paneID,
              let next = tree.item(for: nextID) else { return }
        activePaneIDs[scope] = nextID
        selectTab(next.tabID, in: presentation)
    }

    /// Selecting a folded pane brings it back.
    func restoreFold(ifFolded paneID: String, scope: String) {
        guard foldedPaneIDs[scope] == paneID else { return }
        foldedPaneIDs.removeValue(forKey: scope)
    }

    /// A folded pane whose Session became the selection — from the sidebar, a
    /// shortcut, or anything else that does not pass through a pane — is
    /// unfolded for good, so selecting another pane later does not fold it
    /// again behind the user's back.
    func releaseFoldOfSelectedPane() {
        let presentation = makePresentation()
        guard let scope = currentScopeKey(presentation: presentation),
              let paneID = foldedPaneIDs[scope] else { return }
        // The scope's layout rather than the one on screen: a visit to a
        // Session outside the layout leaves the layout, and its fold, intact.
        let tree = scopeSplitTree(presentation: presentation)
        guard let item = tree.item(for: paneID) else {
            foldedPaneIDs.removeValue(forKey: scope)
            return
        }
        if navigation.selectedTabID == item.tabID {
            foldedPaneIDs.removeValue(forKey: scope)
        }
    }

    /// Focusing another pane of a zoomed layout brings the layout back, so the
    /// pane that was asked for is on screen.
    func restoreZoom(unlessShowing paneID: String, scope: String) {
        guard let zoomed = zoomedPaneIDs[scope], zoomed != paneID else { return }
        zoomedPaneIDs.removeValue(forKey: scope)
    }

    /// Dissolves the group: the focused pane stays on screen and every other
    /// member becomes a Tab of its own. No Session ends.
    func handleUngroup(in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1 else { return }
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        let kept = tree.maximize(paneID: activePaneID)
        zoomedPaneIDs.removeValue(forKey: scope)
        setSplitTree(kept, for: scope)
        if let item = kept.item(for: activePaneID) {
            activePaneIDs[scope] = item.id
            selectTab(item.tabID, in: presentation)
        }
    }

    /// A Tab dropped on the group pill joins the group beside its focused pane.
    func handleMergeIntoGroup(_ tabID: String, in presentation: Presentation) {
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1, !tree.contains(tabID: tabID) else { return }
        handleSplitDrop(
            targetPaneID: currentActivePaneID(presentation: presentation, tree: tree),
            droppedTabID: tabID,
            target: .right,
            in: presentation
        )
    }

    /// A member dragged out of the group onto the strip becomes a Tab of its
    /// own: its pane leaves the layout and its Session keeps running.
    func detachPaneLeavingLayout(
        _ tabID: String,
        before destinationTabID: String?,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        guard tree.count > 1,
              let item = tree.item(forTabID: tabID),
              destinationTabID.map({ !tree.contains(tabID: $0) }) ?? true,
              let remaining = tree.remove(paneID: item.id) else { return }
        if zoomedPaneIDs[scope] == item.id {
            zoomedPaneIDs.removeValue(forKey: scope)
        }
        setSplitTree(remaining, for: scope)
        if activePaneIDs[scope] == item.id {
            activePaneIDs[scope] = remaining.allPaneIDs.first
        }
    }

    func handleOtherPane(in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let activePaneID = currentActivePaneID(presentation: presentation, tree: tree)
        if let nextID = tree.nextPaneID(after: activePaneID, forward: true) {
            activePaneIDs[scope] = nextID
            if let item = tree.item(for: nextID) {
                selectTab(item.tabID, in: presentation)
            }
        }
    }

    /// Places a dragged Tab into the scope's layout.
    ///
    /// The drop is a split command, so it acts on the layout even while the
    /// panel is showing a Session that is only being visited: the drop markers
    /// belong to whatever pane is on screen, and a marker that belongs to a
    /// visit cannot name a place in a layout that is not on screen. When the
    /// named pane is not part of the layout, the Tab joins at the pane the user
    /// was last working in — the same target a split command uses.
    func handleSplitDrop(
        targetPaneID: String,
        droppedTabID: String,
        target: SplitDropTarget,
        in presentation: Presentation
    ) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = scopeSplitTree(presentation: presentation)
        let resolvedPaneID = tree.contains(paneID: targetPaneID)
            ? targetPaneID
            : currentActivePaneID(presentation: presentation, tree: tree)
        guard tree.contains(paneID: resolvedPaneID),
              let droppedTab = presentation.tabs.first(where: { $0.id == droppedTabID }),
              droppedTab.sessionID != nil,
              projection.tabs.contains(where: { $0.id == droppedTabID }),
              (presentation.workspace.map { projection.workspaceID(forTabID: droppedTabID) == $0.id }
                  ?? false),
              pendingSplits[scope] == nil else { return }
        if tree.contains(tabID: droppedTabID), tree.item(for: resolvedPaneID)?.tabID != droppedTabID {
            // Moving a tab between existing panes needs an explicit reorder
            // operation. Rejecting it here prevents duplicate Session IDs.
            return
        }
        let newTree: SplitLayoutTree
        switch target {
        case .top:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: false)
        case .bottom:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .vertical, placeAfter: true)
        case .left:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: false)
        case .right:
            newTree = tree.split(targetPaneID: resolvedPaneID, newTabID: droppedTabID, axis: .horizontal, placeAfter: true)
        case .center:
            newTree = tree.replace(paneID: resolvedPaneID, withTabID: droppedTabID)
        }
        setSplitTree(newTree, for: scope)
        if let item = newTree.item(forTabID: droppedTabID) {
            activePaneIDs[scope] = item.id
            selectTab(droppedTabID, in: presentation)
        }
    }

    /// Applies asynchronous split/close requests only after the Host roster
    /// confirms the corresponding Session transition. This keeps the layout
    /// tree and process lifecycle in lockstep even when a request races a
    /// roster update or another client.
    func reconcilePendingSplitMutations() {
        let presentation = makePresentation()

        for (scope, pending) in Array(pendingSplits) {
            guard currentScopeKey(presentation: presentation) == scope else { continue }
            // The request named a pane of the scope's layout. Any divider the
            // user moved while the Session was starting survives, because the
            // layout itself is the base — and if the pane is gone, the user has
            // reshaped the split since, so the request is dropped rather than
            // applied to whatever happens to be on screen now.
            //
            // The pane is named by the Tab it holds, not by its pane ID.
            // Adopting a visited Session creates that pane under a local ID,
            // and the Host's echo of the adoption replaces the ID before this
            // Session arrives; matching only the ID dropped the request and
            // left the split at the adopted pair with no new pane.
            let tree = currentSplitTree(presentation: presentation)
            let targetPaneID = tree.item(forTabID: pending.targetTabID)?.id
                ?? (tree.contains(paneID: pending.targetPaneID) ? pending.targetPaneID : nil)
            guard let targetPaneID else {
                pendingSplits.removeValue(forKey: scope)
                if pending.createsNewGroup { discardUncommittedNewGroupEdit(scope) }
                paneDiagnostic("pane_split_dropped", scope: scope, [
                    "reason": "targetGone",
                    "target": Self.diagnosticTab(pending.targetTabID),
                    "tree": Self.diagnosticTabs(tree.allTabIDs),
                    "selected": Self.diagnosticTab(navigation.selectedTabID),
                ])
                continue
            }
            // The Session this request created is the one the model reported
            // under its token; any other Session that appeared in the scope
            // meanwhile belongs to another actor. The pane lands as soon as that
            // Session is in the roster: waiting for its selection delayed the
            // split behind a render pass that could be seconds late, and the
            // Session's pane is what its terminal attach is waiting for.
            guard let createdSessionID = createdSessionIDsByToken[pending.token],
                  let newTab = presentation.tabs.first(where: { $0.sessionID == createdSessionID }) else {
                // The create has not answered, or the roster has not published
                // the Session yet. Keep the pending intent; a failed request is
                // released by the timeout below.
                continue
            }
            let newTree = tree.split(
                targetPaneID: targetPaneID,
                newTabID: newTab.id,
                axis: pending.axis,
                placeAfter: true
            )
            guard newTree.count == tree.count + 1 else {
                pendingSplits.removeValue(forKey: scope)
                if pending.createsNewGroup { discardUncommittedNewGroupEdit(scope) }
                paneDiagnostic("pane_split_dropped", scope: scope, [
                    "reason": "splitRejected",
                    "new": Self.diagnosticTab(newTab.id),
                    "tree": Self.diagnosticTabs(tree.allTabIDs),
                ])
                continue
            }
            paneDiagnostic("pane_split_applied", scope: scope, [
                "new": Self.diagnosticTab(newTab.id),
                "newGroup": String(pending.createsNewGroup),
                "tree": Self.diagnosticTabs(newTree.allTabIDs),
            ])
            // A request that opened a new arrangement writes it as a new group;
            // the arrangement on screen keeps its own shape.
            setSplitTree(newTree, for: scope, asNewGroup: pending.createsNewGroup)
            if let item = newTree.item(forTabID: newTab.id) {
                activePaneIDs[scope] = item.id
                selectTab(newTab.id, in: presentation)
            }
            pendingSplits.removeValue(forKey: scope)
        }
    }

    func handleResizeSplit(splitPath: [Bool], ratio: Double, in presentation: Presentation) {
        guard let scope = currentScopeKey(presentation: presentation) else { return }
        let tree = currentSplitTree(presentation: presentation)
        let newTree = tree.updateRatio(path: splitPath, ratio: ratio)
        setSplitTree(newTree, for: scope)
    }

    /// Selects a Tab.
    ///
    /// Re-selecting what is already selected is not navigation: the dispatch
    /// reaches the model as a selection, which re-presents the Session and
    /// replaces the pane's grid, so a full-screen TUI repaints end to end for a
    /// click that changed nothing. A click inside a pane — the whole pane carries
    /// the tap gesture, the terminal body included — and a click on the already
    /// selected chip both arrive here, which is why that repaint was easy to
    /// trigger without doing anything. Selecting a Tab no longer has to leave an
    /// editor mode on the way, so a click on the selected Tab now dispatches
    /// nothing at all.
    func selectTab(_ tabID: String, in presentation: Presentation) {
        guard navigation.selectedTabID != tabID else { return }
        dispatch(.selectTab(tabID))
    }

}
