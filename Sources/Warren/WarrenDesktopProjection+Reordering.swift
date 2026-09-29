import WarrenDesktop

extension WarrenDesktopProjection {
    /// A copy with the scope's Tabs in a new order.
    ///
    /// These builders spell out every stored property, so a field added to the
    /// projection has to be added here too. `paneGroups` and `unreadNoticeCount`
    /// were each lost this way; the tests next to this helper are what keep the
    /// next field from joining them.
    func reorderingTabs(tabID: String, accordingTo orderedIDs: [String]) -> Self {
        let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var orderedTabs = orderedIDs.compactMap { tabsByID[$0] }.makeIterator()
        let reorderedTabs = tabs.map { tab in
            let sameScope = tabWorkspaceIDs[tab.id] != nil
                ? tabWorkspaceIDs[tab.id] == tabWorkspaceIDs[tabID]
                : tabTerminalGroupIDs[tab.id] == tabTerminalGroupIDs[tabID]
            return sameScope ? (orderedTabs.next() ?? tab) : tab
        }
        return Self(
            host: host,
            groups: groups,
            tasks: taskGroups.map(\.task),
            sessions: sessions,
            tabs: reorderedTabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: connectionState,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs,
            paneGroups: paneGroups,
            unreadNoticeCount: unreadNoticeCount
        )
    }

    /// A copy that reports a different connection state.
    func withConnectionState(_ state: WarrenDesktopConnectionState) -> Self {
        Self(
            host: host,
            groups: groups,
            tasks: taskGroups.map(\.task),
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaceIDs,
            tabWorkspaceIDs: tabWorkspaceIDs,
            connectionState: state,
            terminalGroups: terminalGroups,
            sessionTerminalGroupIDs: sessionTerminalGroupIDs,
            tabTerminalGroupIDs: tabTerminalGroupIDs,
            paneGroups: paneGroups,
            unreadNoticeCount: unreadNoticeCount
        )
    }

}
