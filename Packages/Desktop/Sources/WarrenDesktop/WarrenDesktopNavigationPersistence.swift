import Foundation
import WarrenDomain

/// Device-local tab ordering for each resource scope. IDs are stored as raw
/// strings so a layout can survive a reconnect before the remote roster has
/// been decoded, while callers still validate them against their domain type.
public struct WarrenDesktopTabOrders: Codable, Hashable, Sendable {
    public var workspace: [String: [String]]
    public var terminalGroup: [String: [String]]

    public init(
        workspace: [String: [String]] = [:],
        terminalGroup: [String: [String]] = [:]
    ) {
        self.workspace = workspace
        self.terminalGroup = terminalGroup
    }
}

/// Device-local persistence for foreground navigation and scope-local tab
/// ordering.
///
/// Host state owns projects, workspaces, and sessions; this remembers which
/// scope/session the window was showing and how its tabs were arranged so a
/// relaunch can restore the same view instead of falling back to roster order.
public enum WarrenDesktopNavigationPersistence {
    private static let selectionKey = "warren.desktop.navigation.selection"
    private static let selectedTabIDKey = "warren.desktop.navigation.selectedTabID"
    private static let memoryKey = "warren.desktop.navigation.memory"
    private static let tabOrdersKey = "warren.desktop.navigation.tabOrders"
    private static let scopedNavigationKey = "warren.desktop.navigation.scoped"
    private static let scopedTabOrdersKey = "warren.desktop.navigation.tabOrders.scoped"
    private static let navigationMigrationScopeKey = "warren.desktop.navigation.legacyMigrationScope"
    private static let tabOrdersMigrationScopeKey = "warren.desktop.navigation.tabOrders.legacyMigrationScope"

    private struct PersistedNavigationState: Codable {
        let selection: String?
        let selectedTabID: String?
        let memory: WarrenDesktopNavigationMemory

        init(_ state: WarrenDesktopNavigationState) {
            selection = state.selection?.serializedKey
            selectedTabID = state.selectedTabID
            memory = state.memory
        }

        var state: WarrenDesktopNavigationState {
            WarrenDesktopNavigationState(
                selection: selection.flatMap(WarrenDesktopSidebarSelection.init(serializedKey:)),
                selectedTabID: selectedTabID,
                memory: memory
            )
        }
    }

    /// Restores navigation for one Endpoint scope. The scoped store keeps
    /// equal Project/Workspace UUIDs on different Hosts from sharing memory.
    /// A legacy unscoped value is migrated once to the first requested scope.
    public static func restore(
        scope: String,
        from defaults: UserDefaults = .standard
    ) -> WarrenDesktopNavigationState? {
        let scope = normalizedScope(scope)
        var values = decodeNavigationScopes(from: defaults)
        if let value = values[scope] {
            return value.state
        }
        guard defaults.string(forKey: navigationMigrationScopeKey) == nil,
              let legacy = restoreLegacy(from: defaults) else {
            return nil
        }
        values[scope] = PersistedNavigationState(legacy)
        encodeNavigationScopes(values, to: defaults)
        defaults.set(scope, forKey: navigationMigrationScopeKey)
        return legacy
    }

    /// Saves navigation for one Endpoint scope without touching the legacy
    /// keys used by older Desktop builds.
    public static func save(
        _ state: WarrenDesktopNavigationState,
        scope: String,
        to defaults: UserDefaults = .standard
    ) {
        var values = decodeNavigationScopes(from: defaults)
        values[normalizedScope(scope)] = PersistedNavigationState(state)
        encodeNavigationScopes(values, to: defaults)
        if defaults.string(forKey: navigationMigrationScopeKey) == nil {
            defaults.set(normalizedScope(scope), forKey: navigationMigrationScopeKey)
        }
    }

    public static func restore(from defaults: UserDefaults = .standard) -> WarrenDesktopNavigationState? {
        restoreLegacy(from: defaults)
    }

    private static func restoreLegacy(
        from defaults: UserDefaults
    ) -> WarrenDesktopNavigationState? {
        let memory = restoreMemory(from: defaults)
        guard let rawSelection = defaults.string(forKey: selectionKey),
              !rawSelection.isEmpty else {
            return memory.isEmpty
                ? nil
                : WarrenDesktopNavigationState(memory: memory)
        }
        guard let selection = WarrenDesktopSidebarSelection(serializedKey: rawSelection) else {
            return nil
        }

        return WarrenDesktopNavigationState(
            selection: selection,
            selectedTabID: defaults.string(forKey: selectedTabIDKey),
            memory: memory
        )
    }

    public static func save(
        _ state: WarrenDesktopNavigationState,
        to defaults: UserDefaults = .standard
    ) {
        if let selection = state.selection {
            defaults.set(selection.serializedKey, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
        if let selectedTabID = state.selectedTabID {
            defaults.set(selectedTabID, forKey: selectedTabIDKey)
        } else {
            defaults.removeObject(forKey: selectedTabIDKey)
        }
        guard let data = try? JSONEncoder().encode(state.memory) else { return }
        defaults.set(data, forKey: memoryKey)
    }

    public static func restoreTabOrders(
        scope: String,
        from defaults: UserDefaults = .standard
    ) -> WarrenDesktopTabOrders {
        let scope = normalizedScope(scope)
        var values = decodeTabOrderScopes(from: defaults)
        if let value = values[scope] {
            return value
        }
        guard defaults.string(forKey: tabOrdersMigrationScopeKey) == nil else {
            return WarrenDesktopTabOrders()
        }
        let legacy = restoreTabOrders(from: defaults)
        guard !legacy.workspace.isEmpty || !legacy.terminalGroup.isEmpty else {
            return legacy
        }
        values[scope] = legacy
        encodeTabOrderScopes(values, to: defaults)
        defaults.set(scope, forKey: tabOrdersMigrationScopeKey)
        return legacy
    }

    public static func saveTabOrders(
        _ orders: WarrenDesktopTabOrders,
        scope: String,
        to defaults: UserDefaults = .standard
    ) {
        var values = decodeTabOrderScopes(from: defaults)
        values[normalizedScope(scope)] = orders
        encodeTabOrderScopes(values, to: defaults)
        if defaults.string(forKey: tabOrdersMigrationScopeKey) == nil {
            defaults.set(normalizedScope(scope), forKey: tabOrdersMigrationScopeKey)
        }
    }

    private static func restoreMemory(
        from defaults: UserDefaults
    ) -> WarrenDesktopNavigationMemory {
        guard let data = defaults.data(forKey: memoryKey),
              let memory = try? JSONDecoder().decode(
                  WarrenDesktopNavigationMemory.self,
                  from: data
              ) else {
            return WarrenDesktopNavigationMemory()
        }
        return memory
    }

    public static func restoreTabOrders(
        from defaults: UserDefaults = .standard
    ) -> WarrenDesktopTabOrders {
        guard let data = defaults.data(forKey: tabOrdersKey),
              let orders = try? JSONDecoder().decode(WarrenDesktopTabOrders.self, from: data) else {
            return WarrenDesktopTabOrders()
        }
        return orders
    }

    public static func saveTabOrders(
        _ orders: WarrenDesktopTabOrders,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(orders) else { return }
        defaults.set(data, forKey: tabOrdersKey)
    }

    private static func normalizedScope(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "local" : trimmed
    }

    private static func decodeNavigationScopes(
        from defaults: UserDefaults
    ) -> [String: PersistedNavigationState] {
        guard let data = defaults.data(forKey: scopedNavigationKey),
              let values = try? JSONDecoder().decode(
                  [String: PersistedNavigationState].self,
                  from: data
              ) else {
            return [:]
        }
        return values
    }

    private static func encodeNavigationScopes(
        _ values: [String: PersistedNavigationState],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: scopedNavigationKey)
    }

    private static func decodeTabOrderScopes(
        from defaults: UserDefaults
    ) -> [String: WarrenDesktopTabOrders] {
        guard let data = defaults.data(forKey: scopedTabOrdersKey),
              let values = try? JSONDecoder().decode(
                  [String: WarrenDesktopTabOrders].self,
                  from: data
              ) else {
            return [:]
        }
        return values
    }

    private static func encodeTabOrderScopes(
        _ values: [String: WarrenDesktopTabOrders],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: scopedTabOrdersKey)
    }
}
